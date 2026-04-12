#!/usr/bin/env bats
# Tests for /agent-flow-external-review command and /external-review alias

setup() {
  load test_helper
}

# ── Command file structure ───────────────────────────────────────────────────

@test "1. command file exists" {
  [[ -f "$PROJECT_ROOT/.claude/commands/external-review.md" ]]
}

@test "2. command file has correct frontmatter name" {
  head -5 "$PROJECT_ROOT/.claude/commands/external-review.md" | grep -q 'name: external-review'
}

@test "3. command file includes --help handling" {
  grep -q '\-\-help' "$PROJECT_ROOT/.claude/commands/external-review.md"
}

@test "4. command file references the shared script path" {
  grep -q 'external-code-review/external-review.sh' "$PROJECT_ROOT/.claude/commands/external-review.md"
}

@test "5. command file includes ARGUMENTS substitution" {
  grep -q '\$ARGUMENTS' "$PROJECT_ROOT/.claude/commands/external-review.md"
}

@test "6. command file includes diff generation step" {
  grep -q 'merge-base' "$PROJECT_ROOT/.claude/commands/external-review.md"
}

@test "7. command file mentions env vars for user guidance" {
  grep -q 'EXTERNAL_REVIEW_API_KEY' "$PROJECT_ROOT/.claude/commands/external-review.md"
  grep -q 'EXTERNAL_REVIEW_MODEL' "$PROJECT_ROOT/.claude/commands/external-review.md"
  grep -q 'EXTERNAL_REVIEW_API_BASE_URL' "$PROJECT_ROOT/.claude/commands/external-review.md"
}

# ── Command script path ──────────────────────────────────────────────────────

@test "8. command file references new plugin script path" {
  grep -q '\.claude/skills/external-code-review/external-review\.sh' "$PROJECT_ROOT/.claude/commands/external-review.md"
}

@test "9. command file includes result handling step" {
  grep -q 'RESULT' "$PROJECT_ROOT/.claude/commands/external-review.md"
}

@test "10. command file output format includes verdict" {
  grep -q 'Verdict' "$PROJECT_ROOT/.claude/commands/external-review.md"
}

@test "11. command file output format includes concerns" {
  grep -q 'Concerns' "$PROJECT_ROOT/.claude/commands/external-review.md"
}

# ── Skill file ───────────────────────────────────────────────────────────────

@test "12. skill SKILL.md exists and is non-empty" {
  local skill_file="$PROJECT_ROOT/.claude/skills/external-code-review/SKILL.md"
  [[ -f "$skill_file" ]]
  [[ -s "$skill_file" ]]
}

@test "13. skill SKILL.md has correct frontmatter name" {
  head -5 "$PROJECT_ROOT/.claude/skills/external-code-review/SKILL.md" | grep -q 'name: external-code-review'
}

@test "14. skill SKILL.md documents script interface" {
  grep -q 'external-review.sh' "$PROJECT_ROOT/.claude/skills/external-code-review/SKILL.md"
}

@test "15. skill SKILL.md documents env vars" {
  grep -q 'EXTERNAL_REVIEW_API_KEY' "$PROJECT_ROOT/.claude/skills/external-code-review/SKILL.md"
  grep -q 'EXTERNAL_REVIEW_MODEL' "$PROJECT_ROOT/.claude/skills/external-code-review/SKILL.md"
}

@test "16. command file passes suppress-config flags to script" {
  grep -q '\-\-suppress-config' "$PROJECT_ROOT/.claude/commands/external-review.md"
}

@test "17. command file references both shared and repo suppress configs" {
  grep -q 'external-review-config.yml' "$PROJECT_ROOT/.claude/commands/external-review.md"
  grep -q 'external-review-config.repo.yml' "$PROJECT_ROOT/.claude/commands/external-review.md"
}
