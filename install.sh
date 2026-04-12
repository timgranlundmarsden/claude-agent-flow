#!/usr/bin/env bash
# install.sh — Curl-friendly entry point for agent-flow installation
#
# Usage:
#   # Interactive (recommended):
#   curl -fsSL https://raw.githubusercontent.com/timgranlundmarsden/claude-agent-flow/main/install.sh | bash
#
#   # Non-interactive with scope:
#   curl -fsSL https://raw.githubusercontent.com/timgranlundmarsden/claude-agent-flow/main/install.sh | bash -s -- --scope plugin+github
#
#   # Direct execution:
#   bash install.sh
#   bash install.sh --scope sandbox
#   bash install.sh --with-permissions   # install permission overrides without prompting
#   bash install.sh --skip-permissions   # skip permission overrides without prompting
#   bash install.sh --with-mergiraf   # install Mergiraf merge driver without prompting
#   bash install.sh --skip-mergiraf   # skip Mergiraf without prompting
#
#   # Local testing (no clone — uses local plugin repo):
#   bash install.sh --local /path/to/Claude-Agent-Flow --scope plugin
#   bash install.sh --local  # auto-detects from PLUGIN_REPO_TARGET env var or .env

set -euo pipefail

SOURCE_REPO="timgranlundmarsden/claude-agent-flow"
SOURCE_BRANCH="main"
SCOPE=""
AUTO_UPDATE=false
PLUGIN_NAME="agent-flow"
LOCAL_PATH=""
SKIP_PERMISSIONS=false
WITH_PERMISSIONS=false
SKIP_MERGIRAF=false
WITH_MERGIRAF=false
MARKETPLACE_REPO="timgranlundmarsden/claude-code-plugins"
MARKETPLACE_NAME="timgranlundmarsden"

# ── Parse arguments ──
while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope) [[ $# -lt 2 ]] && { echo "Error: --scope requires a value" >&2; exit 1; }; SCOPE="$2"; shift 2 ;;
    --auto-update) AUTO_UPDATE=true; shift ;;
    --source-repo) [[ $# -lt 2 ]] && { echo "Error: --source-repo requires a value" >&2; exit 1; }; SOURCE_REPO="$2"; shift 2 ;;
    --source-branch) [[ $# -lt 2 ]] && { echo "Error: --source-branch requires a value" >&2; exit 1; }; SOURCE_BRANCH="$2"; shift 2 ;;
    --local) if [[ $# -ge 2 && "$2" != --* ]]; then LOCAL_PATH="$2"; shift 2; else LOCAL_PATH="__auto__"; shift; fi ;;
    --skip-permissions) SKIP_PERMISSIONS=true; shift ;;
    --with-permissions) WITH_PERMISSIONS=true; shift ;;
    --skip-mergiraf) SKIP_MERGIRAF=true; shift ;;
    --with-mergiraf) WITH_MERGIRAF=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ "$SKIP_PERMISSIONS" == true && "$WITH_PERMISSIONS" == true ]]; then
  echo "Error: --skip-permissions and --with-permissions are mutually exclusive" >&2
  exit 1
fi
if [[ "$SKIP_MERGIRAF" == true && "$WITH_MERGIRAF" == true ]]; then
  echo "Error: --skip-mergiraf and --with-mergiraf are mutually exclusive" >&2
  exit 1
fi

# ── TTY availability check ──
# Returns 0 if /dev/tty can actually be opened (controlling terminal exists),
# 1 if the file doesn't exist or cannot be opened (no controlling terminal).
_tty_available() {
  [[ "${FORCE_NON_INTERACTIVE:-}" == "1" ]] && return 1
  [[ -c /dev/tty ]] && { : </dev/tty; } 2>/dev/null
}

# ── Permissions consent prompt ──
prompt_permissions() {
  if [[ "$SKIP_PERMISSIONS" == true || "$WITH_PERMISSIONS" == true ]]; then
    return
  fi
  if _tty_available; then
    echo ""
    echo "Agent Flow can install permission overrides in your project settings that"
    echo "allow common operations (git commands, file editing, code search) to run"
    echo "without prompting you each time."
    echo "Permission deny rules (protecting .env, credentials) are always installed"
    echo "regardless of your choice here."
    echo ""
    echo "  Y) Yes, install permission overrides"
    echo "  N) No, skip -- you'll be prompted for each operation"
    echo ""
    while true; do
      read -rp "Install permission overrides? [Y/N] (default: Y): " perm_choice </dev/tty
      case "${perm_choice:-Y}" in
        [Yy]) break ;;
        [Nn]) SKIP_PERMISSIONS=true; break ;;
        *) echo "Invalid choice. Enter Y or N." ;;
      esac
    done
  else
    SKIP_PERMISSIONS=true
    echo ""
    echo "No terminal detected. Skipping permission overrides."
    echo "  Use --with-permissions to include them."
    echo ""
  fi
}

# ── Locate and source consent-utils.sh ──
# Must be called after PLUGIN_DIR is resolved in the fresh-install path.
# Falls back to the already-installed copy in self-install path.
_source_consent_utils() {
  local candidates=(
    "${PLUGIN_DIR:+$PLUGIN_DIR/.claude-agent-flow/scripts/lib/consent-utils.sh}"
    ".claude-agent-flow/scripts/lib/consent-utils.sh"
  )
  local c
  for c in "${candidates[@]}"; do
    [[ -n "$c" && -f "$c" ]] || continue
    # shellcheck source=/dev/null
    source "$c"
    return 0
  done
  return 1
}

# ── Mergiraf consent prompt ──
prompt_mergiraf() {
  if [[ "$SKIP_MERGIRAF" == true || "$WITH_MERGIRAF" == true ]]; then
    # Write consent to disk so session-start.sh picks it up without prompting
    if declare -f consent_write_mergiraf &>/dev/null; then
      local val="disabled"
      [[ "$WITH_MERGIRAF" == true ]] && val="enabled"
      consent_write_mergiraf "$PROJECT_ROOT_INSTALL" "$val" 2>/dev/null || true
    fi
    return
  fi
  if _tty_available; then
    echo ""
    echo "Mergiraf is a syntax-aware merge conflict resolver. When enabled, git will use"
    echo "it as the merge driver for this repo — resulting in fewer conflict markers and"
    echo "smarter auto-resolution of code changes."
    echo ""
    echo "Scope: this repository only (stored in .git/config)."
    echo ""
    echo "  Y) Yes, install Mergiraf merge driver for this repo"
    echo "  N) No, skip — use standard git merge"
    echo ""
    while true; do
      read -rp "Install Mergiraf? [y/N] (default: N): " mg_choice </dev/tty
      case "${mg_choice:-N}" in
        [Yy]) WITH_MERGIRAF=true; break ;;
        [Nn]|"") SKIP_MERGIRAF=true; break ;;
        *) echo "Invalid choice. Enter Y or N." ;;
      esac
    done
    if declare -f consent_write_mergiraf &>/dev/null; then
      local val="disabled"
      [[ "$WITH_MERGIRAF" == true ]] && val="enabled"
      consent_write_mergiraf "$PROJECT_ROOT_INSTALL" "$val" 2>/dev/null || true
    fi
  else
    SKIP_MERGIRAF=true
    # hint handled by print_optional_tools_hint
  fi
}

# ── Combined non-interactive hint ──
# Prints one hint line when Mergiraf was skipped due to no TTY.
# Reads SKIP_MERGIRAF and WITH_MERGIRAF from the calling scope.
print_optional_tools_hint() {
  # Only print if we're in non-interactive mode (no TTY) and at least one is skipped
  _tty_available && return 0

  local hint=""
  local mg_skipped=false
  [[ "$SKIP_MERGIRAF" == true && "$WITH_MERGIRAF" != true ]] && mg_skipped=true

  if [[ "$mg_skipped" == true ]]; then
    hint="Skipping Mergiraf installation. Use --with-mergiraf to include it."
  fi
  [[ -n "$hint" ]] && echo "  $hint"
}

# ── Validate scope if provided ──
if [[ -n "$SCOPE" && "$SCOPE" != "plugin" && "$SCOPE" != "plugin+github" && "$SCOPE" != "sandbox" ]]; then
  echo "Error: Invalid scope '$SCOPE'. Must be one of: plugin, plugin+github, sandbox" >&2
  exit 1
fi

# ── Must be inside a git repo ──
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  echo "Error: Not inside a git repository." >&2
  echo "Run this from the root of the repo you want to install agent-flow into." >&2
  exit 1
fi

# Resolve project root for consent storage
PROJECT_ROOT_INSTALL="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

echo "╔══════════════════════════════════════════════╗"
echo "║       Agent Flow Installer                   ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ── Resolve LOCAL_PATH early (needed before self-install detection) ──
if [[ -n "$LOCAL_PATH" ]]; then
  if [[ "$LOCAL_PATH" == "__auto__" ]]; then
    if [[ -z "${PLUGIN_REPO_TARGET:-}" && -f .env ]]; then
      PLUGIN_REPO_TARGET=$(grep '^PLUGIN_REPO_TARGET=' .env | cut -d= -f2- | tr -d '"' | tr -d "'")
    fi
    if [[ -z "${PLUGIN_REPO_TARGET:-}" ]]; then
      SCRIPT_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
      if [[ -f "$SCRIPT_SELF_DIR/.claude-plugin/plugin.json" ]]; then
        LOCAL_PATH="$SCRIPT_SELF_DIR"
      else
        echo "Error: --local without a path requires PLUGIN_REPO_TARGET env var or .env" >&2
        exit 1
      fi
    else
      LOCAL_PATH="$PLUGIN_REPO_TARGET"
    fi
  fi
fi

# ── Self-install detection ──
# If agent-flow is already installed (sandbox mode), delegate to local install script
if [[ -f ".claude-agent-flow/scripts/agent-flow-install.sh" ]]; then
  echo "Existing installation detected — delegating to local install script..."
  # If no --scope provided, read stored scope from sync-state.json
  if [[ -z "$SCOPE" && -f ".claude-agent-flow/sync-state.json" ]]; then
    STORED_SCOPE=$(jq -r '.scope // "plugin"' ".claude-agent-flow/sync-state.json" 2>/dev/null || echo "plugin")
    # Migrate legacy scope names
    if [[ "$STORED_SCOPE" == "basic" ]]; then
      echo "Migrating scope 'basic' → 'plugin'"
      STORED_SCOPE="plugin"
    elif [[ "$STORED_SCOPE" == "full" ]]; then
      echo "Migrating scope 'full' → 'plugin+github'"
      STORED_SCOPE="plugin+github"
    fi
    if [[ "$STORED_SCOPE" == "plugin" || "$STORED_SCOPE" == "plugin+github" || "$STORED_SCOPE" == "sandbox" ]]; then
      SCOPE="$STORED_SCOPE"
    else
      SCOPE="plugin"
    fi
  fi
  prompt_permissions
  # Source consent utilities from the existing installation
  if ! _source_consent_utils; then
    echo "Warning: consent-utils.sh not found — skipping Mergiraf prompt" >&2
    SKIP_MERGIRAF=true
  fi
  prompt_mergiraf
  print_optional_tools_hint
  INSTALL_ARGS=(--update)
  if [[ -n "$SCOPE" ]]; then
    INSTALL_ARGS+=(--scope "$SCOPE")
  fi
  if [[ "$SOURCE_REPO" != "timgranlundmarsden/claude-agent-flow" ]]; then
    INSTALL_ARGS+=(--source-repo "$SOURCE_REPO")
  fi
  if [[ "$SOURCE_BRANCH" != "main" ]]; then
    INSTALL_ARGS+=(--source-branch "$SOURCE_BRANCH")
  fi
  if $AUTO_UPDATE; then
    INSTALL_ARGS+=(--auto-update)
  fi
  if [[ "$SKIP_PERMISSIONS" == true ]]; then
    INSTALL_ARGS+=(--skip-permissions)
  fi
  # Forward --plugin-dir when running in local mode so the installed script
  # reads from the updated source rather than the already-installed copy
  if [[ -n "$LOCAL_PATH" ]]; then
    INSTALL_ARGS+=(--plugin-dir "$LOCAL_PATH")
  fi
  INSTALL_ARGS+=(--marketplace-name "$MARKETPLACE_NAME" --marketplace-repo "$MARKETPLACE_REPO")
  exec bash .claude-agent-flow/scripts/agent-flow-install.sh "${INSTALL_ARGS[@]}"
fi

# ── Step 1: Interactivity check and scope prompt ──
if [[ -z "$SCOPE" ]]; then
  if _tty_available; then
    echo "Select installation scope:"
    echo ""
    echo "  A) Plugin — Claude Code components only"
    echo "     Patches CLAUDE.md, merges settings.json, sets up .gitattributes, inits backlog"
    echo "     Best for teams that manage their own CI/CD"
    echo ""
    echo "  B) Plugin + GitHub Actions — Plugin + GitHub Actions"
    echo "     Everything in Plugin, plus automated AI code review on every PR"
    echo "     and Telegram notifications for task/review updates"
    echo ""
    echo "  C) Sandbox — Everything, fully self-contained"
    echo "     All of Plugin + GitHub Actions, plus all agent-flow files vendored into your repo"
    echo "     Best for Claude Code web (claude.ai/code) or air-gapped environments"
    echo ""
    while true; do
      read -rp "Choose scope [A/B/C] (default: A): " choice </dev/tty
      case "${choice:-A}" in
        [Aa]) SCOPE="plugin"; break ;;
        [Bb]) SCOPE="plugin+github"; break ;;
        [Cc]) SCOPE="sandbox"; break ;;
        *) echo "Invalid choice. Enter A, B, or C." ;;
      esac
    done
  else
    SCOPE="plugin"
    echo "Non-interactive mode detected. Defaulting to scope: plugin"
    echo "  Tip: Use '--scope plugin+github' or '--scope sandbox' for other options."
    echo ""
    if [[ "$WITH_PERMISSIONS" != true && "$SKIP_PERMISSIONS" != true ]]; then
      SKIP_PERMISSIONS=true
      echo "  Permission overrides skipped. Use --with-permissions to include them."
    fi
  fi
fi

echo "Selected scope: $SCOPE"
echo ""

prompt_permissions

# ── Step 2: Plugin install (if claude CLI is available) ──
if command -v claude &>/dev/null && [[ -z "$LOCAL_PATH" ]]; then
  echo "Claude CLI detected — installing plugin from marketplace..."

  if claude plugin marketplace add "$MARKETPLACE_REPO" 2>/dev/null; then
    echo "Plugin registered in marketplace."
  else
    echo "Note: Plugin marketplace registration skipped (may already be registered)."
  fi

  if claude plugin install "${PLUGIN_NAME}@${MARKETPLACE_NAME}" --scope project 2>/dev/null; then
    echo "Plugin installed successfully."
  else
    echo "Note: Plugin install skipped (may already be installed)."
  fi

  echo ""
  echo "To configure auto-updates, use: claude plugin marketplace settings"
  echo ""
elif [[ -n "$LOCAL_PATH" ]]; then
  echo "Local mode — skipping plugin marketplace install."
  echo ""
else
  echo "Claude CLI not found — skipping plugin marketplace install."
  echo "  The agent-flow files will be installed directly into your repo."
  echo ""
fi

# ── Step 3: Resolve plugin source and run install script ──
if [[ -n "$LOCAL_PATH" ]]; then
  # Local test mode — use a local plugin repo path directly (no clone)
  # (LOCAL_PATH was already resolved from __auto__ earlier)
  echo "Using local plugin repo: $LOCAL_PATH"
  CLONE_DIR=""
  PLUGIN_DIR="$LOCAL_PATH"
else
  echo "Fetching agent-flow from $SOURCE_REPO..."
  CLONE_DIR=$(mktemp -d)

  cleanup() {
    rm -rf "$CLONE_DIR"
  }
  trap cleanup EXIT

  git clone --depth 1 --branch "$SOURCE_BRANCH" \
    "https://github.com/${SOURCE_REPO}.git" "$CLONE_DIR"

  PLUGIN_DIR="$CLONE_DIR"
fi

if [[ ! -f "$PLUGIN_DIR/.claude-agent-flow/install-manifest.yml" ]]; then
  echo "Error: install-manifest.yml not found at $PLUGIN_DIR/.claude-agent-flow/" >&2
  echo "The plugin repo may be outdated or the clone failed." >&2
  exit 1
fi

# Source consent utilities from the plugin dir (now resolved)
if ! _source_consent_utils; then
  echo "Warning: consent-utils.sh not found — skipping Mergiraf prompt" >&2
  SKIP_MERGIRAF=true
fi
prompt_mergiraf
print_optional_tools_hint

echo "Running agent-flow install script..."
FINAL_ARGS=(--scope "$SCOPE" --plugin-dir "$PLUGIN_DIR")
if $AUTO_UPDATE; then
  FINAL_ARGS+=(--auto-update)
fi
if [[ "$SOURCE_REPO" != "timgranlundmarsden/claude-agent-flow" ]]; then
  FINAL_ARGS+=(--source-repo "$SOURCE_REPO")
fi
if [[ "$SOURCE_BRANCH" != "main" ]]; then
  FINAL_ARGS+=(--source-branch "$SOURCE_BRANCH")
fi
if [[ "$SKIP_PERMISSIONS" == true ]]; then
  FINAL_ARGS+=(--skip-permissions)
fi
FINAL_ARGS+=(--marketplace-name "$MARKETPLACE_NAME" --marketplace-repo "$MARKETPLACE_REPO")
bash "$PLUGIN_DIR/.claude-agent-flow/scripts/agent-flow-install.sh" "${FINAL_ARGS[@]}"

# ── Verify installation ──
if [[ -f ".claude-agent-flow/sync-state.json" ]]; then
  echo ""
  echo "Installation verified: .claude-agent-flow/sync-state.json created."
else
  echo ""
  echo "Warning: sync-state.json not found after install. Installation may be incomplete." >&2
fi
