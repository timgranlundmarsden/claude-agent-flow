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


# Derive project root: prefer CLAUDE_PROJECT_DIR, then git root.
PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
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
  echo "$msg"
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

# run_tool wraps an installer function, guaranteeing that:
# - The tool always gets a record() entry (even on unexpected crash)
# - Failures don't propagate (|| true equivalent, but with safety net)
# CURRENT_TOOL is set by run_tool() so installers use it via record()/section_*
# instead of hardcoding names. Eliminates name-mismatch risk between run_tool
# and record() calls.
CURRENT_TOOL=""

run_tool() {
  local tool_name="$1"
  local func="$2"
  CURRENT_TOOL="$tool_name"

  "$func" || true

  # If the function crashed before calling record(), mark it as FAIL.
  local _rk; _rk="$(_key "$tool_name")"
  local _rv; eval "_rv=\${TOOL_RESULT_${_rk}:-}"
  if [[ -z "$_rv" ]]; then
    record "$tool_name" "FAIL" "installer crashed before reporting status"
    log "WARNING: $tool_name installer exited without calling record()"
  fi
  CURRENT_TOOL=""
}

# Convenience wrappers that use CURRENT_TOOL — avoids hardcoded name strings
tool_record()        { record "$CURRENT_TOOL" "$1" "$2"; }
tool_section_start() { section_start "$CURRENT_TOOL"; }
tool_section_end()   { section_end "$CURRENT_TOOL" "$1"; }

# =====================================================================
log "=== Session start ==="
log "PROJECT_ROOT=$PROJECT_ROOT"
log "AGENT_FLOW_ROOT=$AGENT_FLOW_ROOT"
log "CLAUDE_PROJECT_DIR=${CLAUDE_PROJECT_DIR:-<unset>}"
log "Platform: $(uname -s) $(uname -m)"

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

    log "Setting up Chrome/Chromium for playwright-cli (Linux)..."
    local s2_fail_reason=""

    # Strategy 1: npx playwright install chrome (installs full Google Chrome via apt)
    log "Attempting: npx playwright install chrome..."
    npx playwright install chrome 2>&1 || true
    if verify_chrome; then
      local ver
      ver="$(/opt/google/chrome/chrome --version 2>/dev/null || echo 'unknown')"
      log "Installed Google Chrome: $ver"
      tool_record "OK" "installed via playwright ($ver)"
      tool_section_end "OK"
      return 0
    fi
    log "Strategy 1 (playwright install chrome) did not produce working /opt/google/chrome/chrome"

    # Strategy 2: npx playwright install chromium (downloads bundled Chromium, symlink it)
    log "Attempting: npx playwright install chromium..."
    npx playwright install chromium 2>&1 || true
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

    log "FAIL: both strategies failed (s2: $s2_fail_reason)"
    tool_record "FAIL" "s1: no chrome; s2: $s2_fail_reason"
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
      log "Installing Chromium via npx playwright install chromium..."
      npx playwright install chromium 2>&1 || true
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

  # Configure Git for mergiraf (independently useful settings too)
  if command -v mergiraf &>/dev/null; then
    (cd "$PROJECT_ROOT" && git config --local merge.mergiraf.name mergiraf) || true
    (cd "$PROJECT_ROOT" && git config --local merge.mergiraf.driver 'mergiraf merge --git %O %A %B -s %S -x %X -y %Y -p %P -l %L') || true
  fi
  (cd "$PROJECT_ROOT" && git config --local merge.conflictstyle diff3) || true
  (cd "$PROJECT_ROOT" && git config --local rerere.enabled true) || true

  # Create repo-level .gitattributes if missing
  local GITATTRIBUTES_PATH="${PROJECT_ROOT}/.gitattributes"
  if [[ ! -f "$GITATTRIBUTES_PATH" ]]; then
    cat > "$GITATTRIBUTES_PATH" << 'GITATTRIBUTES_EOF'
# Use mergiraf as the merge driver for syntax-aware conflict resolution.
# mergiraf falls back gracefully for unsupported file formats.
* merge=mergiraf
GITATTRIBUTES_EOF
    log "Created .gitattributes with mergiraf merge driver"
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
    if ! apt-get install -y shellcheck 2>&1; then
      log "apt-get install failed; retrying after apt-get update..."
      apt-get update -qq 2>&1 || true
      if ! apt-get install -y shellcheck 2>&1; then
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
    ver="$(rsync --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo 'unknown')"
    log "Already installed: $ver"
    tool_record "OK" "already installed ($ver)"
    tool_section_end "OK"
    return 0
  fi

  local OS_NAME
  OS_NAME="$(uname -s)"

  if [[ "$OS_NAME" == "Linux" ]]; then
    log "Installing rsync via apt..."
    if ! apt-get install -y rsync 2>&1; then
      log "apt-get install failed; retrying after apt-get update..."
      apt-get update -qq 2>&1 || true
      if ! apt-get install -y rsync 2>&1; then
        log "FAIL: apt-get install failed after update"
        tool_record "FAIL" "apt install failed"
        tool_section_end "FAIL"
        return 1
      fi
    fi
    local ver
    ver="$(rsync --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo 'unknown')"
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

  if command -v parallel &>/dev/null; then
    local ver
    ver="$(parallel --version 2>/dev/null | head -1 | grep -oE '[0-9]+' | head -1 || echo 'unknown')"
    log "Already installed: $ver"
    tool_record "OK" "already installed ($ver)"
    tool_section_end "OK"
    return 0
  fi

  local OS_NAME
  OS_NAME="$(uname -s)"

  if [[ "$OS_NAME" == "Linux" ]]; then
    log "Installing parallel via apt..."
    if ! apt-get install -y parallel 2>&1; then
      log "apt-get install failed; retrying after apt-get update..."
      apt-get update -qq 2>&1 || true
      if ! apt-get install -y parallel 2>&1; then
        log "FAIL: apt-get install failed after update"
        tool_record "FAIL" "apt install failed"
        tool_section_end "FAIL"
        return 1
      fi
    fi
    log "Installed"
    tool_record "OK" "installed"
    tool_section_end "OK"
    return 0
  elif [[ "$OS_NAME" == "Darwin" ]]; then
    if command -v brew &>/dev/null; then
      log "Installing parallel via brew..."
      if brew install parallel 2>&1; then
        log "Installed"
        tool_record "OK" "installed"
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

log "Step 1: Installing tools..."

run_tool "Backlog CLI"    install_backlog
run_tool "Playwright CLI" install_playwright_cli
run_tool "Chromium"       install_chromium
run_tool "Mergiraf"       install_mergiraf
run_tool "ShellCheck"     install_shellcheck
run_tool "rsync"          install_rsync
run_tool "GNU parallel"   install_parallel

log "Step 1: Tool installation complete"

run_project_hook || true

# =====================================================================
# Summary table
# =====================================================================
DETAIL_WIDTH=39
FAIL_COUNT=0
log ""
log "┌──────────────────┬────────┬─────────────────────────────────────────┐"
log "│ Tool             │ Status │ Details                                 │"
log "├──────────────────┼────────┼─────────────────────────────────────────┤"

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

  printf -v row "│ %-16s │ %-6s │ %-${DETAIL_WIDTH}s │" "$name" "$result" "$detail"
  log "$row"
  if [[ "$result" == "FAIL" || "$result" == "ERROR" ]]; then
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
    printf -v row "│ %-16s │ %-6s │ %-${DETAIL_WIDTH}s │" "$name" "$result" "$detail"
    log "$row"
    if [[ "$result" == "FAIL" || "$result" == "ERROR" ]]; then
      (( FAIL_COUNT++ )) || true
    fi
  fi
done

log "└──────────────────┴────────┴─────────────────────────────────────────┘"
log ""

if [[ $FAIL_COUNT -gt 0 ]]; then
  log "=== Session start complete ($FAIL_COUNT tool(s) failed — see above) ==="
else
  log "=== Session start complete (all tools OK) ==="
fi
