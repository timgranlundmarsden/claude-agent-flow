#!/usr/bin/env bats
# Tests for reviewer agent external review integration

setup() {
  load test_helper
}

@test "1. reviewer agent file exists" {
  [[ -f "$PROJECT_ROOT/.claude/agents/reviewer.md" ]]
}

@test "2. reviewer agent references external-code-review script" {
  grep -q "external-code-review/external-review.sh" "$PROJECT_ROOT/.claude/agents/reviewer.md"
}

@test "3. reviewer agent calls script twice" {
  local count
  count=$(grep -c "external-review.sh" "$PROJECT_ROOT/.claude/agents/reviewer.md")
  [[ "$count" -ge 2 ]]
}

@test "4. reviewer agent includes aggregation instructions" {
  grep -q "Aggregate" "$PROJECT_ROOT/.claude/agents/reviewer.md" || \
  grep -q "aggregate" "$PROJECT_ROOT/.claude/agents/reviewer.md" || \
  grep -q "AGGREGATE" "$PROJECT_ROOT/.claude/agents/reviewer.md"
}

@test "5. reviewer agent includes deduplication rules" {
  grep -qi "deduplic" "$PROJECT_ROOT/.claude/agents/reviewer.md"
}

@test "6. reviewer agent includes DISAGREEMENTS section in output" {
  grep -q "DISAGREEMENTS" "$PROJECT_ROOT/.claude/agents/reviewer.md"
}

@test "7. reviewer agent references external-review-config.repo.yml for suppressions" {
  grep -q "external-review-config.repo.yml" "$PROJECT_ROOT/.claude/agents/reviewer.md"
}

@test "8. reviewer agent includes graceful degradation" {
  grep -qi "graceful\|skip.*external\|env.*var.*not set\|EXTERNAL_REVIEW_API_KEY" "$PROJECT_ROOT/.claude/agents/reviewer.md"
}

@test "9. reviewer agent preserves read-only constraint with exception" {
  grep -q "read-only" "$PROJECT_ROOT/.claude/agents/reviewer.md"
  grep -q "external-review-config.repo.yml" "$PROJECT_ROOT/.claude/agents/reviewer.md"
}

@test "10. reviewer agent includes highest severity rule" {
  grep -qi "highest severity" "$PROJECT_ROOT/.claude/agents/reviewer.md"
}

@test "11. reviewer agent includes equal weight instruction" {
  grep -qi "equal weight" "$PROJECT_ROOT/.claude/agents/reviewer.md"
}

@test "12. reviewer agent includes External reviews line in output format" {
  grep -q "External reviews:" "$PROJECT_ROOT/.claude/agents/reviewer.md"
}
