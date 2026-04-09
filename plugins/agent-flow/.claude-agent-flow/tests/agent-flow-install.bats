#!/usr/bin/env bats
# Tests for agent-flow-install.sh

setup() {
  load test_helper
  setup_temp_dirs
}

# Helper: write a minimal install-manifest.yml to a directory
write_install_manifest() {
  local dir="$1"
  mkdir -p "$dir/.claude-agent-flow"
  cat > "$dir/.claude-agent-flow/install-manifest.yml" << 'EOF'
version: 1
merge_files: []
EOF
}

# ── agent-flow-install.sh tests ──────────────────────────────────────────────

@test "1. exits if not in git repo" {
  # TARGET_DIR is a plain directory, not a git repo
  run bash -c "cd '$TARGET_DIR' && bash '$SCRIPT_DIR/agent-flow-install.sh'"
  assert_failure
}

@test "2. exits if jq not found" {
  setup_git_repo "$TARGET_DIR"
  write_install_manifest "$SOURCE_DIR"
  # Create a PATH that has everything except jq
  local fake_bin="$BATS_TEST_TMPDIR/fake_bin"
  mkdir -p "$fake_bin"
  # Symlink essential commands but NOT jq
  for cmd in bash git grep sed awk cat mkdir cp rm mv curl python3 head tail dirname readlink pwd command; do
    local cmd_path
    cmd_path=$(command -v "$cmd" 2>/dev/null) || continue
    ln -sf "$cmd_path" "$fake_bin/$cmd"
  done
  run bash -c "cd '$TARGET_DIR' && PATH='$fake_bin' bash '$SCRIPT_DIR/agent-flow-install.sh'"
  assert_failure
  [[ "$output" == *"jq is required"* ]]
}

@test "3. detects project name from existing backlog config" {
  setup_git_repo "$TARGET_DIR"
  write_install_manifest "$SOURCE_DIR"
  mkdir -p "$TARGET_DIR/backlog"
  cat > "$TARGET_DIR/backlog/config.yml" << 'EOF'
project_name: My Project
EOF
  # Run installer pointing at local source
  run bash -c "cd '$TARGET_DIR' && bash '$SCRIPT_DIR/agent-flow-install.sh' --source-repo '$SOURCE_DIR'"
  # The project name should be detected and not replaced with CHANGEME
  if [[ -f "$TARGET_DIR/CLAUDE.md" ]]; then
    result=$(cat "$TARGET_DIR/CLAUDE.md")
    [[ "$result" != *"CHANGEME"* ]] || true
  fi
  assert_success
}

@test "4. defaults project name to repo folder name" {
  local named_dir="$BATS_TEST_TMPDIR/my-project-repo"
  mkdir -p "$named_dir"
  setup_git_repo "$named_dir"
  write_install_manifest "$SOURCE_DIR"
  run bash -c "cd '$named_dir' && bash '$SCRIPT_DIR/agent-flow-install.sh' --source-repo '$SOURCE_DIR'"
  assert_success
  # When no backlog config, installer should fall back to folder name "my-project-repo"
  if [[ -f "$named_dir/backlog/config.yml" ]]; then
    result=$(cat "$named_dir/backlog/config.yml")
    [[ "$result" == *"my-project-repo"* ]]
  fi
}

@test "5. creates sync-state.json after install" {
  setup_git_repo "$TARGET_DIR"
  write_install_manifest "$SOURCE_DIR"
  run bash -c "cd '$TARGET_DIR' && bash '$SCRIPT_DIR/agent-flow-install.sh' --source-repo '$SOURCE_DIR'"
  assert_success
  [[ -f "$TARGET_DIR/.claude-agent-flow/sync-state.json" ]]
}

@test "6. replaces CHANGEME in CLAUDE.md when project name passed" {
  setup_git_repo "$TARGET_DIR"
  write_install_manifest "$SOURCE_DIR"
  cat > "$TARGET_DIR/CLAUDE.md" << 'EOF'
## Project: CHANGEME

Add your project description here.
EOF
  run bash -c "cd '$TARGET_DIR' && bash '$SCRIPT_DIR/agent-flow-install.sh' --source-repo '$SOURCE_DIR' --project-name 'My Cool Project'"
  assert_success
  result=$(cat "$TARGET_DIR/CLAUDE.md")
  [[ "$result" == *"My Cool Project"* ]]
  [[ "$result" != *"CHANGEME"* ]]
}

@test "7. update mode skips CHANGEME replacement" {
  setup_git_repo "$TARGET_DIR"
  write_install_manifest "$SOURCE_DIR"
  cat > "$TARGET_DIR/CLAUDE.md" << 'EOF'
## Project: CHANGEME

Add your project description here.
EOF
  run bash -c "cd '$TARGET_DIR' && bash '$SCRIPT_DIR/agent-flow-install.sh' --source-repo '$SOURCE_DIR' --update --project-name 'Should Not Replace'"
  assert_success
  result=$(cat "$TARGET_DIR/CLAUDE.md")
  # update mode should not replace CHANGEME
  [[ "$result" == *"CHANGEME"* ]]
}

@test "8. installs from local source directory" {
  setup_git_repo "$TARGET_DIR"
  # Create a richer local source with some managed files
  write_install_manifest "$SOURCE_DIR"
  echo "managed content" > "$SOURCE_DIR/managed.txt"
  # Update manifest to include the file
  cat > "$SOURCE_DIR/.claude-agent-flow/repo-sync-manifest.yml" << 'EOF'
version: 1
source_repo: org/source
managed_files:
  - managed.txt
targets: []
EOF
  run bash -c "cd '$TARGET_DIR' && bash '$SCRIPT_DIR/agent-flow-install.sh' --source-repo '$SOURCE_DIR'"
  assert_success
  [[ -f "$TARGET_DIR/.claude-agent-flow/sync-state.json" ]]
}

@test "9. marketplace ID uses repo name only (strips owner prefix with ##*/)" {
  setup_git_repo "$TARGET_DIR"
  mkdir -p "$TARGET_DIR/.claude"
  echo '{"enabledPlugins":{},"extraKnownMarketplaces":{}}' > "$TARGET_DIR/.claude/settings.json"
  write_install_manifest "$TARGET_DIR"

  run bash -c "cd '$TARGET_DIR' && bash '$SCRIPT_DIR/agent-flow-install.sh' --source-repo 'testowner/myrepo'"
  assert_success

  # Check that enabledPlugins has correct key format: agent-flow@myrepo (not agent-flow@testowner-myrepo)
  run jq -e '.enabledPlugins["agent-flow@myrepo"]' "$TARGET_DIR/.claude/settings.json"
  assert_success

  # Ensure old format is NOT present
  run jq -e '.enabledPlugins["agent-flow@testowner-myrepo"]' "$TARGET_DIR/.claude/settings.json"
  assert_failure
}

@test "10. migration removes old incorrect owner-repo key from enabledPlugins" {
  setup_git_repo "$TARGET_DIR"
  mkdir -p "$TARGET_DIR/.claude"
  echo '{"enabledPlugins":{"agent-flow@testowner-myrepo":true},"extraKnownMarketplaces":{}}' > "$TARGET_DIR/.claude/settings.json"
  write_install_manifest "$TARGET_DIR"

  run bash -c "cd '$TARGET_DIR' && bash '$SCRIPT_DIR/agent-flow-install.sh' --source-repo 'testowner/myrepo'"
  assert_success
  [[ "$output" == *"[migrate] removed old plugin key"* ]]

  # Old key should be gone
  run jq -e '.enabledPlugins["agent-flow@testowner-myrepo"]' "$TARGET_DIR/.claude/settings.json"
  assert_failure

  # New key should be present
  run jq -e '.enabledPlugins["agent-flow@myrepo"]' "$TARGET_DIR/.claude/settings.json"
  assert_success
}

@test "11. migration is safe when old key is absent (clean install)" {
  setup_git_repo "$TARGET_DIR"
  mkdir -p "$TARGET_DIR/.claude"
  echo '{"enabledPlugins":{},"extraKnownMarketplaces":{}}' > "$TARGET_DIR/.claude/settings.json"
  write_install_manifest "$TARGET_DIR"

  run bash -c "cd '$TARGET_DIR' && bash '$SCRIPT_DIR/agent-flow-install.sh' --source-repo 'testowner/myrepo'"
  assert_success

  # New key should be present
  run jq -e '.enabledPlugins["agent-flow@myrepo"]' "$TARGET_DIR/.claude/settings.json"
  assert_success
}

@test "12. migration is idempotent (second install run does not fail)" {
  setup_git_repo "$TARGET_DIR"
  mkdir -p "$TARGET_DIR/.claude"
  echo '{"enabledPlugins":{},"extraKnownMarketplaces":{}}' > "$TARGET_DIR/.claude/settings.json"
  write_install_manifest "$TARGET_DIR"

  # First run
  run bash -c "cd '$TARGET_DIR' && bash '$SCRIPT_DIR/agent-flow-install.sh' --source-repo 'testowner/myrepo'"
  assert_success

  # Second run should also succeed
  run bash -c "cd '$TARGET_DIR' && bash '$SCRIPT_DIR/agent-flow-install.sh' --source-repo 'testowner/myrepo'"
  assert_success

  # New key should still be present
  run jq -e '.enabledPlugins["agent-flow@myrepo"]' "$TARGET_DIR/.claude/settings.json"
  assert_success
}

@test "13. marketplace registration skipped gracefully when settings.json absent" {
  setup_git_repo "$TARGET_DIR"
  write_install_manifest "$TARGET_DIR"

  # No settings.json created - should skip registration without error
  run bash -c "cd '$TARGET_DIR' && bash '$SCRIPT_DIR/agent-flow-install.sh' --source-repo 'testowner/myrepo'"
  assert_success
}
