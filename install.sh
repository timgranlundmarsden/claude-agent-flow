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

# ── Parse arguments ──
while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope) [[ $# -lt 2 ]] && { echo "Error: --scope requires a value" >&2; exit 1; }; SCOPE="$2"; shift 2 ;;
    --auto-update) AUTO_UPDATE=true; shift ;;
    --source-repo) [[ $# -lt 2 ]] && { echo "Error: --source-repo requires a value" >&2; exit 1; }; SOURCE_REPO="$2"; shift 2 ;;
    --source-branch) [[ $# -lt 2 ]] && { echo "Error: --source-branch requires a value" >&2; exit 1; }; SOURCE_BRANCH="$2"; shift 2 ;;
    --local) if [[ $# -ge 2 && "$2" != --* ]]; then LOCAL_PATH="$2"; shift 2; else LOCAL_PATH="__auto__"; shift; fi ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

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
      if [[ -d "$SCRIPT_SELF_DIR/plugins/$PLUGIN_NAME" ]]; then
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
  # Forward --plugin-dir when running in local mode so the installed script
  # reads from the updated source rather than the already-installed copy
  if [[ -n "$LOCAL_PATH" ]]; then
    INSTALL_ARGS+=(--plugin-dir "$LOCAL_PATH/plugins/$PLUGIN_NAME")
  fi
  exec bash .claude-agent-flow/scripts/agent-flow-install.sh "${INSTALL_ARGS[@]}"
fi

# ── Step 1: Interactivity check and scope prompt ──
if [[ -z "$SCOPE" ]]; then
  if [ -t 0 ]; then
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
      read -rp "Choose scope [A/B/C] (default: A): " choice
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
  fi
fi

echo "Selected scope: $SCOPE"
echo ""

# ── Step 2: Plugin install (if claude CLI is available) ──
if command -v claude &>/dev/null && [[ -z "$LOCAL_PATH" ]]; then
  echo "Claude CLI detected — installing plugin from marketplace..."
  MARKETPLACE_ID="timgranlundmarsden-claude-agent-flow"

  if claude plugin marketplace add "$SOURCE_REPO" 2>/dev/null; then
    echo "Plugin registered in marketplace."
  else
    echo "Note: Plugin marketplace registration skipped (may already be registered)."
  fi

  if claude plugin install "${PLUGIN_NAME}@${MARKETPLACE_ID}" --scope project 2>/dev/null; then
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
  PLUGIN_DIR="$LOCAL_PATH/plugins/$PLUGIN_NAME"
else
  echo "Fetching agent-flow from $SOURCE_REPO..."
  CLONE_DIR=$(mktemp -d)

  cleanup() {
    rm -rf "$CLONE_DIR"
  }
  trap cleanup EXIT

  if command -v gh &>/dev/null; then
    gh repo clone "$SOURCE_REPO" "$CLONE_DIR" -- --depth 1 --branch "$SOURCE_BRANCH"
  else
    git clone --depth 1 --branch "$SOURCE_BRANCH" \
      "https://github.com/${SOURCE_REPO}.git" "$CLONE_DIR"
  fi

  PLUGIN_DIR="$CLONE_DIR/plugins/$PLUGIN_NAME"
fi

if [[ ! -f "$PLUGIN_DIR/.claude-agent-flow/install-manifest.yml" ]]; then
  echo "Error: install-manifest.yml not found at $PLUGIN_DIR/.claude-agent-flow/" >&2
  echo "The plugin repo may be outdated or the clone failed." >&2
  exit 1
fi

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
bash "$PLUGIN_DIR/.claude-agent-flow/scripts/agent-flow-install.sh" "${FINAL_ARGS[@]}"

# ── Verify installation ──
if [[ -f ".claude-agent-flow/sync-state.json" ]]; then
  echo ""
  echo "Installation verified: .claude-agent-flow/sync-state.json created."
else
  echo ""
  echo "Warning: sync-state.json not found after install. Installation may be incomplete." >&2
fi
