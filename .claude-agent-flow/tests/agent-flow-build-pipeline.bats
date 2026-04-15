#!/usr/bin/env bats
# agent-flow-build-pipeline.bats
# Static checks verifying TECHSTACK context propagation across build.md,
# agent files, and CLAUDE.md (TASK-60).

BUILD_MD="${BATS_TEST_DIRNAME}/../../.claude/commands/build.md"
CLAUDE_MD="${BATS_TEST_DIRNAME}/../../CLAUDE.md"
AGENTS_DIR="${BATS_TEST_DIRNAME}/../../.claude/agents"

# ---------------------------------------------------------------------------
# Tests 1-7: build.md — session-resume guard and per-step reminders
# ---------------------------------------------------------------------------

@test "1. build.md: 'Session-resume rule' present after step 2b" {
  grep -q "Session-resume rule" "$BUILD_MD"
}

@test "2. build.md: session-resume guard mentions techstack_context reload" {
  region=$(sed -n '/omit the section from briefs/,/^3\. If design decisions/p' "$BUILD_MD")
  [ -n "$region" ] || { echo "Could not find session-resume region"; return 1; }
  echo "$region" | grep -q "techstack_context"
}

@test "3. build.md: step 9 (builder) block contains techstack_context verbatim reminder" {
  region=$(sed -n '/^9\. Invoke the relevant builder/,/^10\. After each builder/p' "$BUILD_MD")
  [ -n "$region" ] || { echo "Could not find step 9 block"; return 1; }
  echo "$region" | grep -q "techstack_context.*verbatim"
}

@test "4. build.md: step 12 (critic) block contains techstack_context verbatim reminder" {
  region=$(sed -n '/^12\. Invoke critic with exactly this context/,/^13\. After each critic/p' "$BUILD_MD")
  [ -n "$region" ] || { echo "Could not find step 12 block"; return 1; }
  echo "$region" | grep -q "techstack_context.*verbatim"
}

@test "5. build.md: step 16 (tester) block contains techstack_context verbatim reminder" {
  region=$(sed -n '/^16\. Invoke tester with/,/^17\. After tester/p' "$BUILD_MD")
  [ -n "$region" ] || { echo "Could not find step 16 block"; return 1; }
  echo "$region" | grep -q "techstack_context.*verbatim"
}

@test "6. build.md: step 20 (reviewer) block contains techstack_context verbatim reminder" {
  region=$(sed -n '/^20\. Invoke reviewer/,/^21\. After reviewer/p' "$BUILD_MD")
  [ -n "$region" ] || { echo "Could not find step 20 block"; return 1; }
  echo "$region" | grep -q "techstack_context.*verbatim"
}

@test "7. build.md: step 22 (author) block contains techstack_context verbatim reminder" {
  region=$(sed -n '/^22\. Invoke author/,/^23\. After author/p' "$BUILD_MD")
  [ -n "$region" ] || { echo "Could not find step 22 block"; return 1; }
  echo "$region" | grep -q "techstack_context.*verbatim"
}

# ---------------------------------------------------------------------------
# Tests 8-15: Agent files — TECHSTACK awareness 1-liners
# ---------------------------------------------------------------------------

@test "8. critic.md: contains 'TECHSTACK.md context' and 'do not fail for unlisted technologies'" {
  grep -q "TECHSTACK.md context" "${AGENTS_DIR}/critic.md"
  grep -q "do not fail for unlisted technologies" "${AGENTS_DIR}/critic.md"
}

@test "9. reviewer.md: contains 'TECHSTACK.md context'" {
  grep -q "TECHSTACK.md context" "${AGENTS_DIR}/reviewer.md"
}

@test "10. author.md: contains 'TECHSTACK.md context'" {
  grep -q "TECHSTACK.md context" "${AGENTS_DIR}/author.md"
}

@test "11. architect.md: contains 'TECHSTACK.md context'" {
  grep -q "TECHSTACK.md context" "${AGENTS_DIR}/architect.md"
}

@test "12. frontend.md: contains 'TECHSTACK.md context from your brief'" {
  grep -q "TECHSTACK.md context from your brief" "${AGENTS_DIR}/frontend.md"
}

@test "13. backend.md: contains 'TECHSTACK.md context from your brief'" {
  grep -q "TECHSTACK.md context from your brief" "${AGENTS_DIR}/backend.md"
}

@test "14. storage.md: contains 'TECHSTACK.md context from your brief'" {
  grep -q "TECHSTACK.md context from your brief" "${AGENTS_DIR}/storage.md"
}

@test "15. tester.md: contains 'TECHSTACK.md context from your brief'" {
  grep -q "TECHSTACK.md context from your brief" "${AGENTS_DIR}/tester.md"
}

# ---------------------------------------------------------------------------
# Tests 16-17: CLAUDE.md — universal agent rule
# ---------------------------------------------------------------------------

@test "16. CLAUDE.md: Technology Stack section contains brief-include trigger phrase" {
  grep -q "if your brief includes a" "$CLAUDE_MD"
}

@test "17. CLAUDE.md: universal rule contains self-read fallback phrase" {
  grep -q "read \`TECHSTACK.md\` at the project root yourself before beginning work" "$CLAUDE_MD"
}
