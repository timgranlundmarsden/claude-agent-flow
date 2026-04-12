#!/usr/bin/env bash
# merge-settings-json.sh — Deep-merge managed keys from source settings.json into target
#
# Usage: merge-settings-json.sh <source-settings.json> <target-settings.json> [--skip-permissions] [--managed-key <key>]...
#
# Strategy:
#   - If target doesn't exist: copy source directly (strip defaultMode)
#   - If target exists: merge managed keys (permissions, hooks, extraKnownMarketplaces, enabledPlugins)
#     - permissions.allow: union arrays (deduplicate, sort) unless --skip-permissions
#     - permissions.deny: union arrays (deduplicate, sort)
#     - permissions.defaultMode: never propagated (removed from output)
#     - hooks: source entries tagged _agentFlow replace matching target entries;
#       untagged target entries (child-owned) are preserved; migration: untagged legacy copies
#       are detected by: only standard keys (matcher, pattern, hooks), same matcher+pattern,
#       AND same hooks content — all three must match to be considered a legacy copy
#       Note: a child entry identical in content to a source entry (with no extra keys) will
#       be treated as a legacy copy. To preserve such an entry, add any distinguishing key.
#     - extraKnownMarketplaces: source wins (deep merge — target keys absent from source preserved)
#     - enabledPlugins: source wins (deep merge — target keys absent from source preserved)
#     - All other keys: target preserved
#
# Output: merged JSON to stdout

set -euo pipefail

SKIP_PERMISSIONS=false
SOURCE_FILE=""
TARGET_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-permissions) SKIP_PERMISSIONS=true; shift ;;
    --managed-key) [[ $# -lt 2 ]] && { echo "Error: --managed-key requires a value" >&2; exit 1; }; shift 2 ;;
    *) if [[ -z "$SOURCE_FILE" ]]; then SOURCE_FILE="$1"; elif [[ -z "$TARGET_FILE" ]]; then TARGET_FILE="$1"; fi; shift ;;
  esac
done

if [[ -z "$SOURCE_FILE" || -z "$TARGET_FILE" ]]; then
  echo "Usage: $0 <source-settings.json> <target-settings.json> [--skip-permissions]" >&2
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required but not installed." >&2
  exit 1
fi

# If target doesn't exist, output source directly (strip defaultMode)
if [[ ! -f "$TARGET_FILE" ]]; then
  if [[ "$SKIP_PERMISSIONS" == true ]]; then
    # Fresh install with --skip-permissions: empty allows, source denies only
    jq 'del(.permissions.defaultMode) | .permissions.allow = []' "$SOURCE_FILE"
  else
    jq 'del(.permissions.defaultMode)' "$SOURCE_FILE"
  fi
  exit 0
fi

# Deep merge using jq
jq -s --argjson skip_allow "$SKIP_PERMISSIONS" '
  # $source = .[0], $target = .[1]
  .[0] as $source | .[1] as $target |

  # Start with target as base
  $target |

  # Merge permissions
  .permissions = (
    ($target.permissions // {}) |

    # Conditionally merge allow arrays
    .allow = (
      if $skip_allow then
        ($target.permissions.allow // [])
      else
        (($target.permissions.allow // []) + ($source.permissions.allow // []))
        | unique | sort
      end
    ) |

    # Union deny arrays (deduplicate, sort)
    .deny = (
      (($target.permissions.deny // []) + ($source.permissions.deny // []))
      | unique | sort
    )
  ) |

  # Merge hooks: for each hook type, merge the entries arrays
  .hooks = (
    ($target.hooks // {}) as $target_hooks |
    ($source.hooks // {}) as $source_hooks |
    ($target_hooks | keys) + ($source_hooks | keys) | unique |
    reduce .[] as $hook_type (
      {};
      . + {
        ($hook_type): (
          ($target_hooks[$hook_type] // []) as $t_entries |
          ($source_hooks[$hook_type] // []) as $s_entries |
          # Keep child-owned target entries (not tagged _agentFlow, not a legacy copy of a source entry)
          # Drop tagged entries (source version added below) and untagged legacy copies (migration)
          # Legacy copy detection: same matcher+pattern, only standard keys, AND same hooks content
          [
            $t_entries[] |
            . as $te |
            if (._agentFlow == true) then empty
            elif (
              ($te | keys | map(select(. != "matcher" and . != "pattern" and . != "hooks")) | length == 0) and
              ($s_entries | any(
                (.matcher // "") == ($te.matcher // "") and
                (.pattern // "") == ($te.pattern // "") and
                (.hooks == $te.hooks)
              ))
            ) then empty
            else .
            end
          ] +
          # Add all source entries (canonical parent set — tagged _agentFlow: true)
          $s_entries
        )
      }
    )
  ) |

  # Source wins for extraKnownMarketplaces
  .extraKnownMarketplaces = (
    ($target.extraKnownMarketplaces // {}) * ($source.extraKnownMarketplaces // {})
  ) |

  # Source wins for enabledPlugins
  .enabledPlugins = (
    ($target.enabledPlugins // {}) * ($source.enabledPlugins // {})
  ) |

  # Never propagate defaultMode — it is a personal dev preference
  del(.permissions.defaultMode)
' "$SOURCE_FILE" "$TARGET_FILE"
