#!/usr/bin/env bats
# Tests for session-start.sh core logic (record, run_tool, summary table, truncation)
#
# Strategy: source only the helper functions by mocking the script's
# early-exit guards and skipping top-level installer calls.

setup() {
  load test_helper

  # Minimal environment required by the functions under test
  export LOG_FILE="/dev/null"
  export PROJECT_ROOT="$BATS_TEST_TMPDIR/project"
  export AGENT_FLOW_ROOT="$PROJECT_ROOT/.claude-agent-flow"
  mkdir -p "$PROJECT_ROOT/.claude" "$AGENT_FLOW_ROOT"

  # Reset shared state before each test
  unset EXPECTED_TOOLS RECORDED_TOOLS CURRENT_TOOL FAIL_COUNT DETAIL_WIDTH
  # Clear any leftover dynamic TOOL_RESULT_*/TOOL_DETAIL_* variables
  for _v in ${!TOOL_RESULT_*}; do unset "$_v"; done
  for _v in ${!TOOL_DETAIL_*}; do unset "$_v"; done
  declare -a EXPECTED_TOOLS=()
  declare -a RECORDED_TOOLS=()
  CURRENT_TOOL=""
  DETAIL_WIDTH=39
  FAIL_COUNT=0

  # Source helper functions from production session-start.sh
  # Extract only function definitions (not top-level execution code)
  local script
  script="$(cd "$TESTS_DIR/../.." && pwd)/.claude-agent-flow/scripts/session-start.sh"

  # Extract and eval multi-line function blocks from production code
  eval "$(grep '^_key()' "$script")"
  eval "$(sed -n '/^record() {$/,/^}$/p' "$script")"
  eval "$(sed -n '/^kill_process_tree() {$/,/^}$/p' "$script")"
  eval "$(sed -n '/^run_tool() {$/,/^}$/p' "$script")"

  # Extract single-line wrapper functions (they end with } on the same line)
  eval "$(grep '^tool_record()' "$script")"
  eval "$(grep '^tool_section_start()' "$script")"
  eval "$(grep '^tool_section_end()' "$script")"

  # Test helpers for reading dynamic result/detail variables
  _get_result() {
    local k; k="$(_key "$1")"
    eval "printf '%s' \"\${TOOL_RESULT_${k}:-}\""
  }
  _get_detail() {
    local k; k="$(_key "$1")"
    eval "printf '%s' \"\${TOOL_DETAIL_${k}:-}\""
  }
  _has_result() {
    local k; k="$(_key "$1")"
    eval "[[ -n \"\${TOOL_RESULT_${k}+x}\" ]]"
  }
  # Directly set a result/detail (for summary table tests that bypass record())
  _set_result() {
    local k; k="$(_key "$1")"
    eval "TOOL_RESULT_${k}=\"\$2\""
  }
  _set_detail() {
    local k; k="$(_key "$1")"
    eval "TOOL_DETAIL_${k}=\"\$2\""
  }

  # Override log/section helpers with test-specific mocks that suppress output
  log() { true; }
  section_start() { true; }
  section_end()   { true; }

  export -f _key record kill_process_tree log section_start section_end run_tool tool_record tool_section_start tool_section_end _get_result _get_detail _has_result _set_result _set_detail
}

# ── record() ──────────────────────────────────────────────────────────────────

@test "record stores result and detail in dynamic variables" {
  record "My Tool" "OK" "installed v1.2.3"
  [[ "$(_get_result "My Tool")" == "OK" ]]
  [[ "$(_get_detail "My Tool")" == "installed v1.2.3" ]]
}

@test "record uses FAIL as default result when omitted" {
  record "My Tool"
  [[ "$(_get_result "My Tool")" == "FAIL" ]]
}

@test "record uses (unknown) as default name when omitted" {
  record
  _has_result "(unknown)"
  [[ "$(_get_result "(unknown)")" == "FAIL" ]]
}

@test "record overwrites an existing entry" {
  record "My Tool" "FAIL" "first"
  record "My Tool" "OK"   "second"
  [[ "$(_get_result "My Tool")" == "OK" ]]
  [[ "$(_get_detail "My Tool")" == "second" ]]
}

# ── run_tool() ────────────────────────────────────────────────────────────────

@test "run_tool records OK when installer calls record() on success" {
  mock_installer_ok() { record "Test Tool" "OK" "everything fine"; }
  run_tool "Test Tool" mock_installer_ok
  [[ "$(_get_result "Test Tool")" == "OK" ]]
  [[ "$(_get_detail "Test Tool")" == "everything fine" ]]
}

@test "run_tool records FAIL when installer calls record() with FAIL" {
  mock_installer_fail() { record "Test Tool" "FAIL" "download error"; }
  run_tool "Test Tool" mock_installer_fail
  [[ "$(_get_result "Test Tool")" == "FAIL" ]]
  [[ "$(_get_detail "Test Tool")" == "download error" ]]
}

@test "run_tool auto-records FAIL when installer crashes without calling record()" {
  # This installer exits non-zero without recording anything
  mock_installer_crash() { return 1; }
  run_tool "Crashy Tool" mock_installer_crash
  [[ "$(_get_result "Crashy Tool")" == "FAIL" ]]
  [[ "$(_get_detail "Crashy Tool")" == "installer crashed before reporting status" ]]
}

@test "run_tool does not overwrite record() result when installer crashes after calling record()" {
  # Installer records OK first, then crashes — record() result must be kept
  mock_installer_record_then_crash() {
    record "Partial Tool" "OK" "pre-crash record"
    return 1
  }
  run_tool "Partial Tool" mock_installer_record_then_crash
  [[ "$(_get_result "Partial Tool")" == "OK" ]]
  [[ "$(_get_detail "Partial Tool")" == "pre-crash record" ]]
}

@test "run_tool clears CURRENT_TOOL after installer completes" {
  mock_installer_ok() { record "Tool X" "OK" "fine"; }
  CURRENT_TOOL="should-be-cleared"
  run_tool "Tool X" mock_installer_ok
  [[ -z "$CURRENT_TOOL" ]]
}

@test "run_tool clears CURRENT_TOOL even when installer crashes" {
  mock_installer_crash() { return 1; }
  CURRENT_TOOL="should-be-cleared"
  run_tool "Tool Y" mock_installer_crash
  [[ -z "$CURRENT_TOOL" ]]
}

@test "run_tool records TIMEOUT when installer exceeds deadline" {
  # Use a 1-second deadline and an installer that would run indefinitely.
  mock_installer_hang() { sleep 60; }
  TOOL_INSTALL_TIMEOUT=1 run_tool "Slow Tool" mock_installer_hang
  [[ "$(_get_result "Slow Tool")" == "TIMEOUT" ]]
  [[ "$(_get_detail "Slow Tool")" == "killed after 1s" ]]
}

# ── Summary table — EXPECTED_TOOLS coverage ──────────────────────────────────

@test "summary table shows all EXPECTED_TOOLS even if no installer ran" {
  declare -a EXPECTED_TOOLS=("Alpha" "Beta" "Gamma")
  DETAIL_WIDTH=39
  FAIL_COUNT=0

  # Pre-populate defaults (mirrors the production script logic)
  for name in "${EXPECTED_TOOLS[@]}"; do
    local _pk; _pk="$(_key "$name")"
    local _pv; eval "_pv=\${TOOL_RESULT_${_pk}:-}"
    if [[ -z "$_pv" ]]; then
      record "$name" "ERROR" "installer did not report"
    fi
  done

  # Collect rendered rows
  output=""
  for name in "${EXPECTED_TOOLS[@]}"; do
    local _sk; _sk="$(_key "$name")"
    local result detail
    eval "result=\${TOOL_RESULT_${_sk}:-ERROR}"
    eval "detail=\${TOOL_DETAIL_${_sk}:-installer did not report}"
    if [[ ${#detail} -gt $DETAIL_WIDTH ]]; then
      detail="${detail:0:$(( DETAIL_WIDTH - 1 ))}…"
    fi
    printf -v row "│ %-16s │ %-7s │ %-${DETAIL_WIDTH}s │" "$name" "$result" "$detail"
    output+="$row"$'\n'
    if [[ "$result" == "FAIL" || "$result" == "ERROR" ]]; then
      (( FAIL_COUNT++ )) || true
    fi
  done

  [[ "$output" == *"Alpha"* ]]
  [[ "$output" == *"Beta"* ]]
  [[ "$output" == *"Gamma"* ]]
}

@test "summary table shows ERROR for tools with no installer run" {
  declare -a EXPECTED_TOOLS=("Missing Tool")
  DETAIL_WIDTH=39
  FAIL_COUNT=0

  for name in "${EXPECTED_TOOLS[@]}"; do
    local _pk; _pk="$(_key "$name")"
    local _pv; eval "_pv=\${TOOL_RESULT_${_pk}:-}"
    if [[ -z "$_pv" ]]; then
      record "$name" "ERROR" "installer did not report"
    fi
  done

  [[ "$(_get_result "Missing Tool")" == "ERROR" ]]
}

@test "extra tools (recorded but not in EXPECTED_TOOLS) appear in table" {
  declare -a EXPECTED_TOOLS=("Main Tool")
  declare -a RECORDED_TOOLS=()
  DETAIL_WIDTH=39

  # Simulate recording both tools via record()
  record "Main Tool" "OK" "fine"
  record "Extra Hook" "OK" "hook ran"

  extra_output=""
  for name in "${RECORDED_TOOLS[@]}"; do
    found=0
    for expected in "${EXPECTED_TOOLS[@]}"; do
      if [[ "$name" == "$expected" ]]; then found=1; break; fi
    done
    if [[ $found -eq 0 ]]; then
      local _sk; _sk="$(_key "$name")"
      local result detail
      eval "result=\${TOOL_RESULT_${_sk}:-no detail}"
      eval "detail=\${TOOL_DETAIL_${_sk}:-no detail}"
      printf -v row "│ %-16s │ %-7s │ %-${DETAIL_WIDTH}s │" "$name" "$result" "$detail"
      extra_output+="$row"$'\n'
    fi
  done

  [[ "$extra_output" == *"Extra Hook"* ]]
  [[ "$extra_output" != *"Main Tool"* ]]
}

# ── Detail truncation ─────────────────────────────────────────────────────────

@test "detail truncation at DETAIL_WIDTH boundary (list-driven)" {
  DETAIL_WIDTH=39
  # Each entry: input_len:should_truncate (yes|no)
  local cases=(
    "0:no"
    "38:no"
    "39:no"
    "40:yes"
    "80:yes"
  )
  local case input_len expected detail
  for case in "${cases[@]}"; do
    input_len="${case%%:*}"
    expected="${case#*:}"
    detail="$(printf '%0.s-' $(seq 1 "$input_len") 2>/dev/null || printf '%*s' "$input_len" '' | tr ' ' '-')"
    local orig_len=${#detail}
    if [[ ${#detail} -gt $DETAIL_WIDTH ]]; then
      detail="${detail:0:$(( DETAIL_WIDTH - 1 ))}…"
    fi
    if [ "$expected" = "yes" ]; then
      [[ "$detail" == *"…" ]] || {
        echo "FAIL: len=$input_len should truncate but did not (detail='$detail')" >&2
        return 1
      }
    else
      [[ "$detail" != *"…" ]] || {
        echo "FAIL: len=$input_len should NOT truncate but did" >&2
        return 1
      }
      [[ ${#detail} -eq $orig_len ]] || {
        echo "FAIL: len=$input_len changed unexpectedly" >&2
        return 1
      }
    fi
  done
}

# ── FAIL_COUNT ────────────────────────────────────────────────────────────────

@test "FAIL_COUNT counts FAIL results correctly" {
  declare -a EXPECTED_TOOLS=("Tool A" "Tool B" "Tool C")
  _set_result "Tool A" "OK";    _set_detail "Tool A" "fine"
  _set_result "Tool B" "FAIL";  _set_detail "Tool B" "broke"
  _set_result "Tool C" "FAIL";  _set_detail "Tool C" "also broke"
  DETAIL_WIDTH=39
  FAIL_COUNT=0

  for name in "${EXPECTED_TOOLS[@]}"; do
    local _sk; _sk="$(_key "$name")"
    local result; eval "result=\${TOOL_RESULT_${_sk}:-}"
    if [[ "$result" == "FAIL" || "$result" == "ERROR" ]]; then
      (( FAIL_COUNT++ )) || true
    fi
  done

  [[ "$FAIL_COUNT" -eq 2 ]]
}

@test "FAIL_COUNT counts ERROR results correctly" {
  declare -a EXPECTED_TOOLS=("Tool A" "Tool B")
  _set_result "Tool A" "ERROR"; _set_detail "Tool A" "no report"
  _set_result "Tool B" "OK";    _set_detail "Tool B" "fine"
  DETAIL_WIDTH=39
  FAIL_COUNT=0

  for name in "${EXPECTED_TOOLS[@]}"; do
    local _sk; _sk="$(_key "$name")"
    local result; eval "result=\${TOOL_RESULT_${_sk}:-}"
    if [[ "$result" == "FAIL" || "$result" == "ERROR" ]]; then
      (( FAIL_COUNT++ )) || true
    fi
  done

  [[ "$FAIL_COUNT" -eq 1 ]]
}

@test "FAIL_COUNT is zero when all tools OK" {
  declare -a EXPECTED_TOOLS=("Tool A" "Tool B")
  _set_result "Tool A" "OK";   _set_detail "Tool A" "fine"
  _set_result "Tool B" "SKIP"; _set_detail "Tool B" "skipped"
  DETAIL_WIDTH=39
  FAIL_COUNT=0

  for name in "${EXPECTED_TOOLS[@]}"; do
    local _sk; _sk="$(_key "$name")"
    local result; eval "result=\${TOOL_RESULT_${_sk}:-}"
    if [[ "$result" == "FAIL" || "$result" == "ERROR" ]]; then
      (( FAIL_COUNT++ )) || true
    fi
  done

  [[ "$FAIL_COUNT" -eq 0 ]]
}

@test "FAIL_COUNT counts FAIL from extra tools not in EXPECTED_TOOLS" {
  declare -a EXPECTED_TOOLS=("Main Tool")
  declare -a RECORDED_TOOLS=()
  DETAIL_WIDTH=39
  FAIL_COUNT=0

  # Populate via record() so RECORDED_TOOLS tracks them
  record "Main Tool" "OK" "fine"
  record "Extra Hook" "FAIL" "hook failed"

  # Main loop (expected tools)
  for name in "${EXPECTED_TOOLS[@]}"; do
    local _sk; _sk="$(_key "$name")"
    local result; eval "result=\${TOOL_RESULT_${_sk}:-}"
    if [[ "$result" == "FAIL" || "$result" == "ERROR" ]]; then
      (( FAIL_COUNT++ )) || true
    fi
  done

  # Extra loop (recorded but not expected)
  for name in "${RECORDED_TOOLS[@]}"; do
    found=0
    for expected in "${EXPECTED_TOOLS[@]}"; do
      if [[ "$name" == "$expected" ]]; then found=1; break; fi
    done
    if [[ $found -eq 0 ]]; then
      local _sk; _sk="$(_key "$name")"
      local result; eval "result=\${TOOL_RESULT_${_sk}:-FAIL}"
      if [[ "$result" == "FAIL" || "$result" == "ERROR" ]]; then
        (( FAIL_COUNT++ )) || true
      fi
    fi
  done

  [[ "$FAIL_COUNT" -eq 1 ]]
}

# ── tool_record() / CURRENT_TOOL integration ──────────────────────────────────

@test "tool_record writes to the name set by run_tool via CURRENT_TOOL" {
  mock_installer() {
    tool_record "OK" "tool_record path works"
  }
  run_tool "Named Tool" mock_installer
  [[ "$(_get_result "Named Tool")" == "OK" ]]
  [[ "$(_get_detail "Named Tool")" == "tool_record path works" ]]
}
