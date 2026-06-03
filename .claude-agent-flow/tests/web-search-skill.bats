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

@test "01 disabled flag states exit 2 with disabled message" {
  local value
  for value in "__unset__" "false" "yes"; do
    if [[ "$value" == "__unset__" ]]; then
      unset AGENT_FLOW_WEB_SEARCH_ENABLED
    else
      export AGENT_FLOW_WEB_SEARCH_ENABLED="$value"
    fi
    run bash "$SCRIPT" "some query"
    [ "$status" -eq 2 ] || {
      echo "FAIL: ENABLED=$value expected status 2, got $status" >&2
      return 1
    }
    [[ "$output" == *"disabled"* ]] || {
      echo "FAIL: ENABLED=$value missing disabled message" >&2
      return 1
    }
  done
}

@test "02 activates when AGENT_FLOW_WEB_SEARCH_ENABLED=1" {
  stub_curl 200 "$(make_web_response)"
  AGENT_FLOW_WEB_SEARCH_ENABLED="1" run bash "$SCRIPT" "some query"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# SECTION B: Config validation (run with ENABLED=true)
# ---------------------------------------------------------------------------

@test "03 missing required config exits 3 with relevant variable name" {
  local scenario
  for scenario in "model" "base_url" "api_key"; do
    export AGENT_FLOW_WEB_SEARCH_MODEL="gemini-2.0-flash"
    export AGENT_FLOW_WEB_SEARCH_BASE_URL="https://api.example.com/v1"
    export AGENT_FLOW_WEB_SEARCH_API_KEY="test-api-key"
    unset ANTHROPIC_BASE_URL ANTHROPIC_API_KEY
    case "$scenario" in
      model) unset AGENT_FLOW_WEB_SEARCH_MODEL ;;
      base_url) unset AGENT_FLOW_WEB_SEARCH_BASE_URL ;;
      api_key) unset AGENT_FLOW_WEB_SEARCH_API_KEY ;;
    esac
    run bash "$SCRIPT" "some query"
    [ "$status" -eq 3 ] || {
      echo "FAIL: scenario=$scenario expected status 3, got $status" >&2
      return 1
    }
    case "$scenario" in
      model) [[ "$output" == *"AGENT_FLOW_WEB_SEARCH_MODEL"* ]] ;;
      base_url) [[ "$output" == *"AGENT_FLOW_WEB_SEARCH_BASE_URL"* || "$output" == *"ANTHROPIC_BASE_URL"* ]] ;;
      api_key) [[ "$output" == *"AGENT_FLOW_WEB_SEARCH_API_KEY"* || "$output" == *"ANTHROPIC_API_KEY"* ]] ;;
    esac || {
      echo "FAIL: scenario=$scenario missing relevant variable name" >&2
      return 1
    }
  done
}

@test "04 anthropic fallback env vars are accepted" {
  stub_curl 200 "$(make_web_response)"
  unset AGENT_FLOW_WEB_SEARCH_BASE_URL
  ANTHROPIC_BASE_URL="https://fallback.example.com/v1" run bash "$SCRIPT" "some query"
  [ "$status" -eq 0 ]

  stub_curl 200 "$(make_web_response)"
  export AGENT_FLOW_WEB_SEARCH_BASE_URL="https://api.example.com/v1"
  unset AGENT_FLOW_WEB_SEARCH_API_KEY
  ANTHROPIC_API_KEY="fallback-key" run bash "$SCRIPT" "some query"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# SECTION C: HTTP error handling
# ---------------------------------------------------------------------------

@test "05 exits 4 and surfaces error message on non-2xx response" {
  stub_curl 401 '{"error":{"message":"Unauthorized: invalid API key"}}'
  run bash "$SCRIPT" "some query"
  [ "$status" -eq 4 ]
  [[ "$output" == *"401"* ]]
  [[ "$output" == *"Unauthorized"* ]]
}

@test "06 exits 4 on 500 response with generic message when no error body" {
  stub_curl 500 '{}'
  run bash "$SCRIPT" "some query"
  [ "$status" -eq 4 ]
  [[ "$output" == *"500"* ]]
}

# ---------------------------------------------------------------------------
# SECTION D: Output modes (happy path)
# ---------------------------------------------------------------------------

@test "07 answer mode prints content and Sources section with annotations citations" {
  stub_curl 200 "$(make_web_response "My answer here" "Test Page" "https://test.example.com")"
  run bash "$SCRIPT" --mode answer "test query"
  [ "$status" -eq 0 ]
  [[ "$output" == *"My answer here"* ]]
  [[ "$output" == *"## Sources"* ]]
  [[ "$output" == *"Test Page"* ]]
  [[ "$output" == *"https://test.example.com"* ]]
}

@test "08 answer mode falls back to grounding_metadata when annotations empty" {
  stub_curl 200 "$(make_grounding_response "Grounded answer" "Grounding Title" "https://grounding.example.com")"
  run bash "$SCRIPT" --mode answer "test query"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Grounded answer"* ]]
  [[ "$output" == *"## Sources"* ]]
  [[ "$output" == *"Grounding Title"* ]]
  [[ "$output" == *"https://grounding.example.com"* ]]
}

@test "09 search mode prints only citations (no content)" {
  stub_curl 200 "$(make_web_response "Do not show this content" "Cite Title" "https://cite.example.com")"
  run bash "$SCRIPT" --mode search "test query"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Do not show this content"* ]]
  [[ "$output" == *"Cite Title"* ]]
  [[ "$output" == *"https://cite.example.com"* ]]
}

@test "10 search mode prints (no citations returned) when none present" {
  local empty_response
  empty_response=$(jq -n '{"choices":[{"message":{"content":"Answer only","annotations":[]}}]}')
  stub_curl 200 "$empty_response"
  run bash "$SCRIPT" --mode search "test query"
  [ "$status" -eq 0 ]
  [[ "$output" == *"(no citations returned)"* ]]
}

@test "11 raw mode prints pretty-printed JSON" {
  stub_curl 200 "$(make_web_response "raw content" "Raw Title" "https://raw.example.com")"
  run bash "$SCRIPT" --mode raw "test query"
  [ "$status" -eq 0 ]
  # Output must be valid JSON
  echo "$output" | jq '.' >/dev/null
  [[ "$output" == *"choices"* ]]
}

@test "12 default mode is answer when --mode not specified" {
  stub_curl 200 "$(make_web_response "Default mode content" "Default Title" "https://default.example.com")"
  run bash "$SCRIPT" "test query"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Default mode content"* ]]
  [[ "$output" == *"## Sources"* ]]
}

# ---------------------------------------------------------------------------
# SECTION E: Injection safety
# ---------------------------------------------------------------------------

@test "13 shell-sensitive queries are JSON-escaped in request payload" {
  local query
  for query in "'; rm -rf /; echo '" 'what is "bash injection"'; do
    stub_curl 200 "$(make_web_response)"
    run bash "$SCRIPT" "$query"
    [ "$status" -eq 0 ]
    local captured="$TEST_TMP/stubs/captured-request.json"
    [ -f "$captured" ]
    local extracted
    extracted=$(jq -r '.messages[0].content' "$captured")
    [ "$extracted" = "$query" ] || {
      echo "FAIL: query was not preserved: $query" >&2
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# SECTION F: Tool shapes
# ---------------------------------------------------------------------------

@test "14 supported tool shapes produce expected request keys" {
  local shape jq_expr
  for shape in "googleSearch:.tools[0] | has(\"googleSearch\")" \
               "googleSearchRetrieval:.tools[0] | has(\"googleSearchRetrieval\")" \
               "web_search_options:has(\"web_search_options\")"; do
    stub_curl 200 "$(make_web_response)"
    jq_expr="${shape#*:}"
    shape="${shape%%:*}"
    AGENT_FLOW_WEB_SEARCH_TOOL_SHAPE="$shape" run bash "$SCRIPT" "test query"
    [ "$status" -eq 0 ] || {
      echo "FAIL: shape=$shape expected success, got $status" >&2
      return 1
    }
    local captured="$TEST_TMP/stubs/captured-request.json"
    [ -f "$captured" ]
    [ "$(jq "$jq_expr" "$captured")" = "true" ] || {
      echo "FAIL: shape=$shape missing expected request key" >&2
      return 1
    }
  done
}

@test "15 exits 1 on unknown AGENT_FLOW_WEB_SEARCH_TOOL_SHAPE" {
  AGENT_FLOW_WEB_SEARCH_TOOL_SHAPE="invalidShape" run bash "$SCRIPT" "test query"
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalidShape"* ]]
  [[ "$output" == *"Valid options"* ]]
}

# ---------------------------------------------------------------------------
# SECTION G: .env auto-load
# ---------------------------------------------------------------------------

@test "16 .env auto-load picks up AGENT_FLOW_WEB_SEARCH_ vars" {
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

@test "17 argument parsing errors fail and equals-sign mode succeeds" {
  run bash "$SCRIPT" ""
  [ "$status" -eq 1 ]
  [[ "$output" == *"query is required"* ]]

  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"query is required"* ]]

  run bash "$SCRIPT" --unknown-flag "some query"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown flag"* ]]

  run bash "$SCRIPT" --mode bogus "some query"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown mode"* ]]

  stub_curl 200 "$(make_web_response)"
  run bash "$SCRIPT" --mode=answer "test query"
  [ "$status" -eq 0 ]
}

@test "18 search mode truncates to 10 citations max" {
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

@test "19 exits 2 (not 1) when ENABLED unset even if TOOL_SHAPE is invalid" {
  unset AGENT_FLOW_WEB_SEARCH_ENABLED
  AGENT_FLOW_WEB_SEARCH_TOOL_SHAPE="badShape" run bash "$SCRIPT" "some query"
  [ "$status" -eq 2 ]
  [[ "$output" == *"disabled"* ]]
}

@test "20 .env auto-load works for ENABLED and MODEL when API_KEY already in shell" {
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
