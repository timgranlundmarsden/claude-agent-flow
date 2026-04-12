#!/usr/bin/env bash
# reverse-merge-settings-json.sh — Extract managed portions from downstream settings.json
# and patch them into the source (upstream) settings.json.
#
# Usage: reverse-merge-settings-json.sh <downstream-settings.json> <source-settings.json>
#
# Strategy:
#   - Extract _agentFlow-tagged hook entries from downstream
#   - Replace matching _agentFlow-tagged entries in source with downstream's versions
#   - Preserve all non-hook content from source unchanged
#   - Output patched source JSON to stdout
#
# Returns exit code 2 if no managed differences found (caller can skip).

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <downstream-settings.json> <source-settings.json>" >&2
  exit 1
fi

DOWNSTREAM_FILE="$1"
SOURCE_FILE="$2"

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required but not installed." >&2
  exit 1
fi

if [[ ! -f "$DOWNSTREAM_FILE" || ! -f "$SOURCE_FILE" ]]; then
  echo "Error: Both files must exist." >&2
  exit 1
fi

# Check if managed portions actually differ before producing output
DIFF_CHECK=$(jq -s '
  .[0] as $downstream | .[1] as $source |

  # Extract _agentFlow-tagged entries from both
  [($downstream.hooks // {} | to_entries[] | .value[] | select(._agentFlow == true))] as $d_tagged |
  [($source.hooks // {} | to_entries[] | .value[] | select(._agentFlow == true))] as $s_tagged |

  # Compare (sorted for stable comparison)
  ($d_tagged | sort_by(.matcher // "", .pattern // "")) as $d_sorted |
  ($s_tagged | sort_by(.matcher // "", .pattern // "")) as $s_sorted |

  if $d_sorted == $s_sorted then "no_diff" else "has_diff" end
' "$DOWNSTREAM_FILE" "$SOURCE_FILE")

if [[ "$DIFF_CHECK" == '"no_diff"' ]]; then
  exit 2
fi

# Produce patched source: replace _agentFlow entries in source with downstream's versions
jq -s '
  .[0] as $downstream | .[1] as $source |

  # Start with source as base
  $source |

  # Merge hooks: for each hook type, replace source _agentFlow entries with downstream versions
  .hooks = (
    ($source.hooks // {}) as $source_hooks |
    ($downstream.hooks // {}) as $downstream_hooks |
    ($source_hooks | keys) + ($downstream_hooks | keys) | unique |
    reduce .[] as $hook_type (
      {};
      . + {
        ($hook_type): (
          ($source_hooks[$hook_type] // []) as $s_entries |
          ($downstream_hooks[$hook_type] // []) as $d_entries |
          [$d_entries[] | select(._agentFlow == true)] as $d_tagged |

          # Keep non-_agentFlow entries from source unchanged
          [
            $s_entries[] | select(._agentFlow != true)
          ] +
          # If downstream has tagged entries for this type, use them (the fixes).
          # Otherwise keep the tagged entries from source unchanged.
          (if ($d_tagged | length) > 0 then $d_tagged
           else [$s_entries[] | select(._agentFlow == true)]
           end)
        )
      }
    )
    # Filter out empty hook type arrays (from downstream-only child hook types)
    | with_entries(select(.value | length > 0))
  )
' "$DOWNSTREAM_FILE" "$SOURCE_FILE"
