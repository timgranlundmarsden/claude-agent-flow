#!/usr/bin/env bash
# test_helper.bash — Shared setup/teardown and assertion helpers for BATS tests

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
SCRIPT_DIR="$PROJECT_ROOT/.claude-agent-flow/scripts"
FIXTURES_DIR="$TESTS_DIR/fixtures"

# Load BATS libraries
load "${TESTS_DIR}/lib/bats-support/load"
load "${TESTS_DIR}/lib/bats-assert/load"

# Setup temp directories for each test
setup_temp_dirs() {
  export SOURCE_DIR="$BATS_TEST_TMPDIR/source"
  export TARGET_DIR="$BATS_TEST_TMPDIR/target"
  mkdir -p "$SOURCE_DIR" "$TARGET_DIR"
}

# Initialize a real git repo in the given directory
setup_git_repo() {
  local dir="$1"
  git -C "$dir" init --quiet
  git -C "$dir" config user.name "test"
  git -C "$dir" config user.email "test@test.com"
  git -C "$dir" config commit.gpgsign false
  git -C "$dir" commit --allow-empty --quiet -m "init"
}

# Write a manifest.yml to source_dir/.claude-agent-flow/ (used by sync engine tests)
create_manifest() {
  local dir="$1"
  local content="$2"
  mkdir -p "$dir/.claude-agent-flow"
  if [[ -n "$content" ]]; then
    echo "$content" > "$dir/.claude-agent-flow/manifest.yml"
  else
    cat > "$dir/.claude-agent-flow/manifest.yml" <<'YAML'
version: 2
source_repo: testorg/test-source
managed_files:
  - .claude-agent-flow/
targets:
  - repo: testorg/test-target
    enabled: true
YAML
  fi
  # Also write a minimal install-manifest.yml so install tests don't fail
  if [[ ! -f "$dir/.claude-agent-flow/install-manifest.yml" ]]; then
    cat > "$dir/.claude-agent-flow/install-manifest.yml" <<'YAML'
version: 1
merge_files: []
YAML
  fi
}

# Extract canonical owner/repo from a git remote URL (SSH or HTTPS, with or without .git)
_parse_owner_repo() {
  local url="$1"
  # Strip trailing .git
  url="${url%.git}"
  # SSH: git@github.com:owner/repo -> owner/repo
  if [[ "$url" == git@* ]]; then
    echo "${url#*:}"
  # HTTPS: https://github.com/owner/repo -> owner/repo
  elif [[ "$url" == https://* || "$url" == http://* ]]; then
    echo "${url}" | sed 's|https\{0,1\}://[^/]*/||'
  else
    echo ""
  fi
}

# Check if the current repo is the source repo defined in repo-sync-manifest.yml
is_source_repo() {
  local manifest="$PROJECT_ROOT/.claude-agent-flow/repo-sync-manifest.yml"
  # No manifest = assume source (tests are synced with the manifest, so this shouldn't happen)
  [[ -f "$manifest" ]] || return 0
  local source_repo
  # Extract source_repo value: skip comments, strip quotes, take first match
  source_repo=$(sed -n '/^[[:space:]]*source_repo:/{ s/^[[:space:]]*source_repo:[[:space:]]*//; s/^["'"'"']//; s/["'"'"'][[:space:]]*$//; p; q; }' "$manifest")
  [[ -n "$source_repo" ]] || return 0
  local remote_url
  remote_url=$(git -C "$PROJECT_ROOT" remote get-url origin 2>/dev/null || true)
  local remote_repo
  remote_repo=$(_parse_owner_repo "$remote_url")
  [[ -n "$remote_repo" ]] && [[ "$remote_repo" == "$source_repo" ]]
}

# Skip test if not running in the source repo
skip_unless_source_repo() {
  is_source_repo || skip "only runs in source repo"
}

# Assert a jq expression equals expected value
assert_jq() {
  local label="$1" expr="$2" expected="$3" json="$4"
  local actual
  actual=$(echo "$json" | jq -r "$expr" 2>/dev/null)
  if [[ "$actual" == "$expected" ]]; then
    return 0
  else
    echo "FAIL: $label (expected='$expected' got='$actual')" >&2
    return 1
  fi
}

# Assert a jq count expression equals expected integer
assert_jq_count() {
  local label="$1" expr="$2" expected="$3" json="$4"
  local actual
  actual=$(echo "$json" | jq "$expr" 2>/dev/null)
  if [[ "$actual" == "$expected" ]]; then
    return 0
  else
    echo "FAIL: $label (expected=$expected got=$actual)" >&2
    return 1
  fi
}
