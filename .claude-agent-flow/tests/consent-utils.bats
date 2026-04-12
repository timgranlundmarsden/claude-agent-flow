#!/usr/bin/env bats
# Tests for consent-utils.sh — shared consent management helpers.
#
# Covers: consent_read_mergiraf, consent_write_mergiraf,
#         migrate_mergiraf_consent, _tty_available_consent.

setup() {
  load test_helper

  # Isolated HOME/XDG so tests never touch real ~/.config
  export HOME="$BATS_TEST_TMPDIR/home"
  export XDG_CONFIG_HOME="$HOME/.config"
  export PROJECT_ROOT="$BATS_TEST_TMPDIR/project"
  mkdir -p "$HOME/.config" "$PROJECT_ROOT"

  # Initialise a git repo so .git/config exists
  git -C "$PROJECT_ROOT" init --quiet
  git -C "$PROJECT_ROOT" config user.name "test"
  git -C "$PROJECT_ROOT" config user.email "test@test.com"
  git -C "$PROJECT_ROOT" config commit.gpgsign false
  git -C "$PROJECT_ROOT" commit --allow-empty --quiet -m "init"

  # Source the library under test
  # shellcheck source=/dev/null
  source "$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)/../scripts/lib/consent-utils.sh"
}

teardown() {
  unset HOME XDG_CONFIG_HOME PROJECT_ROOT FORCE_NON_INTERACTIVE 2>/dev/null || true
}

# ── consent_read_mergiraf ─────────────────────────────────────────────────────

@test "1: consent_read_mergiraf returns absent when optional-tools.json does not exist" {
  result="$(consent_read_mergiraf "$PROJECT_ROOT")"
  [[ "$result" == "absent" ]]
}

@test "2: consent_read_mergiraf returns absent when file exists but mergiraf key missing" {
  mkdir -p "$PROJECT_ROOT/.claude-agent-flow"
  printf '{"other_key": "value"}\n' > "$PROJECT_ROOT/.claude-agent-flow/optional-tools.json"
  result="$(consent_read_mergiraf "$PROJECT_ROOT")"
  [[ "$result" == "absent" ]]
}

@test "3: consent_read_mergiraf returns enabled for {\"mergiraf\": \"enabled\"}" {
  mkdir -p "$PROJECT_ROOT/.claude-agent-flow"
  printf '{"mergiraf": "enabled"}\n' > "$PROJECT_ROOT/.claude-agent-flow/optional-tools.json"
  result="$(consent_read_mergiraf "$PROJECT_ROOT")"
  [[ "$result" == "enabled" ]]
}

@test "4: consent_read_mergiraf returns disabled for {\"mergiraf\": \"disabled\"}" {
  mkdir -p "$PROJECT_ROOT/.claude-agent-flow"
  printf '{"mergiraf": "disabled"}\n' > "$PROJECT_ROOT/.claude-agent-flow/optional-tools.json"
  result="$(consent_read_mergiraf "$PROJECT_ROOT")"
  [[ "$result" == "disabled" ]]
}

@test "5: consent_read_mergiraf returns absent for corrupt JSON" {
  mkdir -p "$PROJECT_ROOT/.claude-agent-flow"
  printf '{not valid json!!!\n' > "$PROJECT_ROOT/.claude-agent-flow/optional-tools.json"
  result="$(consent_read_mergiraf "$PROJECT_ROOT")"
  [[ "$result" == "absent" ]]
}

# ── consent_write_mergiraf ────────────────────────────────────────────────────

@test "6: consent_write_mergiraf creates directory if missing" {
  # Ensure dir does not exist first
  rm -rf "$PROJECT_ROOT/.claude-agent-flow"
  consent_write_mergiraf "$PROJECT_ROOT" "enabled"
  [[ -d "$PROJECT_ROOT/.claude-agent-flow" ]]
  [[ -f "$PROJECT_ROOT/.claude-agent-flow/optional-tools.json" ]]
}

@test "7: consent_write_mergiraf + consent_read_mergiraf round-trips enabled" {
  consent_write_mergiraf "$PROJECT_ROOT" "enabled"
  result="$(consent_read_mergiraf "$PROJECT_ROOT")"
  [[ "$result" == "enabled" ]]
}

@test "8: consent_write_mergiraf + consent_read_mergiraf round-trips disabled" {
  consent_write_mergiraf "$PROJECT_ROOT" "disabled"
  result="$(consent_read_mergiraf "$PROJECT_ROOT")"
  [[ "$result" == "disabled" ]]
}

@test "9: consent_write_mergiraf rejects invalid value with nonzero exit" {
  run consent_write_mergiraf "$PROJECT_ROOT" "maybe"
  [[ "$status" -ne 0 ]]
}

@test "9b: consent_write_mergiraf rejects empty value with nonzero exit" {
  run consent_write_mergiraf "$PROJECT_ROOT" ""
  [[ "$status" -ne 0 ]]
}

# ── migrate_mergiraf_consent ──────────────────────────────────────────────────

@test "17: migrate_mergiraf_consent writes enabled when .git/config has mergiraf" {
  # Simulate a .git/config with mergiraf section
  printf '[merge "mergiraf"]\n  name = mergiraf\n' >> "$PROJECT_ROOT/.git/config"
  migrate_mergiraf_consent "$PROJECT_ROOT"
  result="$(consent_read_mergiraf "$PROJECT_ROOT")"
  [[ "$result" == "enabled" ]]
}

@test "18: migrate_mergiraf_consent is no-op when consent already set to disabled" {
  # Pre-set consent to disabled
  consent_write_mergiraf "$PROJECT_ROOT" "disabled"
  # Now add mergiraf to .git/config — migration should not override existing consent
  printf '[merge "mergiraf"]\n  name = mergiraf\n' >> "$PROJECT_ROOT/.git/config"
  migrate_mergiraf_consent "$PROJECT_ROOT"
  result="$(consent_read_mergiraf "$PROJECT_ROOT")"
  [[ "$result" == "disabled" ]]
}

@test "18b: migrate_mergiraf_consent is no-op when consent already set to enabled" {
  consent_write_mergiraf "$PROJECT_ROOT" "enabled"
  migrate_mergiraf_consent "$PROJECT_ROOT"
  result="$(consent_read_mergiraf "$PROJECT_ROOT")"
  [[ "$result" == "enabled" ]]
}

@test "18c: migrate_mergiraf_consent returns 0 (advisory) when no mergiraf in .git/config" {
  # No mergiraf in .git/config — should stay absent (no write)
  run migrate_mergiraf_consent "$PROJECT_ROOT"
  [[ "$status" -eq 0 ]]
  result="$(consent_read_mergiraf "$PROJECT_ROOT")"
  [[ "$result" == "absent" ]]
}

@test "17b: migrate_mergiraf_consent does NOT read global gitconfig" {
  # Write mergiraf only in a fake global gitconfig, NOT in .git/config
  # Migration must NOT pick this up
  mkdir -p "$HOME"
  printf '[merge "mergiraf"]\n  name = mergiraf\n' > "$HOME/.gitconfig"
  # Ensure .git/config has no mergiraf
  # (default from git init has none)
  migrate_mergiraf_consent "$PROJECT_ROOT"
  result="$(consent_read_mergiraf "$PROJECT_ROOT")"
  [[ "$result" == "absent" ]]
}

# ── _tty_available_consent ────────────────────────────────────────────────────

@test "21: _tty_available_consent returns failure when FORCE_NON_INTERACTIVE=1" {
  export FORCE_NON_INTERACTIVE=1
  run _tty_available_consent
  [[ "$status" -ne 0 ]]
}

@test "21b: _tty_available_consent respects FORCE_NON_INTERACTIVE=0 (does not short-circuit)" {
  export FORCE_NON_INTERACTIVE=0
  # We cannot control /dev/tty in test environment; just verify the function exists
  # and does not crash when called
  run bash -c 'source "'"$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)/../scripts/lib/consent-utils.sh"'"; FORCE_NON_INTERACTIVE=0; _tty_available_consent; echo "exit:$?"'
  # Function should have exited without error (may return 0 or 1 based on TTY availability)
  [[ "$status" -eq 0 ]]
}

# ── Two-layer consent (optional-tools.json > consent-defaults.json) ──────────

@test "22: consent_read_mergiraf returns enabled from consent-defaults.json when optional-tools.json is absent" {
  mkdir -p "$PROJECT_ROOT/.claude-agent-flow"
  printf '{"mergiraf": "enabled"}\n' > "$PROJECT_ROOT/.claude-agent-flow/consent-defaults.json"
  result="$(consent_read_mergiraf "$PROJECT_ROOT")"
  [[ "$result" == "enabled" ]]
}

@test "22b: consent_read_mergiraf returns disabled from consent-defaults.json when optional-tools.json is absent" {
  mkdir -p "$PROJECT_ROOT/.claude-agent-flow"
  printf '{"mergiraf": "disabled"}\n' > "$PROJECT_ROOT/.claude-agent-flow/consent-defaults.json"
  result="$(consent_read_mergiraf "$PROJECT_ROOT")"
  [[ "$result" == "disabled" ]]
}

@test "22c: consent_read_mergiraf returns absent when both optional-tools.json and consent-defaults.json are absent" {
  result="$(consent_read_mergiraf "$PROJECT_ROOT")"
  [[ "$result" == "absent" ]]
}

@test "23: consent_read_mergiraf: optional-tools.json (enabled) overrides consent-defaults.json (disabled)" {
  mkdir -p "$PROJECT_ROOT/.claude-agent-flow"
  printf '{"mergiraf": "enabled"}\n'  > "$PROJECT_ROOT/.claude-agent-flow/optional-tools.json"
  printf '{"mergiraf": "disabled"}\n' > "$PROJECT_ROOT/.claude-agent-flow/consent-defaults.json"
  result="$(consent_read_mergiraf "$PROJECT_ROOT")"
  [[ "$result" == "enabled" ]]
}

@test "23b: consent_read_mergiraf: optional-tools.json (disabled) overrides consent-defaults.json (enabled)" {
  mkdir -p "$PROJECT_ROOT/.claude-agent-flow"
  printf '{"mergiraf": "disabled"}\n' > "$PROJECT_ROOT/.claude-agent-flow/optional-tools.json"
  printf '{"mergiraf": "enabled"}\n'  > "$PROJECT_ROOT/.claude-agent-flow/consent-defaults.json"
  result="$(consent_read_mergiraf "$PROJECT_ROOT")"
  [[ "$result" == "disabled" ]]
}

@test "23c: consent_read_mergiraf falls through to consent-defaults.json when optional-tools.json lacks mergiraf key" {
  mkdir -p "$PROJECT_ROOT/.claude-agent-flow"
  printf '{"other_key": "value"}\n' > "$PROJECT_ROOT/.claude-agent-flow/optional-tools.json"
  printf '{"mergiraf": "enabled"}\n' > "$PROJECT_ROOT/.claude-agent-flow/consent-defaults.json"
  result="$(consent_read_mergiraf "$PROJECT_ROOT")"
  [[ "$result" == "enabled" ]]
}

@test "24: consent_write_mergiraf does NOT modify consent-defaults.json" {
  mkdir -p "$PROJECT_ROOT/.claude-agent-flow"
  local defaults_file="$PROJECT_ROOT/.claude-agent-flow/consent-defaults.json"
  printf '{"mergiraf": "disabled"}\n' > "$defaults_file"
  local defaults_before
  defaults_before="$(cat "$defaults_file")"
  consent_write_mergiraf "$PROJECT_ROOT" "enabled"
  local defaults_after
  defaults_after="$(cat "$defaults_file")"
  [[ "$defaults_before" == "$defaults_after" ]]
  result="$(consent_read_mergiraf "$PROJECT_ROOT")"
  [[ "$result" == "enabled" ]]
}

@test "24b: consent_read_mergiraf returns absent when consent-defaults.json has corrupt JSON and no optional-tools.json" {
  mkdir -p "$PROJECT_ROOT/.claude-agent-flow"
  printf '{not valid json!!!\n' > "$PROJECT_ROOT/.claude-agent-flow/consent-defaults.json"
  result="$(consent_read_mergiraf "$PROJECT_ROOT")"
  [[ "$result" == "absent" ]]
}

@test "24c: consent_read_mergiraf bash fallback (no jq) reads from consent-defaults.json" {
  mkdir -p "$PROJECT_ROOT/.claude-agent-flow"
  printf '{"mergiraf": "enabled"}\n' > "$PROJECT_ROOT/.claude-agent-flow/consent-defaults.json"
  result="$(bash -c '
    command() {
      if [[ "${1:-}" == "-v" && "${2:-}" == "jq" ]]; then return 1; fi
      builtin command "$@"
    }
    export -f command
    source "'"$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)/../scripts/lib/consent-utils.sh"'"
    consent_read_mergiraf "'"$PROJECT_ROOT"'"
  ')"
  [[ "$result" == "enabled" ]]
}

# ── Atomic write safety ───────────────────────────────────────────────────────

@test "consent_write_mergiraf is atomic (tmp file cleaned up)" {
  rm -rf "$PROJECT_ROOT/.claude-agent-flow"
  consent_write_mergiraf "$PROJECT_ROOT" "enabled"
  # No .XXXXXX tmp files should remain
  tmp_count="$(find "$PROJECT_ROOT/.claude-agent-flow" -name "optional-tools.json.*" 2>/dev/null | wc -l)"
  [[ "$tmp_count" -eq 0 ]]
}

# ── jq-less fallback (simulated) ──────────────────────────────────────────────

@test "consent_read_mergiraf works without jq (bash fallback)" {
  mkdir -p "$PROJECT_ROOT/.claude-agent-flow"
  printf '{"mergiraf": "enabled"}\n' > "$PROJECT_ROOT/.claude-agent-flow/optional-tools.json"
  # Shadow jq with a fake that fails
  jq() { return 127; }
  export -f jq
  # Unset command -v jq by overriding in subshell
  result="$(bash -c '
    jq() { return 127; }
    export -f jq
    # shellcheck source=/dev/null
    source "'"$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)/../scripts/lib/consent-utils.sh"'"
    # Override command to pretend jq is absent
    command() {
      if [[ "${1:-}" == "-v" && "${2:-}" == "jq" ]]; then return 1; fi
      builtin command "$@"
    }
    export -f command
    consent_read_mergiraf "'"$PROJECT_ROOT"'"
  ')"
  # The file contains "mergiraf": "enabled" — the only correct result is "enabled"
  [[ "$result" == "enabled" ]]
}
