#!/usr/bin/env bats

load 'lib/bats-support/load'
load 'lib/bats-assert/load'
load 'test_helper'

setup() {
    export TEST_PROJECT="$BATS_TMPDIR/test-hooks-migration"
    mkdir -p "$TEST_PROJECT"
}

teardown() {
    rm -rf "$TEST_PROJECT" 2>/dev/null || true
}

@test "hooks/hooks.json exists and is valid JSON with scripts/ path" {
  run jq . "$PROJECT_ROOT/.claude-agent-flow/hooks/hooks.json"
  assert_success
  grep -q "CLAUDE_PLUGIN_ROOT" "$PROJECT_ROOT/.claude-agent-flow/hooks/hooks.json"
  grep -q "scripts/session-start.sh" "$PROJECT_ROOT/.claude-agent-flow/hooks/hooks.json"
}

@test "agent-flow-install.sh syntax is valid" {
    run bash -n "$PROJECT_ROOT/.claude-agent-flow/scripts/agent-flow-install.sh"
    assert_success
}

@test "integration test: settings.json SessionStart hook references correct path" {
    local hook_cmd
    hook_cmd=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$PROJECT_ROOT/.claude/settings.json" 2>/dev/null || echo "")
    [[ "$hook_cmd" == *"scripts/session-start.sh"* ]]
    [[ "$hook_cmd" != *"hooks/session-start.sh"* ]]
}

@test "git recognizes session-start.sh in scripts/ directory" {
    cd "$PROJECT_ROOT"
    run git ls-files ".claude-agent-flow/scripts/session-start.sh"
    assert_success
    assert_output --partial "session-start.sh"
}

@test "settings.json syntax remains valid" {
    run jq . "$PROJECT_ROOT/.claude/settings.json"
    assert_success
    run jq -e '.hooks.SessionStart[0].hooks[0].command' "$PROJECT_ROOT/.claude/settings.json"
    assert_success
}

@test "error handling: install script syntax is valid without hooks directory" {
    local test_script="$BATS_TMPDIR/test-install.sh"
    cp "$PROJECT_ROOT/.claude-agent-flow/scripts/agent-flow-install.sh" "$test_script"
    run bash -n "$test_script"
    assert_success
}

@test "session-start.sh is executable and has valid syntax" {
    [ -x "$PROJECT_ROOT/.claude-agent-flow/scripts/session-start.sh" ]
    run bash -n "$PROJECT_ROOT/.claude-agent-flow/scripts/session-start.sh"
    assert_success
}

@test "generic sweep removes _agentFlow entries from all hook types" {
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

    run jq -r '.hooks.SessionStart | length' <(jq '
      .hooks //= {} |
      .hooks |= with_entries(.value |= map(select(._agentFlow != true))) |
      .hooks |= with_entries(select(.value | length > 0)) |
      if .hooks == {} then del(.hooks) else . end
    ' "$tmp_settings")
    assert_success
    assert_output "1"

    run jq -r '.hooks.PostToolUse | length' <(jq '
      .hooks //= {} |
      .hooks |= with_entries(.value |= map(select(._agentFlow != true))) |
      .hooks |= with_entries(select(.value | length > 0)) |
      if .hooks == {} then del(.hooks) else . end
    ' "$tmp_settings")
    assert_success
    assert_output "1"

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
    run jq 'has("hooks")' <(jq '
      .hooks //= {} |
      .hooks |= with_entries(.value |= map(select(._agentFlow != true))) |
      .hooks |= with_entries(select(.value | length > 0)) |
      if .hooks == {} then del(.hooks) else . end
    ' "$tmp_settings")
    assert_success
    assert_output "false"

    run jq -r '.model' <(jq '
      .hooks //= {} |
      .hooks |= with_entries(.value |= map(select(._agentFlow != true))) |
      .hooks |= with_entries(select(.value | length > 0)) |
      if .hooks == {} then del(.hooks) else . end
    ' "$tmp_settings")
    assert_success
    assert_output "claude-opus-4-5"
}

@test "hooks.json contains PostToolUse array with expected structure" {
    local hooks_json="$PROJECT_ROOT/.claude-agent-flow/hooks/hooks.json"

    run jq . "$hooks_json"
    assert_success

    run jq '.hooks.PostToolUse | length' "$hooks_json"
    assert_success
    assert_output "3"

    # Matchers and _agentFlow flags (list-driven)
    local expected_matchers=("Bash" "Skill" "mcp__*backlog*")
    local i
    for i in 0 1 2; do
      run jq -r ".hooks.PostToolUse[$i].matcher" "$hooks_json"
      assert_success
      [ "$output" = "${expected_matchers[$i]}" ] || {
        echo "FAIL: PostToolUse[$i].matcher='$output' want='${expected_matchers[$i]}'" >&2; return 1
      }
    done
    run jq '[.hooks.PostToolUse[] | ._agentFlow] | all' "$hooks_json"
    assert_output "true"

    # SessionStart must not be clobbered
    run jq -e '.hooks.SessionStart | length' "$hooks_json"
    assert_success
}

@test "agent-flow-install.sh copy block removed (regression guard)" {
    local install_sh="$PROJECT_ROOT/.claude-agent-flow/scripts/agent-flow-install.sh"
    ! grep -q "SS_SOURCE=" "$install_sh" || {
      echo "FAIL: SS_SOURCE= found — copy block was re-introduced" >&2; return 1
    }
    ! grep -q "SS_TARGET=" "$install_sh" || {
      echo "FAIL: SS_TARGET= found — copy block was re-introduced" >&2; return 1
    }
    ! grep -qE 'cp.*session-start|rsync.*session-start' "$install_sh" || {
      echo "FAIL: session-start copy/rsync command found — copy block was re-introduced" >&2; return 1
    }
}
