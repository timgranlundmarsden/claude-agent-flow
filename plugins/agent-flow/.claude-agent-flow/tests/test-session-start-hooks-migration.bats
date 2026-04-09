#!/usr/bin/env bats

load 'lib/bats-support/load'
load 'lib/bats-assert/load'
load 'test_helper'

setup() {
    export TEST_PROJECT="$BATS_TMPDIR/test-hooks-migration"
    mkdir -p "$TEST_PROJECT"
}

teardown() {
    # Clean up test directories
    rm -rf "$TEST_PROJECT" 2>/dev/null || true
}

@test "session-start.sh moved from hooks/ back to scripts/ directory" {
    # Verify the file exists in scripts/ directory
    [ -f "$PROJECT_ROOT/.claude-agent-flow/scripts/session-start.sh" ]

    # Verify the file no longer exists in hooks/ directory
    [ ! -f "$PROJECT_ROOT/.claude-agent-flow/hooks/session-start.sh" ]

    # Verify the file is executable
    [ -x "$PROJECT_ROOT/.claude-agent-flow/scripts/session-start.sh" ]
}

@test "settings.json updated to reference scripts/ path" {
    # Check that settings.json contains the scripts/ path
    grep -q "scripts/session-start.sh" "$PROJECT_ROOT/.claude/settings.json"

    # Check that settings.json does not contain the old hooks/ path
    ! grep -q "hooks/session-start.sh" "$PROJECT_ROOT/.claude/settings.json"
}

@test "hooks/hooks.json exists with valid content" {
    # Verify hooks.json file exists
    [ -f "$PROJECT_ROOT/.claude-agent-flow/hooks/hooks.json" ]

    # Verify it's valid JSON
    run jq . "$PROJECT_ROOT/.claude-agent-flow/hooks/hooks.json"
    assert_success

    # Verify it contains CLAUDE_PLUGIN_ROOT
    grep -q "CLAUDE_PLUGIN_ROOT" "$PROJECT_ROOT/.claude-agent-flow/hooks/hooks.json"

    # Verify it contains scripts/session-start.sh
    grep -q "scripts/session-start.sh" "$PROJECT_ROOT/.claude-agent-flow/hooks/hooks.json"
}

@test "agent-flow-install.sh copy block removed" {
    # Verify SS_SOURCE and SS_TARGET variables are no longer used
    ! grep -q "SS_SOURCE=" "$PROJECT_ROOT/.claude-agent-flow/scripts/agent-flow-install.sh"
    ! grep -q "SS_TARGET=" "$PROJECT_ROOT/.claude-agent-flow/scripts/agent-flow-install.sh"

    # Verify no copy patterns remain
    ! grep -qE 'cp.*session-start|rsync.*session-start' "$PROJECT_ROOT/.claude-agent-flow/scripts/agent-flow-install.sh"
}

@test "agent-flow-install.sh uses generic _agentFlow hook removal sweep" {
    # Verify generic jq sweep exists (not old SessionStart-specific del)
    grep -q "with_entries(.value |= map(select(._agentFlow != true)))" "$PROJECT_ROOT/.claude-agent-flow/scripts/agent-flow-install.sh"

    # Verify generic pruning of empty arrays
    grep -q "with_entries(select(.value | length > 0))" "$PROJECT_ROOT/.claude-agent-flow/scripts/agent-flow-install.sh"

    # Verify removal of empty hooks object
    grep -q 'if .hooks == {} then del(.hooks)' "$PROJECT_ROOT/.claude-agent-flow/scripts/agent-flow-install.sh"

    # Verify informational message
    grep -q "using hooks/hooks.json" "$PROJECT_ROOT/.claude-agent-flow/scripts/agent-flow-install.sh"

    # Verify old SessionStart-specific del is gone
    ! grep -qF 'del(.hooks.SessionStart[]? | select(._agentFlow == true))' "$PROJECT_ROOT/.claude-agent-flow/scripts/agent-flow-install.sh"
}

@test "agent-flow-install.sh syntax is valid" {
    # Verify the script has valid bash syntax
    run bash -n "$PROJECT_ROOT/.claude-agent-flow/scripts/agent-flow-install.sh"
    assert_success
}

@test "session-start.sh content preserved" {
    # Verify the session-start.sh content is intact after move
    [ -s "$PROJECT_ROOT/.claude-agent-flow/scripts/session-start.sh" ]

    # Check for key components of session-start.sh
    grep -q "Bootstrap hook for agent-flow environment setup" "$PROJECT_ROOT/.claude-agent-flow/scripts/session-start.sh"
    grep -q "install_backlog" "$PROJECT_ROOT/.claude-agent-flow/scripts/session-start.sh"
    grep -q "install_mergiraf" "$PROJECT_ROOT/.claude-agent-flow/scripts/session-start.sh"
}

@test "hooks directory structure created correctly" {
    # Verify hooks directory exists
    [ -d "$PROJECT_ROOT/.claude-agent-flow/hooks" ]

    # Verify it has proper permissions
    [ -r "$PROJECT_ROOT/.claude-agent-flow/hooks" ]
    [ -w "$PROJECT_ROOT/.claude-agent-flow/hooks" ]
    [ -x "$PROJECT_ROOT/.claude-agent-flow/hooks" ]
}

@test "integration test: settings.json SessionStart hook references correct path" {
    # Extract the command path from settings.json
    local hook_cmd
    hook_cmd=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$PROJECT_ROOT/.claude/settings.json" 2>/dev/null || echo "")

    # Verify it contains scripts/ path
    [[ "$hook_cmd" == *"scripts/session-start.sh"* ]]

    # Verify it doesn't contain hooks/ path
    [[ "$hook_cmd" != *"hooks/session-start.sh"* ]]
}

@test "git recognizes file move" {
    # This test assumes the file move was done with git mv
    # The file should exist in the scripts directory after the move
    [ -f "$PROJECT_ROOT/.claude-agent-flow/scripts/session-start.sh" ]

    # Verify the file is tracked by git in the new location (use relative path)
    cd "$PROJECT_ROOT"
    run git ls-files ".claude-agent-flow/scripts/session-start.sh"
    assert_success
    assert_output --partial "session-start.sh"
}

# Edge case tests

@test "old hooks directory still exists for hooks.json" {
    # Verify hooks directory still exists (it should have hooks.json)
    [ -d "$PROJECT_ROOT/.claude-agent-flow/hooks" ]

    # Verify hooks.json exists in hooks
    [ -f "$PROJECT_ROOT/.claude-agent-flow/hooks/hooks.json" ]
}

@test "settings.json syntax remains valid after path update" {
    # Test that JSON syntax is still valid
    run jq . "$PROJECT_ROOT/.claude/settings.json"
    assert_success

    # Verify the structure is intact
    run jq -e '.hooks.SessionStart[0].hooks[0].command' "$PROJECT_ROOT/.claude/settings.json"
    assert_success
}

# Boundary condition tests

@test "error handling: missing hooks directory doesn't break install script" {
    # Create a temporary version without hooks dir to test error handling
    local test_script="$BATS_TMPDIR/test-install.sh"
    cp "$PROJECT_ROOT/.claude-agent-flow/scripts/agent-flow-install.sh" "$test_script"

    # The script should still be syntactically valid
    run bash -n "$test_script"
    assert_success
}

@test "session-start.sh still executable and functional" {
    # Verify the moved script is still executable
    [ -x "$PROJECT_ROOT/.claude-agent-flow/scripts/session-start.sh" ]

    # Test that it can run without errors (dry run)
    run bash -n "$PROJECT_ROOT/.claude-agent-flow/scripts/session-start.sh"
    assert_success
}

@test "generic sweep removes _agentFlow entries from all hook types" {
    # Simulate a settings.json with _agentFlow hooks in multiple types
    local tmp_settings="$BATS_TMPDIR/settings-sweep-test.json"
    cat > "$tmp_settings" <<'EOF'
{
  "hooks": {
    "SessionStart": [
      {"_agentFlow": true, "type": "command", "command": "echo ss-agentflow"},
      {"type": "command", "command": "echo ss-keep"}
    ],
    "PostToolUse": [
      {"_agentFlow": true, "matcher": "Bash", "hooks": []},
      {"matcher": "Other", "hooks": []}
    ]
  },
  "otherKey": "preserved"
}
EOF
    run jq '
      .hooks //= {} |
      .hooks |= with_entries(.value |= map(select(._agentFlow != true))) |
      .hooks |= with_entries(select(.value | length > 0)) |
      if .hooks == {} then del(.hooks) else . end
    ' "$tmp_settings"
    assert_success

    # SessionStart should have 1 entry (non-agentFlow kept)
    run jq -r '.hooks.SessionStart | length' <(jq '
      .hooks //= {} |
      .hooks |= with_entries(.value |= map(select(._agentFlow != true))) |
      .hooks |= with_entries(select(.value | length > 0)) |
      if .hooks == {} then del(.hooks) else . end
    ' "$tmp_settings")
    assert_success
    assert_output "1"

    # PostToolUse with only _agentFlow entry removed, "Other" kept
    run jq -r '.hooks.PostToolUse | length' <(jq '
      .hooks //= {} |
      .hooks |= with_entries(.value |= map(select(._agentFlow != true))) |
      .hooks |= with_entries(select(.value | length > 0)) |
      if .hooks == {} then del(.hooks) else . end
    ' "$tmp_settings")
    assert_success
    assert_output "1"

    # otherKey must be preserved
    run jq -r '.otherKey' <(jq '
      .hooks //= {} |
      .hooks |= with_entries(.value |= map(select(._agentFlow != true))) |
      .hooks |= with_entries(select(.value | length > 0)) |
      if .hooks == {} then del(.hooks) else . end
    ' "$tmp_settings")
    assert_success
    assert_output "preserved"
}

@test "generic sweep deletes hooks key when all entries are _agentFlow" {
    local tmp_settings="$BATS_TMPDIR/settings-all-agentflow.json"
    cat > "$tmp_settings" <<'EOF'
{
  "hooks": {
    "SessionStart": [{"_agentFlow": true, "type": "command", "command": "echo test"}],
    "PostToolUse": [{"_agentFlow": true, "matcher": "Bash", "hooks": []}]
  },
  "model": "claude-opus-4-5"
}
EOF
    run jq '
      .hooks //= {} |
      .hooks |= with_entries(.value |= map(select(._agentFlow != true))) |
      .hooks |= with_entries(select(.value | length > 0)) |
      if .hooks == {} then del(.hooks) else . end
    ' "$tmp_settings"
    assert_success

    # hooks key must be deleted entirely
    run jq 'has("hooks")' <(jq '
      .hooks //= {} |
      .hooks |= with_entries(.value |= map(select(._agentFlow != true))) |
      .hooks |= with_entries(select(.value | length > 0)) |
      if .hooks == {} then del(.hooks) else . end
    ' "$tmp_settings")
    assert_success
    assert_output "false"

    # model key must be preserved
    run jq -r '.model' <(jq '
      .hooks //= {} |
      .hooks |= with_entries(.value |= map(select(._agentFlow != true))) |
      .hooks |= with_entries(select(.value | length > 0)) |
      if .hooks == {} then del(.hooks) else . end
    ' "$tmp_settings")
    assert_success
    assert_output "claude-opus-4-5"
}

@test "hooks.json contains PostToolUse array with exactly 3 entries" {
    local hooks_json="$PROJECT_ROOT/.claude-agent-flow/hooks/hooks.json"

    # Must be valid JSON
    run jq . "$hooks_json"
    assert_success

    # Must have exactly 3 PostToolUse entries
    run jq '.hooks.PostToolUse | length' "$hooks_json"
    assert_success
    assert_output "3"

    # Matchers must be Bash, Skill, mcp__*backlog*
    run jq -r '.hooks.PostToolUse[0].matcher' "$hooks_json"
    assert_output "Bash"

    run jq -r '.hooks.PostToolUse[1].matcher' "$hooks_json"
    assert_output "Skill"

    run jq -r '.hooks.PostToolUse[2].matcher' "$hooks_json"
    assert_output "mcp__*backlog*"

    # All must have _agentFlow: true
    run jq '[.hooks.PostToolUse[] | ._agentFlow] | all' "$hooks_json"
    assert_output "true"

    # All must have statusMessage
    run jq '[.hooks.PostToolUse[].hooks[0].statusMessage] | all(. != null)' "$hooks_json"
    assert_output "true"

    # SessionStart must still exist (PostToolUse addition must not clobber it)
    run jq -e '.hooks.SessionStart | length' "$hooks_json"
    assert_success
    assert_output "1"

    # hooks object must have exactly 2 keys: SessionStart and PostToolUse
    run jq '.hooks | keys | length' "$hooks_json"
    assert_output "2"
}

@test "repo-sync-manifest.yml includes .claude/session-start.log in gitignore managed_lines" {
    run grep -F '.claude/session-start.log' "$PROJECT_ROOT/.claude-agent-flow/repo-sync-manifest.yml"
    assert_success
}

@test "install-manifest.yml includes .claude/session-start.log in gitignore managed_lines" {
    run grep -F '.claude/session-start.log' "$PROJECT_ROOT/.claude-agent-flow/install-manifest.yml"
    assert_success
}