#!/usr/bin/env bats
# Tests for web-search.sh
# Run with: .claude-agent-flow/tests/lib/bats-core/bin/bats --jobs 8 .claude-agent-flow/tests/web-search-skill.bats

TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
SCRIPT="$PROJECT_ROOT/.claude/skills/web-search/web-search.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

setup() {
  # Save original PATH so teardown can restore it
  export ORIG_PATH="$PATH"

  # Create a fresh temp directory for each test
  TEST_TMP=$(mktemp -d)

  # Prevent .env auto-load: the script uses git rev-parse --show-toplevel to find
  # .env, which would re-set env vars that tests intentionally unset. Running
  # from $TEST_TMP with GIT_CEILING_DIRECTORIES stops git from discovering the
  # repo's .env file.
  export GIT_CEILING_DIRECTORIES="${TEST_TMP%/*}"
  cd "$TEST_TMP"

  # Valid-looking env vars (no real API calls in most tests — curl is stubbed)
  export AGENT_FLOW_WEB_SEARCH_ENABLED="true"
  export AGENT_FLOW_WEB_SEARCH_MODEL="gemini-2.0-flash"
  export AGENT_FLOW_WEB_SEARCH_BASE_URL="https://api.example.com/v1"
  export AGENT_FLOW_WEB_SEARCH_API_KEY="test-api-key"
}

teardown() {
  cd "$BATS_TEST_DIRNAME"
  rm -rf "$TEST_TMP"
  unset AGENT_FLOW_WEB_SEARCH_ENABLED AGENT_FLOW_WEB_SEARCH_MODEL \
        AGENT_FLOW_WEB_SEARCH_BASE_URL AGENT_FLOW_WEB_SEARCH_API_KEY \
        AGENT_FLOW_WEB_SEARCH_TOOL_SHAPE ANTHROPIC_BASE_URL ANTHROPIC_API_KEY \
        GIT_CEILING_DIRECTORIES
  export PATH="$ORIG_PATH"
}

# Stub curl to return a given HTTP code and body without hitting the network.
# Also captures the -d @<file> argument to $TEST_TMP/stubs/captured-request.json
# for payload inspection tests.
# Usage: stub_curl <http_code> <body_json>
stub_curl() {
  local http_code="$1"
  local body="$2"
  local stub_dir="$TEST_TMP/stubs"
  mkdir -p "$stub_dir"
  # Write body to a file so the stub can read it without inline variable expansion issues
  printf '%s' "$body" > "$stub_dir/response-body.txt"
  # Write a curl replacement script
  cat > "$stub_dir/curl" <<STUB
#!/usr/bin/env bash
# Minimal curl stub — parse -o, -w, and -d from args
output_file=""
write_out=""
data_arg=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) output_file="\$2"; shift 2 ;;
    -w) write_out="\$2"; shift 2 ;;
    -d) data_arg="\$2"; shift 2 ;;
    *)  shift ;;
  esac
done
# Capture request body for payload inspection
if [[ -n "\$data_arg" && "\$data_arg" == @* ]]; then
  cp "\${data_arg#@}" "$stub_dir/captured-request.json"
fi
if [[ -n "\$output_file" ]]; then
  cat "$stub_dir/response-body.txt" > "\$output_file"
fi
if [[ "\$write_out" == "%{http_code}" ]]; then
  printf '%s' "$http_code"
fi
STUB
  chmod +x "$stub_dir/curl"
  export PATH="$stub_dir:$PATH"
}

# Build a mock API response with annotations[] citations.
make_web_response() {
  local content="${1:-Search result content}"
  local title="${2:-Example Title}"
  local url="${3:-https://example.com/result}"
  jq -n --arg content "$content" --arg title "$title" --arg url "$url" '
    {
      choices: [{
        message: {
          content: $content,
          annotations: [{
            type: "url_citation",
            url_citation: {title: $title, url: $url}
          }]
        }
      }]
    }
  '
}

# Build a mock API response using grounding_metadata (fallback path).
make_grounding_response() {
  local content="${1:-Grounding content}"
  local title="${2:-Grounding Title}"
  local uri="${3:-https://grounding.example.com}"
  jq -n --arg content "$content" --arg title "$title" --arg uri "$uri" '
    {
      choices: [{
        message: {
          content: $content,
          annotations: [],
          grounding_metadata: {
            groundingChunks: [{web: {title: $title, uri: $uri}}]
          }
        }
      }]
    }
  '
}

# ---------------------------------------------------------------------------
# SECTION A: Feature flag
# ---------------------------------------------------------------------------

@test "01 exits 2 when AGENT_FLOW_WEB_SEARCH_ENABLED is unset" {
  unset AGENT_FLOW_WEB_SEARCH_ENABLED
  run bash "$SCRIPT" "some query"
  [ "$status" -eq 2 ]
  [[ "$output" == *"disabled"* ]]
}

@test "02 exits 2 when AGENT_FLOW_WEB_SEARCH_ENABLED=false" {
  AGENT_FLOW_WEB_SEARCH_ENABLED="false" run bash "$SCRIPT" "some query"
  [ "$status" -eq 2 ]
  [[ "$output" == *"disabled"* ]]
}

@test "03 exits 2 when AGENT_FLOW_WEB_SEARCH_ENABLED=yes (only true/1 allowed)" {
  AGENT_FLOW_WEB_SEARCH_ENABLED="yes" run bash "$SCRIPT" "some query"
  [ "$status" -eq 2 ]
  [[ "$output" == *"disabled"* ]]
}

@test "04 activates when AGENT_FLOW_WEB_SEARCH_ENABLED=1" {
  stub_curl 200 "$(make_web_response)"
  AGENT_FLOW_WEB_SEARCH_ENABLED="1" run bash "$SCRIPT" "some query"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# SECTION B: Config validation (run with ENABLED=true)
# ---------------------------------------------------------------------------

@test "05 exits 3 when MODEL is unset" {
  unset AGENT_FLOW_WEB_SEARCH_MODEL
  run bash "$SCRIPT" "some query"
  [ "$status" -eq 3 ]
  [[ "$output" == *"AGENT_FLOW_WEB_SEARCH_MODEL"* ]]
}

@test "06 exits 3 when BASE_URL and ANTHROPIC_BASE_URL both unset" {
  unset AGENT_FLOW_WEB_SEARCH_BASE_URL
  unset ANTHROPIC_BASE_URL
  run bash "$SCRIPT" "some query"
  [ "$status" -eq 3 ]
  [[ "$output" == *"AGENT_FLOW_WEB_SEARCH_BASE_URL"* || "$output" == *"ANTHROPIC_BASE_URL"* ]]
}

@test "07 exits 3 when API_KEY and ANTHROPIC_API_KEY both unset" {
  unset AGENT_FLOW_WEB_SEARCH_API_KEY
  unset ANTHROPIC_API_KEY
  run bash "$SCRIPT" "some query"
  [ "$status" -eq 3 ]
  [[ "$output" == *"AGENT_FLOW_WEB_SEARCH_API_KEY"* || "$output" == *"ANTHROPIC_API_KEY"* ]]
}

@test "08 falls back to ANTHROPIC_BASE_URL when AGENT_FLOW_WEB_SEARCH_BASE_URL unset" {
  stub_curl 200 "$(make_web_response)"
  unset AGENT_FLOW_WEB_SEARCH_BASE_URL
  ANTHROPIC_BASE_URL="https://fallback.example.com/v1" run bash "$SCRIPT" "some query"
  [ "$status" -eq 0 ]
}

@test "09 falls back to ANTHROPIC_API_KEY when AGENT_FLOW_WEB_SEARCH_API_KEY unset" {
  stub_curl 200 "$(make_web_response)"
  unset AGENT_FLOW_WEB_SEARCH_API_KEY
  ANTHROPIC_API_KEY="fallback-key" run bash "$SCRIPT" "some query"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# SECTION C: HTTP error handling
# ---------------------------------------------------------------------------

@test "10 exits 4 and surfaces error message on non-2xx response" {
  stub_curl 401 '{"error":{"message":"Unauthorized: invalid API key"}}'
  run bash "$SCRIPT" "some query"
  [ "$status" -eq 4 ]
  [[ "$output" == *"401"* ]]
  [[ "$output" == *"Unauthorized"* ]]
}

@test "11 exits 4 on 500 response with generic message when no error body" {
  stub_curl 500 '{}'
  run bash "$SCRIPT" "some query"
  [ "$status" -eq 4 ]
  [[ "$output" == *"500"* ]]
}

# ---------------------------------------------------------------------------
# SECTION D: Output modes (happy path)
# ---------------------------------------------------------------------------

@test "12 answer mode prints content and Sources section with annotations citations" {
  stub_curl 200 "$(make_web_response "My answer here" "Test Page" "https://test.example.com")"
  run bash "$SCRIPT" --mode answer "test query"
  [ "$status" -eq 0 ]
  [[ "$output" == *"My answer here"* ]]
  [[ "$output" == *"## Sources"* ]]
  [[ "$output" == *"Test Page"* ]]
  [[ "$output" == *"https://test.example.com"* ]]
}

@test "13 answer mode falls back to grounding_metadata when annotations empty" {
  stub_curl 200 "$(make_grounding_response "Grounded answer" "Grounding Title" "https://grounding.example.com")"
  run bash "$SCRIPT" --mode answer "test query"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Grounded answer"* ]]
  [[ "$output" == *"## Sources"* ]]
  [[ "$output" == *"Grounding Title"* ]]
  [[ "$output" == *"https://grounding.example.com"* ]]
}

@test "14 search mode prints only citations (no content)" {
  stub_curl 200 "$(make_web_response "Do not show this content" "Cite Title" "https://cite.example.com")"
  run bash "$SCRIPT" --mode search "test query"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Do not show this content"* ]]
  [[ "$output" == *"Cite Title"* ]]
  [[ "$output" == *"https://cite.example.com"* ]]
}

@test "15 search mode prints (no citations returned) when none present" {
  local empty_response
  empty_response=$(jq -n '{"choices":[{"message":{"content":"Answer only","annotations":[]}}]}')
  stub_curl 200 "$empty_response"
  run bash "$SCRIPT" --mode search "test query"
  [ "$status" -eq 0 ]
  [[ "$output" == *"(no citations returned)"* ]]
}

@test "16 raw mode prints pretty-printed JSON" {
  stub_curl 200 "$(make_web_response "raw content" "Raw Title" "https://raw.example.com")"
  run bash "$SCRIPT" --mode raw "test query"
  [ "$status" -eq 0 ]
  # Output must be valid JSON
  echo "$output" | jq '.' >/dev/null
  [[ "$output" == *"choices"* ]]
}

@test "17 default mode is answer when --mode not specified" {
  stub_curl 200 "$(make_web_response "Default mode content" "Default Title" "https://default.example.com")"
  run bash "$SCRIPT" "test query"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Default mode content"* ]]
  [[ "$output" == *"## Sources"* ]]
}

# ---------------------------------------------------------------------------
# SECTION E: Injection safety
# ---------------------------------------------------------------------------

@test "18 shell metacharacters in query are JSON-escaped in request payload" {
  stub_curl 200 "$(make_web_response)"
  local dangerous_query="'; rm -rf /; echo '"
  run bash "$SCRIPT" "$dangerous_query"
  [ "$status" -eq 0 ]
  # Read the captured request and verify the query was safely encoded
  local captured="$TEST_TMP/stubs/captured-request.json"
  [ -f "$captured" ]
  # jq must parse it successfully (injection would break JSON structure)
  local extracted
  extracted=$(jq -r '.messages[0].content' "$captured")
  [ "$extracted" = "$dangerous_query" ]
}

@test "19 double-quotes in query are JSON-escaped in request payload" {
  stub_curl 200 "$(make_web_response)"
  local quoted_query='what is "bash injection"'
  run bash "$SCRIPT" "$quoted_query"
  [ "$status" -eq 0 ]
  local captured="$TEST_TMP/stubs/captured-request.json"
  [ -f "$captured" ]
  local extracted
  extracted=$(jq -r '.messages[0].content' "$captured")
  [ "$extracted" = "$quoted_query" ]
}

# ---------------------------------------------------------------------------
# SECTION F: Tool shapes
# ---------------------------------------------------------------------------

@test "20 googleSearch shape produces tools array with googleSearch key" {
  stub_curl 200 "$(make_web_response)"
  AGENT_FLOW_WEB_SEARCH_TOOL_SHAPE="googleSearch" run bash "$SCRIPT" "test query"
  [ "$status" -eq 0 ]
  local captured="$TEST_TMP/stubs/captured-request.json"
  [ -f "$captured" ]
  # Must have tools array with googleSearch key
  local has_key
  has_key=$(jq '.tools[0] | has("googleSearch")' "$captured")
  [ "$has_key" = "true" ]
  # Must NOT have web_search_options
  local no_wso
  no_wso=$(jq 'has("web_search_options")' "$captured")
  [ "$no_wso" = "false" ]
}

@test "21 googleSearchRetrieval shape produces tools array with googleSearchRetrieval key" {
  stub_curl 200 "$(make_web_response)"
  AGENT_FLOW_WEB_SEARCH_TOOL_SHAPE="googleSearchRetrieval" run bash "$SCRIPT" "test query"
  [ "$status" -eq 0 ]
  local captured="$TEST_TMP/stubs/captured-request.json"
  [ -f "$captured" ]
  local has_key
  has_key=$(jq '.tools[0] | has("googleSearchRetrieval")' "$captured")
  [ "$has_key" = "true" ]
}

@test "22 web_search_options shape produces web_search_options key (no tools)" {
  stub_curl 200 "$(make_web_response)"
  AGENT_FLOW_WEB_SEARCH_TOOL_SHAPE="web_search_options" run bash "$SCRIPT" "test query"
  [ "$status" -eq 0 ]
  local captured="$TEST_TMP/stubs/captured-request.json"
  [ -f "$captured" ]
  # Must have web_search_options key
  local has_wso
  has_wso=$(jq 'has("web_search_options")' "$captured")
  [ "$has_wso" = "true" ]
  # Must NOT have tools key
  local no_tools
  no_tools=$(jq 'has("tools")' "$captured")
  [ "$no_tools" = "false" ]
  # search_context_size must be "medium"
  local ctx_size
  ctx_size=$(jq -r '.web_search_options.search_context_size' "$captured")
  [ "$ctx_size" = "medium" ]
}

@test "23 exits 1 on unknown AGENT_FLOW_WEB_SEARCH_TOOL_SHAPE" {
  AGENT_FLOW_WEB_SEARCH_TOOL_SHAPE="invalidShape" run bash "$SCRIPT" "test query"
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalidShape"* ]]
  [[ "$output" == *"Valid options"* ]]
}

# ---------------------------------------------------------------------------
# SECTION G: .env auto-load
# ---------------------------------------------------------------------------

@test "24 .env auto-load picks up AGENT_FLOW_WEB_SEARCH_ vars" {
  stub_curl 200 "$(make_web_response)"

  # Create a fake git repo root in TEST_TMP so git rev-parse --show-toplevel returns it
  local fake_root="$TEST_TMP/fakerepo"
  mkdir -p "$fake_root"
  git -C "$fake_root" init -q
  # Write .env with the API key
  printf 'AGENT_FLOW_WEB_SEARCH_API_KEY=env-file-key\n' > "$fake_root/.env"

  # Change GIT_CEILING_DIRECTORIES to allow discovery of this fake repo
  export GIT_CEILING_DIRECTORIES="${fake_root%/*}/.."
  cd "$fake_root"

  # Unset the API key so .env loading is required
  unset AGENT_FLOW_WEB_SEARCH_API_KEY
  unset ANTHROPIC_API_KEY

  run bash "$SCRIPT" "some query"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# SECTION H: Argument parsing edge cases
# ---------------------------------------------------------------------------

@test "25 exits 1 when query is empty string" {
  run bash "$SCRIPT" ""
  [ "$status" -eq 1 ]
  [[ "$output" == *"query is required"* ]]
}

@test "26 exits 1 when no arguments given" {
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"query is required"* ]]
}

@test "27 exits 1 on unknown flag" {
  run bash "$SCRIPT" --unknown-flag "some query"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown flag"* ]]
}

@test "28 exits 1 on unknown mode value" {
  run bash "$SCRIPT" --mode bogus "some query"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown mode"* ]]
}

@test "29 accepts --mode=answer (equals-sign syntax)" {
  stub_curl 200 "$(make_web_response)"
  run bash "$SCRIPT" --mode=answer "test query"
  [ "$status" -eq 0 ]
}

@test "30 search mode truncates to 10 citations max" {
  # Build response with 15 annotations
  local response
  response=$(jq -n '
    {
      choices: [{
        message: {
          content: "content",
          annotations: [
            range(15) | {
              type: "url_citation",
              url_citation: {
                title: ("Title " + (. | tostring)),
                url: ("https://example.com/" + (. | tostring))
              }
            }
          ]
        }
      }]
    }
  ')
  stub_curl 200 "$response"
  run bash "$SCRIPT" --mode search "test query"
  [ "$status" -eq 0 ]
  # Count lines starting with "- ["
  local count
  count=$(echo "$output" | grep -c '^- \[' || true)
  [ "$count" -le 10 ]
}

@test "31 exits 2 (not 1) when ENABLED unset even if TOOL_SHAPE is invalid" {
  unset AGENT_FLOW_WEB_SEARCH_ENABLED
  AGENT_FLOW_WEB_SEARCH_TOOL_SHAPE="badShape" run bash "$SCRIPT" "some query"
  [ "$status" -eq 2 ]
  [[ "$output" == *"disabled"* ]]
}

@test "32 .env auto-load works for ENABLED and MODEL when API_KEY already in shell" {
  stub_curl 200 "$(make_web_response)"

  local fake_root="$TEST_TMP/fakerepo2"
  mkdir -p "$fake_root"
  git -C "$fake_root" init -q
  # Put ENABLED and MODEL in .env
  printf 'AGENT_FLOW_WEB_SEARCH_ENABLED=true\nAGENT_FLOW_WEB_SEARCH_MODEL=gemini-from-env\n' > "$fake_root/.env"

  export GIT_CEILING_DIRECTORIES="${fake_root%/*}/.."
  cd "$fake_root"

  # Unset ENABLED and MODEL from env (they must come from .env)
  unset AGENT_FLOW_WEB_SEARCH_ENABLED
  unset AGENT_FLOW_WEB_SEARCH_MODEL
  # API_KEY is still set from setup() — that's fine

  run bash "$SCRIPT" "some query"
  [ "$status" -eq 0 ]
}
