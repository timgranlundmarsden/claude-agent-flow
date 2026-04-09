#!/usr/bin/env bash
# repo-sync-files.sh — Core sync engine for repo-to-repo sync
#
# Reads .claude-agent-flow/repo-sync-manifest.yml and applies file sync strategies from a source
# directory to a target directory.
#
# Usage: repo-sync-files.sh <source-dir> <target-dir> [--project-name "Name"]
#
# Strategies:
#   managed_files (copy): rsync/cp from source to target (overwrite)
#     - Supports glob patterns (expanded with shell globbing)
#     - Always skips sync-state.json by convention
#   merge_files:
#     - json-deep-merge: merge-settings-json.sh (for settings.json, .mcp.json)
#     - section-patch: patch-claude-md.sh
#     - append-missing: append lines not already present (.gitignore, .gitattributes)
#     - template: copy with variable substitution
#     - orchestrator: source-based dispatcher (session-start.sh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR=""
TARGET_DIR=""
PROJECT_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-name) PROJECT_NAME="$2"; shift 2 ;;
    *) if [[ -z "$SOURCE_DIR" ]]; then SOURCE_DIR="$1"; elif [[ -z "$TARGET_DIR" ]]; then TARGET_DIR="$1"; fi; shift ;;
  esac
done

if [[ -z "$SOURCE_DIR" || -z "$TARGET_DIR" ]]; then
  echo "Usage: $0 <source-dir> <target-dir> [--project-name \"Name\"]" >&2
  exit 1
fi

MANIFEST="$SOURCE_DIR/.claude-agent-flow/repo-sync-manifest.yml"
if [[ ! -f "$MANIFEST" ]]; then
  echo "Error: Manifest not found at $MANIFEST" >&2
  exit 1
fi

# Simple YAML parser — extracts list items under a key
# Usage: yaml_list <file> <key>
yaml_list() {
  local file="$1" key="$2"
  awk -v key="$key:" '
    index($0, key) == 1 {found=1; next}
    found && /^[^ ]/ {found=0}
    found && /^  - / {gsub(/^  - /, ""); gsub(/"/, ""); sub(/  #.*/, ""); print}  # TWO-space heuristic: strips "  # comment" but preserves " #tag" in values
  ' "$file"
}

# Check if a path should be skipped by convention
is_skipped() {
  local check="$1"
  # Always skip sync-state.json — local metadata, not a sync target
  [[ "$check" == ".claude-agent-flow/sync-state.json" ]] && return 0
  [[ "$check" == *"/sync-state.json" ]] && return 0
  # Skip external-review-config.repo.yml — optional repo-specific config, not synced
  [[ "$check" == "external-review-config.repo.yml" ]] && return 0
  return 1
}

# ── Step 1: Copy managed files (with glob expansion) ──
# Note: build.md, plan.md, review.md, rebase.md are intentional alias files
# listed in the manifest — they are NOT legacy orphans.
echo "Syncing managed files..."
while IFS= read -r pattern; do
  [[ -z "$pattern" ]] && continue

  # Skip non-path entries (like vendored_skills_source)
  [[ "$pattern" == *":"* ]] && continue

  # Expand glob patterns relative to source directory
  expanded_paths=()
  pushd "$SOURCE_DIR" > /dev/null
  # Use bash globbing — nullglob prevents literal pattern on no match
  shopt -s nullglob
  for match in $pattern; do
    expanded_paths+=("$match")
  done
  shopt -u nullglob
  popd > /dev/null

  # If no glob matches, try the literal path
  if [[ ${#expanded_paths[@]} -eq 0 ]]; then
    expanded_paths=("$pattern")
  fi

  for path in "${expanded_paths[@]}"; do
    # Skip by convention
    if is_skipped "$path"; then
      echo "  [skip] $path (convention)"
      continue
    fi

    src="$SOURCE_DIR/$path"
    dst="$TARGET_DIR/$path"

    if [[ "$path" == */ ]]; then
      # Directory with trailing slash — recursive copy
      # Note: $src has trailing slash so rsync copies CONTENTS (not the dir itself).
      # Destination must be $dst (the matching target dir), NOT dirname($dst).
      if [[ -d "$src" ]]; then
        mkdir -p "$dst"
        rsync -a --exclude "sync-state.json" "$src" "$dst" 2>/dev/null || {
          cp -a "$src"/. "$dst/" 2>/dev/null || true
          rm -f "$dst/sync-state.json" 2>/dev/null || true
        }
        echo "  [copy] $path"
      else
        echo "  [skip] $path (directory not found in source)"
      fi
    elif [[ -d "$src" ]]; then
      # Directory without trailing slash (from glob like agent-flow-*/)
      mkdir -p "$dst"
      rsync -a --exclude "sync-state.json" "$src/" "$dst/" 2>/dev/null || {
        cp -a "$src"/. "$dst/" 2>/dev/null || true
        rm -f "$dst/sync-state.json" 2>/dev/null || true
      }
      echo "  [copy] $path/"
    elif [[ -f "$src" ]]; then
      # File — direct copy
      mkdir -p "$(dirname "$dst")"
      cp "$src" "$dst"
      echo "  [copy] $path"
    else
      echo "  [skip] $path (not found in source)"
    fi
  done
done < <(yaml_list "$MANIFEST" "managed_files")

# ── Step 1b: Copy vendored skills from skills-filter.yaml ──
VENDORED_SOURCE=$(MANIFEST_PATH="$MANIFEST" python3 -c "
import yaml, os
with open(os.environ['MANIFEST_PATH']) as f:
    manifest = yaml.safe_load(f)
print(manifest.get('vendored_skills_source', ''))
" 2>&1) || {
  echo "  WARN: Failed to read vendored_skills_source from manifest"
  VENDORED_SOURCE=""
}

# Reject unsafe vendored_skills_source values (absolute paths, traversal segments)
if [[ -n "$VENDORED_SOURCE" && ( "$VENDORED_SOURCE" == /* || "$VENDORED_SOURCE" == *..* ) ]]; then
  echo "  WARN: vendored_skills_source contains unsafe path — skipping"
  VENDORED_SOURCE=""
fi

if [[ -n "$VENDORED_SOURCE" && -f "$SOURCE_DIR/$VENDORED_SOURCE" ]]; then
  # Verify resolved path stays within source dir (prevent symlink escape)
  RESOLVED_FILTER=$(realpath "$SOURCE_DIR/$VENDORED_SOURCE" 2>/dev/null) || {
    echo "  WARN: realpath failed for vendored_skills_source — skipping"
    RESOLVED_FILTER=""
  }
  RESOLVED_SOURCE=$(realpath "$SOURCE_DIR" 2>/dev/null) || {
    echo "  WARN: realpath failed for source dir — skipping"
    RESOLVED_SOURCE=""
  }
  if [[ -n "$RESOLVED_FILTER" && -n "$RESOLVED_SOURCE" && "$RESOLVED_FILTER" == "$RESOLVED_SOURCE"/* ]]; then
    echo "Syncing vendored skills from $VENDORED_SOURCE..."
    PARSE_FAILED=false
    INCLUDED_SKILLS=$(FILTER_PATH="$SOURCE_DIR/$VENDORED_SOURCE" python3 -c "
import yaml, os, re, sys
try:
    with open(os.environ['FILTER_PATH']) as f:
        data = yaml.safe_load(f)
    if not isinstance(data, dict):
        print('WARN: skills-filter.yaml did not parse as a dict', file=sys.stderr)
        sys.exit(0)
    for s in data.get('included', []):
        if isinstance(s, str) and re.match(r'^[a-zA-Z0-9][a-zA-Z0-9._-]*\$', s):
            print(s)
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)
" 2>&1) || {
      echo "  ERROR: Failed to parse skills-filter.yaml — vendored skills skipped"
      PARSE_FAILED=true
    }

    if [[ "$PARSE_FAILED" == "true" ]]; then
      echo "  (skipping vendored skills due to parse failure)"
    fi

    while [[ "$PARSE_FAILED" == "false" ]] && IFS= read -r skill_name; do
      [[ -z "$skill_name" ]] && continue
      # Positive allowlist: alphanumeric start, then alphanumeric/dot/hyphen/underscore
      [[ "$skill_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || continue
      skill_src="$SOURCE_DIR/.claude/skills/$skill_name"
      skill_dst="$TARGET_DIR/.claude/skills/$skill_name"
      if [[ -d "$skill_src" ]]; then
        mkdir -p "$skill_dst"
        if command -v rsync &>/dev/null; then
          rsync -a -- "$skill_src/" "$skill_dst/" || { echo "  [error] rsync failed for $skill_name" >&2; continue; }
        else
          cp -a -- "$skill_src"/. "$skill_dst/" || { echo "  [error] cp failed for $skill_name" >&2; continue; }
        fi
        echo "  [copy] .claude/skills/$skill_name/ (vendored)"
      else
        echo "  [skip] .claude/skills/$skill_name/ (not found in source)"
      fi
    done <<< "$INCLUDED_SKILLS"
  else
    echo "  WARN: vendored_skills_source resolves outside source dir — skipping"
  fi
fi

# ── Step 2: Merge settings.json ──
if [[ -f "$SOURCE_DIR/.claude/settings.json" ]]; then
  echo "Merging .claude/settings.json..."
  mkdir -p "$TARGET_DIR/.claude"
  if "$SCRIPT_DIR/merge-settings-json.sh" \
    "$SOURCE_DIR/.claude/settings.json" \
    "$TARGET_DIR/.claude/settings.json" > "$TARGET_DIR/.claude/settings.json.tmp"; then
    mv "$TARGET_DIR/.claude/settings.json.tmp" "$TARGET_DIR/.claude/settings.json"
    echo "  [merge] .claude/settings.json"
  else
    rm -f "$TARGET_DIR/.claude/settings.json.tmp"
    echo "  [error] .claude/settings.json merge failed" >&2
  fi
fi

# ── Step 2b: Merge .mcp.json (json-deep-merge) ──
if [[ -f "$SOURCE_DIR/.mcp.json" ]]; then
  echo "Merging .mcp.json..."
  mkdir -p "$TARGET_DIR"
  if [[ -f "$TARGET_DIR/.mcp.json" ]]; then
    # Deep merge: source managed keys into target, preserving target's other keys
    SYNC_SOURCE="$SOURCE_DIR/.mcp.json" SYNC_TARGET="$TARGET_DIR/.mcp.json" python3 -c "
import json, os
src_path, tgt_path = os.environ['SYNC_SOURCE'], os.environ['SYNC_TARGET']
with open(src_path) as f:
    source = json.load(f)
with open(tgt_path) as f:
    target = json.load(f)
if 'mcpServers' not in target:
    target['mcpServers'] = {}
if 'mcpServers' in source and 'backlog' in source['mcpServers']:
    target['mcpServers']['backlog'] = source['mcpServers']['backlog']
with open(tgt_path, 'w') as f:
    json.dump(target, f, indent=2)
    f.write('\n')
" && echo "  [merge] .mcp.json" || echo "  [error] .mcp.json merge failed" >&2
  else
    cp "$SOURCE_DIR/.mcp.json" "$TARGET_DIR/.mcp.json"
    echo "  [copy] .mcp.json"
  fi
fi

# ── Step 2c: Merge .gitattributes (append-missing) ──
if [[ -f "$SOURCE_DIR/.gitattributes" ]]; then
  echo "Updating .gitattributes..."
  touch "$TARGET_DIR/.gitattributes"
  # Extract managed lines from manifest
  managed_ga_lines=()
  in_gitattributes=false
  in_managed_lines=false
  while IFS= read -r line; do
    if [[ "$line" =~ path:.*\.gitattributes ]]; then
      in_gitattributes=true
      continue
    fi
    if $in_gitattributes && [[ "$line" =~ managed_lines: ]]; then
      in_managed_lines=true
      continue
    fi
    if $in_managed_lines; then
      if [[ "$line" =~ ^[[:space:]]+-[[:space:]]+\"(.+)\" ]]; then
        managed_ga_lines+=("${BASH_REMATCH[1]}")
      elif [[ ! "$line" =~ ^[[:space:]]+-[[:space:]] ]]; then
        break
      fi
    fi
    if $in_gitattributes && [[ "$line" =~ ^[[:space:]]*-[[:space:]]+path: ]]; then
      in_gitattributes=false
      in_managed_lines=false
    fi
  done < "$MANIFEST"

  for ga_line in "${managed_ga_lines[@]}"; do
    if ! grep -qF "$ga_line" "$TARGET_DIR/.gitattributes" 2>/dev/null; then
      echo "$ga_line" >> "$TARGET_DIR/.gitattributes"
    fi
  done
  echo "  [append] .gitattributes (${#managed_ga_lines[@]} managed lines)"
fi

# ── Step 2d: Orchestrator strategy for session-start.sh ──
# Copies the thin orchestrator from source if it doesn't exist in target,
# preserving any project customizations. The orchestrator sources the
# managed bootstrap (agent-flow-session-start.sh) and optional project hook.
if [[ -f "$SOURCE_DIR/.claude/hooks/session-start.sh" ]]; then
  echo "Installing session-start.sh orchestrator..."
  mkdir -p "$TARGET_DIR/.claude/hooks"
  if [[ ! -f "$TARGET_DIR/.claude/hooks/session-start.sh" ]]; then
    # Fresh install — copy the thin orchestrator
    cp "$SOURCE_DIR/.claude/hooks/session-start.sh" "$TARGET_DIR/.claude/hooks/session-start.sh"
    chmod +x "$TARGET_DIR/.claude/hooks/session-start.sh"
    echo "  [copy] .claude/hooks/session-start.sh (new install)"
  elif [[ -f "$TARGET_DIR/.claude/hooks/agent-flow-session-start.sh" ]] && \
       ! grep -q "agent-flow-session-start" "$TARGET_DIR/.claude/hooks/session-start.sh" 2>/dev/null; then
    # v2 migration: detects old monolithic session-start.sh that hasn't been
    # updated to source agent-flow-session-start.sh (or the new plugin hook path)
    cp "$SOURCE_DIR/.claude/hooks/session-start.sh" "$TARGET_DIR/.claude/hooks/session-start.sh"
    chmod +x "$TARGET_DIR/.claude/hooks/session-start.sh"
    echo "  [migrate] .claude/hooks/session-start.sh (replaced with thin orchestrator)"
  else
    echo "  [skip] .claude/hooks/session-start.sh (already orchestrator or customized)"
  fi
fi

# ── Step 3: Patch CLAUDE.md ──
if [[ -f "$SOURCE_DIR/CLAUDE.md" ]]; then
  echo "Patching CLAUDE.md..."
  # Extract managed section names from manifest
  MANAGED_SECTIONS=()
  in_sections=false
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]+managed_sections: ]]; then
      in_sections=true
      continue
    fi
    if $in_sections; then
      if [[ "$line" =~ ^[[:space:]]+-[[:space:]]+\"(.+)\" ]]; then
        MANAGED_SECTIONS+=("${BASH_REMATCH[1]}")
      elif [[ ! "$line" =~ ^[[:space:]]+-[[:space:]] ]]; then
        break
      fi
    fi
  done < "$MANIFEST"

  if [[ ${#MANAGED_SECTIONS[@]} -gt 0 ]]; then
    if "$SCRIPT_DIR/patch-claude-md.sh" \
      "$SOURCE_DIR/CLAUDE.md" \
      "$TARGET_DIR/CLAUDE.md" \
      "${MANAGED_SECTIONS[@]}" > "$TARGET_DIR/CLAUDE.md.tmp"; then
      mv "$TARGET_DIR/CLAUDE.md.tmp" "$TARGET_DIR/CLAUDE.md"
      echo "  [patch] CLAUDE.md (${#MANAGED_SECTIONS[@]} managed sections)"
    else
      rm -f "$TARGET_DIR/CLAUDE.md.tmp"
      echo "  [error] CLAUDE.md patch failed" >&2
    fi
  fi
fi

# ── Step 4: Append missing .gitignore lines ──
if [[ -f "$SOURCE_DIR/.gitignore" ]]; then
  echo "Updating .gitignore..."
  MARKER="# --- Agent Flow (managed) ---"
  END_MARKER="# --- End Agent Flow ---"

  managed_lines=()
  while IFS= read -r path; do
    [[ -n "$path" ]] && managed_lines+=("$path")
  done < <(yaml_list "$MANIFEST" "managed_lines")

  # Also extract from merge_files section for .gitignore
  in_gitignore=false
  in_managed_lines=false
  while IFS= read -r line; do
    if [[ "$line" =~ path:.*\.gitignore ]]; then
      in_gitignore=true
      continue
    fi
    if $in_gitignore && [[ "$line" =~ managed_lines: ]]; then
      in_managed_lines=true
      continue
    fi
    if $in_managed_lines; then
      if [[ "$line" =~ ^[[:space:]]+-[[:space:]]+\"(.+)\" ]]; then
        managed_lines+=("${BASH_REMATCH[1]}")
      elif [[ ! "$line" =~ ^[[:space:]]+-[[:space:]] ]]; then
        break
      fi
    fi
    if $in_gitignore && [[ "$line" =~ ^[[:space:]]*-[[:space:]]+path: ]]; then
      in_gitignore=false
      in_managed_lines=false
    fi
  done < "$MANIFEST"

  if [[ ${#managed_lines[@]} -gt 0 ]]; then
    touch "$TARGET_DIR/.gitignore"

    # Remove existing managed block (plus preceding blank line) if present
    MARKER_ESC=$(printf '%s\n' "$MARKER" | sed 's/[[\.*^$/]/\\&/g')
    END_MARKER_ESC=$(printf '%s\n' "$END_MARKER" | sed 's/[[\.*^$/]/\\&/g')
    if grep -qF "$MARKER" "$TARGET_DIR/.gitignore" 2>/dev/null; then
      # Delete the marker block (cross-platform — avoids macOS sed -i quirks)
      sed "/$MARKER_ESC/,/$END_MARKER_ESC/d" "$TARGET_DIR/.gitignore" > "$TARGET_DIR/.gitignore.tmp" && \
        mv "$TARGET_DIR/.gitignore.tmp" "$TARGET_DIR/.gitignore"
      # Remove trailing blank lines left behind
      sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$TARGET_DIR/.gitignore" > "$TARGET_DIR/.gitignore.tmp" && \
        mv "$TARGET_DIR/.gitignore.tmp" "$TARGET_DIR/.gitignore"
    fi

    # Append managed block
    {
      echo ""
      echo "$MARKER"
      for line in "${managed_lines[@]}"; do
        echo "$line"
      done
      echo "$END_MARKER"
    } >> "$TARGET_DIR/.gitignore"
    echo "  [append] .gitignore (${#managed_lines[@]} managed lines)"
  fi
fi

# ── Step 5: Template files from .claude-agent-flow/templates/ ──
TEMPLATES_DIR="$SOURCE_DIR/.claude-agent-flow/templates"

# 5a. backlog/config.yml
if [[ -n "$PROJECT_NAME" && -f "$TEMPLATES_DIR/backlog/config.yml" ]]; then
  echo "Templating backlog/config.yml..."
  SAFE_NAME=$(printf '%s\n' "$PROJECT_NAME" | sed 's/[&/\]/\\&/g')
  mkdir -p "$TARGET_DIR/backlog"
  if [[ -f "$TARGET_DIR/backlog/config.yml" ]]; then
    # Preserve existing project_name if already customized
    existing_name=$(grep '^project_name:' "$TARGET_DIR/backlog/config.yml" | sed -E 's/project_name:[[:space:]]*"?([^"]*)"?/\1/')
    if [[ "$existing_name" != "CHANGEME" && -n "$existing_name" ]]; then
      echo "  [skip] backlog/config.yml (already customized: $existing_name)"
    else
      sed "s/project_name: .*/project_name: \"$SAFE_NAME\"/" \
        "$TEMPLATES_DIR/backlog/config.yml" > "$TARGET_DIR/backlog/config.yml"
      echo "  [template] backlog/config.yml → $PROJECT_NAME"
    fi
  else
    sed "s/project_name: .*/project_name: \"$SAFE_NAME\"/" \
      "$TEMPLATES_DIR/backlog/config.yml" > "$TARGET_DIR/backlog/config.yml"
    echo "  [template] backlog/config.yml → $PROJECT_NAME"
  fi

  # Create empty backlog directories
  mkdir -p "$TARGET_DIR/backlog/tasks" "$TARGET_DIR/backlog/milestones" "$TARGET_DIR/backlog/archive/tasks"
fi

# 5b. CHANGELOG.md — only create if target doesn't have one
if [[ ! -f "$TARGET_DIR/CHANGELOG.md" && -f "$TEMPLATES_DIR/CHANGELOG.md" ]]; then
  cp "$TEMPLATES_DIR/CHANGELOG.md" "$TARGET_DIR/CHANGELOG.md"
  echo "  [template] CHANGELOG.md (new)"
fi

# 5c. external-review-config.repo.yml — only create if target doesn't have one
if [[ ! -f "$TARGET_DIR/external-review-config.repo.yml" && -f "$TEMPLATES_DIR/external-review-config.repo.yml" ]]; then
  cp "$TEMPLATES_DIR/external-review-config.repo.yml" "$TARGET_DIR/external-review-config.repo.yml"
  echo "  [template] external-review-config.repo.yml (new)"
fi

# ── Step 6: Install managed workflow files ──
# Workflows are matched by glob patterns in managed_files — already handled in Step 1.
# This step is kept for backwards compatibility with explicit workflow paths.
echo "Verifying workflow files..."
for wf in "$TARGET_DIR/.github/workflows/agent-flow-"*.yml; do
  [[ -f "$wf" ]] && echo "  [ok] $(basename "$wf")"
done

echo ""
echo "Sync complete."
