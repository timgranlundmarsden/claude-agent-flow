#!/usr/bin/env bats
# Tests for agent-flow-workflow-helpers.sh

setup() {
  load test_helper
  setup_temp_dirs
  source "$SCRIPT_DIR/agent-flow-workflow-helpers.sh"
}

# ── redact_token ─────────────────────────────────────────────────────────────

@test "redact_token replaces token in output" {
  export SYNC_TOKEN="mySecretToken123"
  result=$(echo "url: https://mySecretToken123@github.com" | redact_token)
  [[ "$result" == "url: https://***@github.com" ]]
}

@test "redact_token passes through when SYNC_TOKEN empty" {
  unset SYNC_TOKEN
  result=$(echo "nothing secret here" | redact_token)
  [[ "$result" == "nothing secret here" ]]
}

@test "redact_token handles realistic PAT token format" {
  # GitHub PATs are typically ghp_xxxx or github_pat_xxxx (no regex metacharacters)
  export SYNC_TOKEN="ghp_ABCDEFghijklmnop1234567890qrst"
  result=$(echo "clone https://x-access-token:ghp_ABCDEFghijklmnop1234567890qrst@github.com/org/repo" | redact_token)
  [[ "$result" == "clone https://x-access-token:***@github.com/org/repo" ]]
}

@test "redact_token handles tokens with regex metacharacters" {
  # Tokens with . + * etc must be treated literally, not as regex
  export SYNC_TOKEN="tok+en.with*special"
  result=$(echo "url: https://tok+en.with*special@github.com" | redact_token)
  [[ "$result" == "url: https://***@github.com" ]]
}

# ── check_sync_loop ──────────────────────────────────────────────────────────

# ── Layer 1: Trailer in HEAD commit body (direct pushes) ────────────────────

@test "check_sync_loop L1: detects trailer in direct push" {
  setup_git_repo "$SOURCE_DIR"
  git -C "$SOURCE_DIR" commit --allow-empty --quiet --no-gpg-sign \
    -m "chore: sync update

Agent-Flow-Sync-Origin: org/repo"
  cd "$SOURCE_DIR"
  result=$(check_sync_loop)
  [[ "$result" == *"skip=true"* ]]
  [[ "$result" == *"origin_repo=org/repo"* ]]
}

@test "check_sync_loop L1: extracts repo with slashes correctly" {
  setup_git_repo "$SOURCE_DIR"
  git -C "$SOURCE_DIR" commit --allow-empty --quiet --no-gpg-sign \
    -m "feat: sync managed files from deep/nested/repo

Upstream sync of managed agent-flow files.

Agent-Flow-Sync-Origin: deep/nested/repo"
  cd "$SOURCE_DIR"
  result=$(check_sync_loop)
  [[ "$result" == *"skip=true"* ]]
  [[ "$result" == *"origin_repo=deep/nested/repo"* ]]
}

@test "check_sync_loop L1: returns skip=false for normal commit" {
  setup_git_repo "$SOURCE_DIR"
  git -C "$SOURCE_DIR" commit --allow-empty --quiet --no-gpg-sign -m "feat: normal change"
  cd "$SOURCE_DIR"
  result=$(check_sync_loop)
  [[ "$result" == *"skip=false"* ]]
  [[ "$result" == *"origin_repo="* ]]
}

@test "check_sync_loop L1: trailer takes priority over API (no API call needed)" {
  setup_git_repo "$SOURCE_DIR"
  git -C "$SOURCE_DIR" commit --allow-empty --quiet --no-gpg-sign \
    -m "feat: sync managed files from org/repo (#42)

Agent-Flow-Sync-Origin: org/repo"
  cd "$SOURCE_DIR"

  # If Layer 1 finds the trailer, curl should never be called
  curl() { echo "ERROR: curl should not be called" >&2; return 1; }
  export -f curl
  export GITHUB_TOKEN="fake-token"
  export GITHUB_REPOSITORY="org/source"

  result=$(check_sync_loop)
  [[ "$result" == *"skip=true"* ]]
  [[ "$result" == *"origin_repo=org/repo"* ]]

  unset GITHUB_TOKEN GITHUB_REPOSITORY
  unset -f curl
}

# ── Layer 2: Trailer in HEAD^2 (merge commits) ─────────────────────────────

@test "check_sync_loop L2: detects trailer in merge commit second parent" {
  setup_git_repo "$SOURCE_DIR"
  cd "$SOURCE_DIR"
  local default_branch
  default_branch=$(git branch --show-current)
  # Create a branch with the sync trailer
  git checkout -b sync-branch --quiet
  git commit --allow-empty --quiet --no-gpg-sign \
    -m "feat: sync managed files from org/target

Agent-Flow-Sync-Origin: org/target"
  # Merge back to default branch (creates a merge commit)
  git checkout "$default_branch" --quiet
  git merge --no-ff --no-edit --no-gpg-sign sync-branch --quiet
  # HEAD is the merge commit (no trailer), HEAD^2 has the trailer
  result=$(check_sync_loop)
  [[ "$result" == *"skip=true"* ]]
  [[ "$result" == *"origin_repo=org/target"* ]]
}

# ── Layer 3: GitHub API label check (squash merges) ────────────────────────

@test "check_sync_loop L3: detects sync label on squash-merged upstream PR" {
  setup_git_repo "$SOURCE_DIR"
  git -C "$SOURCE_DIR" commit --allow-empty --quiet --no-gpg-sign \
    -m "feat: sync managed files from org/idea-factory (#31)"
  cd "$SOURCE_DIR"

  curl() {
    cat <<'MOCK_JSON'
{
  "labels": [{"name": "agent-flow-sync"}, {"name": "enhancement"}],
  "body": "## Upstream Sync from org/idea-factory\n\nAgent-Flow-Sync-Origin: org/idea-factory\n\n---"
}
MOCK_JSON
  }
  export -f curl
  export GITHUB_TOKEN="fake-token"
  export GITHUB_REPOSITORY="org/agent-flow"

  result=$(check_sync_loop)
  [[ "$result" == *"skip=true"* ]]
  [[ "$result" == *"origin_repo=org/idea-factory"* ]]

  unset GITHUB_TOKEN GITHUB_REPOSITORY
  unset -f curl
}

@test "check_sync_loop L3: detects sync label on squash-merged downstream PR" {
  setup_git_repo "$SOURCE_DIR"
  git -C "$SOURCE_DIR" commit --allow-empty --quiet --no-gpg-sign \
    -m "feat: sync agent-flow v3 (#15)"
  cd "$SOURCE_DIR"

  curl() {
    cat <<'MOCK_JSON'
{
  "labels": [{"name": "agent-flow-sync"}],
  "body": "## Downstream Sync\n\nAgent-Flow-Sync-Origin: org/source\n\n---"
}
MOCK_JSON
  }
  export -f curl
  export GITHUB_TOKEN="fake-token"
  export GITHUB_REPOSITORY="org/target"

  result=$(check_sync_loop)
  [[ "$result" == *"skip=true"* ]]
  [[ "$result" == *"origin_repo=org/source"* ]]

  unset GITHUB_TOKEN GITHUB_REPOSITORY
  unset -f curl
}

@test "check_sync_loop L3: returns 'unknown' origin when label present but no trailer in body" {
  setup_git_repo "$SOURCE_DIR"
  git -C "$SOURCE_DIR" commit --allow-empty --quiet --no-gpg-sign \
    -m "feat: sync managed files from org/repo (#42)"
  cd "$SOURCE_DIR"

  curl() {
    cat <<'MOCK_JSON'
{
  "labels": [{"name": "agent-flow-sync"}],
  "body": "## Upstream Sync\n\nNo origin trailer here."
}
MOCK_JSON
  }
  export -f curl
  export GITHUB_TOKEN="fake-token"
  export GITHUB_REPOSITORY="org/source"

  result=$(check_sync_loop)
  [[ "$result" == *"skip=true"* ]]
  [[ "$result" == *"origin_repo=unknown"* ]]

  unset GITHUB_TOKEN GITHUB_REPOSITORY
  unset -f curl
}

@test "check_sync_loop L3: ignores PR without sync label" {
  setup_git_repo "$SOURCE_DIR"
  git -C "$SOURCE_DIR" commit --allow-empty --quiet --no-gpg-sign \
    -m "feat: some feature (#10)"
  cd "$SOURCE_DIR"

  curl() {
    cat <<'MOCK_JSON'
{
  "labels": [{"name": "enhancement"}],
  "body": "Just a regular PR"
}
MOCK_JSON
  }
  export -f curl
  export GITHUB_TOKEN="fake-token"
  export GITHUB_REPOSITORY="org/source"

  result=$(check_sync_loop)
  [[ "$result" == *"skip=false"* ]]

  unset GITHUB_TOKEN GITHUB_REPOSITORY
  unset -f curl
}

@test "check_sync_loop L3: skips API when GITHUB_TOKEN not set" {
  setup_git_repo "$SOURCE_DIR"
  git -C "$SOURCE_DIR" commit --allow-empty --quiet --no-gpg-sign \
    -m "feat: sync managed files from org/repo (#42)"
  cd "$SOURCE_DIR"
  unset GITHUB_TOKEN
  export GITHUB_REPOSITORY="org/source"
  result=$(check_sync_loop)
  [[ "$result" == *"skip=false"* ]]
  unset GITHUB_REPOSITORY
}

@test "check_sync_loop L3: skips API when GITHUB_REPOSITORY not set" {
  setup_git_repo "$SOURCE_DIR"
  git -C "$SOURCE_DIR" commit --allow-empty --quiet --no-gpg-sign \
    -m "feat: sync managed files from org/repo (#42)"
  cd "$SOURCE_DIR"
  export GITHUB_TOKEN="fake-token"
  unset GITHUB_REPOSITORY
  result=$(check_sync_loop)
  [[ "$result" == *"skip=false"* ]]
  unset GITHUB_TOKEN
}

@test "check_sync_loop L3: skips API when commit has no PR number" {
  setup_git_repo "$SOURCE_DIR"
  git -C "$SOURCE_DIR" commit --allow-empty --quiet --no-gpg-sign \
    -m "feat: sync managed files from org/repo"
  cd "$SOURCE_DIR"

  curl() { echo "ERROR: curl should not be called" >&2; return 1; }
  export -f curl
  export GITHUB_TOKEN="fake-token"
  export GITHUB_REPOSITORY="org/source"

  result=$(check_sync_loop)
  [[ "$result" == *"skip=false"* ]]

  unset GITHUB_TOKEN GITHUB_REPOSITORY
  unset -f curl
}

@test "check_sync_loop L3: handles API failure gracefully" {
  setup_git_repo "$SOURCE_DIR"
  git -C "$SOURCE_DIR" commit --allow-empty --quiet --no-gpg-sign \
    -m "feat: sync managed files from org/repo (#42)"
  cd "$SOURCE_DIR"

  # curl returns non-zero (network error, rate limit, etc.)
  curl() { return 1; }
  export -f curl
  export GITHUB_TOKEN="fake-token"
  export GITHUB_REPOSITORY="org/source"

  result=$(check_sync_loop)
  # Should fall through gracefully, not crash
  [[ "$result" == *"skip=false"* ]]

  unset GITHUB_TOKEN GITHUB_REPOSITORY
  unset -f curl
}

@test "check_sync_loop L3: handles malformed API response" {
  setup_git_repo "$SOURCE_DIR"
  git -C "$SOURCE_DIR" commit --allow-empty --quiet --no-gpg-sign \
    -m "feat: sync managed files from org/repo (#42)"
  cd "$SOURCE_DIR"

  curl() { echo "not valid json"; }
  export -f curl
  export GITHUB_TOKEN="fake-token"
  export GITHUB_REPOSITORY="org/source"

  result=$(check_sync_loop)
  [[ "$result" == *"skip=false"* ]]

  unset GITHUB_TOKEN GITHUB_REPOSITORY
  unset -f curl
}

# ── Edge cases ──────────────────────────────────────────────────────────────

@test "check_sync_loop handles no commits gracefully" {
  mkdir -p "$SOURCE_DIR/norepo"
  git -C "$SOURCE_DIR" init --quiet
  # No commits — git log will fail
  cd "$SOURCE_DIR"
  result=$(check_sync_loop)
  [[ "$result" == *"skip=false"* ]]
}

# ── check_source_identity ────────────────────────────────────────────────────

@test "check_source_identity skips non-source repo" {
  mkdir -p "$SOURCE_DIR/.claude-agent-flow"
  cat > "$SOURCE_DIR/.claude-agent-flow/repo-sync-manifest.yml" << 'EOF'
source_repo: org/source
targets: []
EOF
  cd "$SOURCE_DIR"
  result=$(check_source_identity "org/other")
  [[ "$result" == *"skip=true"* ]]
}

@test "check_source_identity allows source repo" {
  mkdir -p "$SOURCE_DIR/.claude-agent-flow"
  cat > "$SOURCE_DIR/.claude-agent-flow/repo-sync-manifest.yml" << 'EOF'
source_repo: org/source
targets: []
EOF
  cd "$SOURCE_DIR"
  result=$(check_source_identity "org/source")
  [[ "$result" == *"skip=false"* ]]
}

@test "check_source_identity fails without manifest" {
  cd "$SOURCE_DIR"
  run check_source_identity "org/any"
  assert_failure
}

# ── read_targets ─────────────────────────────────────────────────────────────

@test "read_targets returns enabled repos" {
  mkdir -p "$SOURCE_DIR/.claude-agent-flow"
  cat > "$SOURCE_DIR/.claude-agent-flow/repo-sync-manifest.yml" << 'EOF'
source_repo: org/source
targets:
  - repo: org/target1
    enabled: true
  - repo: org/target2
    enabled: true
  - repo: org/target3
    enabled: false
EOF
  cd "$SOURCE_DIR"
  result=$(read_targets)
  count=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d))")
  [[ "$count" == "2" ]]
}

@test "read_targets returns empty array when no targets" {
  mkdir -p "$SOURCE_DIR/.claude-agent-flow"
  cat > "$SOURCE_DIR/.claude-agent-flow/repo-sync-manifest.yml" << 'EOF'
source_repo: org/source
targets: []
EOF
  cd "$SOURCE_DIR"
  result=$(read_targets)
  [[ "$result" == "[]" ]]
}

# ── detect_real_changes ──────────────────────────────────────────────────────

@test "detect_real_changes filters sync-state.json" {
  local input
  input=$(printf 'file1.txt\n.claude-agent-flow/sync-state.json\nfile2.txt')
  result=$(detect_real_changes "$input")
  [[ "$result" == *"file1.txt"* ]]
  [[ "$result" == *"file2.txt"* ]]
  [[ "$result" != *"sync-state.json"* ]]
}

@test "detect_real_changes returns empty for only sync-state" {
  result=$(detect_real_changes ".claude-agent-flow/sync-state.json")
  [[ -z "$result" ]]
}

@test "detect_real_changes filters blank lines" {
  local input
  input=$(printf 'file1.txt\n\n\nfile2.txt\n  \n')
  result=$(detect_real_changes "$input")
  [[ "$result" == *"file1.txt"* ]]
  [[ "$result" == *"file2.txt"* ]]
  # No blank or whitespace-only lines in output
  blank_count=$(echo "$result" | grep -c '^[[:space:]]*$' || true)
  [[ "$blank_count" -eq 0 ]]
}

@test "detect_real_changes returns empty for only blank lines" {
  result=$(detect_real_changes $'\n\n\n')
  [[ -z "$result" ]]
}

# ── list_managed_paths ──────────────────────────────────────────────────────

@test "list_managed_paths fails when manifest is missing" {
  cd "$SOURCE_DIR"
  # No manifest exists
  run list_managed_paths
  assert_failure
  assert_output --partial "ERROR: manifest not found"
}

@test "list_managed_paths skips unmatched globs" {
  mkdir -p "$SOURCE_DIR/.claude-agent-flow"
  cat > "$SOURCE_DIR/.claude-agent-flow/repo-sync-manifest.yml" << 'EOF'
version: 1
source_repo: "org/test"
managed_files:
  - "nonexistent-pattern-*.xyz"
targets: []
EOF
  cd "$SOURCE_DIR"
  result=$(list_managed_paths)
  # Unmatched glob should NOT appear in output
  [[ "$result" != *"nonexistent-pattern"* ]]
}

@test "list_managed_paths --include-upstream-merge only includes eligible strategies" {
  mkdir -p "$SOURCE_DIR/.claude-agent-flow"
  cat > "$SOURCE_DIR/.claude-agent-flow/repo-sync-manifest.yml" << 'EOF'
version: 1
source_repo: "org/test"
managed_files: []
merge_files:
  - path: "settings.json"
    strategy: json-deep-merge
  - path: "CLAUDE.md"
    strategy: section-patch
  - path: ".gitignore"
    strategy: append-missing
  - path: "config.yml"
    strategy: template
targets: []
EOF
  cd "$SOURCE_DIR"
  result=$(list_managed_paths --include-upstream-merge)
  # json-deep-merge and section-patch are upstream-eligible
  [[ "$result" == *"settings.json"* ]]
  [[ "$result" == *"CLAUDE.md"* ]]
  # append-missing and template are NOT upstream-eligible
  [[ "$result" != *".gitignore"* ]]
  [[ "$result" != *"config.yml"* ]]
}

@test "list_managed_paths --include-merge includes all merge_files" {
  mkdir -p "$SOURCE_DIR/.claude-agent-flow"
  cat > "$SOURCE_DIR/.claude-agent-flow/repo-sync-manifest.yml" << 'EOF'
version: 1
source_repo: "org/test"
managed_files: []
merge_files:
  - path: "settings.json"
    strategy: json-deep-merge
  - path: ".gitignore"
    strategy: append-missing
targets: []
EOF
  cd "$SOURCE_DIR"
  result=$(list_managed_paths --include-merge)
  [[ "$result" == *"settings.json"* ]]
  [[ "$result" == *".gitignore"* ]]
}

# ── list_managed_paths: vendored skills ─────────────────────────────────────

@test "list_managed_paths resolves vendored skills from skills-filter.yaml" {
  mkdir -p "$SOURCE_DIR/.claude-agent-flow"
  mkdir -p "$SOURCE_DIR/.claude/skills/brainstorming"
  mkdir -p "$SOURCE_DIR/.claude/skills/frontend-design"
  echo "skill content" > "$SOURCE_DIR/.claude/skills/brainstorming/SKILL.md"
  echo "script" > "$SOURCE_DIR/.claude/skills/brainstorming/helper.js"
  echo "design skill" > "$SOURCE_DIR/.claude/skills/frontend-design/SKILL.md"
  mkdir -p "$SOURCE_DIR/.claude/skills/sync-plugin-skills"
  cat > "$SOURCE_DIR/.claude/skills/sync-plugin-skills/skills-filter.yaml" << 'EOF'
included:
  - brainstorming
  - frontend-design
available:
  - other-skill
EOF
  cat > "$SOURCE_DIR/.claude-agent-flow/repo-sync-manifest.yml" << 'EOF'
version: 1
source_repo: "org/test"
managed_files: []
vendored_skills_source: .claude/skills/sync-plugin-skills/skills-filter.yaml
targets: []
EOF
  cd "$SOURCE_DIR"
  result=$(list_managed_paths)
  [[ "$result" == *".claude/skills/brainstorming/SKILL.md"* ]]
  [[ "$result" == *".claude/skills/brainstorming/helper.js"* ]]
  [[ "$result" == *".claude/skills/frontend-design/SKILL.md"* ]]
}

@test "list_managed_paths skips vendored skills not in included list" {
  mkdir -p "$SOURCE_DIR/.claude-agent-flow"
  mkdir -p "$SOURCE_DIR/.claude/skills/brainstorming"
  mkdir -p "$SOURCE_DIR/.claude/skills/excluded-skill"
  echo "included" > "$SOURCE_DIR/.claude/skills/brainstorming/SKILL.md"
  echo "excluded" > "$SOURCE_DIR/.claude/skills/excluded-skill/SKILL.md"
  mkdir -p "$SOURCE_DIR/.claude/skills/sync-plugin-skills"
  cat > "$SOURCE_DIR/.claude/skills/sync-plugin-skills/skills-filter.yaml" << 'EOF'
included:
  - brainstorming
available:
  - excluded-skill
EOF
  cat > "$SOURCE_DIR/.claude-agent-flow/repo-sync-manifest.yml" << 'EOF'
version: 1
source_repo: "org/test"
managed_files: []
vendored_skills_source: .claude/skills/sync-plugin-skills/skills-filter.yaml
targets: []
EOF
  cd "$SOURCE_DIR"
  result=$(list_managed_paths)
  [[ "$result" == *"brainstorming/SKILL.md"* ]]
  [[ "$result" != *"excluded-skill"* ]]
}

@test "list_managed_paths handles missing skills-filter.yaml gracefully" {
  mkdir -p "$SOURCE_DIR/.claude-agent-flow"
  cat > "$SOURCE_DIR/.claude-agent-flow/repo-sync-manifest.yml" << 'EOF'
version: 1
source_repo: "org/test"
managed_files: []
vendored_skills_source: .claude/skills/sync-plugin-skills/skills-filter.yaml
targets: []
EOF
  cd "$SOURCE_DIR"
  # Should not fail — just returns no vendored paths
  result=$(list_managed_paths)
  [[ -z "$result" ]]
}

@test "list_managed_paths handles missing vendored_skills_source key" {
  mkdir -p "$SOURCE_DIR/.claude-agent-flow"
  cat > "$SOURCE_DIR/.claude-agent-flow/repo-sync-manifest.yml" << 'EOF'
version: 1
source_repo: "org/test"
managed_files: []
targets: []
EOF
  cd "$SOURCE_DIR"
  result=$(list_managed_paths)
  [[ -z "$result" ]]
}

@test "list_managed_paths skips vendored skill dir that does not exist" {
  mkdir -p "$SOURCE_DIR/.claude-agent-flow"
  mkdir -p "$SOURCE_DIR/.claude/skills/sync-plugin-skills"
  cat > "$SOURCE_DIR/.claude/skills/sync-plugin-skills/skills-filter.yaml" << 'EOF'
included:
  - nonexistent-skill
EOF
  cat > "$SOURCE_DIR/.claude-agent-flow/repo-sync-manifest.yml" << 'EOF'
version: 1
source_repo: "org/test"
managed_files: []
vendored_skills_source: .claude/skills/sync-plugin-skills/skills-filter.yaml
targets: []
EOF
  cd "$SOURCE_DIR"
  result=$(list_managed_paths)
  [[ "$result" != *"nonexistent-skill"* ]]
}

@test "list_managed_paths handles empty/invalid skills-filter.yaml" {
  mkdir -p "$SOURCE_DIR/.claude-agent-flow"
  mkdir -p "$SOURCE_DIR/.claude/skills/sync-plugin-skills"
  # Empty file parses to null, not a dict
  echo "" > "$SOURCE_DIR/.claude/skills/sync-plugin-skills/skills-filter.yaml"
  cat > "$SOURCE_DIR/.claude-agent-flow/repo-sync-manifest.yml" << 'EOF'
version: 1
source_repo: "org/test"
managed_files: []
vendored_skills_source: .claude/skills/sync-plugin-skills/skills-filter.yaml
targets: []
EOF
  cd "$SOURCE_DIR"
  # Should not crash — just returns no vendored paths
  run list_managed_paths
  assert_success
}

@test "list_managed_paths rejects skill names with path traversal" {
  mkdir -p "$SOURCE_DIR/.claude-agent-flow"
  mkdir -p "$SOURCE_DIR/.claude/skills/sync-plugin-skills"
  cat > "$SOURCE_DIR/.claude/skills/sync-plugin-skills/skills-filter.yaml" << 'EOF'
included:
  - ../../etc/passwd
  - legit-skill/../../../tmp
  - normal/nested
  - foo\bar
  - .
EOF
  cat > "$SOURCE_DIR/.claude-agent-flow/repo-sync-manifest.yml" << 'EOF'
version: 1
source_repo: "org/test"
managed_files: []
vendored_skills_source: .claude/skills/sync-plugin-skills/skills-filter.yaml
targets: []
EOF
  cd "$SOURCE_DIR"
  run list_managed_paths
  assert_success
  [[ "$output" != *"etc/passwd"* ]]
  [[ "$output" != *"tmp"* ]]
  [[ "$output" != *"normal/nested"* ]]
  [[ "$output" != *"foo"* ]]
}

# ── parse_source_repo ────────────────────────────────────────────────────────

@test "parse_source_repo extracts repo from manifest" {
  mkdir -p "$SOURCE_DIR/.claude-agent-flow"
  cat > "$SOURCE_DIR/.claude-agent-flow/repo-sync-manifest.yml" << 'EOF'
source_repo: org/myrepo
targets: []
EOF
  cd "$SOURCE_DIR"
  result=$(parse_source_repo)
  [[ "$result" == "org/myrepo" ]]
}

# ── validate_secrets ─────────────────────────────────────────────────────────

@test "validate_secrets exits 1 when required secret missing" {
  unset MY_REQUIRED_SECRET
  local summary_file
  summary_file=$(mktemp)
  export GITHUB_STEP_SUMMARY="$summary_file"
  export GITHUB_SERVER_URL="https://github.com"
  export GITHUB_REPOSITORY="org/repo"
  run validate_secrets "MY_REQUIRED_SECRET" "" "Test Workflow"
  assert_failure
  [[ "$output" == *"::error title="* ]]
  [[ "$output" == *"MY_REQUIRED_SECRET"* ]]
  [[ "$(cat "$summary_file")" == *"Missing Required Secrets"* ]]
  rm -f "$summary_file"
  unset GITHUB_STEP_SUMMARY GITHUB_SERVER_URL GITHUB_REPOSITORY
}

@test "validate_secrets warns on optional secret missing" {
  unset MY_OPTIONAL_SECRET
  local summary_file
  summary_file=$(mktemp)
  export GITHUB_STEP_SUMMARY="$summary_file"
  run validate_secrets "" "MY_OPTIONAL_SECRET" "Test Workflow"
  assert_success
  [[ "$output" == *"::warning title="* ]]
  [[ "$output" == *"MY_OPTIONAL_SECRET"* ]]
  [[ -z "$(cat "$summary_file")" ]]
  rm -f "$summary_file"
  unset GITHUB_STEP_SUMMARY
}

@test "validate_secrets passes silently when all secrets present" {
  export REQ_SECRET="value1"
  export OPT_SECRET="value2"
  local summary_file
  summary_file=$(mktemp)
  export GITHUB_STEP_SUMMARY="$summary_file"
  run validate_secrets "REQ_SECRET" "OPT_SECRET" "Test Workflow"
  assert_success
  [[ -z "$output" ]]
  [[ -z "$(cat "$summary_file")" ]]
  rm -f "$summary_file"
  unset REQ_SECRET OPT_SECRET GITHUB_STEP_SUMMARY
}

@test "validate_secrets handles mix of missing required and optional" {
  unset REQ_MISSING
  export REQ_PRESENT="val"
  unset OPT_MISSING
  local summary_file
  summary_file=$(mktemp)
  export GITHUB_STEP_SUMMARY="$summary_file"
  export GITHUB_SERVER_URL="https://github.com"
  export GITHUB_REPOSITORY="org/repo"
  run validate_secrets $'REQ_MISSING\nREQ_PRESENT' "OPT_MISSING" "Test Workflow"
  assert_failure
  [[ "$output" == *"::error title="* ]]
  [[ "$output" == *"REQ_MISSING"* ]]
  [[ "$output" != *"::error title=Missing secret::Required secret REQ_PRESENT"* ]]
  [[ "$output" == *"::warning title="* ]]
  [[ "$output" == *"OPT_MISSING"* ]]
  rm -f "$summary_file"
  unset REQ_PRESENT GITHUB_STEP_SUMMARY GITHUB_SERVER_URL GITHUB_REPOSITORY
}

@test "validate_secrets writes Job Summary with setup doc link" {
  unset MISSING_SECRET
  local summary_file
  summary_file=$(mktemp)
  export GITHUB_STEP_SUMMARY="$summary_file"
  export GITHUB_SERVER_URL="https://github.com"
  export GITHUB_REPOSITORY="org/repo"
  run validate_secrets "MISSING_SECRET" "" "Test Workflow"
  [[ "$(cat "$summary_file")" == *"agent-flow-repo-setup.md"* ]]
  [[ "$(cat "$summary_file")" == *"https://github.com/org/repo"* ]]
  rm -f "$summary_file"
  unset GITHUB_STEP_SUMMARY GITHUB_SERVER_URL GITHUB_REPOSITORY
}
