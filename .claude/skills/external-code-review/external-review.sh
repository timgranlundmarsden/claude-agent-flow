#!/usr/bin/env bash
# external-review.sh — Make an external LLM API call for code review
# Usage: external-review.sh --diff-file <path> [--system-prompt <path>] [--user-prompt <path>] [--repo-name <name>] [--response-file <path>]
#
# Required env vars:
#   EXTERNAL_REVIEW_API_KEY       — API key for the external review LLM provider
#   EXTERNAL_REVIEW_MODEL         — Model ID to use
#   EXTERNAL_REVIEW_API_BASE_URL  — Base URL for the API (e.g. https://openrouter.ai/api/v1)
#
# Exit codes: 0 success, 1 any failure
# All errors/diagnostics go to stderr; only the parsed JSON result goes to stdout.

set -euo pipefail

# ---------------------------------------------------------------------------
# SECTION 1: Cleanup trap and temp directory
# ---------------------------------------------------------------------------

TMP_DIR=$(mktemp -d)
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# SECTION 2: Argument parsing
# ---------------------------------------------------------------------------

DIFF_FILE=""
SYSTEM_PROMPT_FILE=""
USER_PROMPT_FILE=""
REPO_NAME=""
RESPONSE_FILE=""
SUPPRESS_CONFIGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --diff-file)
      DIFF_FILE="${2:-}"
      shift 2
      ;;
    --system-prompt)
      SYSTEM_PROMPT_FILE="${2:-}"
      shift 2
      ;;
    --user-prompt)
      USER_PROMPT_FILE="${2:-}"
      shift 2
      ;;
    --repo-name)
      REPO_NAME="${2:-}"
      shift 2
      ;;
    --response-file)
      RESPONSE_FILE="${2:-}"
      shift 2
      ;;
    --suppress-config)
      SUPPRESS_CONFIGS+=("${2:-}")
      shift 2
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      echo "Usage: $0 --diff-file <path> [--system-prompt <path>] [--user-prompt <path>] [--repo-name <name>] [--response-file <path>] [--suppress-config <path>]..." >&2
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# SECTION 3: Validate required arguments
# ---------------------------------------------------------------------------

if [[ -z "$DIFF_FILE" ]]; then
  echo "ERROR: --diff-file is required" >&2
  exit 1
fi

if [[ ! -f "$DIFF_FILE" ]]; then
  echo "ERROR: diff file not found: $DIFF_FILE" >&2
  exit 1
fi

# Default system prompt: resolve from git root
if [[ -z "$SYSTEM_PROMPT_FILE" ]]; then
  GIT_ROOT=$(git rev-parse --show-toplevel 2>"$TMP_DIR/git-err.txt" || true)
  if [[ -z "$GIT_ROOT" ]]; then
    echo "ERROR: could not determine git root to find default system prompt ($(cat "$TMP_DIR/git-err.txt"))" >&2
    exit 1
  fi
  SYSTEM_PROMPT_FILE="$GIT_ROOT/.claude/skills/external-code-review/external-review-system-prompt.md"
fi

if [[ ! -f "$SYSTEM_PROMPT_FILE" ]]; then
  echo "ERROR: system prompt file not found: $SYSTEM_PROMPT_FILE" >&2
  exit 1
fi

# Ensure Python helpers can import repo-local fallback modules (e.g. yaml.py)
# even when this script is executed from outside the repo root.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
export PYTHONPATH="${SCRIPT_REPO_ROOT}${PYTHONPATH:+:${PYTHONPATH}}"

# ---------------------------------------------------------------------------
# SECTION 4: Environment variable validation
# ---------------------------------------------------------------------------

# Auto-load EXTERNAL_REVIEW_* vars from .env if not already set
if [[ -z "${EXTERNAL_REVIEW_API_KEY:-}" ]]; then
  _env_file="$(git rev-parse --show-toplevel 2>/dev/null || true)/.env"
  if [[ -f "$_env_file" ]]; then
    while IFS= read -r _line; do
      export "${_line?}"
    done < <(grep '^EXTERNAL_REVIEW_' "$_env_file")
  fi
  unset _env_file _line
fi

if [[ -z "${EXTERNAL_REVIEW_API_KEY:-}" ]]; then
  echo "ERROR: EXTERNAL_REVIEW_API_KEY environment variable is not set or is empty" >&2
  exit 1
fi

if [[ -z "${EXTERNAL_REVIEW_MODEL:-}" ]]; then
  echo "ERROR: EXTERNAL_REVIEW_MODEL environment variable is not set or is empty" >&2
  exit 1
fi

if [[ -z "${EXTERNAL_REVIEW_API_BASE_URL:-}" ]]; then
  echo "ERROR: EXTERNAL_REVIEW_API_BASE_URL environment variable is not set or is empty" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# SECTION 5: Build user prompt
# ---------------------------------------------------------------------------

if [[ -n "$USER_PROMPT_FILE" ]]; then
  if [[ ! -f "$USER_PROMPT_FILE" ]]; then
    echo "ERROR: user prompt file not found: $USER_PROMPT_FILE" >&2
    exit 1
  fi
  # Copy to temp so we can append suppress context without modifying the original
  CONSTRUCTED_USER_PROMPT_FILE="$TMP_DIR/user-prompt.txt"
  cp "$USER_PROMPT_FILE" "$CONSTRUCTED_USER_PROMPT_FILE"
else
  # Construct user prompt from diff content using direct file concatenation
  # to preserve exact diff bytes (avoids trailing-newline stripping in $(...))
  CONSTRUCTED_USER_PROMPT_FILE="$TMP_DIR/user-prompt.txt"

  {
    printf 'Review this code diff.\n\nDiff:\n```diff\n'
    cat "$DIFF_FILE"
    printf '\n```\n\nInstructions: Respond with JSON only matching this schema (no markdown fences): {"verdict":"PASS|WARN|FAIL","summary":"<summary>","concerns":[{"file":"<path>","line":<n>,"severity":"error|warning|info","message":"<text>"}]}. verdict: PASS=no issues, WARN=minor issues non-blocking, FAIL=must fix before merge. IMPORTANT: every concern MUST include a line number from the NEW file version (the + side of the diff). Look at the @@ hunk headers to determine line numbers — the +N in @@ -X,Y +N,M @@ is the starting line, then count forward through non-minus lines. Never use null for line — always provide the specific line number where the issue occurs.'
  } > "$CONSTRUCTED_USER_PROMPT_FILE"
fi

# ---------------------------------------------------------------------------
# SECTION 5b: Inject suppression context into user prompt
# ---------------------------------------------------------------------------

if [[ ${#SUPPRESS_CONFIGS[@]} -gt 0 ]]; then
  SUPPRESS_ENTRIES=""
  MAX_SUPPRESS_BYTES=51200  # 50KB cap per config file
  for CFG_FILE in "${SUPPRESS_CONFIGS[@]}"; do
    if [[ ! -f "$CFG_FILE" ]]; then
      echo "WARN: suppress config not found: $CFG_FILE" >&2
      continue
    fi
    CFG_SIZE=$(wc -c < "$CFG_FILE")
    if [[ "$CFG_SIZE" -gt "$MAX_SUPPRESS_BYTES" ]]; then
      echo "WARN: suppress config exceeds ${MAX_SUPPRESS_BYTES}B limit, skipping: $CFG_FILE" >&2
      continue
    fi
    ENTRIES=$(python3 - "$CFG_FILE" 2>"$TMP_DIR/suppress-read-err.txt" <<'PYEOF' || true
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1])) or {}
for s in cfg.get('suppress', []):
    print(f"- {s.get('file','*')}: {s.get('keyword','*')} ({s.get('reason','no reason')})")
PYEOF
    )
    SUPPRESS_ENTRIES="${SUPPRESS_ENTRIES}${ENTRIES}"$'\n'
  done
  if [[ "$SUPPRESS_ENTRIES" =~ [^[:space:]] ]]; then
    printf '\n\n## Suppressed concerns (DO NOT flag these)\nThe following patterns are acknowledged by the team and should NOT be reported as concerns:\n%s\nIf a concern matches any of these patterns (same file and keyword appears in the issue), skip it entirely.\n' "$SUPPRESS_ENTRIES" >> "$CONSTRUCTED_USER_PROMPT_FILE"
  fi
fi

# ---------------------------------------------------------------------------
# SECTION 6: Build request JSON
# ---------------------------------------------------------------------------

jq -n \
  --arg model "$EXTERNAL_REVIEW_MODEL" \
  --rawfile system_content "$SYSTEM_PROMPT_FILE" \
  --rawfile user_content "$CONSTRUCTED_USER_PROMPT_FILE" \
  '{
    model: $model,
    messages: [
      {role: "system", content: $system_content},
      {role: "user",   content: $user_content}
    ],
    response_format: {
      type: "json_schema",
      json_schema: {
        name: "pr_review",
        strict: true,
        schema: {
          type: "object",
          required: ["verdict", "summary", "concerns"],
          additionalProperties: false,
          properties: {
            verdict: {type: "string", "enum": ["PASS", "WARN", "FAIL"]},
            summary: {type: "string"},
            concerns: {
              type: "array",
              items: {
                type: "object",
                required: ["file", "line", "severity", "message"],
                additionalProperties: false,
                properties: {
                  file:     {type: "string"},
                  line:     {type: "integer"},
                  severity: {type: "string", "enum": ["error", "warning", "info"]},
                  message:  {type: "string"}
                }
              }
            }
          }
        }
      }
    }
  }' > "$TMP_DIR/llm-request.json"

# ---------------------------------------------------------------------------
# SECTION 7: Call external review API
# ---------------------------------------------------------------------------

HTTP_CODE=$(curl -s -w "%{http_code}" -o "$TMP_DIR/llm-response.json" \
  --max-time 120 --connect-timeout 10 \
  -X POST "${EXTERNAL_REVIEW_API_BASE_URL}/chat/completions" \
  -H "Authorization: Bearer $EXTERNAL_REVIEW_API_KEY" \
  -H "Content-Type: application/json" \
  -H "HTTP-Referer: https://github.com/${REPO_NAME:-unknown}" \
  -d @"$TMP_DIR/llm-request.json" \
  2>"$TMP_DIR/curl-err.txt")

if [[ "$HTTP_CODE" != "200" ]]; then
  echo "ERROR: External review API returned HTTP $HTTP_CODE" >&2
  echo "Response body:" >&2
  cat "$TMP_DIR/llm-response.json" >&2
  if [[ -s "$TMP_DIR/curl-err.txt" ]]; then
    echo "curl error:" >&2
    cat "$TMP_DIR/curl-err.txt" >&2
  fi
  exit 1
fi

# ---------------------------------------------------------------------------
# SECTION 8: Parse response JSON (two-stage)
# ---------------------------------------------------------------------------

# Stage 1: Standard path — content is already clean JSON
PARSED=$(jq -e '.choices[0].message.content | fromjson | select(has("verdict") and has("concerns"))' \
  "$TMP_DIR/llm-response.json" 2>"$TMP_DIR/jq-err.txt" || true)

if [[ -z "$PARSED" ]]; then
  # Stage 2: Extract raw content string and use Python depth-tracking brace parser
  RAW_CONTENT=$(jq -r '.choices[0].message.content' "$TMP_DIR/llm-response.json" 2>"$TMP_DIR/jq2-err.txt" || true)

  if [[ -z "$RAW_CONTENT" ]] || [[ "$RAW_CONTENT" == "null" ]]; then
    echo "ERROR: could not extract message content from API response" >&2
    cat "$TMP_DIR/llm-response.json" >&2
    exit 1
  fi

  printf '%s' "$RAW_CONTENT" > "$TMP_DIR/raw-content.txt"

  PARSED=$(python3 - "$TMP_DIR/raw-content.txt" 2>"$TMP_DIR/py-err.txt" <<'PYEOF'
import sys, json

with open(sys.argv[1], 'r') as fh:
    text = fh.read()

# Depth-tracking brace parser: find every top-level { ... } block
candidates = []
i = 0
n = len(text)
while i < n:
    if text[i] == '{':
        depth = 0
        start = i
        in_str = False
        escape = False
        j = i
        while j < n:
            ch = text[j]
            if escape:
                escape = False
            elif ch == '\\' and in_str:
                escape = True
            elif ch == '"':
                in_str = not in_str
            elif not in_str:
                if ch == '{':
                    depth += 1
                elif ch == '}':
                    depth -= 1
                    if depth == 0:
                        candidates.append(text[start:j+1])
                        break
            j += 1
    i += 1

for candidate in candidates:
    try:
        obj = json.loads(candidate)
        if 'verdict' in obj and 'concerns' in obj:
            print(json.dumps(obj))
            sys.exit(0)
    except json.JSONDecodeError:
        continue

sys.stderr.write("ERROR: no valid JSON object with verdict and concerns found\n")
sys.exit(1)
PYEOF
  ) || true

  if [[ -z "$PARSED" ]]; then
    echo "ERROR: failed to parse review JSON from API response" >&2
    if [[ -s "$TMP_DIR/py-err.txt" ]]; then
      cat "$TMP_DIR/py-err.txt" >&2
    fi
    echo "Raw content:" >&2
    cat "$TMP_DIR/raw-content.txt" >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# SECTION 9: Copy raw response if requested
# ---------------------------------------------------------------------------

if [[ -n "$RESPONSE_FILE" ]]; then
  cp "$TMP_DIR/llm-response.json" "$RESPONSE_FILE"
fi

# ---------------------------------------------------------------------------
# SECTION 9b: Apply suppression rules and recalculate verdict
# ---------------------------------------------------------------------------

if [[ ${#SUPPRESS_CONFIGS[@]} -gt 0 ]]; then
  printf '%s' "$PARSED" > "$TMP_DIR/review-for-suppress.json"
  for CFG_FILE in "${SUPPRESS_CONFIGS[@]}"; do
    if [[ ! -f "$CFG_FILE" ]]; then
      echo "WARN: suppress config not found for post-LLM matching: $CFG_FILE" >&2
      continue
    fi
    CFG_SIZE=$(wc -c < "$CFG_FILE")
    if [[ "$CFG_SIZE" -gt "${MAX_SUPPRESS_BYTES:-51200}" ]]; then
      echo "WARN: suppress config exceeds size limit, skipping post-LLM matching: $CFG_FILE" >&2
      continue
    fi
    python3 - "$CFG_FILE" "$TMP_DIR/review-for-suppress.json" 2>"$TMP_DIR/suppress-apply-err.txt" <<'PYEOF' || true
import sys, yaml, json, fnmatch
cfg = yaml.safe_load(open(sys.argv[1])) or {}
r = json.load(open(sys.argv[2]))
norm = lambda p: (p[2:] if p.startswith('./') else p) if p else ''
for c in r.get('concerns', []):
    if c.get('suppressed'):
        continue
    for s in cfg.get('suppress', []):
        if fnmatch.fnmatch(norm(c.get('file', '')), norm(s.get('file', ''))) and \
           (not s.get('keyword', '') or s['keyword'].lower() in c.get('message', '').lower()):
            c['suppressed'] = True
            c['suppress_reason'] = s.get('reason', '')
            break
json.dump(r, open(sys.argv[2], 'w'))
PYEOF
  done

  # Recalculate verdict based on unsuppressed concerns only
  RECALC_INPUT="$TMP_DIR/review-for-suppress.json"
  PARSED=$(python3 - "$RECALC_INPUT" 2>"$TMP_DIR/verdict-recalc-err.txt" <<'PYEOF' || true
import sys, json
r = json.load(open(sys.argv[1]))
errors = [c for c in r.get('concerns', []) if c.get('severity') == 'error' and not c.get('suppressed')]
warnings = [c for c in r.get('concerns', []) if c.get('severity') == 'warning' and not c.get('suppressed')]
if errors:
    r['verdict'] = 'FAIL'
elif warnings:
    r['verdict'] = 'WARN'
else:
    r['verdict'] = 'PASS'
print(json.dumps(r))
PYEOF
  )

  if [[ -z "$PARSED" ]]; then
    echo "WARN: verdict recalculation failed, re-reading suppressed JSON with original verdict" >&2
    if [[ -s "$TMP_DIR/verdict-recalc-err.txt" ]]; then
      cat "$TMP_DIR/verdict-recalc-err.txt" >&2
    fi
    # Fallback: read the file (has suppression markers) and do minimal recalc inline
    PARSED=$(python3 -c "
import sys, json
r = json.load(open(sys.argv[1]))
errs = [c for c in r.get('concerns',[]) if c.get('severity')=='error' and not c.get('suppressed')]
warns = [c for c in r.get('concerns',[]) if c.get('severity')=='warning' and not c.get('suppressed')]
r['verdict'] = 'FAIL' if errs else ('WARN' if warns else 'PASS')
print(json.dumps(r))
" "$RECALC_INPUT" 2>/dev/null || cat "$RECALC_INPUT")
  fi
fi

# Always recalculate verdict from concern severities — never trust the LLM's verdict field
# (The LLM may return PASS while listing error-severity concerns)
if [[ ${#SUPPRESS_CONFIGS[@]} -eq 0 ]]; then
  PARSED=$(printf '%s' "$PARSED" | python3 -c "
import sys, json
r = json.load(sys.stdin)
errs = [c for c in r.get('concerns',[]) if c.get('severity')=='error' and not c.get('suppressed')]
warns = [c for c in r.get('concerns',[]) if c.get('severity')=='warning' and not c.get('suppressed')]
r['verdict'] = 'FAIL' if errs else ('WARN' if warns else 'PASS')
print(json.dumps(r))
" 2>/dev/null || printf '%s' "$PARSED")
fi

# ---------------------------------------------------------------------------
# SECTION 10: Output result to stdout
# ---------------------------------------------------------------------------

printf '%s\n' "$PARSED"
