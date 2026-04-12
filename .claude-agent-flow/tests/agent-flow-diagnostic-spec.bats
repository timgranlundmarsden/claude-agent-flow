#!/usr/bin/env bats
# agent-flow-diagnostic-spec.bats
#
# Verifies the diagnostic.md command specification is correct:
#  - Check 1 validation logic handles both source-repo and downstream formats
#  - Check 4 session-start.sh path resolution steps are present
#  - Mergiraf platform-guard is specified
#  - Step 4 summary excludes [SKIP] and [N/A ] from N and M counts
#  - test-local-install.sh smoke test timeouts (source repo only — skipped in plugin repo)

setup() {
  load test_helper
  # BATS_TEST_FILENAME is the absolute path to the .bats file itself
  TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  PROJECT_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
  DIAGNOSTIC_MD="$PROJECT_ROOT/.claude/commands/diagnostic.md"
  INSTALL_TEST_SH="$PROJECT_ROOT/.claude-agent-flow/tests/test-local-install.sh"
}

# ── diagnostic.md exists ─────────────────────────────────────────────────────

@test "diagnostic.md exists" {
  [[ -f "$DIAGNOSTIC_MD" ]]
}

@test "test-local-install.sh exists" {
  [[ -f "$INSTALL_TEST_SH" ]] || skip "test-local-install.sh not present (source repo only)"
  [[ -f "$INSTALL_TEST_SH" ]]
}

# ── Change A: Check 1 — source repo accepts both old and new formats ─────────

@test "Check 1: source-repo branch accepts installed:true (old format)" {
  grep -q "installed: true" "$DIAGNOSTIC_MD"
}

@test "Check 1: source-repo branch accepts source_repo field (new format)" {
  # The spec must say EITHER installed:true OR source_repo present is a pass
  grep -q "EITHER" "$DIAGNOSTIC_MD"
}

@test "Check 1: downstream branch still requires source_repo" {
  # Downstream validation must not have been weakened
  grep -A5 "Otherwise.*downstream install" "$DIAGNOSTIC_MD" | grep -q "source_repo"
}

@test "Check 1: downstream branch still requires scope" {
  grep -A5 "Otherwise.*downstream install" "$DIAGNOSTIC_MD" | grep -q "scope"
}

@test "Check 1: downstream branch still requires synced_at" {
  grep -A5 "Otherwise.*downstream install" "$DIAGNOSTIC_MD" | grep -q "synced_at"
}

@test "Check 1: source-repo condition tests for repo-sync-manifest.yml targets section" {
  grep -q "repo-sync-manifest.yml.*targets" "$DIAGNOSTIC_MD"
}

# ── Change B: Check 4 — session-start.sh path resolution ────────────────────

@test "Check 4: local path resolution step is present (sandbox)" {
  grep -q "\.claude-agent-flow/scripts/session-start\.sh" "$DIAGNOSTIC_MD"
}

@test "Check 4: plugin env var resolution step is present" {
  grep -q 'CLAUDE_PLUGIN_ROOT' "$DIAGNOSTIC_MD"
}

@test "Check 4: settings-derived plugin cache resolution step is present" {
  grep -q "enabledPlugins" "$DIAGNOSTIC_MD"
}

@test "Check 4: hook-derived path resolution step is present" {
  grep -q "Hook-derived path" "$DIAGNOSTIC_MD"
  grep -q "SessionStart" "$DIAGNOSTIC_MD"
}

@test "Check 4: broad cache scan resolution step is present" {
  grep -q "find.*plugins/cache" "$DIAGNOSTIC_MD"
}

@test "Check 4: missing session-start.sh is a FAIL not a skip" {
  # Must NOT say "skip" for the not-found case — must be a real FAIL
  local not_found_line
  not_found_line=$(grep "session-start.sh not found" "$DIAGNOSTIC_MD")
  [[ -n "$not_found_line" ]]
  echo "$not_found_line" | grep -q "\[FAIL\]"
  echo "$not_found_line" | grep -qv "\[SKIP\]"
}

@test "Check 4: path resolution has at least 4 numbered probe steps" {
  # Count numbered resolution steps (1. 2. 3. 4. 5.) in the Check 4 section
  # The spec has 4 probes + 1 failure-case step = 5 total
  local count
  count=$(awk '/\*\*Check 4: Session start tools\*\*/,/\*\*Check 5:/' "$DIAGNOSTIC_MD" \
    | grep -c '^[0-9]\+\. ')
  [[ "$count" -ge 4 ]]
}

@test "Check 4: EXPECTED_TOOLS is read dynamically from session-start.sh" {
  grep -q "EXPECTED_TOOLS" "$DIAGNOSTIC_MD"
}

@test "Check 4: uname -s platform detection is required before tool checks" {
  grep -q "uname -s" "$DIAGNOSTIC_MD"
}

@test "Check 4: uname -m architecture detection is required before tool checks" {
  grep -q "uname -m" "$DIAGNOSTIC_MD"
}

# ── Mergiraf platform guard ──────────────────────────────────────────────────

@test "Check 4: Mergiraf has platform check before binary check" {
  grep -A3 '"Mergiraf"' "$DIAGNOSTIC_MD" | grep -q "Platform check first"
}

@test "Check 4: Mergiraf is skipped on unsupported platforms" {
  grep -A4 '"Mergiraf"' "$DIAGNOSTIC_MD" | grep -q "unsupported platform"
}

@test "Check 4: Mergiraf skip outputs [SKIP] not [FAIL]" {
  grep -A4 '"Mergiraf"' "$DIAGNOSTIC_MD" | grep -q "\[SKIP\]"
}

@test "Check 4: Mergiraf documents Darwin arm64 as supported" {
  grep -A4 '"Mergiraf"' "$DIAGNOSTIC_MD" | grep -q "Darwin arm64"
}

@test "Check 4: Mergiraf documents Darwin x86_64 as supported" {
  grep -A4 '"Mergiraf"' "$DIAGNOSTIC_MD" | grep -q "Darwin x86_64"
}

@test "Check 4: Mergiraf documents Linux x86_64 as supported" {
  grep -A4 '"Mergiraf"' "$DIAGNOSTIC_MD" | grep -q "Linux x86_64"
}

@test "Check 4: [SKIP] output format is documented for platform-unsupported tools" {
  grep -q "\[SKIP\] Tool installed:" "$DIAGNOSTIC_MD"
}

# ── Change D: Step 4 summary counting ───────────────────────────────────────

@test "Step 4: [SKIP] lines are excluded from N (pass count)" {
  grep -q "\[SKIP\].*do NOT count" "$DIAGNOSTIC_MD"
}

@test "Step 4: [N/A ] lines are excluded from M (total count)" {
  grep -q "\[N/A \].*do NOT count" "$DIAGNOSTIC_MD"
}

@test "Step 4: skipped count suffix is documented" {
  grep -q "K skipped" "$DIAGNOSTIC_MD"
}

@test "Step 4: Result line format N/M passed is present" {
  grep -q "Result: N/M passed" "$DIAGNOSTIC_MD"
}

@test "Step 4: skipped suffix Result line format is present" {
  grep -q "Result: N/M passed (K skipped)" "$DIAGNOSTIC_MD"
}

# ── Invariant: tool list must NOT be hardcoded ───────────────────────────────

@test "diagnostic.md forbids hardcoding tool list" {
  grep -q "do NOT hardcode the list" "$DIAGNOSTIC_MD"
}

@test "diagnostic.md forbids using which for binary checks" {
  grep -q 'command -v.*not.*which\|not.*which.*command -v\|Use.*command -v.*not.*which' "$DIAGNOSTIC_MD"
}

@test "diagnostic.md does not invoke agent-flow-init-check as guard" {
  grep -q "Do NOT use.*agent-flow-init-check" "$DIAGNOSTIC_MD"
}

# ── Change E: timeout values in test-local-install.sh ───────────────────────

@test "test-local-install.sh: sandbox smoke test uses 240s timeout" {
  [[ -f "$INSTALL_TEST_SH" ]] || skip "test-local-install.sh not present (source repo only)"
  local line
  line=$(grep "portable_timeout.*claude.*-p.*diagnostic" "$INSTALL_TEST_SH" | grep -v "\-\-plugin-dir")
  [[ -n "$line" ]]
  echo "$line" | grep -q "portable_timeout 240"
}

@test "test-local-install.sh: smoke tests use perl or timeout, not bash background fallback" {
  [[ -f "$INSTALL_TEST_SH" ]] || skip "test-local-install.sh not present (source repo only)"
  # Verify portable_timeout uses perl alarm+exec as fallback (no background+wait race)
  grep -q 'perl -e' "$INSTALL_TEST_SH"
}

# ── Step 1: session-start.sh is listed as a file to read ────────────────────

@test "Step 1: session-start.sh is listed in files to read" {
  grep -q "session-start\.sh" "$DIAGNOSTIC_MD"
}

# ── Probe via Bash constraint (no template substitution) ─────────────────────

@test "Check 4: CLAUDE_PLUGIN_ROOT is probed via Bash echo, not template-substituted" {
  # The spec must use Bash to echo the var, not ${CLAUDE_PLUGIN_ROOT} as a literal substitute
  grep -q 'echo.*CLAUDE_PLUGIN_ROOT' "$DIAGNOSTIC_MD"
}
