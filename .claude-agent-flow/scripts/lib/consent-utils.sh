#!/usr/bin/env bash
# consent-utils.sh — Shared consent management helpers for optional tool installation.
#
# Consent storage (resolution order, highest priority first):
#   1. <project_root>/.claude-agent-flow/optional-tools.json  (per-machine, gitignored)
#   2. <project_root>/.claude-agent-flow/consent-defaults.json (committed repo default)
#   3. Absent → TTY prompt or skip
#
# To reset per-machine override: delete optional-tools.json.
# To reset repo default: delete consent-defaults.json.
#
# Usage: source this file — no top-level side effects.
# Compatible with set -u; does NOT require set -e.

# ── TTY availability ──────────────────────────────────────────────────────────

_tty_available_consent() {
  # Returns 0 if /dev/tty can be opened, 1 otherwise.
  # Respects FORCE_NON_INTERACTIVE=1.
  [[ "${FORCE_NON_INTERACTIVE:-}" == "1" ]] && return 1
  [[ -c /dev/tty ]] && { : </dev/tty; } 2>/dev/null
}

# ── Mergiraf consent (per-repo JSON file) ────────────────────────────────────

_consent_read_mergiraf_from_file() {
  # Args: FILE_PATH
  # Echoes: enabled | disabled | absent
  local consent_file="${1:-}"
  [[ -f "$consent_file" ]] || { echo "absent"; return 0; }

  local value=""
  if command -v jq &>/dev/null; then
    value="$(jq -r '.mergiraf // empty' "$consent_file" 2>/dev/null || true)"
  else
    # Bash fallback: no jq
    value="$(grep -oE '"mergiraf"[[:space:]]*:[[:space:]]*"(enabled|disabled)"' "$consent_file" 2>/dev/null \
      | sed 's/.*"\(enabled\|disabled\)".*/\1/' || true)"
  fi

  case "${value:-}" in
    enabled|disabled) echo "$value" ;;
    *)                echo "absent" ;;
  esac
}

consent_read_mergiraf() {
  # Args: PROJECT_ROOT
  # Precedence: optional-tools.json > consent-defaults.json > absent
  local project_root="${1:-}"
  local dir="${project_root}/.claude-agent-flow"

  local result
  result="$(_consent_read_mergiraf_from_file "${dir}/optional-tools.json")"
  if [[ "$result" != "absent" ]]; then
    echo "$result"
    return 0
  fi
  _consent_read_mergiraf_from_file "${dir}/consent-defaults.json"
}

consent_write_mergiraf() {
  # Args: PROJECT_ROOT VALUE
  # VALUE must be "enabled" or "disabled"
  local project_root="${1:-}"
  local value="${2:-}"

  case "$value" in
    enabled|disabled) ;;
    *) return 1 ;;
  esac

  local consent_dir="${project_root}/.claude-agent-flow"
  mkdir -p "$consent_dir" || return 1

  local consent_file="${consent_dir}/optional-tools.json"
  local tmp_file
  tmp_file="$(mktemp "${consent_dir}/optional-tools.json.XXXXXX")" || return 1

  if command -v jq &>/dev/null && [[ -f "$consent_file" ]]; then
    # Preserve other keys
    if ! jq --arg v "$value" '. + {mergiraf: $v}' "$consent_file" > "$tmp_file" 2>/dev/null; then
      # Fallback if existing file is corrupt
      printf '{"mergiraf": "%s"}\n' "$value" > "$tmp_file" || { rm -f "$tmp_file"; return 1; }
    fi
  elif command -v jq &>/dev/null; then
    printf '{"mergiraf": "%s"}\n' "$value" > "$tmp_file" || { rm -f "$tmp_file"; return 1; }
  else
    # No jq: overwrite with single key (acceptable)
    printf '{"mergiraf": "%s"}\n' "$value" > "$tmp_file" || { rm -f "$tmp_file"; return 1; }
  fi

  mv -f "$tmp_file" "$consent_file" || { rm -f "$tmp_file"; return 1; }
}

# ── Migration helpers ─────────────────────────────────────────────────────────

migrate_mergiraf_consent() {
  # Args: PROJECT_ROOT
  # Advisory: returns 0 always.
  # If consent already present (from either optional-tools.json or consent-defaults.json) → no-op.
  # If .git/config contains mergiraf → write enabled consent to optional-tools.json.
  # Note: when consent-defaults.json specifies a value, migration is intentionally skipped —
  # the defaults layer already provides the answer, so writing optional-tools.json is unnecessary.
  local project_root="${1:-}"

  local existing
  existing="$(consent_read_mergiraf "$project_root")"
  [[ "$existing" != "absent" ]] && return 0

  # Check only per-repo .git/config — never global ~/.gitconfig
  if grep -q '^\[merge "mergiraf"\]' "${project_root}/.git/config" 2>/dev/null; then
    consent_write_mergiraf "$project_root" "enabled" 2>/dev/null || true
  fi

  return 0
}

# ── Interactive prompts ───────────────────────────────────────────────────────

prompt_mergiraf_interactive() {
  # Caller must ensure _tty_available_consent before calling.
  # Args: PROJECT_ROOT
  # Echoes: enabled | disabled
  local project_root="${1:-}"

  printf '\nMergiraf is a syntax-aware merge conflict resolver. When enabled, git will use\n'
  printf 'it as the merge driver for this repo — resulting in fewer conflict markers and\n'
  printf 'smarter auto-resolution of code changes.\n'
  printf '\nScope: this repository only (stored in .git/config).\n'
  printf '\n  Y) Yes, install Mergiraf merge driver for this repo\n'
  printf '  N) No, skip — use standard git merge\n'
  printf '\n'

  local choice=""
  while true; do
    read -rp "Install Mergiraf? [y/N] (default: N): " choice </dev/tty || true
    case "${choice:-N}" in
      [Yy])
        if ! consent_write_mergiraf "$project_root" "enabled"; then
          echo "Warning: could not persist Mergiraf consent — defaulting to disabled" >&2
          echo "disabled"
          return 0
        fi
        echo "enabled"
        return 0
        ;;
      [Nn]|"")
        if ! consent_write_mergiraf "$project_root" "disabled"; then
          echo "Warning: could not persist Mergiraf consent — defaulting to disabled" >&2
          echo "disabled"
          return 0
        fi
        echo "disabled"
        return 0
        ;;
      *)
        printf 'Invalid choice. Enter Y or N.\n' >&2
        ;;
    esac
  done
}
