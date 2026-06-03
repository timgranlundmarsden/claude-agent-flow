#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BATS_BIN="$ROOT_DIR/.claude-agent-flow/tests/lib/bats-core/bin/bats"
# Allow test stubs via env override (used by test-test-sh-modes.bats)
BATS_BIN="${BATS_BIN_OVERRIDE:-$BATS_BIN}"
TESTS_DIR="$ROOT_DIR/.claude-agent-flow/tests"
TIMINGS_FILE="$ROOT_DIR/.codex/.test-timings.json"
REQUESTED_JOBS="${BATS_JOBS:-8}"
export BATS_TEST_TIMEOUT="${BATS_TEST_TIMEOUT:-120}"

# Safe glob expansion into a named array — avoids word-splitting on spaces/metacharacters.
# Usage: _collect_bats selected_files   OR   _collect_bats all_bats
_collect_bats() {
  local _dest="$1"
  eval "${_dest}=()"
  local _f
  for _f in "$TESTS_DIR"/*.bats; do
    [[ -f "$_f" ]] && eval "${_dest}+=(\"${_f//\"/\\\"}\")"
  done
}

if [[ ! -x "$BATS_BIN" ]]; then
  echo "[test.sh] error: bats binary not found: $BATS_BIN" >&2
  exit 1
fi

# ── Help ──────────────────────────────────────────────────────────────────────

_print_help() {
  cat <<'HELP'
Usage: test.sh [MODE] [--update-timings] [--help] [file.bats ...]

Modes (mutually exclusive; last flag wins):
  --smoke           Run top-5 fastest .bats files from .codex/.test-timings.json
  --changed         Run .bats files mapped from git-changed source files
  --full            Run entire suite with bats --jobs N

Options:
  --update-timings  Alias for --full; refreshes .codex/.test-timings.json on success
  --help            Show this help and exit

Precedence table:
  Positional *.bats paths: bypass mode dispatch (mode flag ignored with stderr notice)
  Last flag wins among mode flags: --smoke --changed → changed; --changed --full → full
  No flag + no positional: CI/GITHUB_ACTIONS/CODEX_CI set → full; else → changed

Concurrency:
  all modes: bats --jobs N (TAP-ordered output via bats parallel mode)
  BATS_JOBS=K env override sets N for any mode

Notes:
  .codex/.test-timings.json updated only by successful (rc=0) --update-timings runs.
  New .bats files not yet in timings won't appear in --smoke until next --update-timings.
HELP
}

# ── Flag parsing ───────────────────────────────────────────────────────────────

mode=""
positional_files=()
explicit_update_timings=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --smoke)          mode="smoke";   explicit_update_timings=false; shift ;;
    --changed)        mode="changed"; explicit_update_timings=false; shift ;;
    --full)           mode="full";    explicit_update_timings=false; shift ;;
    --update-timings) mode="full";    explicit_update_timings=true;  shift ;;
    --help)           _print_help; exit 0 ;;
    -*)               echo "[test.sh] unknown flag: $1" >&2; exit 1 ;;
    *.bats)           positional_files+=("$1"); shift ;;
    *)                echo "[test.sh] unknown argument: $1" >&2; exit 1 ;;
  esac
done

# Positional *.bats paths bypass mode dispatch
if [[ ${#positional_files[@]} -gt 0 ]]; then
  if [[ -n "$mode" ]]; then
    echo "[test.sh] note: positional *.bats args given; mode flag '$mode' ignored" >&2
  fi
  mode="explicit-files"
  selected_files=("${positional_files[@]}")
fi

# Default mode resolution (no flag, no positional)
if [[ -z "$mode" ]]; then
  if [[ -n "${CI:-}" || -n "${GITHUB_ACTIONS:-}" || -n "${CODEX_CI:-}" ]]; then
    mode="full"
  else
    mode="changed"
  fi
fi

# ── CPU / job detection (preserved from original) ─────────────────────────────

detect_cpu_cores() {
  local cores=""
  local quota_file="/sys/fs/cgroup/cpu.max"
  local quota period quota_cores
  if command -v nproc >/dev/null 2>&1; then
    cores="$(nproc 2>/dev/null || true)"
  elif command -v getconf >/dev/null 2>&1; then
    cores="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  fi
  if [[ ! "$cores" =~ ^[0-9]+$ || "$cores" -lt 1 ]]; then
    cores=1
  fi
  if [[ -r "$quota_file" ]]; then
    read -r quota period < "$quota_file" || true
    if [[ "$quota" != "max" ]] \
      && [[ "$quota" =~ ^[0-9]+$ ]] \
      && [[ "$period" =~ ^[0-9]+$ ]] \
      && (( quota > 0 && period > 0 )); then
      quota_cores=$(( (quota + period - 1) / period ))
      if (( quota_cores > 0 && quota_cores < cores )); then
        cores="$quota_cores"
      fi
    fi
  fi
  printf '%s' "$cores"
}

resolve_jobs() {
  local requested="$REQUESTED_JOBS"
  local cores="$1"
  local adaptive_cap
  if [[ ! "$requested" =~ ^[0-9]+$ || "$requested" -lt 1 ]]; then
    echo "[test.sh] invalid BATS_JOBS='$requested' (must be integer >= 1)" >&2
    exit 1
  fi
  if [[ -n "${BATS_MAX_JOBS:-}" ]]; then
    if [[ ! "${BATS_MAX_JOBS}" =~ ^[0-9]+$ || "${BATS_MAX_JOBS}" -lt 1 ]]; then
      echo "[test.sh] invalid BATS_MAX_JOBS='${BATS_MAX_JOBS}' (must be integer >= 1)" >&2
      exit 1
    fi
    if (( requested > BATS_MAX_JOBS )); then
      requested="$BATS_MAX_JOBS"
    fi
  fi
  adaptive_cap=$(( cores * 2 ))
  if (( adaptive_cap < 1 )); then adaptive_cap=1; fi
  if [[ -z "${BATS_ALLOW_OVERSUBSCRIBE:-}" ]] && (( requested > adaptive_cap )); then
    requested="$adaptive_cap"
  fi
  printf '%s' "$requested"
}

CPU_CORES="$(detect_cpu_cores)"
JOBS="$(resolve_jobs "$CPU_CORES")"

# ── run_bats_with_heartbeat (preserved from original) ─────────────────────────

run_bats_with_heartbeat() {
  local heartbeat_secs="${BATS_HEARTBEAT_SECONDS:-30}"
  local batch_timeout="${BATS_BATCH_TIMEOUT_SECONDS:-900}"
  local start_ts now_ts elapsed last_heartbeat=0
  local cmd_pid
  local timed_out=0

  if [[ ! "$heartbeat_secs" =~ ^[0-9]+$ || "$heartbeat_secs" -lt 1 ]]; then
    echo "[test.sh] invalid BATS_HEARTBEAT_SECONDS='$heartbeat_secs' (must be integer >= 1)" >&2
    exit 1
  fi
  if [[ ! "$batch_timeout" =~ ^[0-9]+$ ]]; then
    echo "[test.sh] invalid BATS_BATCH_TIMEOUT_SECONDS='$batch_timeout' (must be integer >= 0)" >&2
    exit 1
  fi

  if command -v setsid >/dev/null 2>&1; then
    setsid "$@" &
  else
    "$@" &
  fi
  cmd_pid=$!
  start_ts="$(date +%s)"

  while kill -0 "$cmd_pid" 2>/dev/null; do
    sleep 1
    if ! kill -0 "$cmd_pid" 2>/dev/null; then break; fi
    now_ts="$(date +%s)"
    elapsed=$(( now_ts - start_ts ))
    if (( batch_timeout > 0 )) && (( elapsed >= batch_timeout )); then
      timed_out=1
      echo "[test.sh] error: batch timed out after ${batch_timeout}s; terminating test process group" >&2
      kill -TERM -- "-$cmd_pid" 2>/dev/null || kill -TERM "$cmd_pid" 2>/dev/null || true
      sleep 2
      kill -KILL -- "-$cmd_pid" 2>/dev/null || kill -KILL "$cmd_pid" 2>/dev/null || true
      break
    fi
    if (( elapsed - last_heartbeat >= heartbeat_secs )); then
      echo "[test.sh] heartbeat: still running (${elapsed}s elapsed)"
      last_heartbeat="$elapsed"
    fi
  done

  local exit_code=0
  if ! wait "$cmd_pid"; then exit_code=$?; fi
  if (( timed_out == 1 )); then return 124; fi
  return "$exit_code"
}

# ── Smoke file selection ───────────────────────────────────────────────────────

_smoke_curated=(
  "codex-compatibility.bats"
  "test-helper-url-parsing.bats"
  "test-curl-pipe-fix.bats"
  "agent-flow-tech-agnostic.bats"
  "test-marketplace-id-fix.bats"
)

select_smoke_files() {
  selected_files=()

  if [[ -f "$TIMINGS_FILE" ]]; then
    if ! command -v jq >/dev/null 2>&1; then
      echo "[test.sh] [smoke] jq not found; cannot parse timings; using curated fallback" >&2
    else
      local sorted
      if ! sorted=$(jq -r 'to_entries | sort_by(.value) | .[].key' "$TIMINGS_FILE" 2>/dev/null); then
        echo "[test.sh] [smoke] warning: failed to parse $TIMINGS_FILE; using curated fallback" >&2
        sorted=""
      fi
      while IFS= read -r fname; do
        [[ -z "$fname" ]] && continue
        local fpath="$TESTS_DIR/$fname"
        [[ -f "$fpath" ]] || continue
        selected_files+=("$fpath")
        [[ ${#selected_files[@]} -ge 5 ]] && break
      done <<< "$sorted"
    fi
  else
    echo "[test.sh] [smoke] no timings file; using curated fallback" >&2
  fi

  # Top up from curated list if fewer than 5 found
  local fname
  for fname in "${_smoke_curated[@]}"; do
    [[ ${#selected_files[@]} -ge 5 ]] && break
    local fpath="$TESTS_DIR/$fname"
    [[ -f "$fpath" ]] || continue
    local already=false existing
    for existing in "${selected_files[@]}"; do
      [[ "$existing" == "$fpath" ]] && { already=true; break; }
    done
    [[ "$already" == "true" ]] && continue
    selected_files+=("$fpath")
  done

  if [[ ${#selected_files[@]} -eq 0 ]]; then
    echo "[test.sh] [smoke] no files found; falling back to --full" >&2
    _collect_bats selected_files
    mode="full"
  fi
}

# ── Changed file selection ─────────────────────────────────────────────────────

_always_full_triggers=(
  "test_helper.bash"
  "tests/lib/"
  ".claude-agent-flow/scripts/test.sh"
  "install.sh"
)

_resolve_diff_base() {
  local candidate ref current_branch

  if [[ -n "${AGENT_FLOW_TEST_DIFF_BASE:-}" ]]; then
    if ! git -C "$ROOT_DIR" rev-parse --verify "${AGENT_FLOW_TEST_DIFF_BASE}^{commit}" >/dev/null 2>&1; then
      echo "[test.sh] [changed] AGENT_FLOW_TEST_DIFF_BASE='${AGENT_FLOW_TEST_DIFF_BASE}' is not a valid commit; running --full" >&2
      return 1
    fi
    git -C "$ROOT_DIR" rev-parse --verify "${AGENT_FLOW_TEST_DIFF_BASE}^{commit}"
    return 0
  fi

  # Prefer the branch upstream when present. Codex cloud tasks may not have an
  # origin remote, but local task branches often still have a main/master base.
  if candidate=$(git -C "$ROOT_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null); then
    if git -C "$ROOT_DIR" merge-base HEAD "$candidate" >/dev/null 2>&1; then
      git -C "$ROOT_DIR" merge-base HEAD "$candidate"
      return 0
    fi
  fi

  for ref in origin/HEAD origin/main origin/master main master; do
    if git -C "$ROOT_DIR" rev-parse --verify "$ref^{commit}" >/dev/null 2>&1 \
      && git -C "$ROOT_DIR" merge-base HEAD "$ref" >/dev/null 2>&1; then
      git -C "$ROOT_DIR" merge-base HEAD "$ref"
      return 0
    fi
  done

  current_branch="$(git -C "$ROOT_DIR" branch --show-current 2>/dev/null || true)"
  if [[ "$current_branch" == "main" || "$current_branch" == "master" ]]; then
    git -C "$ROOT_DIR" rev-parse --verify HEAD
    return 0
  fi

  return 2
}

_collect_changed_paths() {
  local diff_base="$1"
  {
    if [[ -n "$diff_base" ]]; then
      git -C "$ROOT_DIR" diff --name-only "${diff_base}...HEAD" 2>/dev/null || return 1
    fi
    git -C "$ROOT_DIR" diff --name-only 2>/dev/null || return 1
    git -C "$ROOT_DIR" diff --cached --name-only 2>/dev/null || return 1
    git -C "$ROOT_DIR" ls-files --others --exclude-standard 2>/dev/null || return 1
  } | awk 'NF && !seen[$0]++'
}

select_changed_files() {
  local diff_base=""

  if ! diff_base="$(_resolve_diff_base)"; then
    echo "[test.sh] [changed] no safe diff base; using worktree changes only" >&2
    diff_base=""
  fi

  local changed_str
  if ! changed_str="$(_collect_changed_paths "$diff_base")"; then
    echo "[test.sh] [changed] git changed-file detection failed; running --full" >&2
    _collect_bats selected_files
    mode="full"
    return
  fi

  if [[ -z "$changed_str" ]]; then
    echo "[test.sh] [changed] no changed files; running --smoke" >&2
    mode="smoke"
    select_smoke_files
    return
  fi

  # 100-file guardrail: any large change set falls back to --full
  local count
  count=$(awk 'NF { count++ } END { print count + 0 }' <<< "$changed_str")
  if (( count > 100 )); then
    echo "[test.sh] [changed] WARNING: $count changed files (>100 limit); running --full" >&2
    _collect_bats selected_files
    mode="full"
    return
  fi

  # Check always-full triggers
  local trigger="" pat f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    for pat in "${_always_full_triggers[@]}"; do
      if [[ "$f" == *"$pat"* ]]; then
        trigger="$f"
        break 2
      fi
    done
  done <<< "$changed_str"

  if [[ -n "$trigger" ]]; then
    echo "[test.sh] [changed] always-full trigger: $trigger; running --full" >&2
    _collect_bats selected_files
    mode="full"
    return
  fi

  # Build test file set using convention pass + grep fallback
  local -A file_set=()
  local all_bats
    _collect_bats all_bats

  while IFS= read -r f; do
    [[ -z "$f" ]] && continue

    # .bats files in diff: add directly
    if [[ "$f" == *.bats ]]; then
      local bpath="$ROOT_DIR/$f"
      [[ -f "$bpath" ]] && file_set["$bpath"]=1
      continue
    fi

    local term; term=$(basename "${f%.*}")
    # Skip empty terms (dotfiles like .gitignore produce empty basename after %.*)
    [[ -z "$term" ]] && continue
    local bf
    # Convention pass: *term*.bats in tests dir
    for bf in "${all_bats[@]}"; do
      [[ "$(basename "$bf")" == *"${term}"* ]] && file_set["$bf"]=1
    done
    # Grep fallback: fixed-string search to avoid BRE metachar injection
    for bf in "${all_bats[@]}"; do
      grep -qF -- "$term" "$bf" 2>/dev/null && file_set["$bf"]=1
    done
    # Path-stem grep: also search by full relative path (without extension) to
    # catch bats files that source the script by absolute/relative path.
    # e.g. scripts/repo-sync-files.sh → grep for "scripts/repo-sync-files"
    local path_stem="${f%.*}"
    if [[ "$path_stem" != "$term" ]]; then
      for bf in "${all_bats[@]}"; do
        grep -qF -- "$path_stem" "$bf" 2>/dev/null && file_set["$bf"]=1
      done
    fi
  done <<< "$changed_str"

  if [[ ${#file_set[@]} -gt 0 ]]; then
    mapfile -t selected_files < <(printf '%s\n' "${!file_set[@]}" | sort)
  else
    selected_files=()
  fi

  if [[ ${#selected_files[@]} -eq 0 ]]; then
    echo "[test.sh] [changed] no test mapping; running --full" >&2
    _collect_bats selected_files
    mode="full"
    return
  fi

  local total
  total=$(awk 'NF { count++ } END { print count + 0 }' <<< "$changed_str")
  echo "[test.sh] [changed] ${#selected_files[@]} file(s) mapped from $total changed source(s)" >&2
}

# ── Timing update (only when --update-timings is explicit) ────────────────────

_update_timings() {
  local all_bats
    _collect_bats all_bats

  echo "[test.sh] [timings] measuring ${#all_bats[@]} files with jobs=$JOBS" >&2

  local results_dir; results_dir=$(mktemp -d)
  local wrapper; wrapper=$(mktemp)

  # Wrapper script: time one .bats file and record nanoseconds.
  # Uses sanitized key (/ → _) for the temp result filename; JSON key is
  # the relative path from TESTS_DIR to avoid basename collisions across
  # any future subdirectories.
  cat > "$wrapper" <<WRAPPER
#!/usr/bin/env bash
f="\$1"
rel="\${f#${TESTS_DIR}/}"
safe="\${rel//\//_}"
start=\$(date +%s%N 2>/dev/null || echo "\$(date +%s)000000000")
"$BATS_BIN" "\$f" >/dev/null 2>&1
bats_rc=\$?
end=\$(date +%s%N 2>/dev/null || echo "\$(date +%s)000000000")
# Only record timing for a clean run; failed files are excluded from smoke selection
if (( bats_rc == 0 )); then
  ns=\$(( end - start ))
  printf '%s\n' "\$ns" > "$results_dir/\${safe}.time"
fi
WRAPPER
  chmod +x "$wrapper"

  printf '%s\n' "${all_bats[@]}" | xargs -P "$JOBS" -I {} "$wrapper" {} || true
  rm -f "$wrapper"

  local timings_dir; timings_dir=$(dirname "$TIMINGS_FILE")
  mkdir -p "$timings_dir"
  # Use suffix-free mktemp for portability; final rename gives correct name
  local tmp_json; tmp_json=$(mktemp "$timings_dir/.test-timings.XXXXXX")

  printf '{' > "$tmp_json"
  local first=true bf rel safe tfile ns secs
  for bf in "${all_bats[@]}"; do
    rel="${bf#${TESTS_DIR}/}"
    safe="${rel//\//_}"
    tfile="$results_dir/${safe}.time"
    [[ -f "$tfile" ]] || continue
    ns=$(cat "$tfile")
    if [[ "$ns" =~ ^[0-9]+$ ]] && (( ns > 0 )); then
      secs=$(awk "BEGIN {printf \"%.3f\", $ns / 1000000000}" 2>/dev/null || echo "1.0")
    else
      secs="1.0"
    fi
    [[ "$first" == "true" ]] || printf ',' >> "$tmp_json"
    first=false
    # Key is the relative path so smoke selector can reconstruct the full path
    printf '"%s":%s' "$rel" "$secs" >> "$tmp_json"
  done
  printf '}\n' >> "$tmp_json"

  rm -rf "$results_dir"
  mv "$tmp_json" "$TIMINGS_FILE"
  echo "[test.sh] [timings] written to $TIMINGS_FILE" >&2
}

# ── File selection ─────────────────────────────────────────────────────────────

if [[ "$mode" != "explicit-files" ]]; then
  selected_files=()
  case "$mode" in
    full)    _collect_bats selected_files ;;
    smoke)   select_smoke_files ;;
    changed) select_changed_files ;;
  esac
fi

# ── Execute ────────────────────────────────────────────────────────────────────

echo "[test.sh] mode=$mode | files=${#selected_files[@]} | jobs=$JOBS (cores=$CPU_CORES)"
echo "[test.sh] per-test timeout: ${BATS_TEST_TIMEOUT}s"

rc=0
case "$mode" in
  full|explicit-files|smoke|changed)
    echo "[test.sh] concurrency: bats --jobs $JOBS"
    run_bats_with_heartbeat "$BATS_BIN" --jobs "$JOBS" "${selected_files[@]}" || rc=$?
    ;;
esac

# Timing update only on explicit --update-timings with successful run
if [[ "$explicit_update_timings" == "true" ]] && [[ $rc -eq 0 ]]; then
  _update_timings
fi

exit $rc
