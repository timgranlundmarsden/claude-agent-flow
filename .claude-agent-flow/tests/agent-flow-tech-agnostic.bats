#!/usr/bin/env bats
# Validates that the agent-flow plugin is technology-agnostic:
# - No tech brand names in builder agent definitions
# - No hardcoded tool commands in generic test instructions
# - Ways-of-working roster table uses generic role descriptions
# - build.md and plan.md use generic language

setup() {
  load test_helper
}

# ── Part A: No tech brand names in builder agents ─────────────────────────────

@test "frontend.md: no React in domain or description" {
  ! grep -q '\bReact\b' "$PROJECT_ROOT/.claude/agents/frontend.md"
}

@test "frontend.md: no TypeScript in domain or description" {
  ! grep -q '\bTypeScript\b' "$PROJECT_ROOT/.claude/agents/frontend.md"
}

@test "frontend.md: no Tailwind in domain or description" {
  ! grep -q '\bTailwind\b' "$PROJECT_ROOT/.claude/agents/frontend.md"
}

@test "frontend.md: contains no anti-pattern block (font rules removed)" {
  ! grep -q 'Anti-patterns that mean you have FAILED' "$PROJECT_ROOT/.claude/agents/frontend.md"
}

@test "frontend.md: contains no NEVER font prohibition in typography line" {
  ! grep -q 'NEVER use Inter' "$PROJECT_ROOT/.claude/agents/frontend.md"
}

@test "backend.md: no Node/Python tech stack in description" {
  ! grep -q 'Node/Python' "$PROJECT_ROOT/.claude/agents/backend.md"
}

@test "backend.md: no n8n in domain list" {
  ! grep -q '\bn8n\b' "$PROJECT_ROOT/.claude/agents/backend.md"
}

@test "backend.md: no Supabase in domain list" {
  ! grep -q '\bSupabase\b' "$PROJECT_ROOT/.claude/agents/backend.md"
}

@test "backend.md: no Postgres brand name in domain list" {
  ! grep -q 'Supabase / Postgres' "$PROJECT_ROOT/.claude/agents/backend.md"
}

@test "storage.md: no Postgres brand in description" {
  ! grep -q 'Postgres, Supabase' "$PROJECT_ROOT/.claude/agents/storage.md"
}

@test "storage.md: no Supabase-specific line" {
  ! grep -q 'Supabase-specific' "$PROJECT_ROOT/.claude/agents/storage.md"
}

@test "storage.md: no pgvector brand name" {
  ! grep -q '\bpgvector\b' "$PROJECT_ROOT/.claude/agents/storage.md"
}

@test "storage.md: no OneDrive brand name" {
  ! grep -q 'OneDrive' "$PROJECT_ROOT/.claude/agents/storage.md"
}

@test "storage.md: no S3-compatible specific bullet" {
  ! grep -q 'S3-compatible object storage' "$PROJECT_ROOT/.claude/agents/storage.md"
}

@test "storage.md: no n8n in Never touch line" {
  ! grep -q 'n8n workflow logic' "$PROJECT_ROOT/.claude/agents/storage.md"
}

# ── Part A: No hardcoded tool commands in generic test instructions ────────────

@test "tester.md: no npm-specific test command in app test instruction" {
  # The app test instruction line should not reference npm or vitest directly
  ! grep -q 'npx vitest' "$PROJECT_ROOT/.claude/agents/tester.md"
}

@test "tester.md: no pytest in app test instruction" {
  # Backend pytest line should be removed
  ! grep -q 'Backend: .pytest' "$PROJECT_ROOT/.claude/agents/tester.md"
}

@test "backend.md: no pytest in test suite instruction" {
  ! grep -q '`pytest`' "$PROJECT_ROOT/.claude/agents/backend.md"
}

@test "backend.md: no npm test in test suite instruction" {
  ! grep -q 'npm test.*per stack' "$PROJECT_ROOT/.claude/agents/backend.md"
}

# ── Part A: Ways-of-working roster table uses generic descriptions ────────────

@test "ways-of-working: no React in agent roster table" {
  local skill="$PROJECT_ROOT/.claude/skills/ways-of-working/SKILL.md"
  local row
  row=$(grep -E '^\| frontend' "$skill")
  [[ -n "$row" ]]  # guard: row must exist
  ! echo "$row" | grep -q '\bReact\b'
}

@test "ways-of-working: no TypeScript in agent roster table" {
  local skill="$PROJECT_ROOT/.claude/skills/ways-of-working/SKILL.md"
  local row
  row=$(grep -E '^\| frontend' "$skill")
  [[ -n "$row" ]]  # guard: row must exist
  ! echo "$row" | grep -q '\bTypeScript\b'
}

@test "ways-of-working: no Tailwind in agent roster table" {
  local skill="$PROJECT_ROOT/.claude/skills/ways-of-working/SKILL.md"
  local row
  row=$(grep -E '^\| frontend' "$skill")
  [[ -n "$row" ]]  # guard: row must exist
  ! echo "$row" | grep -q '\bTailwind\b'
}

@test "ways-of-working: no Supabase in backend roster entry" {
  local skill="$PROJECT_ROOT/.claude/skills/ways-of-working/SKILL.md"
  local row
  row=$(grep -E '^\| backend' "$skill")
  [[ -n "$row" ]]  # guard: row must exist
  ! echo "$row" | grep -q '\bSupabase\b'
}

@test "ways-of-working: no n8n in backend roster entry" {
  local skill="$PROJECT_ROOT/.claude/skills/ways-of-working/SKILL.md"
  local row
  row=$(grep -E '^\| backend' "$skill")
  [[ -n "$row" ]]  # guard: row must exist
  ! echo "$row" | grep -q '\bn8n\b'
}

# ── Part A: build.md and plan.md use generic language ─────────────────────────

@test "build.md: no 'No generic system fonts' trailing clause" {
  ! grep -q 'No generic system fonts' "$PROJECT_ROOT/.claude/commands/build.md"
}

@test "plan.md: no 'UI/React/CSS' label inference rule" {
  ! grep -q 'UI/React/CSS' "$PROJECT_ROOT/.claude/commands/plan.md"
}

@test "plan.md: has 'UI/styling/components' label inference rule" {
  grep -q 'UI/styling/components' "$PROJECT_ROOT/.claude/commands/plan.md"
}

# ── Part B: TECHSTACK.md format validation ────────────────────────────────────

@test "TECHSTACK.md exists at project root" {
  [[ -f "$PROJECT_ROOT/TECHSTACK.md" ]]
}

@test "TECHSTACK.md has generated_by frontmatter" {
  grep -q 'generated_by: agent-flow' "$PROJECT_ROOT/TECHSTACK.md"
}

@test "TECHSTACK.md has last_scanned frontmatter" {
  grep -q 'last_scanned:' "$PROJECT_ROOT/TECHSTACK.md"
}

@test "TECHSTACK.md has Languages section" {
  grep -q '^## Languages' "$PROJECT_ROOT/TECHSTACK.md"
}

@test "TECHSTACK.md has description in frontmatter" {
  grep -q '^description:' "$PROJECT_ROOT/TECHSTACK.md"
}
