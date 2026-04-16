#!/usr/bin/env bats
# Tests for --force flag and 72h threshold in techstack-refresh and related files

setup() {
  load test_helper
}

# Helper: given age in hours, returns 0 if stale (>= 72h), 1 if fresh (< 72h)
is_stale_by_age() {
  local hours="$1"
  [[ "$hours" -ge 72 ]]
}

# ── techstack-refresh --force behaviour ──────────────────────────────────────

@test "1. techstack-refresh: --force appears in usage line" {
  local REFRESH="$PROJECT_ROOT/.claude/commands/techstack-refresh.md"
  grep -q '\-\-force' "$REFRESH"
}

@test "2. techstack-refresh: help text describes --force flag" {
  local REFRESH="$PROJECT_ROOT/.claude/commands/techstack-refresh.md"
  grep -q 'Bypass the 72-hour freshness check' "$REFRESH"
}

@test "3. techstack-refresh: flag parsing sets force_mode from --force argument" {
  local REFRESH="$PROJECT_ROOT/.claude/commands/techstack-refresh.md"
  grep -q 'force_mode' "$REFRESH"
}

@test "4. techstack-refresh: fresh guard checks force_mode is false" {
  local REFRESH="$PROJECT_ROOT/.claude/commands/techstack-refresh.md"
  grep -qE 'AND.*force_mode.*is false|force_mode.*is false' "$REFRESH"
}

@test "4b. techstack-refresh: continue-to-Step-2 condition includes force_mode" {
  local REFRESH="$PROJECT_ROOT/.claude/commands/techstack-refresh.md"
  grep -qE 'missing.*stale.*force_mode|force_mode.*continue to Step 2|missing, stale, or.*force_mode' "$REFRESH"
}

@test "4c. techstack-refresh: Case C handler includes force_mode for force+fresh scenario" {
  local REFRESH="$PROJECT_ROOT/.claude/commands/techstack-refresh.md"
  grep -qE 'stale.*force_mode.*Case C|force_mode.*true.*Case C|stale or.*force_mode.*Case C' "$REFRESH"
}

@test "4d. techstack-refresh: Step 4 write condition includes force_mode" {
  local REFRESH="$PROJECT_ROOT/.claude/commands/techstack-refresh.md"
  # stale or force_mode must appear at least twice: once in Step 3 (line ~77), once in Step 4 (~line 92)
  local count
  count=$(grep -cE 'stale or.*force_mode|force_mode.*true.*Case C' "$REFRESH")
  [[ "$count" -ge 2 ]]
}

@test "5. techstack-refresh: hint message contains --force suggestion" {
  local REFRESH="$PROJECT_ROOT/.claude/commands/techstack-refresh.md"
  grep -q 'techstack-refresh --force' "$REFRESH"
}

@test "6. techstack-refresh: no 'No action needed' text remains" {
  local REFRESH="$PROJECT_ROOT/.claude/commands/techstack-refresh.md"
  ! grep -q 'No action needed' "$REFRESH"
}

# ── --help ordering ───────────────────────────────────────────────────────────

@test "7. techstack-refresh: --help check precedes flag parsing in file" {
  local REFRESH="$PROJECT_ROOT/.claude/commands/techstack-refresh.md"
  local help_line force_line
  help_line=$(grep -n 'contains.*--help.*standalone\|--help.*as a standalone word' "$REFRESH" | head -1 | cut -d: -f1)
  force_line=$(grep -n 'force_mode' "$REFRESH" | head -1 | cut -d: -f1)
  [[ -n "$help_line" ]] || { echo "Could not find --help standalone line" >&2; return 1; }
  [[ -n "$force_line" ]] || { echo "Could not find force_mode line" >&2; return 1; }
  [[ "$help_line" -lt "$force_line" ]]
}

@test "7b. techstack-refresh: STOP directive appears before flag parsing (--help wins at runtime)" {
  local REFRESH="$PROJECT_ROOT/.claude/commands/techstack-refresh.md"
  local stop_line force_line
  stop_line=$(grep -n 'stop here — do not read or execute' "$REFRESH" | head -1 | cut -d: -f1)
  force_line=$(grep -n 'force_mode' "$REFRESH" | head -1 | cut -d: -f1)
  [[ -n "$stop_line" ]] || { echo "Could not find STOP directive line" >&2; return 1; }
  [[ -n "$force_line" ]] || { echo "Could not find force_mode line" >&2; return 1; }
  [[ "$stop_line" -lt "$force_line" ]]
}

# ── no-change + force path ────────────────────────────────────────────────────

@test "8. techstack-refresh: force no-change path updates last_scanned and commits" {
  local REFRESH="$PROJECT_ROOT/.claude/commands/techstack-refresh.md"
  grep -q 'forced rescan, no changes' "$REFRESH"
}

@test "8b. techstack-refresh: last_scanned update and commit message are co-located in Step 3" {
  local REFRESH="$PROJECT_ROOT/.claude/commands/techstack-refresh.md"
  local ts_line commit_line
  ts_line=$(grep -n 'update.*last_scanned\|last_scanned.*current UTC' "$REFRESH" | head -1 | cut -d: -f1)
  commit_line=$(grep -n 'forced rescan, no changes' "$REFRESH" | head -1 | cut -d: -f1)
  [[ -n "$ts_line" ]] || { echo "Could not find last_scanned update line" >&2; return 1; }
  [[ -n "$commit_line" ]] || { echo "Could not find commit message line" >&2; return 1; }
  local diff=$(( commit_line - ts_line ))
  [[ "${diff#-}" -le 10 ]]  # absolute value <= 10
}

# ── explorer brief mentions --force ───────────────────────────────────────────

@test "9. techstack-refresh: explorer brief mentions --force case as Case C" {
  local REFRESH="$PROJECT_ROOT/.claude/commands/techstack-refresh.md"
  grep -qE 'force was passed.*Case C|--force.*Case C|force.*treat as Case C' "$REFRESH"
}

# ── 72h threshold across all four files ───────────────────────────────────────

@test "10. techstack-refresh.md: freshness threshold is 72 hours not 24" {
  local REFRESH="$PROJECT_ROOT/.claude/commands/techstack-refresh.md"
  grep -q '72 hours ago' "$REFRESH"
  ! grep -q '24 hours ago' "$REFRESH"
}

@test "11. plan.md: freshness threshold is 72 hours not 24" {
  local plan="$PROJECT_ROOT/.claude/commands/plan.md"
  grep -q '72 hours ago' "$plan"
  ! grep -qE 'last_scanned.*24 hours|24 hours.*last_scanned' "$plan"
}

@test "12. build.md: freshness threshold is 72 hours not 24" {
  local build="$PROJECT_ROOT/.claude/commands/build.md"
  grep -q '72 hours ago' "$build"
  ! grep -qE 'last_scanned.*24 hours|24 hours.*last_scanned' "$build"
}

@test "13. explorer.md: Case B and C thresholds are 72 hours" {
  local explorer="$PROJECT_ROOT/.claude/agents/explorer.md"
  grep -q 'last_scanned.*< 72 hours ago' "$explorer"
  grep -q 'last_scanned.*>= 72 hours ago' "$explorer"
  ! grep -q 'last_scanned.*24 hours' "$explorer"
}

# ── freshness boundary logic ──────────────────────────────────────────────────

@test "14. freshness boundary: 71h ago is fresh (not stale)" {
  ! is_stale_by_age 71
}

@test "15. freshness boundary: 72h ago is stale (boundary — >= 72h)" {
  is_stale_by_age 72
}

@test "16. freshness boundary: 73h ago is stale" {
  is_stale_by_age 73
}

@test "17. freshness boundary: 24h ago is fresh under new 72h rule" {
  ! is_stale_by_age 24
}

@test "18. freshness boundary: 48h ago is fresh under new 72h rule" {
  ! is_stale_by_age 48
}

@test "19. freshness boundary: 0h ago (just scanned) is fresh" {
  ! is_stale_by_age 0
}

# ── structural tests ──────────────────────────────────────────────────────────

@test "20. techstack-refresh: [--force] present in usage line not just --force" {
  local REFRESH="$PROJECT_ROOT/.claude/commands/techstack-refresh.md"
  grep -q '\[--force\]' "$REFRESH"
}

@test "21. techstack-refresh: flag parsing is after branch guard" {
  local REFRESH="$PROJECT_ROOT/.claude/commands/techstack-refresh.md"
  local branch_guard_line force_line
  branch_guard_line=$(grep -n 'checkout -b claude/update-techstack' "$REFRESH" | head -1 | cut -d: -f1)
  force_line=$(grep -n 'force_mode' "$REFRESH" | head -1 | cut -d: -f1)
  [[ -n "$branch_guard_line" ]] || { echo "Could not find branch guard line" >&2; return 1; }
  [[ -n "$force_line" ]] || { echo "Could not find force_mode line" >&2; return 1; }
  [[ "$branch_guard_line" -lt "$force_line" ]]
}
