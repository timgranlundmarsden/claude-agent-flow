#!/usr/bin/env bash
set -euo pipefail

# Usage: visual-check.sh <path-to-html-file> [css-selector-for-uniform-width] [--evidence <task-slug> [prefix]]
#
# --evidence <task-slug> [prefix]
#   Save JPEG screenshots to .scratch/evidence/<task-slug>/ and stage with git add.
#   If prefix is provided: <prefix>_mobile.jpg, <prefix>_tablet.jpg, <prefix>_desktop.jpg
#   If omitted: mobile.jpg, tablet.jpg, desktop.jpg (backwards compatible)

FILE_ARG=""
SELECTOR=""
EVIDENCE_SLUG=""
EVIDENCE_PREFIX=""

# Parse arguments: positional args first, then --evidence flag
while [[ $# -gt 0 ]]; do
  case "$1" in
    --evidence)
      EVIDENCE_SLUG="${2:-}"
      if [[ -z "$EVIDENCE_SLUG" ]]; then
        echo "ERROR: --evidence requires a task-slug argument" >&2
        exit 2
      fi
      shift 2
      # Optional prefix: next arg if it doesn't start with --
      if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
        EVIDENCE_PREFIX="$1"
        shift
      fi
      ;;
    *)
      if [[ -z "$FILE_ARG" ]]; then
        FILE_ARG="$1"
      elif [[ -z "$SELECTOR" ]]; then
        SELECTOR="$1"
      fi
      shift
      ;;
  esac
done

if [[ -z "$FILE_ARG" ]]; then
  echo "Usage: $0 <path-to-html-file> [css-selector] [--evidence <task-slug> [prefix]]" >&2
  exit 2
fi

# Check file exists before resolving path (realpath fails under set -e if missing)
if [[ ! -e "$FILE_ARG" ]]; then
  echo "ERROR: file not found: $FILE_ARG" >&2
  exit 2
fi

# Resolve to absolute path (handles non-canonical/relative paths)
ABS_PATH="$(realpath "$FILE_ARG")"

if [[ ! -f "$ABS_PATH" ]]; then
  echo "ERROR: not a regular file: $ABS_PATH" >&2
  exit 2
fi

# Validate selector early (before browser launch)
if [[ -n "$SELECTOR" ]]; then
  if [[ ! "$SELECTOR" =~ ^[]a-zA-Z0-9_.#=~^\$\*\|\:\(\)\ \>\+\,\-[]+$ ]]; then
    echo "ERROR: selector contains unsafe characters: $SELECTOR" >&2
    exit 2
  fi
fi

# mktemp: Linux requires at least 3 X's in the template; macOS adds them automatically.
# Use XXXXXX to be portable across both.
MOBILE_PNG=$(mktemp -t visual-check-mobileXXXXXX).png
TABLET_PNG=$(mktemp -t visual-check-tabletXXXXXX).png
DESKTOP_PNG=$(mktemp -t visual-check-desktopXXXXXX).png

# Disable Chromium sandbox when running as root (common in CI/containers).
# Safe on macOS too — the env var is simply ignored when sandboxing works.
if [[ "$(id -u)" == "0" ]]; then
  export PLAYWRIGHT_MCP_SANDBOX=false
fi

# Spin up a local HTTP server so playwright-cli can load the file (file:// URLs are blocked)
FILE_DIR="$(dirname "$ABS_PATH")"
FILE_NAME="$(basename "$ABS_PATH")"
HTTP_PORT=18765
# Kill any stale server on the same port from a previous run
if lsof -ti :"$HTTP_PORT" &>/dev/null; then
  kill "$(lsof -ti :"$HTTP_PORT")" 2>/dev/null || true
  sleep 0.3
fi
python3 -m http.server "$HTTP_PORT" --directory "$FILE_DIR" &>/dev/null &
HTTP_PID=$!
sleep 0.5
FILE_URL="http://localhost:${HTTP_PORT}/${FILE_NAME}"

# Cleanup on exit: close browser session and HTTP server
cleanup() {
  playwright-cli close 2>/dev/null || true
  kill "$HTTP_PID" 2>/dev/null || true
}
trap cleanup EXIT

echo "Checking: $ABS_PATH"

# Helper: extract JSON from playwright-cli eval output.
# playwright-cli wraps the return value as a JSON-encoded string, e.g. "{\"key\":1}"
# We find the first quoted or raw JSON line and unwrap it.
extract_json() {
  python3 -c "
import sys, json
lines = [l.strip() for l in sys.stdin]
for line in lines:
    if line.startswith('\"') or line.startswith('{') or line.startswith('['):
        try:
            val = json.loads(line)
            # If it decoded to a string, parse that string as JSON too
            if isinstance(val, str):
                val = json.loads(val)
            print(json.dumps(val))
            sys.exit(0)
        except Exception:
            continue
print('ERROR: no JSON in playwright-cli output', file=sys.stderr)
sys.exit(1)
"
}

# Helper: check horizontal overflow at current viewport, fail with label if detected
check_overflow() {
  local label="$1"
  local result
  result=$(playwright-cli eval "JSON.stringify({ overflow: document.body.scrollWidth > document.body.clientWidth, scrollWidth: document.body.scrollWidth, clientWidth: document.body.clientWidth })" | extract_json)

  local overflow scroll_w client_w
  read -r overflow scroll_w client_w <<< "$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print('YES' if d['overflow'] else 'NO', d['scrollWidth'], d['clientWidth'])")"

  if [[ "$overflow" == "YES" ]]; then
    echo "FAIL: horizontal overflow at ${label} (scrollWidth: ${scroll_w}, clientWidth: ${client_w})"
    exit 1
  fi
}

# Session-based workflow: open, screenshot + overflow check at each viewport
playwright-cli open "$FILE_URL"

playwright-cli resize 375 812
playwright-cli screenshot --filename="$MOBILE_PNG"
check_overflow "375px (mobile)"

playwright-cli resize 768 1024
playwright-cli screenshot --filename="$TABLET_PNG"
check_overflow "768px (tablet)"

playwright-cli resize 1280 900
playwright-cli screenshot --filename="$DESKTOP_PNG"
check_overflow "1280px (desktop)"

# Optional: uniform-width check on CSS selector
if [[ -n "$SELECTOR" ]]; then
  # Escape backslashes first, then single quotes to prevent injection (defense-in-depth)
  SAFE_SELECTOR="${SELECTOR//\\/\\\\}"
  SAFE_SELECTOR="${SAFE_SELECTOR//\'/\\\'}"
  WIDTHS_JSON=$(playwright-cli eval \
    "JSON.stringify(Array.from(document.querySelectorAll('${SAFE_SELECTOR}')).map(function(el) { return Math.round(el.getBoundingClientRect().width); }))" | extract_json)

  UNIFORM=$(echo "$WIDTHS_JSON" | python3 -c "
import sys, json
widths = json.load(sys.stdin)
if len(widths) == 0:
    print('NO_ELEMENTS')
elif len(set(widths)) == 1:
    print('UNIFORM')
else:
    print('NON_UNIFORM')
")

  WIDTHS_LIST=$(echo "$WIDTHS_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin))")

  if [[ "$UNIFORM" == "NO_ELEMENTS" ]]; then
    echo "WARNING: selector '$SELECTOR' matched no elements"
  elif [[ "$UNIFORM" == "NON_UNIFORM" ]]; then
    echo "FAIL: non-uniform widths for '$SELECTOR': $WIDTHS_LIST"
    exit 1
  else
    echo "Uniform widths for '$SELECTOR': $WIDTHS_LIST"
  fi
fi

# Save JPEG evidence if --evidence was provided
if [[ -n "$EVIDENCE_SLUG" ]]; then
  # Find the repo root (where .git lives)
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  EVIDENCE_DIR="${REPO_ROOT}/.scratch/evidence/${EVIDENCE_SLUG}"
  mkdir -p "$EVIDENCE_DIR"

  # Build filenames: with prefix → <prefix>_mobile.jpg, without → mobile.jpg
  if [[ -n "$EVIDENCE_PREFIX" ]]; then
    MOBILE_NAME="${EVIDENCE_PREFIX}_mobile.jpg"
    TABLET_NAME="${EVIDENCE_PREFIX}_tablet.jpg"
    DESKTOP_NAME="${EVIDENCE_PREFIX}_desktop.jpg"
  else
    MOBILE_NAME="mobile.jpg"
    TABLET_NAME="tablet.jpg"
    DESKTOP_NAME="desktop.jpg"
  fi

  # Take JPEG screenshots using run-code for explicit type control.
  # playwright-cli screenshot ignores extension; run-code with type:'jpeg' produces real JPEG.
  playwright-cli resize 375 812
  playwright-cli run-code "async page => { await page.screenshot({ path: '${EVIDENCE_DIR}/${MOBILE_NAME}', type: 'jpeg', quality: 80 }); }"
  playwright-cli resize 768 1024
  playwright-cli run-code "async page => { await page.screenshot({ path: '${EVIDENCE_DIR}/${TABLET_NAME}', type: 'jpeg', quality: 80 }); }"
  playwright-cli resize 1280 900
  playwright-cli run-code "async page => { await page.screenshot({ path: '${EVIDENCE_DIR}/${DESKTOP_NAME}', type: 'jpeg', quality: 80 }); }"

  git -C "$REPO_ROOT" add "${EVIDENCE_DIR}/"

  echo "PASS"
  echo "  Evidence saved:     ${EVIDENCE_DIR}/"
  echo "    ${MOBILE_NAME}$(printf '%*s' $((20 - ${#MOBILE_NAME})) '')$(du -h "${EVIDENCE_DIR}/${MOBILE_NAME}" | cut -f1)"
  echo "    ${TABLET_NAME}$(printf '%*s' $((20 - ${#TABLET_NAME})) '')$(du -h "${EVIDENCE_DIR}/${TABLET_NAME}" | cut -f1)"
  echo "    ${DESKTOP_NAME}$(printf '%*s' $((20 - ${#DESKTOP_NAME})) '')$(du -h "${EVIDENCE_DIR}/${DESKTOP_NAME}" | cut -f1)"
  echo "  Staged for commit."
else
  echo "PASS"
  echo "  Mobile screenshot:  $MOBILE_PNG"
  echo "  Tablet screenshot:  $TABLET_PNG"
  echo "  Desktop screenshot: $DESKTOP_PNG"
fi
exit 0
