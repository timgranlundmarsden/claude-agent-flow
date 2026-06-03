#!/bin/bash
# session-start.sh — Bootstrap hook for agent-flow environment setup
#
# Installs required tools (backlog CLI, playwright-cli, mergiraf, rsync) and
# optionally runs a project-local hook for repo-specific setup.
#
# Each tool install is isolated — a failure in one does not block the others.
# A summary table is printed at the end showing pass/fail per tool.
set -uo pipefail
# NOTE: set -e is intentionally omitted so individual failures don't abort the script.


# Derive project root: prefer CLAUDE_PROJECT_DIR, then CODEX_PROJECT_DIR,
# then git root, then pwd.
PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || true)}}"
[[ -z "$PROJECT_ROOT" ]] && PROJECT_ROOT="$(pwd 2>/dev/null || true)"
if [[ -z "$PROJECT_ROOT" || ! -d "$PROJECT_ROOT" ]]; then
  echo "ERROR: Could not determine project root — skipping session-start setup" >&2
  exit 0
fi
AGENT_FLOW_ROOT="$PROJECT_ROOT/.claude-agent-flow"
if [[ ! -d "$AGENT_FLOW_ROOT" ]]; then
  echo "ERROR: $AGENT_FLOW_ROOT not found — skipping session-start setup" >&2
  exit 0
fi

# ── Consent utilities ──────────────────────────────────────────────────────
# Load the consent-utils library for optional tool consent management.
# Falls back to CLAUDE_PLUGIN_ROOT for plugin-cache installs.
CONSENT_UTILS_LIB="${AGENT_FLOW_ROOT}/scripts/lib/consent-utils.sh"
if [[ ! -f "$CONSENT_UTILS_LIB" && -n "${CLAUDE_PLUGIN_ROOT:-}" && -d "${CLAUDE_PLUGIN_ROOT}" ]]; then
  CONSENT_UTILS_LIB="${CLAUDE_PLUGIN_ROOT}/.claude-agent-flow/scripts/lib/consent-utils.sh"
fi
CONSENT_UTILS_LOADED=0
if [[ -f "$CONSENT_UTILS_LIB" ]]; then
  # shellcheck source=/dev/null
  source "$CONSENT_UTILS_LIB"
  CONSENT_UTILS_LOADED=1
fi

# --- Logging helpers ---
mkdir -p "$PROJECT_ROOT/.claude" 2>/dev/null || true
LOG_FILE="$PROJECT_ROOT/.claude/session-start.log"

# Verify log file is writable — warn once to stderr if not (debugging aid)
if ! touch "$LOG_FILE" 2>/dev/null; then
  echo "WARNING: Cannot write to $LOG_FILE — log output will be stdout only" >&2
  LOG_FILE="/dev/null"
fi

log() {
  local msg
  msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg" >> "$LOG_FILE"
  # run_tool executes installers in a subshell with stdout redirected to LOG_FILE.
  # In that context, suppress echo to avoid duplicate log lines in the file.
  if [[ "${AGENT_FLOW_LOG_TO_STDOUT:-1}" == "1" ]]; then
    echo "$msg"
  fi
}

# Track results for summary table.
# EXPECTED_TOOLS lists every tool that should appear in the table.
# record() populates the actual results; run_tool() guarantees an entry
# even if the installer crashes before calling record().
declare -a EXPECTED_TOOLS=("Backlog CLI" "Playwright CLI" "Chromium" "Mergiraf" "ShellCheck" "rsync" "GNU parallel")
declare -a RECORDED_TOOLS=()

# Sanitise a tool name into a valid variable-name fragment (bash 3.2 compatible)
_key() { printf '%s' "$1" | tr -c '[:alnum:]_' '_'; }

record() {
  # Usage: record "Tool Name" "OK|FAIL|SKIP" "detail message"
  local name="${1:-(unknown)}"
  local result="${2:-FAIL}"
  local detail="${3:-no detail}"
  local key; key="$(_key "$name")"
  eval "TOOL_RESULT_${key}=\"\$result\""
  eval "TOOL_DETAIL_${key}=\"\$detail\""
  RECORDED_TOOLS+=("$name")
}

section_start() { log "──── $1 ────"; }
section_end()   { log "──── $1: $2 ────"; }

# Per-tool install timeout in seconds. Override via env: TOOL_INSTALL_TIMEOUT=30
TOOL_INSTALL_TIMEOUT="${TOOL_INSTALL_TIMEOUT:-120}"
# First session timeout (fresh setup can need longer apt/npm work).
# Override via env: TOOL_INSTALL_TIMEOUT_FIRST_RUN=300
TOOL_INSTALL_TIMEOUT_FIRST_RUN="${TOOL_INSTALL_TIMEOUT_FIRST_RUN:-300}"
SESSION_START_STAMP="$PROJECT_ROOT/.claude/.session-start-tools-ready"
if [[ ! -f "$SESSION_START_STAMP" ]]; then
  TOOL_INSTALL_TIMEOUT="$TOOL_INSTALL_TIMEOUT_FIRST_RUN"
fi

kill_process_tree() {
  # Usage: kill_process_tree TERM|KILL <pid>
  # Kill descendants first so tools that spawn apt/npm/npx children cannot keep
  # the startup hook's stdout/stderr pipes open after the wrapper times out.
  local signal="$1"
  local pid="$2"
  local child

  # Preferred path: run_tool starts installers with job control enabled, making
  # the background shell a process-group leader. This kills the full group even
  # in restricted environments where ps cannot enumerate child processes.
  kill "-$signal" -- "-$pid" 2>/dev/null || true

  while IFS= read -r child; do
    [[ -n "$child" ]] || continue
    kill_process_tree "$signal" "$child"
  done < <(ps -o pid= --ppid "$pid" 2>/dev/null | tr -d ' ')

  kill "-$signal" "$pid" 2>/dev/null || true
}

# run_tool wraps an installer function, guaranteeing that:
# - The tool always gets a record() entry (even on unexpected crash or timeout)
# - Failures don't propagate (|| true equivalent, but with safety net)
# - A hung installer is killed after TOOL_INSTALL_TIMEOUT seconds; the summary
#   table shows TIMEOUT so startup always completes.
#
# CURRENT_TOOL is set by run_tool() so installers use it via record()/section_*
# instead of hardcoding names. Eliminates name-mismatch risk between run_tool
# and record() calls.
#
# Implementation: the installer runs as a background subshell so we can apply a
# deadline. Inside the subshell, record() is overridden to write STATUS<TAB>DETAIL
# to a temp file; the parent reads it back after the subshell exits.
CURRENT_TOOL=""

run_tool() {
  local tool_name="$1"
  local func="$2"
  local timeout_secs="${TOOL_INSTALL_TIMEOUT:-120}"
  if [[ ! "$timeout_secs" =~ ^[0-9]+$ || "$timeout_secs" -lt 1 ]]; then
    timeout_secs=120
  fi
  CURRENT_TOOL="$tool_name"

  # _result_file: installer subshell writes STATUS<TAB>DETAIL here via overridden record().
  # _done_file: installer subshell touches this after the function returns so
  # fast tools do not wait for the polling interval before being reaped.
  # _timed_out_file: timeout handling touches this before killing so we can
  # distinguish timeout from an installer that crashed without calling record().
  local _result_file _done_file _timed_out_file
  _result_file=$(mktemp /tmp/tool-result.XXXXXX)
  _done_file=$(mktemp /tmp/tool-done.XXXXXX)
  _timed_out_file=$(mktemp /tmp/tool-timeout.XXXXXX)
  rm -f "$_done_file"
  rm -f "$_timed_out_file"

  # Run installer in a background subshell with a scoped record() override.
  # Installer output goes to the log file; otherwise an orphaned child process
  # can keep the startup hook's stdout/stderr pipe open after a timeout.
  local _job_control_was_on=0
  case $- in *m*) _job_control_was_on=1 ;; esac
  set -m 2>/dev/null || true
  (
    export AGENT_FLOW_LOG_TO_STDOUT=0
    # shellcheck disable=SC2329 # Overrides record() for indirect calls via tool_record().
    record() { printf '%s\t%s\n' "$2" "$3" > "$_result_file"; }
    "$func" || true
    touch "$_done_file" 2>/dev/null || true
  ) >> "$LOG_FILE" 2>&1 &
  local _pid=$!
  if [[ $_job_control_was_on -eq 0 ]]; then
    set +m 2>/dev/null || true
  fi

  # Poll instead of using a background watchdog. A watchdog needs its own sleep
  # process; if cancellation fails, that child can keep startup hooks alive.
  local _start_secs="$SECONDS"
  while [[ ! -e "$_done_file" ]] && kill -0 "$_pid" 2>/dev/null; do
    if (( SECONDS - _start_secs >= timeout_secs )); then
      touch "$_timed_out_file"
      kill_process_tree TERM "$_pid"
      sleep 2
      kill_process_tree KILL "$_pid"
      break
    fi
    sleep 0.2
  done

  # Block until the installer finishes (normally or killed by timeout handling).
  wait "$_pid" 2>/dev/null || true

  if [[ -e "$_timed_out_file" ]]; then
    log "WARNING: $tool_name installer timed out after ${timeout_secs}s"
    section_end "$tool_name" "TIMEOUT"
    record "$tool_name" "TIMEOUT" "killed after ${timeout_secs}s"
  elif [[ -s "$_result_file" ]]; then
    local _status _detail
    IFS=$'\t' read -r _status _detail < "$_result_file"
    record "$tool_name" "$_status" "$_detail"
  else
    record "$tool_name" "FAIL" "installer crashed before reporting status"
    log "WARNING: $tool_name installer exited without calling record()"
  fi

  rm -f "$_result_file" "$_done_file" "$_timed_out_file"
  CURRENT_TOOL=""
}

# Convenience wrappers that use CURRENT_TOOL — avoids hardcoded name strings
tool_record()        { record "$CURRENT_TOOL" "$1" "$2"; }
tool_section_start() { section_start "$CURRENT_TOOL"; }
tool_section_end()   { section_end "$CURRENT_TOOL" "$1"; }

# =====================================================================
# Two environment flags — use these for all conditional branching here
# and in any other script that sources or calls session-start.sh.
#
#   IS_CLOUD   true  — running in a remote cloud environment
#              false — running locally (developer machine or Codex Desktop)
#
#   AI_FLAVOUR claude — Claude Code is the invoking agent
#                       (CLAUDECODE=1 | AI_AGENT=claude-code/* | CLAUDE_PROJECT_DIR set)
#              codex  — Codex is the invoking agent
#              none   — direct shell invocation, no AI agent detected
#
# Combinations that matter:
#   IS_CLOUD=false, AI_FLAVOUR=claude  → Claude Code running locally (normal dev)
#   IS_CLOUD=true,  AI_FLAVOUR=claude  → Claude Code running in a cloud container
#   IS_CLOUD=false, AI_FLAVOUR=codex   → Codex Desktop/local sandbox
#   IS_CLOUD=true,  AI_FLAVOUR=codex   → Codex cloud container
#   IS_CLOUD=false, AI_FLAVOUR=none    → developer running directly in a local shell

codex_invocation_detected() {
  local _originator_lc="${CODEX_INTERNAL_ORIGINATOR_OVERRIDE:-}"
  _originator_lc="${_originator_lc,,}"
  [[ "${CODEX_CI:-}" == "1" \
    || -n "${CODEX_THREAD_ID:-}" \
    || -n "${CODEX_PROJECT_DIR:-}" \
    || "${CODEX_SHELL:-}" == "1" \
    || -n "${CODEX_SANDBOX:-}" \
    || "$_originator_lc" == codex* ]]
}

# Fallback for startup contexts where CODEX_* vars are not yet exported.
# Keep this conservative: only treat as Codex when no Claude signal exists and
# a Codex runtime footprint is present on disk.
codex_runtime_hint_detected() {
  [[ -z "${CLAUDECODE:-}" \
    && -z "${CLAUDE_PROJECT_DIR:-}" \
    && "${AI_AGENT:-}" != claude-code/* \
    && ( -d /opt/codex || -d /opt/codex/skills ) ]]
}

# IS_CLOUD: true if any cloud-environment signal is present
IS_CLOUD=true
if [[ "${CLAUDE_CODE_REMOTE:-}" == "true" \
   || -n "${CLAUDE_CODE_REMOTE_ENVIRONMENT_TYPE:-}" ]]; then
  IS_CLOUD=true
fi
_originator_lc="${CODEX_INTERNAL_ORIGINATOR_OVERRIDE:-}"
_originator_lc="${_originator_lc,,}"
if (codex_invocation_detected || codex_runtime_hint_detected) \
   && [[ "$_originator_lc" != "codex desktop" ]]; then
  IS_CLOUD=true
fi

# AI_FLAVOUR: which AI agent invoked this script
AI_FLAVOUR=codex
if [[ "${CLAUDECODE:-}" == "1" \
   || "${AI_AGENT:-}" == claude-code/* \
   || -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
  AI_FLAVOUR=claude
elif codex_invocation_detected || codex_runtime_hint_detected; then
  AI_FLAVOUR=codex
fi

# IS_CODEX_ENV: 1 when AI_FLAVOUR=codex (backward compat for installers below).
IS_CODEX_ENV=0
[[ "$AI_FLAVOUR" == "codex" ]] && IS_CODEX_ENV=1

# =====================================================================
log "=== Session start ==="
log "PROJECT_ROOT=$PROJECT_ROOT"
log "AGENT_FLOW_ROOT=$AGENT_FLOW_ROOT"
log "CLAUDE_PROJECT_DIR=${CLAUDE_PROJECT_DIR:-<unset>}"
log "CODEX_PROJECT_DIR=${CODEX_PROJECT_DIR:-<unset>}"
log "CODEX_CI=${CODEX_CI:-<unset>}"
log "CODEX_THREAD_ID=${CODEX_THREAD_ID:-<unset>}"
log "CODEX_SHELL=${CODEX_SHELL:-<unset>}"
log "CODEX_SANDBOX=${CODEX_SANDBOX:-<unset>}"
log "CODEX_INTERNAL_ORIGINATOR_OVERRIDE=${CODEX_INTERNAL_ORIGINATOR_OVERRIDE:-<unset>}"
log "IS_CLOUD=$IS_CLOUD"
log "AI_FLAVOUR=$AI_FLAVOUR"
log "Platform: $(uname -s) $(uname -m)"
log "Runtime: IS_CLOUD=$IS_CLOUD | AI_FLAVOUR=$AI_FLAVOUR"

# Returns the first writable directory already in PATH, so installed binaries
# are immediately usable without any shell config changes.
find_writable_bin_dir() {
  local dir
  if [[ -n "${PATH:-}" ]]; then
    while IFS= read -r -d: dir; do
      [[ -n "$dir" && -d "$dir" && -w "$dir" ]] && echo "$dir" && return 0
    done <<< "${PATH}:"
  fi
  # Fallback: create ~/.local/bin (standard XDG location)
  local fallback="${HOME:?HOME must be set}/.local/bin"
  mkdir -p "$fallback" || return 1
  echo "$fallback"
}

# Probe for the codex CLI binary.
# Sets global: CAP_CODEX ("true"/"false").
probe_codex() {
  CAP_CODEX=false
  if command -v codex &>/dev/null; then
    CAP_CODEX=true
  fi
}

# Re-probe git/gh capabilities each session and refresh sync-state.json.
# Sets globals: CAP_GIT_BINARY, CAP_GIT_REPO, CAP_GH_CLI, CAP_CODEX ("true"/"false").
refresh_capabilities() {
  CAP_GIT_BINARY=false
  CAP_GIT_REPO=false
  CAP_GH_CLI=false
  probe_codex
  if command -v git &>/dev/null; then
    CAP_GIT_BINARY=true
    if git -C "$PROJECT_ROOT" rev-parse --is-inside-work-tree &>/dev/null; then
      CAP_GIT_REPO=true
    fi
  fi
  if command -v gh &>/dev/null; then
    CAP_GH_CLI=true
  fi
  local state_file="$AGENT_FLOW_ROOT/sync-state.json"
  if [[ -f "$state_file" ]]; then
    local updated
    if updated=$(jq \
      --argjson git_binary "$CAP_GIT_BINARY" \
      --argjson git_repo "$CAP_GIT_REPO" \
      --argjson gh_cli "$CAP_GH_CLI" \
      --argjson codex "$CAP_CODEX" \
      '.capabilities = {git_binary: $git_binary, git_repo: $git_repo, gh_cli: $gh_cli, codex: $codex}' \
      "$state_file" 2>/dev/null); then
      echo "$updated" > "${state_file}.tmp" && mv "${state_file}.tmp" "$state_file"
    else
      log "WARNING: failed to update capabilities in sync-state.json — stale values may persist"
    fi
  fi
}

# Write or remove the "## VCS Status" section in CLAUDE.md based on git_repo capability.
update_vcs_status() {
  local claude_md="$PROJECT_ROOT/CLAUDE.md"
  [[ -f "$claude_md" ]] || return 0
  if [[ "$CAP_GIT_REPO" == false ]]; then
    if ! grep -q "^## VCS Status" "$claude_md" 2>/dev/null; then
      printf '\n\n## VCS Status\n\nThis project is running without git version control. Skip all git operations including:\nbranch guards, commits, pushes, rebases, PR creation, and backlog auto-push hooks.\nBacklog changes are local-only. Commands that require git (/rebase, /check-pr,\n/external-review, /plugin-repo-sync, /review) are unavailable.\n\n<!-- VCS-STATUS-END -->\n' >> "$claude_md"
      log "Added VCS Status section to CLAUDE.md (no git repo)"
    fi
  else
    if grep -q "^## VCS Status" "$claude_md" 2>/dev/null; then
      # Stop at explicit sentinel if present (new format), else stop at next ## (old format).
      awk '/^## VCS Status/{in_s=1;next} in_s && /^<!-- VCS-STATUS-END -->/{in_s=0;next} in_s && /^## /{in_s=0} !in_s{if(NF)p=NR; a[NR]=$0} END{for(i=1;i<=p;i++) print a[i]}' \
        "$claude_md" > "$claude_md.tmp" && mv "$claude_md.tmp" "$claude_md" || true
      log "Removed VCS Status section from CLAUDE.md (git repo active)"
    fi
  fi
}

# --- 1. Backlog CLI ---
install_backlog() {
  tool_section_start

  if command -v backlog &>/dev/null; then
    local ver
    ver="$(backlog --version 2>/dev/null || echo 'unknown')"
    log "Already installed: $ver"
    tool_record "OK" "already installed ($ver)"
    tool_section_end "OK"
    return 0
  fi

  log "Installing backlog CLI from fork..."
  local OS ARCH BIN
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  ARCH=$(uname -m)

  case "${OS}-${ARCH}" in
    linux-x86_64)   BIN="backlog-linux-x64" ;;
    linux-aarch64)  BIN="backlog-linux-arm64" ;;
    darwin-x86_64)  BIN="backlog-darwin-x64" ;;
    darwin-arm64)   BIN="backlog-darwin-arm64" ;;
    *)
      log "Unsupported platform: ${OS}-${ARCH}"
      tool_record "SKIP" "unsupported (${OS}-${ARCH})"
      tool_section_end "SKIP"
      return 0
      ;;
  esac

  local INSTALL_DIR
  if [[ "$OS" == "darwin" ]] && command -v brew &>/dev/null; then
    INSTALL_DIR="$(brew --prefix)/bin"
  else
    INSTALL_DIR="$(find_writable_bin_dir)"
  fi

  local URL="https://github.com/timgranlundmarsden/Backlog.md/releases/download/latest/${BIN}"
  if ! curl -fsSL "$URL" -o "${INSTALL_DIR}/backlog"; then
    log "FAIL: curl download failed (URL: $URL)"
    tool_record "FAIL" "download failed"
    tool_section_end "FAIL"
    return 1
  fi

  chmod +x "${INSTALL_DIR}/backlog" || true
  local ver
  ver="$("${INSTALL_DIR}/backlog" --version 2>/dev/null || echo 'unknown')"
  log "Installed to ${INSTALL_DIR}: $ver"
  tool_record "OK" "installed ($ver)"
  tool_section_end "OK"
}

# --- 2. Playwright CLI ---
install_playwright_cli() {
  tool_section_start

  if command -v playwright-cli &>/dev/null; then
    log "Already installed"
    tool_record "OK" "already installed"
    tool_section_end "OK"
    return 0
  fi

  log "Installing playwright-cli..."
  if npm install -g @playwright/cli@latest 2>&1; then
    if command -v playwright-cli &>/dev/null; then
      log "Installed"
      tool_record "OK" "installed"
      tool_section_end "OK"
      return 0
    fi
  fi

  log "FAIL: playwright-cli installation failed"
  tool_record "FAIL" "npm install failed"
  tool_section_end "FAIL"
  return 1
}

# --- 3. Chrome/Chromium browser ---
# Helper: verify /opt/google/chrome/chrome is executable and returns a version
verify_chrome() {
  [[ -x /opt/google/chrome/chrome ]] && /opt/google/chrome/chrome --version &>/dev/null
}

install_chromium() {
  tool_section_start

  local OS_NAME
  OS_NAME="$(uname -s)"

  if [[ "$OS_NAME" == "Linux" ]]; then
    # Check if Chrome/Chromium is already available and working
    if verify_chrome; then
      local ver
      ver="$(/opt/google/chrome/chrome --version 2>/dev/null || echo 'unknown')"
      log "Already available at /opt/google/chrome/chrome ($ver)"
      tool_record "OK" "already installed ($ver)"
      tool_section_end "OK"
      return 0
    fi

    # Accept an existing browser on PATH (common in Codex/CI containers)
    local path_browser=""
    for candidate in google-chrome chrome chromium chromium-browser; do
      if command -v "$candidate" &>/dev/null; then
        path_browser="$candidate"
        break
      fi
    done
    if [[ -n "$path_browser" ]]; then
      local ver
      ver="$($path_browser --version 2>/dev/null || echo 'unknown')"
      log "Already available on PATH: $path_browser ($ver)"
      tool_record "OK" "already installed ($path_browser)"
      tool_section_end "OK"
      return 0
    fi

    log "Setting up Chrome/Chromium for playwright-cli (Linux)..."
    local s2_fail_reason=""

    # Strategy 1: install Playwright Chromium first (lighter than full Chrome apt path)
    # Use non-interactive npx invocation so startup hooks never block on:
    # "Need to install playwright@... Ok to proceed? (y)"
    # (Seen in session-start logs when playwright package is not preinstalled.)
    log "Attempting: npx --yes playwright install chromium..."
    npx --yes playwright install chromium 2>&1 || true
    local PLAYWRIGHT_CHROME err_msg
    PLAYWRIGHT_CHROME=$(find ~/.cache/ms-playwright -name "chrome" -path "*/chrome-linux/*" -type f -perm -111 2>/dev/null | head -1)

    if [[ -n "$PLAYWRIGHT_CHROME" ]]; then
      if ! err_msg=$(mkdir -p /opt/google/chrome 2>&1); then
        s2_fail_reason="mkdir failed: $err_msg"
        log "Strategy 2: $s2_fail_reason"
      elif ! err_msg=$(ln -sf "$PLAYWRIGHT_CHROME" /opt/google/chrome/chrome 2>&1); then
        s2_fail_reason="symlink failed: $err_msg"
        log "Strategy 2: $s2_fail_reason"
      elif verify_chrome; then
        log "Linked: $PLAYWRIGHT_CHROME -> /opt/google/chrome/chrome"
        tool_record "OK" "linked from playwright cache"
        tool_section_end "OK"
        return 0
      else
        s2_fail_reason="symlink created but binary not functional"
        log "Strategy 2: $s2_fail_reason"
      fi
    else
      s2_fail_reason="no executable chrome in playwright cache"
      log "Strategy 2: $s2_fail_reason"
    fi

    # Strategy 2: fallback to full Google Chrome install only outside Codex envs.
    if [[ "${IS_CODEX_ENV:-0}" == "1" ]]; then
      log "SKIP: not attempting full Chrome apt install in Codex environment"
      tool_record "SKIP" "playwright chromium unavailable; skipped full chrome install in Codex"
      tool_section_end "SKIP"
      return 0
    fi
    log "Attempting fallback: npx --yes playwright install chrome..."
    npx --yes playwright install chrome 2>&1 || true
    if verify_chrome; then
      local ver
      ver="$(/opt/google/chrome/chrome --version 2>/dev/null || echo 'unknown')"
      log "Installed Google Chrome: $ver"
      tool_record "OK" "installed via playwright chrome ($ver)"
      tool_section_end "OK"
      return 0
    fi

    log "FAIL: chromium install failed (s1: $s2_fail_reason; s2: full chrome install failed)"
    tool_record "FAIL" "playwright chromium failed; full chrome install failed"
    tool_section_end "FAIL"
    return 1

  elif [[ "$OS_NAME" == "Darwin" ]]; then
    if [[ -d "/Applications/Google Chrome.app" ]]; then
      log "Google Chrome available (macOS)"
      tool_record "OK" "Google Chrome.app found"
      tool_section_end "OK"
      return 0
    fi

    log "No system Chrome found, checking playwright cache..."
    local PLAYWRIGHT_CHROME
    PLAYWRIGHT_CHROME=$(find ~/Library/Caches/ms-playwright -name "Chromium.app" -type d 2>/dev/null | head -1)

    if [[ -z "$PLAYWRIGHT_CHROME" ]]; then
      log "Installing Chromium via npx --yes playwright install chromium..."
      npx --yes playwright install chromium 2>&1 || true
      PLAYWRIGHT_CHROME=$(find ~/Library/Caches/ms-playwright -name "Chromium.app" -type d 2>/dev/null | head -1)
    fi

    # Validate the .app bundle contains an actual executable
    if [[ -n "$PLAYWRIGHT_CHROME" && -d "$PLAYWRIGHT_CHROME" ]]; then
      local chromium_bin="$PLAYWRIGHT_CHROME/Contents/MacOS/Chromium"
      if [[ -x "$chromium_bin" ]]; then
        log "Chromium validated at $PLAYWRIGHT_CHROME"
        tool_record "OK" "playwright cache (macOS)"
        tool_section_end "OK"
        return 0
      else
        log "FAIL: Chromium.app found but no executable at $chromium_bin"
        tool_record "FAIL" "Chromium.app bundle incomplete"
        tool_section_end "FAIL"
        return 1
      fi
    fi

    log "FAIL: could not find or install Chromium"
    tool_record "FAIL" "no Chromium binary found"
    tool_section_end "FAIL"
    return 1

  else
    log "SKIP: unsupported OS ($OS_NAME)"
    tool_record "SKIP" "unsupported OS $OS_NAME"
    tool_section_end "SKIP"
    return 0
  fi
}

# --- 4. Mergiraf ---
install_mergiraf() {
  tool_section_start

  # Consent gate — never install without explicit user opt-in
  if [[ "${CONSENT_UTILS_LOADED:-0}" != "1" ]]; then
    log "consent-utils.sh not loaded — cannot install Mergiraf safely"
    tool_record "SKIP" "consent-utils.sh unavailable"
    tool_section_end "SKIP"
    return 0
  fi
  local mg_consent
  mg_consent="$(consent_read_mergiraf "$PROJECT_ROOT")"
  if [[ "$mg_consent" == "absent" ]]; then
    log "Mergiraf consent absent — run /install to configure"
    tool_record "SKIP" "consent absent — run /install to configure"
    tool_section_end "SKIP"
    return 0
  fi
  if [[ "$mg_consent" != "enabled" ]]; then
    log "Mergiraf consent: disabled — skipping"
    tool_record "SKIP" "user consent: disabled"
    tool_section_end "SKIP"
    return 0
  fi

  if [[ "${CAP_GIT_REPO:-false}" != "true" ]]; then
    log "SKIP: no git repo — mergiraf is a git merge driver"
    tool_record "SKIP" "no git repo — mergiraf not needed"
    tool_section_end "SKIP"
    return 0
  fi

  local MERGIRAF_VERSION="0.16.3"
  local OS_NAME_MG ARCH_MG
  OS_NAME_MG="$(uname -s)"
  ARCH_MG="$(uname -m)"

  # Resolve target triple from OS+arch
  local TARGET_TRIPLE=""
  if [[ "$OS_NAME_MG" == "Darwin" && "$ARCH_MG" == "arm64" ]]; then
    TARGET_TRIPLE="aarch64-apple-darwin"
  elif [[ "$OS_NAME_MG" == "Darwin" && "$ARCH_MG" == "x86_64" ]]; then
    TARGET_TRIPLE="x86_64-apple-darwin"
  elif [[ "$OS_NAME_MG" == "Linux" && "$ARCH_MG" == "x86_64" ]]; then
    TARGET_TRIPLE="x86_64-unknown-linux-musl"
  else
    log "SKIP: unsupported platform (${OS_NAME_MG} ${ARCH_MG})"
    tool_record "SKIP" "unsupported (${OS_NAME_MG} ${ARCH_MG})"
    tool_section_end "SKIP"
    return 0
  fi

  # Already at the right version?
  local INSTALLED_VERSION
  INSTALLED_VERSION="$(mergiraf --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)"
  if [[ "$INSTALLED_VERSION" == "$MERGIRAF_VERSION" ]]; then
    log "Already installed: $INSTALLED_VERSION"
    tool_record "OK" "already installed ($INSTALLED_VERSION)"
    tool_section_end "OK"
  else
    # Resolve vendored tarball path
    local MERGIRAF_TARBALL="${AGENT_FLOW_ROOT}/bin/mergiraf-v${MERGIRAF_VERSION}-${TARGET_TRIPLE}.tar.gz"
    if [[ ! -f "$MERGIRAF_TARBALL" && -n "${CLAUDE_PLUGIN_ROOT:-}" && -d "${CLAUDE_PLUGIN_ROOT}" ]]; then
      MERGIRAF_TARBALL="${CLAUDE_PLUGIN_ROOT}/.claude-agent-flow/bin/mergiraf-v${MERGIRAF_VERSION}-${TARGET_TRIPLE}.tar.gz"
      log "Trying plugin cache: $MERGIRAF_TARBALL"
    fi

    if [[ -f "$MERGIRAF_TARBALL" ]]; then
      log "Installing mergiraf ${MERGIRAF_VERSION} from vendored tarball (${TARGET_TRIPLE})..."
      local MERGIRAF_TMP
      MERGIRAF_TMP="$(mktemp -d)"
      if ! tar xzf "$MERGIRAF_TARBALL" -C "$MERGIRAF_TMP" 2>&1; then
        log "FAIL: tar extraction failed"
        rm -rf "$MERGIRAF_TMP" 2>/dev/null || true
        tool_record "FAIL" "tar extraction failed"
        tool_section_end "FAIL"
        return 1
      fi
      local MERGIRAF_BIN
      MERGIRAF_BIN="$(find "$MERGIRAF_TMP" -name 'mergiraf' -type f 2>/dev/null | head -1)"
      if [[ -z "$MERGIRAF_BIN" ]]; then
        log "FAIL: mergiraf binary not found in tarball"
        rm -rf "$MERGIRAF_TMP" 2>/dev/null || true
        tool_record "FAIL" "binary not found in tarball"
        tool_section_end "FAIL"
        return 1
      fi
      # Resolve install destination: brew prefix on Darwin, else first writable PATH dir
      local MERGIRAF_INSTALL_DIR
      if [[ "$OS_NAME_MG" == "Darwin" ]] && command -v brew &>/dev/null; then
        MERGIRAF_INSTALL_DIR="$(brew --prefix)/bin"
      else
        MERGIRAF_INSTALL_DIR="$(find_writable_bin_dir)" || {
          log "FAIL: no writable bin directory found"
          rm -rf "$MERGIRAF_TMP" 2>/dev/null || true
          tool_record "FAIL" "no writable bin dir"
          tool_section_end "FAIL"
          return 1
        }
      fi
      local MERGIRAF_DEST="${MERGIRAF_INSTALL_DIR}/mergiraf"
      if cp "$MERGIRAF_BIN" "$MERGIRAF_DEST" && chmod +x "$MERGIRAF_DEST"; then
        local ver
        ver="$(mergiraf --version 2>/dev/null || echo 'unknown')"
        log "Installed: $ver"
        tool_record "OK" "installed from tarball ($ver)"
        tool_section_end "OK"
      else
        log "FAIL: could not copy binary to $MERGIRAF_DEST"
        tool_record "FAIL" "copy to $(dirname "$MERGIRAF_DEST") failed"
        tool_section_end "FAIL"
        rm -rf "$MERGIRAF_TMP" 2>/dev/null || true
        return 1
      fi
      rm -rf "$MERGIRAF_TMP" 2>/dev/null || true

    elif [[ "$OS_NAME_MG" == "Darwin" ]] && command -v brew &>/dev/null; then
      log "Vendored tarball not found — falling back to Homebrew..."
      if brew install mergiraf 2>&1; then
        local ver
        ver="$(mergiraf --version 2>/dev/null || echo 'unknown')"
        log "Installed: $ver"
        tool_record "OK" "installed via brew ($ver)"
        tool_section_end "OK"
      else
        log "FAIL: brew install mergiraf failed"
        tool_record "FAIL" "brew install failed"
        tool_section_end "FAIL"
        return 1
      fi
    else
      log "FAIL: vendored tarball not found at $MERGIRAF_TARBALL"
      tool_record "FAIL" "tarball not found"
      tool_section_end "FAIL"
      return 1
    fi
  fi

  if [[ "${CAP_GIT_REPO:-false}" == "true" ]]; then
    if command -v mergiraf &>/dev/null; then
      (cd "$PROJECT_ROOT" && git config --local merge.mergiraf.name mergiraf) || true
      (cd "$PROJECT_ROOT" && git config --local merge.mergiraf.driver 'mergiraf merge --git %O %A %B -s %S -x %X -y %Y -p %P -l %L') || true
    fi
    (cd "$PROJECT_ROOT" && git config --local merge.conflictstyle diff3) || true
    (cd "$PROJECT_ROOT" && git config --local rerere.enabled true) || true

    local GITATTRIBUTES_PATH="${PROJECT_ROOT}/.gitattributes"
    if [[ ! -f "$GITATTRIBUTES_PATH" ]]; then
      cat > "$GITATTRIBUTES_PATH" << 'GITATTRIBUTES_EOF'
# Use mergiraf as the merge driver for syntax-aware conflict resolution.
# mergiraf falls back gracefully for unsupported file formats.
* merge=mergiraf
GITATTRIBUTES_EOF
      log "Created .gitattributes with mergiraf merge driver"
    fi
  fi
}

# --- 5. ShellCheck ---
install_shellcheck() {
  tool_section_start

  if command -v shellcheck &>/dev/null; then
    local ver
    ver="$(shellcheck --version 2>/dev/null | grep '^version:' | awk '{print $2}' || echo 'unknown')"
    log "Already installed: $ver"
    tool_record "OK" "already installed ($ver)"
    tool_section_end "OK"
    return 0
  fi

  local OS_NAME
  OS_NAME="$(uname -s)"

  if [[ "$OS_NAME" == "Linux" ]]; then
    log "Installing shellcheck via apt..."
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y shellcheck 2>&1; then
      log "apt-get install failed; retrying after apt-get update..."
      apt-get update -qq 2>&1 || true
      if ! DEBIAN_FRONTEND=noninteractive apt-get install -y shellcheck 2>&1; then
        log "FAIL: apt-get install failed after update"
        tool_record "FAIL" "apt install failed"
        tool_section_end "FAIL"
        return 1
      fi
    fi
    local ver
    ver="$(shellcheck --version 2>/dev/null | grep '^version:' | awk '{print $2}' || echo 'unknown')"
    log "Installed: $ver"
    tool_record "OK" "installed ($ver)"
    tool_section_end "OK"
    return 0
  elif [[ "$OS_NAME" == "Darwin" ]]; then
    if command -v brew &>/dev/null; then
      log "Installing shellcheck via brew..."
      if brew install shellcheck 2>&1; then
        local ver
        ver="$(shellcheck --version 2>/dev/null | grep '^version:' | awk '{print $2}' || echo 'unknown')"
        log "Installed: $ver"
        tool_record "OK" "installed ($ver)"
        tool_section_end "OK"
        return 0
      fi
      log "FAIL: brew install failed"
      tool_record "FAIL" "brew install failed"
      tool_section_end "FAIL"
      return 1
    else
      log "SKIP: brew not available"
      tool_record "SKIP" "brew not available"
      tool_section_end "SKIP"
      return 0
    fi
  else
    log "SKIP: auto-install only supported on Linux/macOS"
    tool_record "SKIP" "unsupported OS ($OS_NAME)"
    tool_section_end "SKIP"
    return 0
  fi
}

# --- 6. rsync ---
install_rsync() {
  tool_section_start

  if command -v rsync &>/dev/null; then
    local ver
    ver="$(rsync --version 2>/dev/null | awk '
      NR==1 {
        for (i=1; i<=NF; i++) {
          if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+$/) { print $i; exit }
        }
      }
    ')"
    [[ -z "$ver" ]] && ver="unknown"
    log "Already installed: $ver"
    tool_record "OK" "already installed ($ver)"
    tool_section_end "OK"
    return 0
  fi

  local OS_NAME
  OS_NAME="$(uname -s)"

  if [[ "$OS_NAME" == "Linux" ]]; then
    log "Installing rsync via apt..."
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y rsync 2>&1; then
      log "apt-get install failed; retrying after apt-get update..."
      apt-get update -qq 2>&1 || true
      if ! DEBIAN_FRONTEND=noninteractive apt-get install -y rsync 2>&1; then
        log "FAIL: apt-get install failed after update"
        tool_record "FAIL" "apt install failed"
        tool_section_end "FAIL"
        return 1
      fi
    fi
    local ver
    ver="$(rsync --version 2>/dev/null | awk '
      NR==1 {
        for (i=1; i<=NF; i++) {
          if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+$/) { print $i; exit }
        }
      }
    ')"
    [[ -z "$ver" ]] && ver="unknown"
    log "Installed: $ver"
    tool_record "OK" "installed ($ver)"
    tool_section_end "OK"
    return 0
  elif [[ "$OS_NAME" == "Darwin" ]]; then
    # rsync is bundled with macOS
    log "SKIP: rsync should be pre-installed on macOS"
    tool_record "SKIP" "expected pre-installed on macOS"
    tool_section_end "SKIP"
    return 0
  else
    log "SKIP: auto-install only supported on Linux/macOS"
    tool_record "SKIP" "unsupported OS ($OS_NAME)"
    tool_section_end "SKIP"
    return 0
  fi
}

# --- 7. GNU parallel (needed for BATS --jobs) ---
install_parallel() {
  tool_section_start

  local ver=""
  if command -v parallel &>/dev/null; then
    ver="$(parallel --version 2>/dev/null | awk '
      NR==1 { print; exit }
    ')"

    # moreutils also ships a `parallel` command; it is not GNU parallel and
    # does not satisfy the BATS --jobs requirement.
    if [[ "$ver" =~ ^GNU[[:space:]]+parallel[[:space:]]+ ]]; then
      ver="$(printf '%s\n' "$ver" | awk '
        {
          for (i=1; i<=NF; i++) {
            if ($i ~ /^[0-9]{6,8}$/ || $i ~ /^[0-9]+\.[0-9.]+$/) { print $i; exit }
          }
        }
      ')"
      [[ -z "$ver" ]] && ver="unknown"
      log "Already installed: $ver"
      tool_record "OK" "already installed ($ver)"
      tool_section_end "OK"
      return 0
    fi

    log "Found non-GNU parallel on PATH; installing GNU parallel..."
  fi

  local OS_NAME
  OS_NAME="$(uname -s)"

  if [[ "$OS_NAME" == "Linux" ]]; then
    log "Installing parallel via apt..."
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y parallel 2>&1; then
      log "apt-get install failed; retrying after apt-get update..."
      apt-get update -qq 2>&1 || true
      if ! DEBIAN_FRONTEND=noninteractive apt-get install -y parallel 2>&1; then
        log "FAIL: apt-get install failed after update"
        tool_record "FAIL" "apt install failed"
        tool_section_end "FAIL"
        return 1
      fi
    fi

    ver="$(parallel --version 2>/dev/null | awk '
      NR==1 {
        for (i=1; i<=NF; i++) {
          if ($i ~ /^[0-9]{6,8}$/ || $i ~ /^[0-9]+\.[0-9.]+$/) { print $i; exit }
        }
      }
    ')"
    [[ -z "$ver" ]] && ver="unknown"
    log "Installed: $ver"
    tool_record "OK" "installed ($ver)"
    tool_section_end "OK"
    return 0
  fi
  if [[ "$OS_NAME" == "Darwin" ]]; then
    if command -v brew &>/dev/null; then
      log "Installing parallel via brew..."
      if brew install parallel 2>&1; then
        ver="$(parallel --version 2>/dev/null | awk '
          NR==1 {
            for (i=1; i<=NF; i++) {
              if ($i ~ /^[0-9]{6,8}$/ || $i ~ /^[0-9]+\.[0-9.]+$/) { print $i; exit }
            }
          }
        ')"
        [[ -z "$ver" ]] && ver="unknown"
        log "Installed: $ver"
        tool_record "OK" "installed ($ver)"
        tool_section_end "OK"
        return 0
      fi
      log "FAIL: brew install failed"
      tool_record "FAIL" "brew install failed"
      tool_section_end "FAIL"
      return 1
    else
      log "SKIP: brew not available"
      tool_record "SKIP" "brew not available"
      tool_section_end "SKIP"
      return 0
    fi
  else
    log "SKIP: auto-install only supported on Linux/macOS"
    tool_record "SKIP" "unsupported OS ($OS_NAME)"
    tool_section_end "SKIP"
    return 0
  fi
}

# --- 8. Project-local hook (optional) ---
run_project_hook() {
  local HOOK="$PROJECT_ROOT/.claude-agent-flow/scripts/project-session-start.sh"
  if [[ ! -f "$HOOK" ]]; then
    return 0
  fi

  section_start "Project hook"
  log "Running $HOOK..."
  if (bash "$HOOK") >> "$LOG_FILE" 2>&1; then
    record "Project hook" "OK" "completed"
    section_end "Project hook" "OK"
  else
    local rc=$?
    log "FAIL: project hook exited with code $rc"
    record "Project hook" "FAIL" "exit code $rc"
    section_end "Project hook" "FAIL"
    return 1
  fi
}

# =====================================================================
# Run all installers — each is wrapped by run_tool for safety
# =====================================================================

refresh_capabilities
update_vcs_status

log "Step 1: Installing tools..."

run_tool "Backlog CLI"    install_backlog
run_tool "Playwright CLI" install_playwright_cli
run_tool "Chromium"       install_chromium
run_tool "Mergiraf"       install_mergiraf
run_tool "ShellCheck"     install_shellcheck
run_tool "rsync"          install_rsync
run_tool "GNU parallel"   install_parallel

log "Step 1: Tool installation complete"

if [[ -f "$PROJECT_ROOT/.claude-agent-flow/scripts/project-session-start.sh" ]]; then
  run_tool "Project hook" run_project_hook
fi

# =====================================================================
# Summary table
# =====================================================================
DETAIL_WIDTH=39
FAIL_COUNT=0
log ""
log "┌──────────────────┬─────────┬─────────────────────────────────────────┐"
log "│ Tool             │ Status  │ Details                                 │"
log "├──────────────────┼─────────┼─────────────────────────────────────────┤"

# Pre-populate defaults for any expected tool that wasn't recorded
for name in "${EXPECTED_TOOLS[@]}"; do
  _pk="$(_key "$name")"
  eval "_pv=\${TOOL_RESULT_${_pk}:-}"
  if [[ -z "$_pv" ]]; then
    record "$name" "ERROR" "installer did not report"
  fi
done

# Use EXPECTED_TOOLS to guarantee every tool appears, even if installer crashed
for name in "${EXPECTED_TOOLS[@]}"; do
  _sk="$(_key "$name")"
  eval "result=\${TOOL_RESULT_${_sk}:-ERROR}"
  eval "detail=\${TOOL_DETAIL_${_sk}:-installer did not report}"

  # Truncate detail to fit column width, append ellipsis if truncated
  if [[ ${#detail} -gt $DETAIL_WIDTH ]]; then
    detail="${detail:0:$(( DETAIL_WIDTH - 1 ))}…"
  fi

  printf -v row "│ %-16s │ %-7s │ %-${DETAIL_WIDTH}s │" "$name" "$result" "$detail"
  log "$row"
  if [[ "$result" == "FAIL" || "$result" == "ERROR" || "$result" == "TIMEOUT" ]]; then
    (( FAIL_COUNT++ )) || true
  fi
done

# Also print any extra tools recorded but not in EXPECTED_TOOLS (e.g. project hook)
for name in "${RECORDED_TOOLS[@]}"; do
  found=0
  for expected in "${EXPECTED_TOOLS[@]}"; do
    if [[ "$name" == "$expected" ]]; then found=1; break; fi
  done
  if [[ $found -eq 0 ]]; then
    _sk="$(_key "$name")"
    eval "result=\${TOOL_RESULT_${_sk}:-no detail}"
    eval "detail=\${TOOL_DETAIL_${_sk}:-no detail}"
    if [[ ${#detail} -gt $DETAIL_WIDTH ]]; then
      detail="${detail:0:$(( DETAIL_WIDTH - 1 ))}…"
    fi
    printf -v row "│ %-16s │ %-7s │ %-${DETAIL_WIDTH}s │" "$name" "$result" "$detail"
    log "$row"
    if [[ "$result" == "FAIL" || "$result" == "ERROR" || "$result" == "TIMEOUT" ]]; then
      (( FAIL_COUNT++ )) || true
    fi
  fi
done

log "└──────────────────┴─────────┴─────────────────────────────────────────┘"
log ""

if [[ $FAIL_COUNT -gt 0 ]]; then
  log "=== Session start complete ($FAIL_COUNT tool(s) failed — see above) ==="
else
  log "=== Session start complete (all tools OK) ==="
  touch "$SESSION_START_STAMP" 2>/dev/null || true
fi
