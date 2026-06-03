#!/usr/bin/env bats
# Tests for .claude-agent-flow/scripts/resolve-task.sh

setup() {
  load test_helper
  export SCRIPT="$SCRIPT_DIR/resolve-task.sh"
  # Create a temp dir for fake backlog + plan files
  export WORK_DIR="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK_DIR/plans"
  # Create a mock backlog binary that returns canned output
  export FAKE_BIN="$BATS_TEST_TMPDIR/fake_bin"
  mkdir -p "$FAKE_BIN"
}

# Helper: run the script in WORK_DIR with a mock backlog on PATH
run_script() {
  local input="$1"
  run bash -c "cd '$WORK_DIR' && PATH='$FAKE_BIN:$PATH' bash '$SCRIPT' '$input'"
}

# Install a mock backlog script that returns given output for a task
mock_backlog_task() {
  local task_id="$1"
  local output="$2"
  cat > "$FAKE_BIN/backlog" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "task" && "\$2" == "$task_id" ]]; then
  echo "$output"
  exit 0
fi
echo "ERROR: unknown task \$2" >&2; exit 2
EOF
  chmod +x "$FAKE_BIN/backlog"
}

# ── 1. TASK-XX input → emits TASK_ID ───────────────────────────────────────

@test "1. TASK-XX input resolves task ID" {
  mock_backlog_task "TASK-41" "Title: Test Task
Status: In Progress
References:
Acceptance Criteria:
--------------------------------------------------"
  run_script "TASK-41"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TASK_ID=TASK-41"* ]]
}

@test "1b. TASK-XX input resolves current Backlog plain header format" {
  mock_backlog_task "TASK-42" "Task TASK-42 - Test Task
==================================================

Status: ○ To Do
Priority: Medium
References: plans/current-format.md

Acceptance Criteria:
--------------------------------------------------"
  cat > "$WORK_DIR/plans/current-format.md" <<'EOF'
# Feature: Current Format
EOF

  run_script "TASK-42"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TASK_ID=TASK-42"* ]]
  [[ "$output" == *"PLAN_FILE=plans/current-format.md"* ]]
  [[ "$output" == *"PLAN_CONTEXT:"* ]]
}

# ── 2. 'task 41' normalisation → same as TASK-41 ───────────────────────────

@test "2. 'task 41' normalises to TASK-41" {
  mock_backlog_task "TASK-41" "Title: Test Task
Status: In Progress
References:
Acceptance Criteria:
--------------------------------------------------"
  run_script "task 41"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TASK_ID=TASK-41"* ]]
}

# ── 3. 'task41' (no space) normalisation ───────────────────────────────────

@test "3. 'task41' normalises to TASK-41" {
  mock_backlog_task "TASK-41" "Title: Test Task
Status: In Progress
References:
Acceptance Criteria:
--------------------------------------------------"
  run_script "task41"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TASK_ID=TASK-41"* ]]
}

# ── 4. Bare digit → task ID ─────────────────────────────────────────────────

@test "4. bare digit '41' resolves to TASK-41" {
  mock_backlog_task "TASK-41" "Title: Test Task
Status: In Progress
References:
Acceptance Criteria:
--------------------------------------------------"
  run_script "41"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TASK_ID=TASK-41"* ]]
}

# ── 5. Leading zeros stripped ───────────────────────────────────────────────

@test "5. '041' strips leading zeros to TASK-41" {
  mock_backlog_task "TASK-41" "Title: Test Task
Status: In Progress
References:
Acceptance Criteria:
--------------------------------------------------"
  run_script "041"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TASK_ID=TASK-41"* ]]
}

# ── 6. Inline text → INLINE_BRIEF ──────────────────────────────────────────

@test "6. inline text emits INLINE_BRIEF" {
  run_script "add a new feature for exporting data"
  [ "$status" -eq 0 ]
  [[ "$output" == *"INLINE_BRIEF=add a new feature for exporting data"* ]]
}

# ── 7. 'task' alone → inline brief (empty remainder) ───────────────────────

@test "7. bare 'task' with no number is treated as inline brief" {
  run_script "task"
  [ "$status" -eq 0 ]
  [[ "$output" == *"INLINE_BRIEF="* ]]
}

# ── 8. '0' → inline brief (zero is not a valid task ID) ────────────────────

@test "8. input '0' is treated as inline brief" {
  run_script "0"
  [ "$status" -eq 0 ]
  [[ "$output" == *"INLINE_BRIEF=0"* ]]
}

# ── 9. @plans/file.md with task link → PLAN_CONTEXT + TASK_ID ──────────────

@test "9. @plans/file.md with Backlog Task header emits PLAN_CONTEXT and TASK_ID" {
  cat > "$WORK_DIR/plans/my-feature.md" <<'EOF'
# Feature: My Feature

## Backlog Task: TASK-7

## What it must do
Build something useful.
EOF
  mock_backlog_task "TASK-7" "Title: My Feature
Status: In Progress
References:
Acceptance Criteria:
--------------------------------------------------
- [ ] #1 Do the thing"
  run_script "@plans/my-feature.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_FILE=plans/my-feature.md"* ]]
  [[ "$output" == *"PLAN_CONTEXT:"* ]]
  [[ "$output" == *"TASK_ID=TASK-7"* ]]
}

# ── 10. @plans/file.md without task link → PLAN_CONTEXT only ───────────────

@test "10. @plans/file.md without Backlog Task header emits only PLAN_CONTEXT" {
  cat > "$WORK_DIR/plans/no-task.md" <<'EOF'
# Feature: No Task Yet

## What it must do
Something.
EOF
  run_script "@plans/no-task.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_FILE=plans/no-task.md"* ]]
  [[ "$output" == *"PLAN_CONTEXT:"* ]]
  [[ "$output" != *"TASK_ID="* ]]
}

# ── 11. TASK-XX with References plan file → dual context ───────────────────

@test "11. TASK-XX with valid References plan file emits dual context" {
  cat > "$WORK_DIR/plans/feature.md" <<'EOF'
# Feature: The Feature

## What it must do
Be useful.
EOF
  mock_backlog_task "TASK-5" "Title: The Feature
Status: In Progress
References: plans/feature.md
Acceptance Criteria:
--------------------------------------------------
- [ ] #1 Be useful"
  run_script "TASK-5"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TASK_ID=TASK-5"* ]]
  [[ "$output" == *"PLAN_FILE=plans/feature.md"* ]]
  [[ "$output" == *"PLAN_CONTEXT:"* ]]
}

# ── 12. Path traversal in References is rejected ───────────────────────────

@test "12. References path with '..' is rejected and falls back to no plan file" {
  mock_backlog_task "TASK-9" "Title: Security Test
Status: In Progress
References: plans/../secret.md
Acceptance Criteria:
--------------------------------------------------"
  run_script "TASK-9"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TASK_ID=TASK-9"* ]]
  # Should NOT emit PLAN_FILE for the path-traversal reference
  [[ "$output" != *"PLAN_FILE="* ]]
}

# ── 13. @backlog/tasks/task-N format → task ID extracted ───────────────────

@test "13. @backlog/tasks/task-37 - Title.md extracts TASK-37" {
  mock_backlog_task "TASK-37" "Title: Some Task
Status: In Progress
References:
Acceptance Criteria:
--------------------------------------------------
- [ ] #1 Do it"
  run_script "@backlog/tasks/task-37 - Some Task.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TASK_ID=TASK-37"* ]]
}

@test "13b. @backlog/tasks/TASK-37 - Title.md (uppercase prefix) extracts TASK-37" {
  mock_backlog_task "TASK-37" "Title: Some Task
Status: In Progress
References:
Acceptance Criteria:
--------------------------------------------------
- [ ] #1 Do it"
  run_script "@backlog/tasks/TASK-37 - Some Task.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TASK_ID=TASK-37"* ]]
}

# ── 14. TASK_STATUS emitted when AC lines present ──────────────────────────

@test "14. TASK_STATUS block emitted when AC check-state lines are present" {
  mock_backlog_task "TASK-3" "Title: AC Task
Status: In Progress
References:
Acceptance Criteria:
--------------------------------------------------
- [ ] #1 First criterion
- [x] #2 Second criterion"
  run_script "TASK-3"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TASK_STATUS:"* ]]
  [[ "$output" == *"#1 First criterion"* ]]
  [[ "$output" == *"#2 Second criterion"* ]]
}

# ── 15. @plans/ path traversal is rejected ─────────────────────────────────

@test "15. @plans/../backlog/tasks/task-1.md is rejected as path traversal" {
  run_script "@plans/../backlog/tasks/task-1.md"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "invalid plan path" || "$stderr" =~ "invalid plan path" ]]
}
