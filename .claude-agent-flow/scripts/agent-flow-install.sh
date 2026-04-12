#!/usr/bin/env bash
# agent-flow-install.sh — Install or update agent-flow in a target repo
#
# Reads install-manifest.yml from the plugin directory to determine what
# files to merge, copy, or reverse-map into the user's repository.
#
# Usage:
#   # Called by install.sh (normal flow):
#   agent-flow-install.sh --scope plugin --plugin-dir /path/to/claude-agent-flow
#
#   # Update mode (re-sync from source):
#   agent-flow-install.sh --update --scope plugin+github --plugin-dir /path/to/claude-agent-flow

set -euo pipefail

PROJECT_NAME=""
UPDATE_MODE=false
# Placeholder token split to survive repo-sync's CHANGEME→project-name sed replacement
PLACEHOLDER_TOKEN="CHANGE""ME"
SOURCE_REPO="timgranlundmarsden/claude-agent-flow"
SOURCE_BRANCH="main"
SCOPE=""
AUTO_UPDATE=false
PLUGIN_DIR=""
SKIP_PERMISSIONS=false
SKIP_MERGIRAF=false
WITH_MERGIRAF=false
MARKETPLACE_NAME="timgranlundmarsden"
MARKETPLACE_REPO="timgranlundmarsden/claude-code-plugins"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-name) [[ $# -lt 2 ]] && { echo "Error: --project-name requires a value" >&2; exit 1; }; PROJECT_NAME="$2"; shift 2 ;;
    --update) UPDATE_MODE=true; shift ;;
    --source-repo) [[ $# -lt 2 ]] && { echo "Error: --source-repo requires a value" >&2; exit 1; }; SOURCE_REPO="$2"; shift 2 ;;
    --source-branch) [[ $# -lt 2 ]] && { echo "Error: --source-branch requires a value" >&2; exit 1; }; SOURCE_BRANCH="$2"; shift 2 ;;
    --scope) [[ $# -lt 2 ]] && { echo "Error: --scope requires a value" >&2; exit 1; }; SCOPE="$2"; shift 2 ;;
    --auto-update) AUTO_UPDATE=true; shift ;;
    --plugin-dir) [[ $# -lt 2 ]] && { echo "Error: --plugin-dir requires a value" >&2; exit 1; }; PLUGIN_DIR="$2"; shift 2 ;;
    --skip-permissions) SKIP_PERMISSIONS=true; shift ;;
    --skip-mergiraf) SKIP_MERGIRAF=true; shift ;;
    --with-mergiraf) WITH_MERGIRAF=true; shift ;;
    --marketplace-name) [[ $# -lt 2 ]] && { echo "Error: --marketplace-name requires a value" >&2; exit 1; }; MARKETPLACE_NAME="$2"; shift 2 ;;
    --marketplace-repo) [[ $# -lt 2 ]] && { echo "Error: --marketplace-repo requires a value" >&2; exit 1; }; MARKETPLACE_REPO="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ── Validate inputs ──
if [[ -n "$SCOPE" && "$SCOPE" != "plugin" && "$SCOPE" != "plugin+github" && "$SCOPE" != "sandbox" ]]; then
  echo "Error: Invalid scope '$SCOPE'. Must be one of: plugin, plugin+github, sandbox" >&2
  exit 1
fi
[[ -z "$SCOPE" ]] && SCOPE="plugin"

TARGET_DIR="$(pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Resolve plugin directory ──
if [[ -z "$PLUGIN_DIR" ]]; then
  # Infer from script location: scripts/ is inside .claude-agent-flow/
  PLUGIN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
fi

# ── Self-install detection ──
# When PLUGIN_DIR == TARGET_DIR (running install from within the plugin repo clone),
# all files are already in place. Skip merge and copy operations; only run
# backlog init, sync-state creation, and Mergiraf setup.
SELF_INSTALL=false
if [[ "$(realpath "$PLUGIN_DIR" 2>/dev/null || echo "$PLUGIN_DIR")" == \
      "$(realpath "$TARGET_DIR" 2>/dev/null || echo "$TARGET_DIR")" ]]; then
  SELF_INSTALL=true
fi

INSTALL_MANIFEST="$PLUGIN_DIR/.claude-agent-flow/install-manifest.yml"
if [[ ! -f "$INSTALL_MANIFEST" ]]; then
  echo "Error: install-manifest.yml not found at $INSTALL_MANIFEST" >&2
  exit 1
fi

echo "╔══════════════════════════════════════════════╗"
echo "║       Agent Flow Installation Script         ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ── Prerequisites ──
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  echo "Error: Not inside a git repository." >&2
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required. Install with: apt-get install jq / brew install jq" >&2
  exit 1
fi

if ! command -v rsync &>/dev/null; then
  echo "Error: rsync is required. Install with: apt-get install rsync / brew install rsync" >&2
  exit 1
fi

# ── Prompt for project name if not provided ──
if [[ -z "$PROJECT_NAME" && "$UPDATE_MODE" == false ]]; then
  if [[ -f "$TARGET_DIR/backlog/config.yml" ]]; then
    existing=$(grep '^project_name:' "$TARGET_DIR/backlog/config.yml" | sed -E 's/project_name:[[:space:]]*"?([^"]*)"?/\1/')
    if [[ "$existing" != "$PLACEHOLDER_TOKEN" && -n "$existing" ]]; then
      PROJECT_NAME="$existing"
      echo "Detected project name: $PROJECT_NAME"
    fi
  fi

  if [[ -z "$PROJECT_NAME" ]]; then
    PROJECT_NAME="$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null)"
    if [[ -n "$PROJECT_NAME" && "$PROJECT_NAME" != "/" ]]; then
      echo "Using repo folder name as project: $PROJECT_NAME"
    else
      echo ""
      read -rp "Enter project name: " PROJECT_NAME
      if [[ -z "$PROJECT_NAME" ]]; then
        echo "Error: Project name is required." >&2
        exit 1
      fi
    fi
  fi
fi

echo ""
echo "Configuration:"
echo "  Source:  $SOURCE_REPO ($SOURCE_BRANCH)"
echo "  Plugin:  $PLUGIN_DIR"
echo "  Target:  $TARGET_DIR"
if [[ -n "$PROJECT_NAME" ]]; then
  echo "  Project: $PROJECT_NAME"
fi
echo "  Mode:    $(if $UPDATE_MODE; then echo "Update"; else echo "Install"; fi)"
echo "  Scope:   $SCOPE"
if $AUTO_UPDATE; then echo "  Auto-update: enabled"; fi
echo "  Permissions: $(if [[ "$SKIP_PERMISSIONS" == true ]]; then echo "skipped (--skip-permissions)"; else echo "installed"; fi)"
echo ""

# ── Detect scope change on re-run ──
if [[ -f "$TARGET_DIR/.claude-agent-flow/sync-state.json" ]]; then
  EXISTING_SCOPE=$(jq -r '.scope // "plugin"' "$TARGET_DIR/.claude-agent-flow/sync-state.json" 2>/dev/null || echo "plugin")
  # Migrate legacy scope names
  if [[ "$EXISTING_SCOPE" == "basic" ]]; then
    echo "Migrating scope 'basic' → 'plugin'"
    EXISTING_SCOPE="plugin"
  elif [[ "$EXISTING_SCOPE" == "full" ]]; then
    echo "Migrating scope 'full' → 'plugin+github'"
    EXISTING_SCOPE="plugin+github"
  fi
  if [[ "$EXISTING_SCOPE" != "plugin" && "$EXISTING_SCOPE" != "plugin+github" && "$EXISTING_SCOPE" != "sandbox" ]]; then
    EXISTING_SCOPE="plugin"
  fi
  if [[ "$EXISTING_SCOPE" != "$SCOPE" ]]; then
    SCOPE_ORDER="plugin plugin+github sandbox"
    OLD_IDX=$(echo "$SCOPE_ORDER" | tr ' ' '\n' | grep -xFn "${EXISTING_SCOPE}" | cut -d: -f1 || echo "0")
    NEW_IDX=$(echo "$SCOPE_ORDER" | tr ' ' '\n' | grep -xFn "${SCOPE}" | cut -d: -f1 || echo "0")
    OLD_IDX="${OLD_IDX:-0}"
    NEW_IDX="${NEW_IDX:-0}"
    if [[ "$NEW_IDX" -lt "$OLD_IDX" && "$OLD_IDX" -gt 0 && "$NEW_IDX" -gt 0 ]]; then
      echo "Warning: Downgrading scope from '$EXISTING_SCOPE' to '$SCOPE'."
      echo "  Previously installed files will NOT be removed."
      echo "  To fully downgrade, manually remove unwanted files."
      echo ""
    else
      echo "Upgrading scope from '$EXISTING_SCOPE' to '$SCOPE'."
      echo ""
    fi
  fi
fi

# ── Simple YAML parser helpers ──
yaml_list() {
  local file="$1" key="$2"
  awk -v key="$key:" '
    index($0, key) == 1 {found=1; next}
    found && /^[^ ]/ {found=0}
    found && /^  - / {gsub(/^  - /, ""); gsub(/"/, ""); sub(/[[:space:]]*#.*$/, ""); print}
  ' "$file"
}

yaml_scalar() {
  local file="$1" key="$2"
  awk -v key="$key:" '
    index($0, key) == 1 {
      val=$0; sub("^" key "[[:space:]]*", "", val); gsub(/"/, "", val); sub(/[[:space:]]*#.*$/, "", val); print val; exit
    }
  ' "$file"
}

# ── Mergiraf consent ──
# Prompt if consent is absent and no flag was passed. When called via install.sh,
# that script writes consent first so this block is a no-op (consent not absent).
# When called directly (e.g. /install command), this is where the user is asked.
_CONSENT_UTILS="$PLUGIN_DIR/.claude-agent-flow/scripts/lib/consent-utils.sh"
if [[ -f "$_CONSENT_UTILS" ]]; then
  # shellcheck source=/dev/null
  source "$_CONSENT_UTILS"
  # Explicit flags always win — write consent before migration check so the
  # flag result is never overwritten by migration logic.
  if [[ "$SKIP_MERGIRAF" == true ]]; then
    consent_write_mergiraf "$TARGET_DIR" "disabled" 2>/dev/null || true
  elif [[ "$WITH_MERGIRAF" == true ]]; then
    consent_write_mergiraf "$TARGET_DIR" "enabled" 2>/dev/null || true
    consent_write_mergiraf "$TARGET_DIR" "enabled" "consent-defaults.json" 2>/dev/null || true
  else
    _mg_consent="$(consent_read_mergiraf "$TARGET_DIR")"
    if [[ "$_mg_consent" == "absent" ]]; then
      migrate_mergiraf_consent "$TARGET_DIR"
      _mg_consent="$(consent_read_mergiraf "$TARGET_DIR")"
    fi
    if [[ "$_mg_consent" == "absent" ]]; then
      if _tty_available_consent; then
        _mg_consent="$(prompt_mergiraf_interactive "$TARGET_DIR")"
      else
        echo "  Mergiraf: no TTY — skipping (re-run /install to configure)"
      fi
    fi
  fi
fi

# ── Process merge_files from install-manifest ──
echo "Processing merge operations..."

# Parse merge_files block — each entry starts with "  - path:"
process_merge_files() {
  local current_path="" current_strategy="" current_source=""
  local -a current_lines=()
  local -a current_sections=()
  local -a current_keys=()
  local in_lines=false in_sections=false in_keys=false

  while IFS= read -r line; do
    # Detect new entry
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]path:[[:space:]]*(.*) ]]; then
      # Process previous entry if exists
      if [[ -n "$current_path" ]]; then
        execute_merge "$current_path" "$current_strategy" "$current_source" \
          "$(printf '%s\n' "${current_lines[@]+"${current_lines[@]}"}")" \
          "$(printf '%s\n' "${current_sections[@]+"${current_sections[@]}"}")" \
          "$(printf '%s\n' "${current_keys[@]+"${current_keys[@]}"}")"
      fi
      current_path="${BASH_REMATCH[1]}"
      current_path="${current_path//\"/}"
      current_strategy=""
      current_source=""
      current_lines=()
      current_sections=()
      current_keys=()
      in_lines=false
      in_sections=false
      in_keys=false
      continue
    fi

    [[ -z "$current_path" ]] && continue

    if [[ "$line" =~ ^[[:space:]]*strategy:[[:space:]]*(.*) ]]; then
      current_strategy="${BASH_REMATCH[1]//\"/}"
      in_lines=false; in_sections=false; in_keys=false
    elif [[ "$line" =~ ^[[:space:]]*source:[[:space:]]*(.*) ]]; then
      current_source="${BASH_REMATCH[1]//\"/}"
      in_lines=false; in_sections=false; in_keys=false
    elif [[ "$line" =~ ^[[:space:]]*managed_lines: ]]; then
      in_lines=true; in_sections=false; in_keys=false
    elif [[ "$line" =~ ^[[:space:]]*managed_sections: ]]; then
      in_sections=true; in_lines=false; in_keys=false
    elif [[ "$line" =~ ^[[:space:]]*managed_keys: ]]; then
      in_keys=true; in_lines=false; in_sections=false
    elif [[ "$line" =~ ^[[:space:]]*-[[:space:]]+(.*) ]]; then
      local val="${BASH_REMATCH[1]//\"/}"
      val="${val%%[[:space:]]\#*}"  # strip inline comments
      if $in_lines; then current_lines+=("$val")
      elif $in_sections; then current_sections+=("$val")
      elif $in_keys; then current_keys+=("$val")
      fi
    elif [[ "$line" =~ ^[[:space:]]*[a-z] && ! "$line" =~ ^[[:space:]]*- ]]; then
      in_lines=false; in_sections=false; in_keys=false
    fi
  done < <(awk '/^merge_files:/{found=1;next} found && /^[a-z]/{exit} found{print}' "$INSTALL_MANIFEST")

  # Process last entry
  if [[ -n "$current_path" ]]; then
    execute_merge "$current_path" "$current_strategy" "$current_source" \
      "$(printf '%s\n' "${current_lines[@]+"${current_lines[@]}"}")" \
      "$(printf '%s\n' "${current_sections[@]+"${current_sections[@]}"}")" \
      "$(printf '%s\n' "${current_keys[@]+"${current_keys[@]}"}")"
  fi
}

execute_merge() {
  local path="$1" strategy="$2" source="$3" lines="$4" sections="$5" keys="$6"
  local target_file="$TARGET_DIR/$path"
  local source_file=""
  [[ -n "$source" ]] && source_file="$PLUGIN_DIR/$source"

  # In self-install mode (PLUGIN_DIR == TARGET_DIR), skip strategies that
  # modify existing files — they are already correct in the clone.
  # Allow template and create-only through (they create new files if absent).
  if $SELF_INSTALL; then
    case "$strategy" in
      section-patch|json-deep-merge|append-missing)
        echo "  [skip] $path (self-install — already in place)"
        return 0
        ;;
    esac
  fi

  case "$strategy" in
    section-patch)
      echo "  [patch] $path"
      local patch_script="$PLUGIN_DIR/.claude-agent-flow/scripts/patch-claude-md.sh"
      if [[ ! -f "$patch_script" ]]; then
        echo "  [warn] patch-claude-md.sh not found — skipping $path" >&2
        return 0
      fi
      if [[ ! -f "$source_file" ]]; then
        echo "  [warn] source not found: $source — skipping $path" >&2
        return 0
      fi
      # Create target with preamble if it doesn't exist
      if [[ ! -f "$target_file" ]]; then
        local preamble
        preamble=$(awk '/^merge_files:/,0' "$INSTALL_MANIFEST" | \
          awk -v p="$path" '$0 ~ "path:.*" p {found=1} found && /preamble:/ {
            val=$0; sub(/.*preamble:[[:space:]]*/, "", val); gsub(/"/, "", val); print val; exit
          }')
        if [[ -n "$preamble" && -f "$PLUGIN_DIR/$preamble" ]]; then
          mkdir -p "$(dirname "$target_file")"
          cp "$PLUGIN_DIR/$preamble" "$target_file"
          echo "  [create] $path (from preamble template)"
        else
          mkdir -p "$(dirname "$target_file")"
          touch "$target_file"
        fi
      fi
      # Build section args — patch-claude-md.sh takes bare section names as positional args
      local section_args=()
      while IFS= read -r sec; do
        [[ -n "$sec" ]] && section_args+=("$sec")
      done <<< "$sections"
      local tmp_patch
      tmp_patch=$(mktemp)
      if bash "$patch_script" "$source_file" "$target_file" "${section_args[@]+"${section_args[@]}"}" > "$tmp_patch"; then
        mv "$tmp_patch" "$target_file"
      else
        rm -f "$tmp_patch"
        echo "  [warn] patch-claude-md.sh failed for $path" >&2
      fi
      ;;

    json-deep-merge)
      echo "  [merge] $path"
      if [[ -z "$source_file" || ! -f "$source_file" ]]; then
        echo "  [warn] source not found for $path — skipping" >&2
        return 0
      fi
      mkdir -p "$(dirname "$target_file")"
      [[ ! -f "$target_file" ]] && echo '{}' > "$target_file"

      if [[ -z "$keys" || "$keys" == "" ]]; then
        # No managed_keys — simple jq deep merge (for .mcp.json etc.)
        local tmp_merge
        tmp_merge=$(mktemp)
        if jq -s '.[0] * .[1]' "$target_file" "$source_file" > "$tmp_merge"; then
          mv "$tmp_merge" "$target_file"
        else
          rm -f "$tmp_merge"
          echo "  [warn] jq merge failed for $path" >&2
        fi
      else
        # Has managed_keys — use merge-settings-json.sh (for settings.json)
        local merge_script="$PLUGIN_DIR/.claude-agent-flow/scripts/merge-settings-json.sh"
        if [[ ! -f "$merge_script" ]]; then
          echo "  [warn] merge-settings-json.sh not found — skipping $path" >&2
          return 0
        fi
        local key_args=()
        while IFS= read -r k; do
          [[ -n "$k" ]] && key_args+=(--managed-key "$k")
        done <<< "$keys"
        local merge_args=("$source_file" "$target_file" "${key_args[@]+"${key_args[@]}"}")
        if [[ "$SKIP_PERMISSIONS" == true ]]; then
          merge_args+=(--skip-permissions)
        fi
        local tmp_merge
        tmp_merge=$(mktemp)
        if bash "$merge_script" "${merge_args[@]}" > "$tmp_merge"; then
          mv "$tmp_merge" "$target_file"
        else
          rm -f "$tmp_merge"
          echo "  [warn] merge-settings-json.sh failed for $path" >&2
        fi
      fi
      ;;

    append-missing)
      echo "  [append] $path"
      mkdir -p "$(dirname "$target_file")"
      [[ ! -f "$target_file" ]] && touch "$target_file"
      while IFS= read -r managed_line; do
        [[ -z "$managed_line" ]] && continue
        if ! grep -qF "$managed_line" "$target_file" 2>/dev/null; then
          echo "$managed_line" >> "$target_file"
        fi
      done <<< "$lines"
      ;;

    template)
      if [[ -z "$source_file" || ! -f "$source_file" ]]; then
        echo "  [warn] template source not found for $path — skipping" >&2
        return 0
      fi
      if [[ -f "$target_file" && "$UPDATE_MODE" == true ]]; then
        echo "  [skip] $path (exists, update mode)"
        return 0
      fi
      echo "  [template] $path"
      mkdir -p "$(dirname "$target_file")"
      cp "$source_file" "$target_file"
      # Substitute project name (strip newlines for sed safety)
      if [[ -n "$PROJECT_NAME" ]]; then
        local safe_name
        safe_name=$(printf '%s' "$PROJECT_NAME" | tr -d '\n\r' | sed 's/[&/\]/\\&/g')
        local sed_i_flag=(-i)
        [[ "$(uname)" == "Darwin" ]] && sed_i_flag=(-i '')
        sed "${sed_i_flag[@]}" "s/$PLACEHOLDER_TOKEN/$safe_name/g" "$target_file"
      fi
      ;;

    create-only)
      if [[ -f "$target_file" ]]; then
        echo "  [skip] $path (exists)"
        return 0
      fi
      if [[ -z "$source_file" || ! -f "$source_file" ]]; then
        echo "  [warn] source not found for $path — skipping" >&2
        return 0
      fi
      echo "  [create] $path"
      mkdir -p "$(dirname "$target_file")"
      cp "$source_file" "$target_file"
      ;;

    *)
      echo "  [warn] Unknown strategy '$strategy' for $path — skipping" >&2
      ;;
  esac
}

process_merge_files

# ── Inject agent-flow plugin registration (plugin + plugin+github only) ──
# Sandbox uses vendored local code, so the plugin should not be registered.
# This repo (agent-team) is itself a sandbox, so the source settings.json
# does not contain this registration — we inject it at install time.
if [[ "$SCOPE" != "sandbox" ]]; then
  SETTINGS_FILE="$TARGET_DIR/.claude/settings.json"
  if [[ -f "$SETTINGS_FILE" ]]; then
    # Derive marketplace ID using marketplace owner name (MARKETPLACE_ID = name@owner)
    if [[ -z "$MARKETPLACE_NAME" ]]; then
      echo "  [warn] MARKETPLACE_NAME is not set — plugin registration skipped" >&2
    else
    # Read plugin name from plugin.json
    PLUGIN_JSON="$PLUGIN_DIR/.claude-plugin/plugin.json"
    if [[ -f "$PLUGIN_JSON" ]]; then
      AF_PLUGIN_NAME=$(jq -r '.name' "$PLUGIN_JSON")
    else
      AF_PLUGIN_NAME="agent-flow"
    fi

    # Migration: remove old incorrect plugin key (owner-repo format) if it exists
    OLD_MARKETPLACE_ID="${SOURCE_REPO//\//-}"
    OLD_PLUGIN_KEY="${AF_PLUGIN_NAME}@${OLD_MARKETPLACE_ID}"
    if jq -e --arg key "$OLD_PLUGIN_KEY" '.enabledPlugins[$key]' "$SETTINGS_FILE" >/dev/null 2>&1; then
      jq --arg key "$OLD_PLUGIN_KEY" 'del(.enabledPlugins[$key])' "$SETTINGS_FILE" > "$SETTINGS_FILE.tmp" && mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
      echo "  [migrate] removed old plugin key: $OLD_PLUGIN_KEY"
    fi

    # Migration: remove legacy agent-flow@claude-agent-flow key if it exists
    LEGACY_PLUGIN_KEY="${AF_PLUGIN_NAME}@claude-agent-flow"
    if jq -e --arg key "$LEGACY_PLUGIN_KEY" '.enabledPlugins[$key]' "$SETTINGS_FILE" >/dev/null 2>&1; then
      jq --arg key "$LEGACY_PLUGIN_KEY" 'del(.enabledPlugins[$key])' "$SETTINGS_FILE" > "$SETTINGS_FILE.tmp" && mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
      echo "  [migrate] removed legacy plugin key: $LEGACY_PLUGIN_KEY"
    fi

    jq --arg mname "$MARKETPLACE_NAME" --arg mrepo "$MARKETPLACE_REPO" --arg pname "$AF_PLUGIN_NAME" '
      .extraKnownMarketplaces //= {} |
      .enabledPlugins //= {} |
      .extraKnownMarketplaces[$mname] = {"source": {"source": "github", "repo": $mrepo}} |
      .enabledPlugins[$pname + "@" + $mname] = true
    ' "$SETTINGS_FILE" > "$SETTINGS_FILE.tmp" && mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
    echo "  [inject] $AF_PLUGIN_NAME@$MARKETPLACE_NAME plugin registration"
    fi

    # Plugin modes: all _agentFlow hooks are served by hooks/hooks.json — strip them from settings.json
    if command -v jq &>/dev/null; then
      jq '
        .hooks //= {} |
        .hooks |= with_entries(.value |= map(select(._agentFlow != true))) |
        .hooks |= with_entries(select(.value | length > 0)) |
        if .hooks == {} then del(.hooks) else . end
      ' "$SETTINGS_FILE" > "$SETTINGS_FILE.tmp" && mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
      echo "  [remove] _agentFlow hooks (plugin mode — using hooks/hooks.json)"
    fi
  else
    echo "  [warn] .claude/settings.json not found — plugin registration skipped" >&2
  fi
fi


# ── Scope-dependent operations ──

# Plugin+GitHub + Sandbox: copy workflow files
if ! $SELF_INSTALL && [[ "$SCOPE" == "plugin+github" || "$SCOPE" == "sandbox" ]]; then
  echo ""
  echo "Copying GitHub Actions workflows (scope: $SCOPE)..."
  WF_SOURCE_REL=$(awk '/^workflow_files:/{found=1;next} found && /^[[:space:]]+source:/{val=$0; sub(/.*source:[[:space:]]*/, "", val); gsub(/"/, "", val); print val; exit}' "$INSTALL_MANIFEST")
  WF_TARGET_REL=$(awk '/^workflow_files:/{found=1;next} found && /^[[:space:]]+target:/{val=$0; sub(/.*target:[[:space:]]*/, "", val); gsub(/"/, "", val); print val; exit}' "$INSTALL_MANIFEST")
  [[ -z "$WF_SOURCE_REL" ]] && WF_SOURCE_REL=".github/workflows/"
  [[ -z "$WF_TARGET_REL" ]] && WF_TARGET_REL=".github/workflows/"
  WF_SOURCE="$PLUGIN_DIR/$WF_SOURCE_REL"
  if [[ -d "$WF_SOURCE" ]]; then
    mkdir -p "$TARGET_DIR/$WF_TARGET_REL"
    if [[ "$SCOPE" == "plugin+github" ]]; then
      # Plugin+GitHub mode: only copy workflows listed in github_only (no vendored code to sync/test)
      while IFS= read -r wf; do
        [[ -z "$wf" ]] && continue
        if [[ -f "$WF_SOURCE/$wf" ]]; then
          cp "$WF_SOURCE/$wf" "${TARGET_DIR%/}/${WF_TARGET_REL%/}/$wf"
          echo "  [copy] $wf"
        fi
      done < <(awk '/^workflow_files:/{found=1;next} found && /^[a-z]/{exit} found && /github_only:/{in_list=1;next} in_list && /^[[:space:]]*- /{val=$0; sub(/.*- /, ""); gsub(/"/, ""); print; next} in_list{exit}' "$INSTALL_MANIFEST")
    else
      # Sandbox mode: selectively copy only workflows listed in sandbox_only
      while IFS= read -r wf; do
        [[ -z "$wf" ]] && continue
        if [[ ! -f "$WF_SOURCE/$wf" ]]; then
          echo "  [warn] sandbox_only workflow not found in source: $wf" >&2
          continue
        fi
        cp "$WF_SOURCE/$wf" "${TARGET_DIR%/}/${WF_TARGET_REL%/}/$wf"
        echo "  [copy] $wf"
      done < <(awk '/^workflow_files:/{found=1;next} found && /^[a-z]/{exit} found && /sandbox_only:/{in_list=1;next} in_list && /^[[:space:]]*- /{val=$0; sub(/.*- /, ""); gsub(/"/, ""); print; next} in_list{exit}' "$INSTALL_MANIFEST")
    fi
  else
    echo "  [warn] No workflows directory found at $WF_SOURCE" >&2
  fi
fi

# Capture target's existing allows before sandbox copy overwrites them
PRE_SANDBOX_ALLOWS=""
if [[ "$SCOPE" == "sandbox" && "$SKIP_PERMISSIONS" == true ]]; then
  SANDBOX_SETTINGS_PRE="$TARGET_DIR/.claude/settings.json"
  if [[ -f "$SANDBOX_SETTINGS_PRE" ]]; then
    PRE_SANDBOX_ALLOWS=$(jq -c '.permissions.allow // []' "$SANDBOX_SETTINGS_PRE" 2>/dev/null || echo "[]")
  fi
fi

# Sandbox: reverse-map plugin layout to master layout
if $SELF_INSTALL && [[ "$SCOPE" == "sandbox" ]]; then
  echo ""
  echo "Sandbox file copy skipped — files already in place (self-install)"
elif [[ "$SCOPE" == "sandbox" ]]; then
  echo ""
  echo "Installing sandbox mode (full agent-flow tree)..."

  # Read sandbox_mappings from install-manifest
  execute_mapping() {
    local source="$1" target="$2"
    shift 2
    local excludes=("$@")

    local local_source local_target
    local_source="$PLUGIN_DIR/$source"
    local_target="$TARGET_DIR/$target"

    # Top-level self-install guard: skip rsync when PLUGIN_DIR == TARGET_DIR
    if [[ "${_self_install:-false}" == "true" ]]; then
      echo "  [sandbox] skip rsync $source -> $target (self-install, already in place)"
      return 0
    fi

    if [[ -d "$local_source" ]]; then
      mkdir -p "$local_target"
      sb_exclude_flags=()
      if [[ ${#excludes[@]} -gt 0 ]]; then
        for excl in "${excludes[@]}"; do
          [[ -n "$excl" ]] && sb_exclude_flags+=("--exclude=$excl")
        done
      fi
      rsync -a --exclude='.DS_Store' --exclude='sync-state.json' \
        "${sb_exclude_flags[@]+"${sb_exclude_flags[@]}"}" \
        "${local_source%/}/" "${local_target%/}/"
      echo "  [sandbox] $source -> $target"
    elif [[ -f "$local_source" ]]; then
      mkdir -p "$(dirname "$local_target")"
      cp "$local_source" "$local_target"
      echo "  [sandbox] $source -> $target"
    else
      echo "  [warn] sandbox source not found: $source" >&2
    fi
  }

  # Compute self-install flag once at the top level: if PLUGIN_DIR resolves to the
  # same real path as TARGET_DIR, all sandbox mappings are no-ops (already in place).
  _self_install=false
  if [[ "$(realpath "$PLUGIN_DIR" 2>/dev/null || echo "$PLUGIN_DIR")" == "$(realpath "$TARGET_DIR" 2>/dev/null || echo "$TARGET_DIR")" ]]; then
    _self_install=true
  fi

  sb_source=""
  sb_target=""
  sb_excludes=()
  in_sb_excludes=0
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]source:[[:space:]]*(.*) ]]; then
      # Execute previous mapping if complete
      if [[ -n "$sb_source" && -n "$sb_target" ]]; then
        execute_mapping "$sb_source" "$sb_target" "${sb_excludes[@]+"${sb_excludes[@]}"}"
      fi
      # New mapping entry — reset state
      sb_source="${BASH_REMATCH[1]//\"/}"
      sb_target=""
      sb_excludes=()
      in_sb_excludes=0
    elif [[ "$line" =~ ^[[:space:]]*target:[[:space:]]*(.*) ]]; then
      sb_target="${BASH_REMATCH[1]//\"/}"
      in_sb_excludes=0
    elif [[ "$line" =~ ^[[:space:]]*sandbox_excludes:[[:space:]]*$ ]]; then
      in_sb_excludes=1
    elif [[ $in_sb_excludes -eq 1 && "$line" =~ ^[[:space:]]*-[[:space:]]\"?([^\"]+)\"?[[:space:]]*$ ]]; then
      sb_excludes+=("${BASH_REMATCH[1]}")
    elif [[ "$line" =~ ^[[:space:]]*[a-z_]+:[[:space:]] && ! "$line" =~ ^[[:space:]]*- ]]; then
      # Any other non-list key resets excludes mode
      in_sb_excludes=0
    fi
  done < <(awk '/^sandbox_mappings:/{found=1;next} found && /^[a-z]/{exit} found{print}' "$INSTALL_MANIFEST")

  # Execute final mapping if complete
  if [[ -n "$sb_source" && -n "$sb_target" ]]; then
    execute_mapping "$sb_source" "$sb_target" "${sb_excludes[@]+"${sb_excludes[@]}"}"
  fi

  # Remove agent-flow plugin from enabledPlugins — sandbox uses vendored local code
  SANDBOX_SETTINGS="$TARGET_DIR/.claude/settings.json"
  SB_PLUGIN_JSON="$PLUGIN_DIR/.claude-plugin/plugin.json"
  if [[ -f "$SB_PLUGIN_JSON" ]]; then
    SB_PLUGIN_NAME=$(jq -r '.name' "$SB_PLUGIN_JSON")
  else
    SB_PLUGIN_NAME="agent-flow"
  fi
  SB_PLUGIN_KEY="${SB_PLUGIN_NAME}@${MARKETPLACE_NAME}"
  if [[ -n "$MARKETPLACE_NAME" ]] && [[ -f "$SANDBOX_SETTINGS" ]] && jq -e --arg key "$SB_PLUGIN_KEY" '.enabledPlugins[$key]' "$SANDBOX_SETTINGS" >/dev/null 2>&1; then
    jq --arg key "$SB_PLUGIN_KEY" 'del(.enabledPlugins[$key])' "$SANDBOX_SETTINGS" > "$SANDBOX_SETTINGS.tmp" && mv "$SANDBOX_SETTINGS.tmp" "$SANDBOX_SETTINGS"
    echo "  [sandbox] removed $SB_PLUGIN_KEY from enabledPlugins (local code takes precedence)"
  fi

  # Strip source allow rules from sandbox-copied settings.json when --skip-permissions is active
  # Restore any allows the target had before the sandbox copy overwrote it
  if [[ "$SKIP_PERMISSIONS" == true ]]; then
    SANDBOX_SETTINGS="$TARGET_DIR/.claude/settings.json"
    if [[ -f "$SANDBOX_SETTINGS" ]]; then
      if [[ -n "${PRE_SANDBOX_ALLOWS:-}" && "$PRE_SANDBOX_ALLOWS" != "[]" ]]; then
        # Restore pre-existing target allows (captured before sandbox copy)
        jq --argjson allows "$PRE_SANDBOX_ALLOWS" '.permissions.allow = $allows' \
          "$SANDBOX_SETTINGS" > "$SANDBOX_SETTINGS.tmp" \
          && mv "$SANDBOX_SETTINGS.tmp" "$SANDBOX_SETTINGS"
        echo "  [sandbox] restored pre-existing permissions.allow (--skip-permissions)"
      else
        jq '.permissions.allow = []' "$SANDBOX_SETTINGS" > "$SANDBOX_SETTINGS.tmp" \
          && mv "$SANDBOX_SETTINGS.tmp" "$SANDBOX_SETTINGS"
        echo "  [sandbox] stripped permissions.allow (--skip-permissions)"
      fi
    fi
  fi

  echo "Sandbox mode: all files vendored into repo"
fi

# ── Initialize sync state ──
MANIFEST_VERSION=$(yaml_scalar "$INSTALL_MANIFEST" "version")
[[ -z "$MANIFEST_VERSION" || ! "$MANIFEST_VERSION" =~ ^[0-9]+$ ]] && MANIFEST_VERSION=0
# Try to get commit from the plugin repo clone
SOURCE_COMMIT=""
if [[ -d "$PLUGIN_DIR/.git" ]]; then
  # Only use .git if it's directly in the plugin dir (not an ancestor repo)
  SOURCE_COMMIT=$(cd "$PLUGIN_DIR" && git rev-parse HEAD 2>/dev/null || echo "unknown")
elif command -v git &>/dev/null; then
  # Use git rev-parse from within PLUGIN_DIR — git itself finds the right repo
  # but verify the discovered root is PLUGIN_DIR or a subdirectory of it
  PLUGIN_GIT_ROOT=$(cd "$PLUGIN_DIR" && git rev-parse --show-toplevel 2>/dev/null || true)
  if [[ -n "$PLUGIN_GIT_ROOT" && "$PLUGIN_DIR" == "$PLUGIN_GIT_ROOT"* ]]; then
    SOURCE_COMMIT=$(cd "$PLUGIN_DIR" && git rev-parse HEAD 2>/dev/null || echo "unknown")
  fi
fi
[[ -z "$SOURCE_COMMIT" ]] && SOURCE_COMMIT="unknown"

mkdir -p "$TARGET_DIR/.claude-agent-flow"
jq -n \
  --arg repo "$SOURCE_REPO" \
  --arg version "${MANIFEST_VERSION:-0}" \
  --arg commit "$SOURCE_COMMIT" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg scope "$SCOPE" \
  --argjson auto_update "$AUTO_UPDATE" \
  '{source_repo: $repo, last_synced_version: ($version | tonumber), source_commit: $commit, synced_at: $ts, scope: $scope, auto_update: $auto_update}' \
  > "$TARGET_DIR/.claude-agent-flow/sync-state.json"
echo ""
echo "Initialized .claude-agent-flow/sync-state.json (version $MANIFEST_VERSION, scope: $SCOPE)"

# ── Update mode cleanup ──
if [[ "$UPDATE_MODE" == true && "$SCOPE" != "sandbox" ]]; then
  OLD_SS="$TARGET_DIR/.claude-agent-flow/scripts/session-start.sh"
  if [[ -f "$OLD_SS" ]]; then
    rm -f "$OLD_SS"
    echo "  [cleanup] removed legacy scripts/session-start.sh"
  fi
fi

# ── Update CLAUDE.md project header if installing (not updating) ──
if [[ "$UPDATE_MODE" == false && -n "$PROJECT_NAME" ]]; then
  if [[ -f "$TARGET_DIR/CLAUDE.md" ]]; then
    if grep -q "$PLACEHOLDER_TOKEN" "$TARGET_DIR/CLAUDE.md"; then
      SAFE_NAME=$(printf '%s\n' "$PROJECT_NAME" | sed 's/[&/\]/\\&/g')
      sed "s/$PLACEHOLDER_TOKEN/$SAFE_NAME/g" "$TARGET_DIR/CLAUDE.md" > "$TARGET_DIR/CLAUDE.md.tmp" && \
        mv "$TARGET_DIR/CLAUDE.md.tmp" "$TARGET_DIR/CLAUDE.md"
      echo "Updated CLAUDE.md project header: $PROJECT_NAME"
    fi
  fi
fi

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║          Installation Complete!              ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "Installed scope: $SCOPE"
echo ""
echo "Next steps:"
echo "  1. Review the changes: git diff"
echo "  2. Commit: git add -A && git commit -m 'feat: install agent-flow system'"
if [[ "$SCOPE" == "plugin+github" || "$SCOPE" == "sandbox" ]]; then
  echo "  3. Set up AGENT_FLOW_SYNC_TOKEN secret in your repo for sync workflows"
else
  echo "  3. To add GitHub Actions later, re-run with: --scope plugin+github"
fi
echo ""
