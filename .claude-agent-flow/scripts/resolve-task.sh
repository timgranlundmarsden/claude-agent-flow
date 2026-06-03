#!/usr/bin/env bash
# resolve-task.sh — Phase 0 task-ID input resolver for /build.
#
# Usage: resolve-task.sh <raw-arguments>
#   raw-arguments: the $ARGUMENTS string after stripping --loops/--external-review flags
#
# Output (stdout) — one or more of the following tagged blocks:
#   TASK_ID=TASK-<N>          (when a task was found or created)
#   PLAN_FILE=<path>          (when a plan file was resolved)
#   PLAN_CONTEXT:             (followed by plan file contents on subsequent lines)
#   END_PLAN_CONTEXT
#   TASK_STATUS:              (followed by AC + notes on subsequent lines, if non-empty)
#   END_TASK_STATUS
#   INLINE_BRIEF=<text>       (when input is plain inline text)
#
# Exit codes:
#   0  success
#   1  invalid / unrecognisable input (message on stderr)
#   2  backlog CLI call failed (message on stderr)
set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Emit PLAN_CONTEXT block from a file
emit_plan_context() {
  local file="$1"
  echo "PLAN_CONTEXT:"
  cat "$file"
  echo "END_PLAN_CONTEXT"
}

# Emit TASK_STATUS block by parsing `backlog task <id> --plain` output.
# Extracts AC check-state lines from Acceptance Criteria section and
# Implementation Notes body.
emit_task_status() {
  local plain_output="$1"
  local ac_lines notes_lines

  # Extract AC check-state block: lines between "Acceptance Criteria:" header
  # and next section header, matching "- [x] #N" or "- [ ] #N" pattern.
  ac_lines=$(echo "$plain_output" | awk '
    /^Acceptance Criteria:/ { in_ac=1; next }
    in_ac && /^[A-Za-z].*:$/ { in_ac=0 }
    in_ac && /^-+ *$/ { next }
    in_ac && /- \[[x ]\] #[0-9]/ { print }
  ')

  # Fallback: if no #N-indexed lines found, capture all - [x]/- [ ] in AC section
  if [[ -z "$ac_lines" ]]; then
    ac_lines=$(echo "$plain_output" | awk '
      /^Acceptance Criteria:/ { in_ac=1; next }
      in_ac && /^[A-Za-z].*:$/ { in_ac=0 }
      in_ac && /^-+ *$/ { next }
      in_ac && /- \[[x ]\]/ { print }
    ')
  fi

  # Extract Implementation Notes body: lines after the dashed separator under
  # "Implementation Notes:" until next known section header or EOF.
  notes_lines=$(echo "$plain_output" | awk '
    /^Implementation Notes:/ { in_notes=1; next }
    in_notes && /^-{3,}/ { in_sep=1; next }
    in_sep && /^(Definition of Done|Implementation Plan|Acceptance Criteria|Description|References):/ { exit }
    in_sep { print }
  ')

  if [[ -z "$ac_lines" && -z "$notes_lines" ]]; then
    return 0  # Nothing to emit
  fi

  echo "TASK_STATUS:"
  if [[ -n "$ac_lines" ]]; then
    echo "$ac_lines"
  fi
  if [[ -n "$notes_lines" ]]; then
    echo "$notes_lines"
  fi
  echo "END_TASK_STATUS"
}

# Backlog CLI plain output has appeared in both forms over time:
# older versions include "Title:", newer versions start "Task TASK-N - Title".
task_plain_exists() {
  local plain_output="$1"
  local task_id="$2"
  local line expected_header
  if echo "$plain_output" | grep -q '^Title:'; then
    return 0
  fi
  expected_header="Task ${task_id}"
  while IFS= read -r line; do
    if [[ "$line" == "$expected_header" || "$line" == "$expected_header - "* ]]; then
      return 0
    fi
  done <<< "$plain_output"
  return 1
}

# Validate and return a References plan file path (guards against path traversal)
validate_plan_path() {
  local raw="$1"
  local trimmed="${raw#"${raw%%[![:space:]]*}"}"  # ltrim
  trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"  # rtrim

  # Must start with "plans/", end with ".md", no "://", no ".." segment
  if [[ "$trimmed" != plans/* ]]; then return 1; fi
  if [[ "$trimmed" != *.md ]]; then return 1; fi
  case "$trimmed" in *://*) return 1;; esac
  case "$trimmed" in */../*|*/..|../*) return 1;; esac
  echo "$trimmed"
}

# ---------------------------------------------------------------------------
# Input normalisation
# ---------------------------------------------------------------------------

raw_input="$*"

# Strip leading/trailing whitespace
input="${raw_input#"${raw_input%%[![:space:]]*}"}"
input="${input%"${input##*[![:space:]]}"}"

# ---------------------------------------------------------------------------
# Entry point detection
# ---------------------------------------------------------------------------

# 1. @backlog/tasks/*.md — any .md file under backlog/tasks/
# Supports: task-37 - Title.md, TASK-37 - Title.md (case-insensitive prefix, hyphen required)
if [[ "$input" == @backlog/tasks/*.md ]]; then
  filename="${input#@backlog/tasks/}"
  # Extract first digit run that follows an optional case-insensitive "task" prefix + hyphen.
  # Uses sed for case-insensitive match: strips task- or TASK- then grabs leading digit run.
  numeric=$(echo "$filename" | sed -E 's/^[Tt][Aa][Ss][Kk]-([0-9]+).*/\1/; s/^0*([0-9])/\1/')
  # If sed produced nothing useful (no task-N pattern found), fall through to inline brief
  if [[ -z "$numeric" || "$numeric" == "0" ]] || ! [[ "$numeric" =~ ^[0-9]+$ ]]; then
    echo "ERROR: resolve-task.sh: could not parse task number from '${input}'" >&2
    exit 1
  fi
  task_id="TASK-${numeric}"
  plain=$(backlog task "$task_id" --plain 2>&1) || { echo "ERROR: resolve-task.sh: backlog task ${task_id} failed: ${plain}" >&2; exit 2; }
  if ! task_plain_exists "$plain" "$task_id"; then
    echo "ERROR: resolve-task.sh: task not found: ${task_id}" >&2
    exit 1
  fi
  echo "TASK_ID=${task_id}"

  # Look for References plan file
  plan_file=""
  ref_line=$(echo "$plain" | grep -m1 '^References: ' || true)
  if [[ -n "$ref_line" ]]; then
    refs="${ref_line#References: }"
    IFS=',' read -ra ref_entries <<< "$refs"
    for entry in "${ref_entries[@]}"; do
      candidate=$(validate_plan_path "$entry" 2>/dev/null || true)
      if [[ -n "$candidate" && -r "$candidate" ]]; then
        plan_file="$candidate"
        break
      fi
    done
  fi

  if [[ -n "$plan_file" ]]; then
    echo "PLAN_FILE=${plan_file}"
    emit_plan_context "$plan_file"
  fi
  emit_task_status "$plain"
  exit 0
fi

# 2. @plans/filename.md (including nested paths like @plans/subdir/file.md)
if [[ "$input" =~ ^@plans/.+\.md$ ]]; then
  plan_path="${input#@}"
  # Apply the same path-traversal guard used for References paths
  plan_path=$(validate_plan_path "$plan_path") || {
    echo "ERROR: resolve-task.sh: invalid plan path '${input#@}' (must be under plans/, no '..' segments)" >&2
    exit 1
  }
  if [[ ! -r "$plan_path" ]]; then
    echo "ERROR: resolve-task.sh: plan file '${plan_path}' not found or not readable" >&2
    exit 1
  fi
  echo "PLAN_FILE=${plan_path}"
  emit_plan_context "$plan_path"

  # Scan for ## Backlog Task: TASK-XX
  task_id=$(grep -m1 '^## Backlog Task:' "$plan_path" | sed 's/^## Backlog Task: *//' | tr -d '[:space:]' || true)
  if [[ -n "$task_id" ]]; then
    plain=$(backlog task "$task_id" --plain 2>&1) || { echo "WARN: resolve-task.sh: backlog task ${task_id} failed; omitting TASK_STATUS" >&2; exit 0; }
    if task_plain_exists "$plain" "$task_id"; then
      echo "TASK_ID=${task_id}"
      emit_task_status "$plain"
    fi
  fi
  exit 0
fi

# 3. TASK-XX / task 41 / task41 / 41 style task ID
# Normalise: strip "task" prefix (case-insensitive), then strip leading dashes/spaces, then strip leading zeros
# Guard: only match "task" when immediately followed by dash, space, or digit — prevents accidental matches
# on words like "tasks-41" or "taskforce-bar".
normalized="$input"
if echo "$normalized" | grep -qiE '^task[-[:space:]0-9]'; then
  normalized="${normalized:4}"  # remove "task" (4 chars)
  # Strip leading dashes and spaces greedily
  while [[ "$normalized" == [-\ ]* ]]; do
    normalized="${normalized:1}"
  done
fi

# Strip leading zeros from a purely-digit remainder
if [[ "$normalized" =~ ^[0-9]+$ ]]; then
  normalized="${normalized#"${normalized%%[!0]*}"}"
  [[ -z "$normalized" ]] && normalized="0"
fi

if [[ "$normalized" =~ ^[0-9]+$ && "$normalized" != "0" ]]; then
  task_id="TASK-${normalized}"
  plain=$(backlog task "$task_id" --plain 2>&1) || { echo "ERROR: resolve-task.sh: backlog task ${task_id} failed: ${plain}" >&2; exit 2; }
  if ! task_plain_exists "$plain" "$task_id"; then
    echo "ERROR: resolve-task.sh: task not found: ${task_id}" >&2
    exit 1
  fi
  echo "TASK_ID=${task_id}"

  # Look for References plan file
  plan_file=""
  ref_line=$(echo "$plain" | grep -m1 '^References: ' || true)
  if [[ -n "$ref_line" ]]; then
    refs="${ref_line#References: }"
    IFS=',' read -ra ref_entries <<< "$refs"
    for entry in "${ref_entries[@]}"; do
      candidate=$(validate_plan_path "$entry" 2>/dev/null || true)
      if [[ -n "$candidate" && -r "$candidate" ]]; then
        plan_file="$candidate"
        break
      fi
    done
  fi

  if [[ -n "$plan_file" ]]; then
    echo "PLAN_FILE=${plan_file}"
    emit_plan_context "$plan_file"
  fi
  emit_task_status "$plain"
  exit 0
fi

# 4. Inline brief text (or empty — caller handles empty check)
echo "INLINE_BRIEF=${input}"
exit 0
