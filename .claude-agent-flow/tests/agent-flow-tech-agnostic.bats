#!/usr/bin/env bats
# Consolidated technology-agnostic checks with list-driven assertions.

setup() {
  load test_helper
}

assert_no_terms_in_file() {
  local file="$1"
  shift
  local terms=("$@")

  for term in "${terms[@]}"; do
    local matched
    matched=$(grep -En "$term" "$file" 2>/dev/null | head -3)
    if [[ -n "$matched" ]]; then
      echo "FAIL: banned term '$term' found in $file:" >&2
      echo "$matched" >&2
      return 1
    fi
  done
}

@test "agent docs avoid banned technology terms (list-driven)" {
  local files=(
    "$PROJECT_ROOT/.claude/agents/frontend.md"
    "$PROJECT_ROOT/.claude/agents/backend.md"
    "$PROJECT_ROOT/.claude/agents/storage.md"
    "$PROJECT_ROOT/.claude/agents/tester.md"
  )

  local banned_terms=(
    '\\bReact\\b'
    '\\bTypeScript\\b'
    '\\bTailwind\\b'
    'Node/Python'
    '\\bn8n\\b'
    '\\bSupabase\\b'
    'Postgres, Supabase'
    '\\bpgvector\\b'
    'OneDrive'
    'S3-compatible object storage'
    'n8n workflow logic'
    'npx vitest'
    'Backend: \\.pytest'
    '`pytest`'
    'npm test.*per stack'
    'Anti-patterns that mean you have FAILED'
    'NEVER use Inter'
  )

  local file
  for file in "${files[@]}"; do
    assert_no_terms_in_file "$file" "${banned_terms[@]}" || {
      echo "offending file: $file" >&2
      return 1
    }
  done
}

@test "build/plan commands keep generic language" {
  local checks=(
    "$PROJECT_ROOT/.claude/commands/build.md|No generic system fonts"
    "$PROJECT_ROOT/.claude/commands/plan.md|UI/React/CSS"
  )

  local entry file pattern
  for entry in "${checks[@]}"; do
    file="${entry%%|*}"
    pattern="${entry#*|}"
    if grep -q "$pattern" "$file"; then
      echo "FAIL: found banned phrase '$pattern' in $file" >&2
      return 1
    fi
  done
}

@test "TECHSTACK.md includes required metadata and sections" {
  skip_unless_source_repo
  local techstack="$PROJECT_ROOT/TECHSTACK.md"
  [[ -f "$techstack" ]] || {
    echo "FAIL: missing $techstack" >&2
    return 1
  }

  local required_patterns=(
    'generated_by: agent-flow'
    'last_scanned:'
    '^## Languages'
  )

  local pattern
  for pattern in "${required_patterns[@]}"; do
    if ! grep -Eq "$pattern" "$techstack"; then
      echo "FAIL: missing pattern '$pattern' in $techstack" >&2
      return 1
    fi
  done
}
