#!/usr/bin/env bats
# Tests for .claude-agent-flow/scripts/ensure-feature-branch.sh

setup() {
  load test_helper
  export SCRIPT="$SCRIPT_DIR/ensure-feature-branch.sh"
}

# Helper: create a git repo in a temp dir and run the script inside it
run_in_repo() {
  local dir="$1"; shift
  run bash -c "cd '$dir' && bash '$SCRIPT' $*"
}

# ── 1. Non-git directory → exit 1 ──────────────────────────────────────────

@test "1. exit 1 when not in a git repository" {
  local tmpdir
  tmpdir=$(mktemp -d)
  run bash -c "cd '$tmpdir' && bash '$SCRIPT'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not in a git repository"* ]]
  rm -rf "$tmpdir"
}

# ── 2. Feature branch → no-op ───────────────────────────────────────────────

@test "2. no-op when already on a feature branch" {
  local tmpdir
  tmpdir=$(mktemp -d)
  setup_git_repo "$tmpdir"
  git -C "$tmpdir" checkout -b claude/feature-branch --quiet
  run_in_repo "$tmpdir"
  [ "$status" -eq 0 ]
  local branch
  branch=$(git -C "$tmpdir" branch --show-current)
  [ "$branch" = "claude/feature-branch" ]
  rm -rf "$tmpdir"
}

# ── 3. main branch → creates claude/<slug> ─────────────────────────────────

@test "3. creates new branch when on main" {
  local tmpdir
  tmpdir=$(mktemp -d)
  setup_git_repo "$tmpdir"
  # Rename the default branch to main if needed
  git -C "$tmpdir" branch -M main 2>/dev/null || true
  run bash -c "cd '$tmpdir' && CLAUDE_BRANCH_SLUG=my-feature CLAUDE_BRANCH_SUFFIX=beef bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  local branch
  branch=$(git -C "$tmpdir" branch --show-current)
  [ "$branch" = "claude/my-feature-beef" ]
  rm -rf "$tmpdir"
}

# ── 3b. Detached HEAD → exit 2 ─────────────────────────────────────────────

@test "3b. exit 2 when in detached HEAD state" {
  local tmpdir
  tmpdir=$(mktemp -d)
  setup_git_repo "$tmpdir"
  # Detach HEAD by checking out a commit directly
  local sha
  sha=$(git -C "$tmpdir" rev-parse HEAD)
  git -C "$tmpdir" checkout --detach "$sha" --quiet 2>/dev/null || \
    git -C "$tmpdir" checkout "$sha" --quiet 2>/dev/null
  run bash -c "cd '$tmpdir' && bash '$SCRIPT'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"detached HEAD"* ]]
  rm -rf "$tmpdir"
}

# ── 3c. master branch → creates claude/<slug> ──────────────────────────────

@test "3c. creates new branch when on master" {
  local tmpdir
  tmpdir=$(mktemp -d)
  setup_git_repo "$tmpdir"
  git -C "$tmpdir" branch -M master 2>/dev/null || true
  run bash -c "cd '$tmpdir' && CLAUDE_BRANCH_SLUG=my-master-feature CLAUDE_BRANCH_SUFFIX=cafe bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  local branch
  branch=$(git -C "$tmpdir" branch --show-current)
  [ "$branch" = "claude/my-master-feature-cafe" ]
  rm -rf "$tmpdir"
}

# ── 3d. Non-main/master branch → no-op ─────────────────────────────────────

@test "3d. no-op when on arbitrary non-main branch (develop)" {
  local tmpdir
  tmpdir=$(mktemp -d)
  setup_git_repo "$tmpdir"
  git -C "$tmpdir" checkout -b develop --quiet
  run_in_repo "$tmpdir"
  [ "$status" -eq 0 ]
  local branch
  branch=$(git -C "$tmpdir" branch --show-current)
  [ "$branch" = "develop" ]
  rm -rf "$tmpdir"
}

# ── 4. Slug collision → numeric suffix ─────────────────────────────────────

@test "4. appends numeric suffix when slug branch already exists" {
  local tmpdir
  tmpdir=$(mktemp -d)
  setup_git_repo "$tmpdir"
  git -C "$tmpdir" branch -M main 2>/dev/null || true
  # Pre-create the branch that would be chosen to force numeric fallback.
  git -C "$tmpdir" branch claude/my-slug-abcd
  run bash -c "cd '$tmpdir' && CLAUDE_BRANCH_SLUG=my-slug CLAUDE_BRANCH_SUFFIX=abcd bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  local branch
  branch=$(git -C "$tmpdir" branch --show-current)
  [ "$branch" = "claude/my-slug-abcd-2" ]
  rm -rf "$tmpdir"
}
