#!/usr/bin/env bats
# Tests for .claude-agent-flow/scripts/test.sh mode dispatch, flag parsing, and file selection.

TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
TEST_SH="$PROJECT_ROOT/.claude-agent-flow/scripts/test.sh"
BATS_BIN="$PROJECT_ROOT/.claude-agent-flow/tests/lib/bats-core/bin/bats"

setup() {
  load test_helper
  # Isolated git repo for changed-mode tests
  export TEST_REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$TEST_REPO/.codex/tasks"
  git -C "$TEST_REPO" init --quiet
  git -C "$TEST_REPO" config user.name "test"
  git -C "$TEST_REPO" config user.email "test@test.com"
  git -C "$TEST_REPO" config commit.gpgsign false
  git -C "$TEST_REPO" commit --allow-empty --quiet -m "init"
  # Unset CI vars so default resolves to --changed
  unset CI GITHUB_ACTIONS CODEX_CI 2>/dev/null || true
}

create_stub_bats() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  printf '#!/usr/bin/env bash\nif [[ "${1:-}" == "--" ]]; then echo "bad separator: $*" >&2; exit 64; fi\necho "stub bats: $@"\ntrue\n' > "$path"
  chmod +x "$path"
}

install_test_sh_fixture() {
  local repo="$1"
  mkdir -p "$repo/.claude-agent-flow/scripts" "$repo/.claude-agent-flow/tests"
  cp "$TEST_SH" "$repo/.claude-agent-flow/scripts/test.sh"
  create_stub_bats "$repo/.claude-agent-flow/tests/lib/bats-core/bin/bats"
}

write_dummy_bats() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  printf '#!/usr/bin/env bats\n@test "x" { true; }\n' > "$path"
}

# ── Help flag ─────────────────────────────────────────────────────────────────

@test "1. --help lists modes, precedence, and timing option" {
  run bash "$TEST_SH" --help
  assert_success
  [[ "$output" == *"--smoke"* ]]
  [[ "$output" == *"--changed"* ]]
  [[ "$output" == *"--full"* ]]
  [[ "$output" == *"Last flag wins"* ]]
  [[ "$output" == *"--update-timings"* ]]
}

# ── Last-flag-wins ────────────────────────────────────────────────────────────

@test "4. --smoke --changed selects --changed (last flag wins, not --smoke)" {
  local repo="$BATS_TEST_TMPDIR/last-flag-repo"
  mkdir -p "$repo/.claude-agent-flow/scripts" "$repo/.claude-agent-flow/tests"
  git -C "$repo" init --quiet
  git -C "$repo" config user.name "test"
  git -C "$repo" config user.email "test@test.com"
  git -C "$repo" config commit.gpgsign false
  install_test_sh_fixture "$repo"
  printf '#!/usr/bin/env bash\ntrue\n' > "$repo/.claude-agent-flow/scripts/repo-sync-files.sh"
  write_dummy_bats "$repo/.claude-agent-flow/tests/test-repo-sync-files.bats"
  git -C "$repo" add .
  git -C "$repo" commit --quiet --no-gpg-sign -m "base"
  printf '#!/usr/bin/env bash\nfalse\n' > "$repo/.claude-agent-flow/scripts/repo-sync-files.sh"

  run bash -c "
    unset CI GITHUB_ACTIONS CODEX_CI
    BATS_JOBS=1 BATS_HEARTBEAT_SECONDS=1 AGENT_FLOW_TEST_DIFF_BASE=HEAD bash '$repo/.claude-agent-flow/scripts/test.sh' --smoke --changed 2>&1
  "
  [[ "$output" == *"mode=changed"* ]]
  [[ "$output" != *"mode=smoke"* ]]
}

@test "5. --changed --full selects --full (last flag wins)" {
  run bash -c "
    mkdir -p \"\$BATS_TEST_TMPDIR/stubs\"
    printf '#!/usr/bin/env bash\ntrue\n' > \"\$BATS_TEST_TMPDIR/stubs/bats\"
    chmod +x \"\$BATS_TEST_TMPDIR/stubs/bats\"
    BATS_BIN_OVERRIDE=\"\$BATS_TEST_TMPDIR/stubs/bats\" BATS_JOBS=1 BATS_HEARTBEAT_SECONDS=1 bash '$TEST_SH' --changed --full 2>&1 | grep 'mode='
  "
  [[ "$output" == *"mode=full"* ]]
}

# ── Positional bypass ─────────────────────────────────────────────────────────

@test "6. positional *.bats args bypass mode dispatch and emit notice when mode flag given" {
  # Create a tiny real bats file to pass as positional arg
  local fake_bats="$BATS_TEST_TMPDIR/fake.bats"
  printf '#!/usr/bin/env bats\n@test "x" { true; }\n' > "$fake_bats"
  run bash "$TEST_SH" --smoke "$fake_bats" 2>&1
  [[ "$output" == *"positional *.bats"*"mode flag"* ]]
}

@test "7. positional *.bats forwarded unchanged to bats with --jobs (mode=explicit-files)" {
  local fake_bats="$BATS_TEST_TMPDIR/explicit.bats"
  printf '#!/usr/bin/env bats\n@test "x" { true; }\n' > "$fake_bats"
  run bash -c "
    mkdir -p \"\$BATS_TEST_TMPDIR/stubs\"
    printf '#!/usr/bin/env bash\necho \"bats-args: \$*\"\ntrue\n' > \"\$BATS_TEST_TMPDIR/stubs/bats\"
    chmod +x \"\$BATS_TEST_TMPDIR/stubs/bats\"
    BATS_BIN_OVERRIDE=\"\$BATS_TEST_TMPDIR/stubs/bats\" bash '$TEST_SH' \"$fake_bats\" 2>&1
  "
  assert_success
  [[ "$output" == *"mode=explicit-files"* ]]
  [[ "$output" == *"--jobs"* ]]   # explicit-files uses bats --jobs like --full
  [[ "$output" == *"bats-args: "*"$fake_bats"* ]]   # exact path appears in bats invocation args
}

# ── Default mode resolution ───────────────────────────────────────────────────

@test "6. no flags in CI-like env resolves to --full" {
  local env_name
  mkdir -p "$BATS_TEST_TMPDIR/stubs"
  printf '#!/usr/bin/env bash\ntrue\n' > "$BATS_TEST_TMPDIR/stubs/bats"
  chmod +x "$BATS_TEST_TMPDIR/stubs/bats"
  for env_name in CI GITHUB_ACTIONS CODEX_CI; do
    run env BATS_BIN_OVERRIDE="$BATS_TEST_TMPDIR/stubs/bats" \
      BATS_JOBS=1 BATS_HEARTBEAT_SECONDS=1 "$env_name=true" \
      bash "$TEST_SH"
    [[ "$output" == *"mode=full"* ]] || {
      echo "FAIL: $env_name did not select full mode" >&2
      return 1
    }
  done
}

@test "11. no flags and no CI env resolves to --changed (or smoke when no changes)" {
  local repo="$BATS_TEST_TMPDIR/default-mode-repo"
  mkdir -p "$repo"
  git -C "$repo" init --quiet
  git -C "$repo" config user.name "test"
  git -C "$repo" config user.email "test@test.com"
  git -C "$repo" config commit.gpgsign false
  git -C "$repo" commit --allow-empty --quiet -m "base"
  install_test_sh_fixture "$repo"
  write_dummy_bats "$repo/.claude-agent-flow/tests/codex-compatibility.bats"
  git -C "$repo" add .
  git -C "$repo" commit --quiet --no-gpg-sign -m "fixture"

  run bash -c "
    unset CI GITHUB_ACTIONS CODEX_CI
    BATS_JOBS=1 BATS_HEARTBEAT_SECONDS=1 AGENT_FLOW_TEST_DIFF_BASE=HEAD bash '$repo/.claude-agent-flow/scripts/test.sh' 2>&1
  "
  # AGENT_FLOW_TEST_DIFF_BASE=HEAD means no changed files; default --changed falls back to smoke.
  [[ "$output" == *"no changed files"* ]]
  [[ "$output" == *"mode=smoke"* ]]
}

# ── --changed mode mapping ────────────────────────────────────────────────────

@test "12. --changed with changed source but no mapping falls back to --full with notice" {
  local repo="$BATS_TEST_TMPDIR/no-map-repo"
  mkdir -p "$repo"
  git -C "$repo" init --quiet
  git -C "$repo" config user.name "test"
  git -C "$repo" config user.email "test@test.com"
  git -C "$repo" config commit.gpgsign false
  git -C "$repo" commit --allow-empty --quiet -m "base"
  install_test_sh_fixture "$repo"
  write_dummy_bats "$repo/.claude-agent-flow/tests/dummy.bats"
  git -C "$repo" add .
  git -C "$repo" commit --quiet --no-gpg-sign -m "fixture"
  printf 'notes\n' > "$repo/UNMAPPED.md"

  run bash -c "
    unset CI GITHUB_ACTIONS CODEX_CI
    mkdir -p \"\$BATS_TEST_TMPDIR/stubs\"
    printf '#!/usr/bin/env bash\ntrue\n' > \"\$BATS_TEST_TMPDIR/stubs/bats\"
    chmod +x \"\$BATS_TEST_TMPDIR/stubs/bats\"
    BATS_BIN_OVERRIDE=\"\$BATS_TEST_TMPDIR/stubs/bats\" BATS_JOBS=1 BATS_HEARTBEAT_SECONDS=1 AGENT_FLOW_TEST_DIFF_BASE=HEAD bash '$repo/.claude-agent-flow/scripts/test.sh' --changed 2>&1
  "
  [[ "$output" == *"no test mapping"* ]]
  [[ "$output" == *"mode=full"* ]]
}

@test "13. --changed always-full trigger on test_helper.bash falls back to --full" {
  # Create a fake git repo where test_helper.bash was changed
  local repo="$BATS_TEST_TMPDIR/trigger-repo"
  mkdir -p "$repo/.claude-agent-flow/tests/lib/bats-core/bin"
  mkdir -p "$repo/.claude-agent-flow/scripts"
  git -C "$repo" init --quiet
  git -C "$repo" config user.name "test"
  git -C "$repo" config user.email "test@test.com"
  git -C "$repo" config commit.gpgsign false
  git -C "$repo" commit --allow-empty --quiet -m "base"
  # Stage a change to test_helper.bash
  printf 'content\n' > "$repo/.claude-agent-flow/tests/test_helper.bash"
  git -C "$repo" add .
  git -C "$repo" commit --quiet --no-gpg-sign -m "change helper"
  local base; base=$(git -C "$repo" rev-list --max-parents=0 HEAD | head -1)

  install_test_sh_fixture "$repo"
  # Create dummy .bats files
  write_dummy_bats "$repo/.claude-agent-flow/tests/dummy.bats"

  run bash -c "
    unset CI GITHUB_ACTIONS CODEX_CI
    mkdir -p \"\$BATS_TEST_TMPDIR/stubs\"
    printf '#!/usr/bin/env bash\ntrue\n' > \"\$BATS_TEST_TMPDIR/stubs/bats\"
    chmod +x \"\$BATS_TEST_TMPDIR/stubs/bats\"
    BATS_BIN_OVERRIDE=\"\$BATS_TEST_TMPDIR/stubs/bats\" BATS_JOBS=1 BATS_HEARTBEAT_SECONDS=1 AGENT_FLOW_TEST_DIFF_BASE='$base' bash '$repo/.claude-agent-flow/scripts/test.sh' --changed 2>&1
  "
  [[ "$output" == *"always-full trigger"* ]]
  [[ "$output" == *"mode=full"* ]]
}

@test "14. --changed maps an unstaged source edit without requiring a commit" {
  local repo="$BATS_TEST_TMPDIR/unstaged-repo"
  mkdir -p "$repo/.claude-agent-flow/scripts" "$repo/.claude-agent-flow/tests"
  git -C "$repo" init --quiet
  git -C "$repo" config user.name "test"
  git -C "$repo" config user.email "test@test.com"
  git -C "$repo" config commit.gpgsign false
  install_test_sh_fixture "$repo"
  printf '#!/usr/bin/env bash\ntrue\n' > "$repo/.claude-agent-flow/scripts/repo-sync-files.sh"
  write_dummy_bats "$repo/.claude-agent-flow/tests/test-repo-sync-files.bats"
  git -C "$repo" add .
  git -C "$repo" commit --quiet --no-gpg-sign -m "base"
  printf '#!/usr/bin/env bash\nfalse\n' > "$repo/.claude-agent-flow/scripts/repo-sync-files.sh"

  run bash -c "
    unset CI GITHUB_ACTIONS CODEX_CI
    BATS_JOBS=1 BATS_HEARTBEAT_SECONDS=1 AGENT_FLOW_TEST_DIFF_BASE=HEAD bash '$repo/.claude-agent-flow/scripts/test.sh' --changed 2>&1
  "
  [[ "$output" == *"mode=changed"* ]]
  [[ "$output" == *"files=1"* ]]
  [[ "$output" == *"concurrency: bats --jobs 1"* ]]
  [[ "$output" == *"test-repo-sync-files.bats"* ]]
}

@test "15a. --changed maps an unstaged edit when no safe branch base exists" {
  local repo="$BATS_TEST_TMPDIR/unbased-worktree-repo"
  mkdir -p "$repo/.claude-agent-flow/scripts" "$repo/.claude-agent-flow/tests"
  git -C "$repo" init --quiet
  git -C "$repo" config user.name "test"
  git -C "$repo" config user.email "test@test.com"
  git -C "$repo" config commit.gpgsign false
  install_test_sh_fixture "$repo"
  printf '#!/usr/bin/env bash\ntrue\n' > "$repo/.claude-agent-flow/scripts/repo-sync-files.sh"
  write_dummy_bats "$repo/.claude-agent-flow/tests/test-repo-sync-files.bats"
  git -C "$repo" add .
  git -C "$repo" commit --quiet --no-gpg-sign -m "base"
  local base_branch
  base_branch="$(git -C "$repo" branch --show-current)"
  git -C "$repo" checkout --quiet -b task
  git -C "$repo" branch --quiet -D "$base_branch"
  printf '#!/usr/bin/env bash\nfalse\n' > "$repo/.claude-agent-flow/scripts/repo-sync-files.sh"

  run bash -c "
    unset CI GITHUB_ACTIONS CODEX_CI
    BATS_JOBS=1 BATS_HEARTBEAT_SECONDS=1 bash '$repo/.claude-agent-flow/scripts/test.sh' --changed 2>&1
  "
  [[ "$output" == *"no safe diff base; using worktree changes only"* ]]
  [[ "$output" == *"mode=changed"* ]]
  [[ "$output" == *"files=1"* ]]
  [[ "$output" == *"test-repo-sync-files.bats"* ]]
}

@test "15. --changed maps a committed local branch change without origin" {
  local repo="$BATS_TEST_TMPDIR/local-branch-repo"
  mkdir -p "$repo/.claude-agent-flow/scripts" "$repo/.claude-agent-flow/tests"
  git -C "$repo" init --quiet
  git -C "$repo" config user.name "test"
  git -C "$repo" config user.email "test@test.com"
  git -C "$repo" config commit.gpgsign false
  install_test_sh_fixture "$repo"
  printf '#!/usr/bin/env bash\ntrue\n' > "$repo/.claude-agent-flow/scripts/repo-sync-files.sh"
  write_dummy_bats "$repo/.claude-agent-flow/tests/test-repo-sync-files.bats"
  git -C "$repo" add .
  git -C "$repo" commit --quiet --no-gpg-sign -m "base"
  git -C "$repo" checkout --quiet -b task
  printf '#!/usr/bin/env bash\nfalse\n' > "$repo/.claude-agent-flow/scripts/repo-sync-files.sh"
  git -C "$repo" add .
  git -C "$repo" commit --quiet --no-gpg-sign -m "change script"

  run bash -c "
    unset CI GITHUB_ACTIONS CODEX_CI
    BATS_JOBS=1 BATS_HEARTBEAT_SECONDS=1 bash '$repo/.claude-agent-flow/scripts/test.sh' --changed 2>&1
  "
  [[ "$output" == *"mode=changed"* ]]
  [[ "$output" == *"files=1"* ]]
  [[ "$output" == *"test-repo-sync-files.bats"* ]]
}

@test "16. --changed clean repo without origin does not compare from root commit" {
  local repo="$BATS_TEST_TMPDIR/no-origin-clean-repo"
  mkdir -p "$repo"
  git -C "$repo" init --quiet
  git -C "$repo" config user.name "test"
  git -C "$repo" config user.email "test@test.com"
  git -C "$repo" config commit.gpgsign false
  git -C "$repo" commit --allow-empty --quiet -m "root"
  install_test_sh_fixture "$repo"
  local i
  for i in $(seq 1 105); do
    printf 'file %s\n' "$i" > "$repo/file-$i.txt"
  done
  write_dummy_bats "$repo/.claude-agent-flow/tests/codex-compatibility.bats"
  git -C "$repo" add .
  git -C "$repo" commit --quiet --no-gpg-sign -m "many files"

  run bash -c "
    unset CI GITHUB_ACTIONS CODEX_CI
    BATS_JOBS=1 BATS_HEARTBEAT_SECONDS=1 bash '$repo/.claude-agent-flow/scripts/test.sh' --changed 2>&1
  "
  [[ "$output" == *"no changed files"* ]]
  [[ "$output" == *"mode=smoke"* ]]
  [[ "$output" != *">100 limit"* ]]
}

# ── Smoke file selection ───────────────────────────────────────────────────────

@test "17. --smoke with no timings file uses curated fallback" {
  run bash -c "
    unset CI GITHUB_ACTIONS CODEX_CI
    mkdir -p \"\$BATS_TEST_TMPDIR/stubs\"
    printf '#!/usr/bin/env bash\ntrue\n' > \"\$BATS_TEST_TMPDIR/stubs/bats\"
    chmod +x \"\$BATS_TEST_TMPDIR/stubs/bats\"
    BATS_BIN_OVERRIDE=\"\$BATS_TEST_TMPDIR/stubs/bats\" BATS_JOBS=1 BATS_HEARTBEAT_SECONDS=1 bash '$TEST_SH' --smoke 2>&1
  "
  [[ "$output" == *"mode=smoke"* ]]
}

# ── --full uses bats --jobs ───────────────────────────────────────────────────

@test "18. --full path shows bats --jobs in output" {
  run bash -c "
    mkdir -p \"\$BATS_TEST_TMPDIR/stubs\"
    printf '#!/usr/bin/env bash\necho \"bats-args: \$@\"\ntrue\n' > \"\$BATS_TEST_TMPDIR/stubs/bats\"
    chmod +x \"\$BATS_TEST_TMPDIR/stubs/bats\"
    BATS_BIN_OVERRIDE=\"\$BATS_TEST_TMPDIR/stubs/bats\" BATS_JOBS=1 BATS_HEARTBEAT_SECONDS=1 bash '$TEST_SH' --full 2>&1
  "
  [[ "$output" == *"mode=full"* ]]
  [[ "$output" == *"bats --jobs"* ]]
}

# ── Unknown flags ─────────────────────────────────────────────────────────────

@test "19. unknown flag exits with error" {
  run bash "$TEST_SH" --unknown-flag 2>&1
  assert_failure
  [[ "$output" == *"unknown flag"* ]]
}

# ── BATS_JOBS respected ───────────────────────────────────────────────────────

@test "20. BATS_JOBS env override applies (output shows jobs=1)" {
  run bash -c "
    mkdir -p \"\$BATS_TEST_TMPDIR/stubs\"
    printf '#!/usr/bin/env bash\ntrue\n' > \"\$BATS_TEST_TMPDIR/stubs/bats\"
    chmod +x \"\$BATS_TEST_TMPDIR/stubs/bats\"
    BATS_BIN_OVERRIDE=\"\$BATS_TEST_TMPDIR/stubs/bats\" BATS_JOBS=1 BATS_HEARTBEAT_SECONDS=1 bash '$TEST_SH' --full 2>&1 | grep 'jobs='
  "
  [[ "$output" == *"jobs=1"* ]]
}
