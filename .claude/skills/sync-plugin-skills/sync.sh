#!/bin/bash
set -euo pipefail

# Syncs skill files from installed Claude Code plugins into the repo's
# .claude/skills/ directory so they work in web environments too.
#
# Usage: .claude/skills/sync-plugin-skills/sync.sh [--dry-run]
#
# Reads enabledPlugins from .claude/settings.json, finds each plugin's
# skills in the local cache, and copies them into .claude/skills/.
# Only skills listed in skills-filter.yaml (included section) are synced.
# A manifest (.claude/skills/.vendored.json) tracks what was synced.

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SETTINGS="${REPO_ROOT}/.claude/settings.json"
SKILLS_DIR="${REPO_ROOT}/.claude/skills"
MANIFEST="$(dirname "$0")/.plugin-sync-log.json"
FILTER_FILE="$(dirname "$0")/skills-filter.yaml"
DRY_RUN=false

# Returns 0 if the license file contains a recognised open-source identifier,
# 1 otherwise (proprietary, unknown, or unreadable).  Uses a positive match so
# that unrecognised licenses are skipped rather than accidentally distributed.
is_open_source_license() {
  local file="$1"
  grep -qiE \
    "(MIT License|Apache License|GNU (General|Lesser|Affero) Public License|BSD [0-9]-Clause|ISC License|Mozilla Public License|The Unlicense|Permission is hereby granted, free of charge)" \
    "$file" 2>/dev/null
}

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required but not installed."
  exit 1
fi

if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
  echo "[dry-run] No files will be written."
fi

# --- Read included skills from filter file ---
if [[ ! -f "$FILTER_FILE" ]]; then
  echo "Error: Filter file not found at ${FILTER_FILE}"
  echo "Expected a skills-filter.yaml with an 'included:' section."
  exit 1
fi

# Parse the included: block (lines between 'included:' and the next top-level key or EOF)
INCLUDED_SKILLS=()
in_included=false
while IFS= read -r line; do
  if [[ "$line" =~ ^included: ]]; then
    in_included=true
    continue
  fi
  # Stop at next top-level key (non-indented, non-comment, non-blank)
  if [[ "$in_included" == true && "$line" =~ ^[a-zA-Z] ]]; then
    break
  fi
  if [[ "$in_included" == true ]]; then
    skill=$(echo "$line" | sed 's/^[[:space:]]*-[[:space:]]*//' | sed 's/[[:space:]]*#.*//' | tr -d '[:space:]')
    if [[ -n "$skill" && ! "$skill" =~ ^# ]]; then
      INCLUDED_SKILLS+=("$skill")
    fi
  fi
done < "$FILTER_FILE"

if [[ ${#INCLUDED_SKILLS[@]} -eq 0 ]]; then
  echo "No skills listed in 'included:' section of skills-filter.yaml."
  echo "Add skill names under 'included:' and re-run."
  exit 0
fi

echo "Skills to sync (from skills-filter.yaml):"
printf '  - %s\n' "${INCLUDED_SKILLS[@]}"
echo ""

# Helper: check if a skill name is in the included list
is_included() {
  local name="$1"
  for s in "${INCLUDED_SKILLS[@]}"; do
    [[ "$s" == "$name" ]] && return 0
  done
  return 1
}

# --- Locate plugin cache roots ---
CACHE_ROOTS=()
for candidate in \
  "${HOME}/.claude/plugins/cache" \
  "${HOME}/.claude/plugins" \
  "${HOME}/.claude-code/plugins/cache" \
  "${HOME}/.claude-code/plugins"; do
  if [[ -d "$candidate" ]]; then
    CACHE_ROOTS+=("$candidate")
  fi
done

if [[ ${#CACHE_ROOTS[@]} -eq 0 ]]; then
  echo "Error: No plugin cache directories found."
  echo "Searched: ~/.claude/plugins/cache, ~/.claude/plugins, ~/.claude-code/plugins/cache, ~/.claude-code/plugins"
  echo ""
  echo "Make sure you have plugins installed locally via the Claude Code CLI."
  echo "Run: /plugin install superpowers@claude-plugins-official"
  exit 1
fi

echo "Cache roots:"
printf '  - %s\n' "${CACHE_ROOTS[@]}"
echo ""

if [[ ! -f "$SETTINGS" ]]; then
  echo "Error: Settings file not found at ${SETTINGS}"
  exit 1
fi

# Extract enabled plugin names from project settings.json
PLUGINS=$(jq -r '.enabledPlugins // {} | to_entries[] | select(.value == true) | .key' "$SETTINGS")

# Also scan user-level settings for additional plugins not in the project config.
USER_SETTINGS="${HOME}/.claude/settings.json"
if [[ -f "$USER_SETTINGS" ]]; then
  USER_PLUGINS=$(jq -r '.enabledPlugins // {} | to_entries[] | select(.value == true) | .key' "$USER_SETTINGS")
  if [[ -n "$USER_PLUGINS" ]]; then
    # Merge: add user plugins not already in the project list
    MERGED_PLUGINS="$PLUGINS"
    while IFS= read -r up; do
      if ! echo "$MERGED_PLUGINS" | grep -qxF "$up"; then
        MERGED_PLUGINS="${MERGED_PLUGINS}"$'\n'"${up}"
      fi
    done <<< "$USER_PLUGINS"
    PLUGINS="$MERGED_PLUGINS"
  fi
fi

if [[ -z "$PLUGINS" ]]; then
  echo "No enabled plugins found in ${SETTINGS} or ${USER_SETTINGS}"
  exit 0
fi

echo "Enabled plugins:"
echo "$PLUGINS" | sed 's/^/  - /'
echo ""

SYNCED=0
SKIPPED=0
MANIFEST_ENTRIES="[]"

while IFS= read -r plugin_id; do
  # plugin_id is like "superpowers@claude-plugins-official"
  PLUGIN_NAME="${plugin_id%%@*}"
  MARKETPLACE="${plugin_id##*@}"

  # Validate plugin and marketplace names to prevent glob/traversal injection
  if [[ ! "$PLUGIN_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "  WARNING: Skipping invalid plugin name: ${PLUGIN_NAME}"
    continue
  fi
  if [[ ! "$MARKETPLACE" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "  WARNING: Skipping invalid marketplace name: ${MARKETPLACE}"
    continue
  fi

  echo "--- ${PLUGIN_NAME} (${MARKETPLACE}) ---"

  # Search all cache roots for this plugin
  PLUGIN_DIR=""
  for cache_root in "${CACHE_ROOTS[@]}"; do
    for candidate in \
      "${cache_root}/${MARKETPLACE}/${PLUGIN_NAME}" \
      "${cache_root}/${PLUGIN_NAME}" \
      "${cache_root}/${MARKETPLACE}--${PLUGIN_NAME}" \
      "${cache_root}/${PLUGIN_NAME}@${MARKETPLACE}"; do
      if [[ -d "$candidate" ]]; then
        PLUGIN_DIR="$candidate"
        break 2
      fi
    done
  done

  # Fallback: broader find across all cache roots, scoped to marketplace to avoid
  # silently picking the wrong source when the same plugin name exists in multiple marketplaces
  if [[ -z "$PLUGIN_DIR" ]]; then
    for cache_root in "${CACHE_ROOTS[@]}"; do
      PLUGIN_DIR=$(find "$cache_root" -maxdepth 3 -type d -name "$PLUGIN_NAME" 2>/dev/null \
        | grep "/${MARKETPLACE}/" | head -1)
      [[ -n "$PLUGIN_DIR" ]] && break
    done
  fi

  # Last resort: unscoped match with a warning that marketplace could not be verified
  if [[ -z "$PLUGIN_DIR" ]]; then
    for cache_root in "${CACHE_ROOTS[@]}"; do
      PLUGIN_DIR=$(find "$cache_root" -maxdepth 3 -type d -name "$PLUGIN_NAME" 2>/dev/null | head -1)
      if [[ -n "$PLUGIN_DIR" ]]; then
        echo "  WARNING: Found ${PLUGIN_NAME} but could not verify marketplace (${MARKETPLACE}): ${PLUGIN_DIR}"
        break
      fi
    done
  fi

  if [[ -z "$PLUGIN_DIR" ]]; then
    echo "  WARNING: Plugin not found in cache. Install it first:"
    echo "    /plugin install ${plugin_id}"
    echo ""
    continue
  fi

  echo "  Found: ${PLUGIN_DIR}"

  # Resolve versioned subdirectory if present (e.g., plugin/1.2.3/skills -> plugin/skills)
  # Pick the latest semver-looking subdirectory if the direct skills/commands paths don't exist
  RESOLVED_DIR="$PLUGIN_DIR"
  if [[ ! -d "${PLUGIN_DIR}/skills" && ! -d "${PLUGIN_DIR}/commands" ]]; then
    VERSIONED=$(find "$PLUGIN_DIR" -maxdepth 1 -type d -name '[0-9]*' 2>/dev/null | sort -V | tail -1)
    if [[ -n "$VERSIONED" ]]; then
      RESOLVED_DIR="$VERSIONED"
      echo "  Resolved versioned dir: ${RESOLVED_DIR}"
    fi
  fi

  # Process skills directories within the plugin
  SKILLS_FOUND=false
  for skills_root in "${RESOLVED_DIR}/skills" "${RESOLVED_DIR}/commands"; do
    if [[ ! -d "$skills_root" ]]; then
      continue
    fi

    for skill_dir in "${skills_root}"/*/; do
      [[ -d "$skill_dir" ]] || continue
      SKILL_NAME=$(basename "$skill_dir")
      # Validate skill name
      if [[ ! "$SKILL_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo "  WARNING: Skipping invalid skill name: ${SKILL_NAME}"
        continue
      fi
      SKILL_FILE="${skill_dir}SKILL.md"

      if [[ ! -f "$SKILL_FILE" ]]; then
        # Check for lowercase
        SKILL_FILE="${skill_dir}skill.md"
        [[ -f "$SKILL_FILE" ]] || continue
      fi

      SKILLS_FOUND=true

      # Skip if not in the included list
      if ! is_included "$SKILL_NAME"; then
        echo "  Skipped (not in included list): ${SKILL_NAME}"
        SKIPPED=$((SKIPPED + 1))
        continue
      fi

      DEST_DIR="${SKILLS_DIR}/${SKILL_NAME}"

      if [[ "$DRY_RUN" == true ]]; then
        echo "  [dry-run] Would sync: ${SKILL_NAME} -> .claude/skills/${SKILL_NAME}/"
        # Copy plugin LICENSE file into skill directory (dry-run preview)
        PLUGIN_LICENSE="${RESOLVED_DIR}/LICENSE"
        DEST_LICENSE="${DEST_DIR}/LICENSE"
        if [[ -f "$PLUGIN_LICENSE" && ! -f "$DEST_LICENSE" ]]; then
          if is_open_source_license "$PLUGIN_LICENSE"; then
            echo "  [dry-run] Would copy LICENSE for ${SKILL_NAME}"
          else
            echo "  [dry-run] Would skip LICENSE for ${SKILL_NAME} (proprietary or unknown)"
          fi
        fi
      else
        # Reject skill directories containing symlinks
        if find "$skill_dir" -type l 2>/dev/null | grep -q .; then
          echo "  WARNING: Skipping ${SKILL_NAME} — contains symlinks"
          continue
        fi
        mkdir -p "$DEST_DIR"
        # Copy the entire skill directory contents (skip if empty)
        if compgen -G "${skill_dir}*" > /dev/null; then
          cp -rP "${skill_dir}"* "$DEST_DIR/"
          # Post-copy: reject if symlinks landed in destination
          if find "$DEST_DIR" -type l 2>&1 | grep -q .; then
            echo "  WARNING: Skipping ${SKILL_NAME} — symlinks detected in destination"
            rm -rf "$DEST_DIR"
            continue
          fi
          echo "  Synced: ${SKILL_NAME} -> .claude/skills/${SKILL_NAME}/"
          # Copy plugin LICENSE file into skill directory if freely licensed
          PLUGIN_LICENSE="${RESOLVED_DIR}/LICENSE"
          DEST_LICENSE="${DEST_DIR}/LICENSE"
          if [[ -f "$PLUGIN_LICENSE" && ! -f "$DEST_LICENSE" ]]; then
            if is_open_source_license "$PLUGIN_LICENSE"; then
              cp "$PLUGIN_LICENSE" "$DEST_LICENSE"
              echo "  Copied LICENSE for ${SKILL_NAME}"
            else
              echo "  Skipping LICENSE for ${SKILL_NAME} (proprietary or unknown)"
            fi
          fi
        else
          echo "  WARNING: ${SKILL_NAME} skill directory is empty, skipping"
          continue
        fi
      fi

      MANIFEST_ENTRIES=$(echo "$MANIFEST_ENTRIES" | jq \
        --arg name "$SKILL_NAME" \
        --arg plugin "$plugin_id" \
        --arg source "$SKILL_FILE" \
        --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '. + [{"skill": $name, "plugin": $plugin, "source": $source, "synced_at": $date}]')

      SYNCED=$((SYNCED + 1))
    done
  done

  if [[ "$SKILLS_FOUND" == false ]]; then
    echo "  No skills found in plugin directory."
  fi

  echo ""
done <<< "$PLUGINS"

# --- Global skills (~/.claude/skills/) ---
# Discover skills installed directly in the user's global skills directory.
# These are not managed by the plugin system but are still available locally.
GLOBAL_SKILLS_DIR="${HOME}/.claude/skills"
if [[ -d "$GLOBAL_SKILLS_DIR" ]]; then
  echo "--- Global skills (~/.claude/skills/) ---"
  GLOBAL_FOUND=false

  for skill_dir in "${GLOBAL_SKILLS_DIR}"/*/; do
    [[ -d "$skill_dir" ]] || continue
    SKILL_NAME=$(basename "$skill_dir")

    if [[ ! "$SKILL_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
      echo "  WARNING: Skipping invalid skill name: ${SKILL_NAME}"
      continue
    fi

    SKILL_FILE="${skill_dir}SKILL.md"
    if [[ ! -f "$SKILL_FILE" ]]; then
      SKILL_FILE="${skill_dir}skill.md"
      [[ -f "$SKILL_FILE" ]] || continue
    fi

    GLOBAL_FOUND=true

    if ! is_included "$SKILL_NAME"; then
      echo "  Skipped (not in included list): ${SKILL_NAME}"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi

    DEST_DIR="${SKILLS_DIR}/${SKILL_NAME}"

    if [[ "$DRY_RUN" == true ]]; then
      echo "  [dry-run] Would sync: ${SKILL_NAME} -> .claude/skills/${SKILL_NAME}/"
    else
      if find "$skill_dir" -type l 2>/dev/null | grep -q .; then
        echo "  WARNING: Skipping ${SKILL_NAME} — contains symlinks"
        continue
      fi
      mkdir -p "$DEST_DIR"
      if compgen -G "${skill_dir}*" > /dev/null; then
        cp -rP "${skill_dir}"* "$DEST_DIR/"
        if find "$DEST_DIR" -type l 2>&1 | grep -q .; then
          echo "  WARNING: Skipping ${SKILL_NAME} — symlinks detected in destination"
          rm -rf "$DEST_DIR"
          continue
        fi
        echo "  Synced: ${SKILL_NAME} -> .claude/skills/${SKILL_NAME}/"
      else
        echo "  WARNING: ${SKILL_NAME} skill directory is empty, skipping"
        continue
      fi
    fi

    MANIFEST_ENTRIES=$(echo "$MANIFEST_ENTRIES" | jq \
      --arg name "$SKILL_NAME" \
      --arg plugin "global:~/.claude/skills" \
      --arg source "$SKILL_FILE" \
      --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '. + [{"skill": $name, "plugin": $plugin, "source": $source, "synced_at": $date}]')

    SYNCED=$((SYNCED + 1))
  done

  if [[ "$GLOBAL_FOUND" == false ]]; then
    echo "  No skills found."
  fi
  echo ""
fi

# Write manifest
if [[ "$DRY_RUN" == false && $SYNCED -gt 0 ]]; then
  echo "$MANIFEST_ENTRIES" | jq '.' > "$MANIFEST"
  echo "Manifest written: ${MANIFEST}"
fi

echo "Done. ${SYNCED} skill(s) synced, ${SKIPPED} skipped."

if [[ "$DRY_RUN" == false && $SYNCED -gt 0 ]]; then
  echo ""
  echo "Next steps:"
  echo "  1. Review the synced skills in .claude/skills/"
  echo "  2. Commit and push so web sessions pick them up"
  echo "  3. To add more skills: edit skills-filter.yaml and re-run"
fi
