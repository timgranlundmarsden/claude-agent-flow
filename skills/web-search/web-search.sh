#!/usr/bin/env bash
# web-search.sh — Optional grounded web-search via LiteLLM-compatible endpoint
# Usage: web-search.sh [--mode answer|search|raw] "<query>"
#
# Required env vars (when enabled):
#   AGENT_FLOW_WEB_SEARCH_ENABLED  — must be "true" or "1" to activate
#   AGENT_FLOW_WEB_SEARCH_MODEL    — model ID (e.g. gemini-2.0-flash)
#   AGENT_FLOW_WEB_SEARCH_BASE_URL — base URL (defaults to $ANTHROPIC_BASE_URL)
#   AGENT_FLOW_WEB_SEARCH_API_KEY  — API key (defaults to $ANTHROPIC_API_KEY)
#
# Optional env vars:
#   AGENT_FLOW_WEB_SEARCH_TOOL_SHAPE — googleSearch|googleSearchRetrieval|web_search_options
#
# Exit codes: 0 success, 1 usage error, 2 disabled, 3 config error, 4 HTTP/API error

# ---------------------------------------------------------------------------
# Section 1: Cleanup trap and temp directory
# ---------------------------------------------------------------------------
set -euo pipefail

TMP_DIR=$(mktemp -d)
# shellcheck disable=SC2317  # cleanup is invoked via trap, not dead code
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Section 2: Argument parsing
# ---------------------------------------------------------------------------
_mode="answer"
_query=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      if [[ $# -lt 2 ]]; then
        echo "web-search: --mode requires an argument (answer|search|raw)" >&2
        exit 1
      fi
      _mode="$2"
      shift 2
      ;;
    --mode=*)
      _mode="${1#--mode=}"
      shift
      ;;
    --)
      shift
      _query="$*"
      break
      ;;
    -*)
      echo "web-search: unknown flag: $1" >&2
      echo "Usage: web-search.sh [--mode answer|search|raw] \"<query>\"" >&2
      exit 1
      ;;
    *)
      _query="$1"
      shift
      ;;
  esac
done

# Validate mode
case "$_mode" in
  answer|search|raw) ;;
  *)
    echo "web-search: unknown mode '$_mode' (must be answer, search, or raw)" >&2
    exit 1
    ;;
esac

# Validate query
if [[ -z "$_query" ]]; then
  echo "web-search: query is required" >&2
  echo "Usage: web-search.sh [--mode answer|search|raw] \"<query>\"" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Section 4: .env auto-load (before all gates)
# ---------------------------------------------------------------------------
_repo_root=""
_repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [[ -n "$_repo_root" && -f "$_repo_root/.env" ]]; then
  while IFS= read -r _line || [[ -n "$_line" ]]; do
    if [[ "$_line" == AGENT_FLOW_WEB_SEARCH_* ]]; then
      export "${_line?}"
    fi
  done < "$_repo_root/.env"
fi
unset _repo_root _line

# ---------------------------------------------------------------------------
# Section 4b: Gate A — feature flag
# ---------------------------------------------------------------------------
_enabled="${AGENT_FLOW_WEB_SEARCH_ENABLED:-}"
if [[ "$_enabled" != "true" && "$_enabled" != "1" ]]; then
  echo "web-search: disabled; set AGENT_FLOW_WEB_SEARCH_ENABLED=true to enable" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Section 5: Tool shape validation
# ---------------------------------------------------------------------------
_tool_shape="${AGENT_FLOW_WEB_SEARCH_TOOL_SHAPE:-googleSearch}"
case "$_tool_shape" in
  googleSearch|googleSearchRetrieval|web_search_options) ;;
  *)
    echo "web-search: unknown AGENT_FLOW_WEB_SEARCH_TOOL_SHAPE value '$_tool_shape'" >&2
    echo "  Valid options: googleSearch, googleSearchRetrieval, web_search_options" >&2
    exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# Section 6: Gate B — config validation
# ---------------------------------------------------------------------------
_model="${AGENT_FLOW_WEB_SEARCH_MODEL:-}"
if [[ -z "$_model" ]]; then
  echo "web-search: AGENT_FLOW_WEB_SEARCH_MODEL is required but not set" >&2
  exit 3
fi

_base_url="${AGENT_FLOW_WEB_SEARCH_BASE_URL:-${ANTHROPIC_BASE_URL:-}}"
if [[ -z "$_base_url" ]]; then
  echo "web-search: one of AGENT_FLOW_WEB_SEARCH_BASE_URL or ANTHROPIC_BASE_URL must be set" >&2
  exit 3
fi

_api_key="${AGENT_FLOW_WEB_SEARCH_API_KEY:-${ANTHROPIC_API_KEY:-}}"
if [[ -z "$_api_key" ]]; then
  echo "web-search: one of AGENT_FLOW_WEB_SEARCH_API_KEY or ANTHROPIC_API_KEY must be set" >&2
  exit 3
fi

command -v jq >/dev/null 2>&1 || { echo "web-search: jq is required but not installed" >&2; exit 4; }

# Strip trailing slash
_base_url="${_base_url%/}"

# ---------------------------------------------------------------------------
# Section 7: Build request JSON via jq
# ---------------------------------------------------------------------------
case "$_tool_shape" in
  googleSearch)
    jq -n \
      --arg model "$_model" \
      --arg query "$_query" \
      '{"model": $model, "messages": [{"role": "user", "content": $query}], "tools": [{"googleSearch": {}}]}' \
      > "$TMP_DIR/request.json"
    ;;
  googleSearchRetrieval)
    jq -n \
      --arg model "$_model" \
      --arg query "$_query" \
      '{"model": $model, "messages": [{"role": "user", "content": $query}], "tools": [{"googleSearchRetrieval": {}}]}' \
      > "$TMP_DIR/request.json"
    ;;
  web_search_options)
    jq -n \
      --arg model "$_model" \
      --arg query "$_query" \
      '{"model": $model, "messages": [{"role": "user", "content": $query}], "web_search_options": {"search_context_size": "medium"}}' \
      > "$TMP_DIR/request.json"
    ;;
esac

# ---------------------------------------------------------------------------
# Section 8: Call API
# ---------------------------------------------------------------------------
HTTP_CODE=$(curl -s -w "%{http_code}" -o "$TMP_DIR/response.json" \
  --max-time 120 --connect-timeout 10 \
  -X POST "${_base_url}/chat/completions" \
  -H "Authorization: Bearer ${_api_key}" \
  -H "Content-Type: application/json" \
  -d @"$TMP_DIR/request.json" \
  2>"$TMP_DIR/curl-err.txt") || {
    _curl_err=$(cat "$TMP_DIR/curl-err.txt" 2>/dev/null || true)
    echo "web-search: connection timeout or network error${_curl_err:+: $_curl_err}" >&2
    exit 4
  }

# ---------------------------------------------------------------------------
# Section 9: HTTP error handling
# ---------------------------------------------------------------------------
if [[ "${HTTP_CODE:0:1}" != "2" ]]; then
  _err_msg=$(jq -r '.error.message // empty' "$TMP_DIR/response.json" 2>/dev/null || true)
  if [[ -n "$_err_msg" ]]; then
    echo "web-search: HTTP $HTTP_CODE error: $_err_msg" >&2
  else
    echo "web-search: HTTP $HTTP_CODE error (see response for details)" >&2
  fi
  exit 4
fi

# ---------------------------------------------------------------------------
# Section 10: Output modes
# ---------------------------------------------------------------------------

# raw mode
if [[ "$_mode" == "raw" ]]; then
  jq '.' "$TMP_DIR/response.json"
  exit 0
fi

# Citation extraction — try path 1: annotations[]
_citations=$(jq -r '
  .choices[0].message.annotations[]? |
  select(.type == "url_citation") |
  .url_citation |
  "- [\(.title // .url)](\(.url))"
' "$TMP_DIR/response.json" 2>/dev/null || true)

# Fallback path 2: grounding_metadata (check both choices[0].message and root)
if [[ -z "$_citations" ]]; then
  _citations=$(jq -r '
    (.choices[0].message.grounding_metadata // .grounding_metadata) |
    .groundingChunks[]? | .web |
    "- [\(.title // .uri)](\(.uri))"
  ' "$TMP_DIR/response.json" 2>/dev/null || true)
fi

if [[ "$_mode" == "search" ]]; then
  # Truncate to top 10 lines
  if [[ -n "$_citations" ]]; then
    printf '%s\n' "$_citations" | head -10
  else
    echo "(no citations returned)"
  fi
  exit 0
fi

# answer mode (default)
_content=$(jq -r '.choices[0].message.content // ""' "$TMP_DIR/response.json" 2>/dev/null || true)

printf '%s\n' "$_content"
if [[ -n "$_citations" ]]; then
  printf '\n## Sources\n'
  printf '%s\n' "$_citations"
else
  printf '\n## Sources\n(no citations returned)\n'
fi

exit 0
