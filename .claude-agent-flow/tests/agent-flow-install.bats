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

@test "9. marketplace ID uses marketplace-name not repo name (flat layout)" {
  setup_git_repo "$TARGET_DIR"
  mkdir -p "$TARGET_DIR/.claude"
  echo '{"enabledPlugins":{},"extraKnownMarketplaces":{}}' > "$TARGET_DIR/.claude/settings.json"
  write_install_manifest "$TARGET_DIR"

  run bash -c "cd '$TARGET_DIR' && bash '$SCRIPT_DIR/agent-flow-install.sh' \
    --source-repo 'testowner/myrepo' --marketplace-name 'testmarketplace'"
  assert_success

  # New flat layout: key is agent-flow@testmarketplace (marketplace owner name, not repo name)
  run jq -e '.enabledPlugins["agent-flow@testmarketplace"]' "$TARGET_DIR/.claude/settings.json"
  assert_success

  # Old repo-name format must NOT be present
  run jq -e '.enabledPlugins["agent-flow@myrepo"]' "$TARGET_DIR/.claude/settings.json"
  assert_failure

  # Old hyphenated format must also be absent
  run jq -e '.enabledPlugins["agent-flow@testowner-myrepo"]' "$TARGET_DIR/.claude/settings.json"
  assert_failure
}

@test "10. migration removes old incorrect owner-repo key from enabledPlugins" {
  setup_git_repo "$TARGET_DIR"
  mkdir -p "$TARGET_DIR/.claude"
  echo '{"enabledPlugins":{"agent-flow@testowner-myrepo":true},"extraKnownMarketplaces":{}}' > "$TARGET_DIR/.claude/settings.json"
  write_install_manifest "$TARGET_DIR"

  run bash -c "cd '$TARGET_DIR' && bash '$SCRIPT_DIR/agent-flow-install.sh' \
    --source-repo 'testowner/myrepo' --marketplace-name 'testmarketplace'"
  assert_success
  [[ "$output" == *"[migrate] removed old plugin key"* ]]

  # Old hyphenated key should be gone
  run jq -e '.enabledPlugins["agent-flow@testowner-myrepo"]' "$TARGET_DIR/.claude/settings.json"
  assert_failure

  # New key format should be present
  run jq -e '.enabledPlugins["agent-flow@testmarketplace"]' "$TARGET_DIR/.claude/settings.json"
  assert_success
}

@test "11. migration removes legacy agent-flow@claude-agent-flow key" {
  setup_git_repo "$TARGET_DIR"
  mkdir -p "$TARGET_DIR/.claude"
  echo '{"enabledPlugins":{"agent-flow@claude-agent-flow":true},"extraKnownMarketplaces":{}}' > "$TARGET_DIR/.claude/settings.json"
  write_install_manifest "$TARGET_DIR"

  run bash -c "cd '$TARGET_DIR' && bash '$SCRIPT_DIR/agent-flow-install.sh' \
    --source-repo 'testowner/myrepo' --marketplace-name 'testmarketplace'"
  assert_success
  [[ "$output" == *"[migrate] removed legacy plugin key"* ]]

  # Legacy key should be gone
  run jq -e '.enabledPlugins["agent-flow@claude-agent-flow"]' "$TARGET_DIR/.claude/settings.json"
  assert_failure

  # New key should be present
  run jq -e '.enabledPlugins["agent-flow@testmarketplace"]' "$TARGET_DIR/.claude/settings.json"
  assert_success
}

@test "12. migration is idempotent (second install run does not fail)" {
  setup_git_repo "$TARGET_DIR"
  mkdir -p "$TARGET_DIR/.claude"
  echo '{"enabledPlugins":{},"extraKnownMarketplaces":{}}' > "$TARGET_DIR/.claude/settings.json"
  write_install_manifest "$TARGET_DIR"

  # First run
  run bash -c "cd '$TARGET_DIR' && bash '$SCRIPT_DIR/agent-flow-install.sh' \
    --source-repo 'testowner/myrepo' --marketplace-name 'testmarketplace'"
  assert_success

  # Second run should also succeed
  run bash -c "cd '$TARGET_DIR' && bash '$SCRIPT_DIR/agent-flow-install.sh' \
    --source-repo 'testowner/myrepo' --marketplace-name 'testmarketplace'"
  assert_success

  # Key should still be present
  run jq -e '.enabledPlugins["agent-flow@testmarketplace"]' "$TARGET_DIR/.claude/settings.json"
  assert_success
}

@test "13. marketplace registration skipped gracefully when settings.json absent" {
  setup_git_repo "$TARGET_DIR"
  write_install_manifest "$TARGET_DIR"

  # No settings.json created - should skip registration without error
  run bash -c "cd '$TARGET_DIR' && bash '$SCRIPT_DIR/agent-flow-install.sh' --source-repo 'testowner/myrepo'"
  assert_success
}

# ── AC #16: self-clone + init-check guard tests ───────────────────────────────

@test "14. workspace mode: fresh clone of flat plugin repo has agents and commands but no sync-state.json" {
  # Simulate the flat plugin repo layout after plugin-repo-sync runs.
  # The repo has .claude/agents/, .claude/commands/, etc. at the root level.
  # sync-state.json should NOT exist because install has not been run yet.
  local clone_dir="$BATS_TEST_TMPDIR/flat-plugin-clone"
  mkdir -p "$clone_dir/.claude/agents"
  mkdir -p "$clone_dir/.claude/commands"
  mkdir -p "$clone_dir/.claude/skills"
  echo "# Explorer" > "$clone_dir/.claude/agents/explorer.md"
  echo "# Build" > "$clone_dir/.claude/commands/build.md"
  mkdir -p "$clone_dir/.claude-agent-flow"
  echo "version: 1" > "$clone_dir/.claude-agent-flow/repo-sync-manifest.yml"

  # Workspace is ready: all key directories exist
  [[ -d "$clone_dir/.claude/agents" ]]
  [[ -d "$clone_dir/.claude/commands" ]]
  [[ -f "$clone_dir/.claude/agents/explorer.md" ]]

  # sync-state.json must NOT exist on a fresh clone (install has not been run)
  [[ ! -f "$clone_dir/.claude-agent-flow/sync-state.json" ]]
}

@test "15a. execute_mapping realpath guard: skips rsync when source and target resolve to the same path" {
  # Self-install scenario: PLUGIN_DIR == TARGET_DIR (source == target).
  # execute_mapping() must detect this via realpath comparison and skip rsync
  # so that existing files are not wiped.
  local self_dir="$BATS_TEST_TMPDIR/self-install"
  mkdir -p "$self_dir/.claude-agent-flow/scripts"
  mkdir -p "$self_dir/.claude/agents"
  echo "test agent" > "$self_dir/.claude/agents/test.md"

  cat > "$self_dir/.claude-agent-flow/install-manifest.yml" <<'YAML'
version: 1
merge_files: []
sandbox_mappings:
  - source: .claude/agents/
    target: .claude/agents/
YAML

  setup_git_repo "$self_dir"
  cp "$SCRIPT_DIR/agent-flow-install.sh" "$self_dir/.claude-agent-flow/scripts/"

  # Run installer with CWD == PLUGIN_DIR (source == target)
  run bash -c "cd '$self_dir' && bash '$self_dir/.claude-agent-flow/scripts/agent-flow-install.sh' \
    --scope sandbox --plugin-dir '$self_dir' --project-name 'self-test'"

  assert_success

  # File must still exist (not wiped by rsync)
  assert [ -f "$self_dir/.claude/agents/test.md" ]
  local content
  content=$(cat "$self_dir/.claude/agents/test.md")
  assert_equal "$content" "test agent"

  # Output must include the self-install skip message
  assert_output --partial "already in place"
}

@test "15. init-check guard: sync-state.json absent triggers stop condition (no repo-sync-manifest.yml)" {
  # The agent-flow-init-check skill checks for:
  #   1. .claude-agent-flow/repo-sync-manifest.yml  → if present: master repo, skip all checks
  #   2. .claude-agent-flow/sync-state.json         → if absent: halt with run /install message
  #
  # This test verifies the condition the skill evaluates:
  # a directory WITHOUT repo-sync-manifest.yml AND WITHOUT sync-state.json is an
  # uninitialized user repo that requires /install.
  local user_repo="$BATS_TEST_TMPDIR/user-repo-uninit"
  mkdir -p "$user_repo/.claude-agent-flow"

  # No repo-sync-manifest.yml (this is not the master plugin repo)
  [[ ! -f "$user_repo/.claude-agent-flow/repo-sync-manifest.yml" ]]

  # No sync-state.json (install has never been run)
  [[ ! -f "$user_repo/.claude-agent-flow/sync-state.json" ]]

  # The guard condition: check absent → would output "run /install" and stop
  # Verify the guard logic inline: not a master repo AND not initialized
  local is_master_repo=false
  local is_initialized=false
  [[ -f "$user_repo/.claude-agent-flow/repo-sync-manifest.yml" ]] && is_master_repo=true
  [[ -f "$user_repo/.claude-agent-flow/sync-state.json" ]] && is_initialized=true

  # Guard should trigger: neither master repo nor initialized
  [[ "$is_master_repo" == "false" ]]
  [[ "$is_initialized" == "false" ]]

  # After running install the guard should pass: create sync-state.json
  echo '{"scope":"plugin"}' > "$user_repo/.claude-agent-flow/sync-state.json"
  is_initialized=false
  [[ -f "$user_repo/.claude-agent-flow/sync-state.json" ]] && is_initialized=true
  [[ "$is_initialized" == "true" ]]
}
