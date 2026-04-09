#!/usr/bin/env bash
# agent-flow-workflow-helpers.sh — Shared functions for agent-flow sync workflows.
# This file is sourced (not executed). Contains only function definitions.
# Do NOT add set -euo pipefail or top-level code.

# Redact SYNC_TOKEN from stdin. Passes through unchanged if token empty/unset.
# Uses Python str.replace() for literal string substitution (no regex metachar issues).
redact_token() {
  if [[ -n "${SYNC_TOKEN:-}" ]]; then
    python3 -c "import sys,os; t=os.environ['SYNC_TOKEN']; [print(l.replace(t,'***'),end='') for l in sys.stdin]"
  else
    cat
  fi
}

# Check for sync loop by looking for sync markers on the last commit.
# Outputs key=value pairs: skip=true/false and origin_repo=<value>
#
# Detection layers:
#   1. Agent-Flow-Sync-Origin trailer in commit body (direct pushes)
#   2. Trailer in HEAD^2 commit body (merge commits)
#   3. GitHub API: "agent-flow-sync" label on the PR (squash merges)
#      Requires GITHUB_TOKEN and GITHUB_REPOSITORY env vars.
#      Extracts origin_repo from Agent-Flow-Sync-Origin in the PR body.
check_sync_loop() {
  local commit_msg
  commit_msg=$(git log -1 --format=%B HEAD 2>/dev/null) || {
    echo "skip=false"
    echo "origin_repo="
    return 0
  }

  # Layer 1: check trailer in HEAD commit body (direct pushes)
  local origin
  origin=$(echo "$commit_msg" | grep "Agent-Flow-Sync-Origin:" | awk '{print $2}' | tr -d ' ' || true)

  # Layer 2: check trailer in HEAD^2 (merge commits)
  if [[ -z "$origin" ]]; then
    local parent_count
    parent_count=$(git log -1 --format=%P HEAD 2>/dev/null | wc -w | tr -d ' ')
    if [[ "$parent_count" -gt 1 ]]; then
      origin=$(git log -1 --format=%B HEAD^2 2>/dev/null | grep "Agent-Flow-Sync-Origin:" | awk '{print $2}' | tr -d ' ' || true)
    fi
  fi

  # Layer 3: query GitHub API for the "agent-flow-sync" PR label
  # This survives all merge strategies (squash, merge, rebase).
  if [[ -z "$origin" && -n "${GITHUB_TOKEN:-}" && -n "${GITHUB_REPOSITORY:-}" ]]; then
    local subject pr_number
    subject=$(echo "$commit_msg" | head -1)
    # GitHub appends (#N) to squash/merge commit subjects
    if [[ "$subject" =~ \(#([0-9]+)\) ]]; then
      pr_number="${BASH_REMATCH[1]}"
      local pr_json
      pr_json=$(curl -sf \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/${GITHUB_REPOSITORY}/pulls/${pr_number}" 2>/dev/null || true)
      if [[ -n "$pr_json" ]]; then
        local has_label
        has_label=$(echo "$pr_json" | jq -r '[.labels[].name] | any(. == "agent-flow-sync")' 2>/dev/null || echo "false")
        if [[ "$has_label" == "true" ]]; then
          # Extract origin from Agent-Flow-Sync-Origin in the PR body
          origin=$(echo "$pr_json" | jq -r '.body // ""' 2>/dev/null \
            | grep "Agent-Flow-Sync-Origin:" | awk '{print $2}' | tr -d ' ' || true)
          # Label confirms it's a sync PR even if origin can't be parsed
          [[ -z "$origin" ]] && origin="unknown"
        fi
      fi
    fi
  fi

  if [[ -n "$origin" ]]; then
    echo "skip=true"
    echo "origin_repo=$origin"
  else
    echo "skip=false"
    echo "origin_repo="
  fi
}

# Check if current repo is the source repo from manifest.
# Args: $1 = current github.repository value
# Outputs: skip=false if IS source (should run downstream), skip=true if NOT source
check_source_identity() {
  local current_repo="$1"
  local source_repo
  source_repo=$(parse_source_repo) || return 1

  if [[ "$current_repo" == "$source_repo" ]]; then
    echo "skip=false"
  else
    echo "skip=true"
  fi
}

# Read enabled target repos from manifest as JSON array.
# Requires: python3 with pyyaml
read_targets() {
  local manifest=".claude-agent-flow/repo-sync-manifest.yml"

  if [[ ! -f "$manifest" ]]; then
    echo "ERROR: manifest not found at $manifest" >&2
    return 1
  fi

  MANIFEST_PATH="$manifest" python3 -c "
import yaml, json, sys, os
try:
    with open(os.environ['MANIFEST_PATH']) as f:
        manifest = yaml.safe_load(f)
    targets = [t['repo'] for t in manifest.get('targets', []) if t.get('enabled', True)]
    print(json.dumps(targets))
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)
" || {
    # Fallback if python3/pyyaml unavailable — stderr already shown above
    echo "[]"
    return 1
  }
}

# Filter out .claude-agent-flow/sync-state.json from staged changed files.
# Args: $1 = newline-separated list of changed file paths
# Outputs: filtered list (without sync-state.json), mirrors downstream workflow lines 211-212.
detect_real_changes() {
  local changed_files="$1"
  echo "$changed_files" | grep -v '^\.claude-agent-flow/sync-state\.json$' | grep -v '^[[:space:]]*$' || true
}

# Extract source_repo value from manifest.
parse_source_repo() {
  local manifest=".claude-agent-flow/repo-sync-manifest.yml"

  if [[ ! -f "$manifest" ]]; then
    echo "ERROR: manifest not found at $manifest" >&2
    return 1
  fi

  local repo
  repo=$(grep '^source_repo:' "$manifest" | sed 's/^source_repo:[[:space:]]*//' | sed 's/^"//;s/"$//' | sed 's/[[:space:]]*$//')

  if [[ -z "$repo" ]]; then
    echo "ERROR: source_repo not found in manifest" >&2
    return 1
  fi

  echo "$repo"
}

# List managed file paths from manifest, expanding globs recursively.
# Args:
#   --include-merge            Also include ALL merge_files paths (used by downstream)
#   --include-upstream-merge   Include only upstream-eligible merge_files
#                              (json-deep-merge, section-patch strategies)
# Outputs: newline-separated list of file paths (deduplicated, sorted)
# Requires: python3 with pyyaml
list_managed_paths() {
  local include_merge=false
  local include_upstream_merge=false
  if [[ "${1:-}" == "--include-merge" ]]; then
    include_merge=true
  elif [[ "${1:-}" == "--include-upstream-merge" ]]; then
    include_upstream_merge=true
  fi

  local manifest=".claude-agent-flow/repo-sync-manifest.yml"
  if [[ ! -f "$manifest" ]]; then
    echo "ERROR: manifest not found at $manifest" >&2
    return 1
  fi

  INCLUDE_MERGE="$include_merge" INCLUDE_UPSTREAM_MERGE="$include_upstream_merge" python3 -c "
import yaml, glob, os

with open('.claude-agent-flow/repo-sync-manifest.yml') as f:
    manifest = yaml.safe_load(f)

paths = []
for entry in manifest.get('managed_files', []):
    if isinstance(entry, str):
        expanded = glob.glob(entry, recursive=True)
        if expanded:
            for p in expanded:
                if os.path.isdir(p):
                    # Recurse into directories to get actual files
                    for root, dirs, files in os.walk(p):
                        for f in files:
                            paths.append(os.path.join(root, f))
                else:
                    paths.append(p)
        else:
            # Glob matched nothing — skip rather than emit raw pattern
            pass

if os.environ.get('INCLUDE_MERGE') == 'true':
    # Include ALL merge_files paths (downstream needs all strategies)
    for entry in manifest.get('merge_files', []):
        if isinstance(entry, dict) and 'path' in entry:
            paths.append(entry['path'])
elif os.environ.get('INCLUDE_UPSTREAM_MERGE') == 'true':
    # Include only upstream-eligible merge_files (reverse-merge strategies)
    upstream_strategies = {'json-deep-merge', 'section-patch'}
    for entry in manifest.get('merge_files', []):
        if isinstance(entry, dict) and entry.get('strategy') in upstream_strategies:
            paths.append(entry['path'])

# Resolve vendored skills from skills-filter.yaml (vendored_skills_source)
filter_path = manifest.get('vendored_skills_source', '')
if filter_path and not os.path.isabs(filter_path) and os.path.isfile(filter_path):
    resolved = os.path.realpath(filter_path)
    cwd = os.path.realpath('.')
    try:
        contained = os.path.commonpath([resolved, cwd]) == cwd
    except ValueError:
        contained = False
    if contained:
        with open(resolved) as sf:
            skills_filter = yaml.safe_load(sf)
        if not isinstance(skills_filter, dict):
            skills_filter = {}
        import re
        for skill_name in skills_filter.get('included', []):
            if not isinstance(skill_name, str) or not re.match(r'^[a-zA-Z0-9][a-zA-Z0-9._-]*$', skill_name):
                continue
            skill_dir = f'.claude/skills/{skill_name}'
            if os.path.isdir(skill_dir):
                for root, dirs, files in os.walk(skill_dir):
                    for f in files:
                        paths.append(os.path.join(root, f))

for p in sorted(set(paths)):
    print(p)
" || { echo "ERROR: Failed to parse manifest" >&2; return 1; }
}

# Validate required and optional secret env vars.
# Args:
#   $1 = newline-delimited required secret env var names
#   $2 = newline-delimited optional secret env var names (can be empty)
#   $3 = workflow display name for Job Summary heading
# Returns 1 if any required secret is missing, 0 otherwise.
validate_secrets() {
  local required_names="$1"
  local optional_names="$2"
  local workflow_name="$3"
  local missing_required=()
  local missing_optional=()

  # Check required secrets
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    # GitHub Actions passes unconfigured secrets as empty strings, so empty == missing
    if [[ -z "${!name}" ]]; then
      echo "::error title=Missing secret::Required secret ${name} is not configured. See repo setup docs for instructions."
      missing_required+=("$name")
    fi
  done < <(printf '%s\n' "$required_names")

  # Check optional secrets
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if [[ -z "${!name}" ]]; then
      echo "::warning title=Missing secret::Optional secret ${name} is not configured. Functionality that depends on it will be skipped."
      missing_optional+=("$name")
    fi
  done < <(printf '%s\n' "$optional_names")

  # Write Job Summary if any required secrets are missing
  if [[ "${#missing_required[@]}" -gt 0 ]]; then
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
      {
        echo "## ${workflow_name}: Missing Required Secrets"
        echo ""
        echo "### Required (missing)"
        for name in "${missing_required[@]}"; do
          echo "- \`${name}\`"
        done
        if [[ "${#missing_optional[@]}" -gt 0 ]]; then
          echo ""
          echo "### Optional (missing)"
          for name in "${missing_optional[@]}"; do
            echo "- \`${name}\`"
          done
        fi
        echo ""
        echo "See setup instructions: ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/blob/main/.claude-agent-flow/docs/agent-flow-repo-setup.md"
      } >> "$GITHUB_STEP_SUMMARY"
    fi
    return 1
  fi

  return 0
}
