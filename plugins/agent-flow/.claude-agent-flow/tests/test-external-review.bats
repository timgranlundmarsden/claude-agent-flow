#!/usr/bin/env bats
# Tests for external-review.sh
# Run with: bats test-external-review.bats

TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
SCRIPT="$PROJECT_ROOT/.claude/skills/external-code-review/external-review.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

setup() {
  # Save original PATH so teardown can restore it
  export ORIG_PATH="$PATH"

  # Create a fresh temp directory for each test
  TEST_TMP=$(mktemp -d)

  # A minimal diff file
  DIFF_FILE="$TEST_TMP/test.diff"
  printf -- '--- a/foo.py\n+++ b/foo.py\n@@ -1,3 +1,4 @@\n def bar():\n-    pass\n+    return 1\n' > "$DIFF_FILE"

  # A minimal system prompt file
  SYSTEM_PROMPT="$TEST_TMP/system-prompt.md"
  printf 'You are a code reviewer.\n' > "$SYSTEM_PROMPT"

  # Prevent .env auto-load: the script uses git rev-parse --show-toplevel to find
  # .env, which would re-set env vars that tests intentionally unset. Running
  # from $TEST_TMP with GIT_CEILING_DIRECTORIES stops git from discovering the
  # repo's .env file.
  export GIT_CEILING_DIRECTORIES="${TEST_TMP%/*}"
  cd "$TEST_TMP"

  # Valid-looking env vars (no real API calls in most tests — curl is stubbed)
  export EXTERNAL_REVIEW_API_KEY="test-api-key"
  export EXTERNAL_REVIEW_MODEL="openai/gpt-4o"
  export EXTERNAL_REVIEW_API_BASE_URL="https://api.example.com/v1"
}

teardown() {
  cd "$BATS_TEST_DIRNAME"
  rm -rf "$TEST_TMP"
  unset EXTERNAL_REVIEW_API_KEY EXTERNAL_REVIEW_MODEL EXTERNAL_REVIEW_API_BASE_URL GIT_CEILING_DIRECTORIES
  export PATH="$ORIG_PATH"
}

# Stub curl to return a given HTTP code and body without hitting the network.
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
# Minimal curl stub — parse -o and -w from args
output_file=""
write_out=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) output_file="\$2"; shift 2 ;;
    -w) write_out="\$2"; shift 2 ;;
    *)  shift ;;
  esac
done
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

# Build a valid API response JSON wrapping a review object.
make_api_response() {
  local verdict="${1:-PASS}"
  local summary="${2:-Looks good}"
  local inner
  inner=$(printf '{"verdict":"%s","summary":"%s","concerns":[]}' "$verdict" "$summary")
  # The API wraps content as a JSON string
  local escaped
  escaped=$(printf '%s' "$inner" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
  printf '{"choices":[{"message":{"content":%s}}]}' "$escaped"
}

# ---------------------------------------------------------------------------
# SECTION A: Argument parsing — missing / unknown args
# ---------------------------------------------------------------------------

@test "exits 1 when --diff-file is missing" {
  run bash "$SCRIPT" --system-prompt "$SYSTEM_PROMPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--diff-file is required"* ]]
}

@test "exits 1 when --diff-file path does not exist" {
  run bash "$SCRIPT" --diff-file /nonexistent/path.diff --system-prompt "$SYSTEM_PROMPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"diff file not found"* ]]
}

@test "exits 1 on unknown argument" {
  run bash "$SCRIPT" --diff-file "$DIFF_FILE" --system-prompt "$SYSTEM_PROMPT" --unknown-flag
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown argument"* ]]
}

@test "exits 1 when --user-prompt path does not exist" {
  stub_curl 200 "$(make_api_response PASS 'ok')"
  run bash "$SCRIPT" \
    --diff-file "$DIFF_FILE" \
    --system-prompt "$SYSTEM_PROMPT" \
    --user-prompt /nonexistent/prompt.txt
  [ "$status" -eq 1 ]
  [[ "$output" == *"user prompt file not found"* ]]
}

@test "exits 1 when --system-prompt path does not exist" {
  run bash "$SCRIPT" --diff-file "$DIFF_FILE" --system-prompt /nonexistent/system.md
  [ "$status" -eq 1 ]
  [[ "$output" == *"system prompt file not found"* ]]
}

# ---------------------------------------------------------------------------
# SECTION B: Environment variable validation
# ---------------------------------------------------------------------------

@test "exits 1 when EXTERNAL_REVIEW_API_KEY is unset" {
  unset EXTERNAL_REVIEW_API_KEY
  run bash "$SCRIPT" --diff-file "$DIFF_FILE" --system-prompt "$SYSTEM_PROMPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"EXTERNAL_REVIEW_API_KEY"* ]]
}

@test "exits 1 when EXTERNAL_REVIEW_API_KEY is empty string" {
  EXTERNAL_REVIEW_API_KEY="" run bash "$SCRIPT" --diff-file "$DIFF_FILE" --system-prompt "$SYSTEM_PROMPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"EXTERNAL_REVIEW_API_KEY"* ]]
}

@test "exits 1 when EXTERNAL_REVIEW_MODEL is unset" {
  unset EXTERNAL_REVIEW_MODEL
  run bash "$SCRIPT" --diff-file "$DIFF_FILE" --system-prompt "$SYSTEM_PROMPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"EXTERNAL_REVIEW_MODEL"* ]]
}

@test "exits 1 when EXTERNAL_REVIEW_MODEL is empty string" {
  EXTERNAL_REVIEW_MODEL="" run bash "$SCRIPT" --diff-file "$DIFF_FILE" --system-prompt "$SYSTEM_PROMPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"EXTERNAL_REVIEW_MODEL"* ]]
}

@test "exits 1 when EXTERNAL_REVIEW_API_BASE_URL is unset" {
  unset EXTERNAL_REVIEW_API_BASE_URL
  run bash "$SCRIPT" --diff-file "$DIFF_FILE" --system-prompt "$SYSTEM_PROMPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"EXTERNAL_REVIEW_API_BASE_URL"* ]]
}

@test "exits 1 when EXTERNAL_REVIEW_API_BASE_URL is empty string" {
  EXTERNAL_REVIEW_API_BASE_URL="" run bash "$SCRIPT" --diff-file "$DIFF_FILE" --system-prompt "$SYSTEM_PROMPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"EXTERNAL_REVIEW_API_BASE_URL"* ]]
}

# ---------------------------------------------------------------------------
# SECTION C: HTTP error handling
# ---------------------------------------------------------------------------

@test "exits 1 and prints HTTP code on non-200 response" {
  stub_curl 401 '{"error":"Unauthorized"}'
  run bash "$SCRIPT" --diff-file "$DIFF_FILE" --system-prompt "$SYSTEM_PROMPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"401"* ]]
}

@test "exits 1 on 500 response" {
  stub_curl 500 '{"error":"Internal Server Error"}'
  run bash "$SCRIPT" --diff-file "$DIFF_FILE" --system-prompt "$SYSTEM_PROMPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"500"* ]]
}

@test "exits 1 on 422 response" {
  stub_curl 422 '{"error":"Unprocessable Entity"}'
  run bash "$SCRIPT" --diff-file "$DIFF_FILE" --system-prompt "$SYSTEM_PROMPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"422"* ]]
}

# ---------------------------------------------------------------------------
# SECTION D: Happy path — stage-1 parsing (clean JSON content)
# ---------------------------------------------------------------------------

@test "succeeds and outputs PASS JSON when API returns clean JSON content" {
  stub_curl 200 "$(make_api_response PASS 'All good')"
  run bash "$SCRIPT" --diff-file "$DIFF_FILE" --system-prompt "$SYSTEM_PROMPT"
  [ "$status" -eq 0 ]
  # stdout must be valid JSON with verdict
  echo "$output" | python3 -c 'import sys,json; obj=json.load(sys.stdin); assert obj["verdict"]=="PASS"'
}

@test "succeeds and outputs FAIL JSON with concerns" {
  local inner='{"verdict":"FAIL","summary":"Bad code","concerns":[{"file":"foo.py","line":3,"severity":"error","message":"Missing return"}]}'
  local escaped
  escaped=$(printf '%s' "$inner" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
  local body
  body=$(printf '{"choices":[{"message":{"content":%s}}]}' "$escaped")
  stub_curl 200 "$body"
  run bash "$SCRIPT" --diff-file "$DIFF_FILE" --system-prompt "$SYSTEM_PROMPT"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c 'import sys,json; obj=json.load(sys.stdin); assert obj["verdict"]=="FAIL"; assert len(obj["concerns"])==1'
}

@test "succeeds and outputs WARN JSON" {
  # Must include a warning concern — verdict is recalculated from concern severities
  local inner='{"verdict":"WARN","summary":"Minor issues","concerns":[{"file":"foo.py","line":1,"severity":"warning","message":"unused var"}]}'
  local escaped
  escaped=$(printf '%s' "$inner" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
  local body
  body=$(printf '{"choices":[{"message":{"content":%s}}]}' "$escaped")
  stub_curl 200 "$body"
  run bash "$SCRIPT" --diff-file "$DIFF_FILE" --system-prompt "$SYSTEM_PROMPT"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c 'import sys,json; obj=json.load(sys.stdin); assert obj["verdict"]=="WARN"'
}

@test "outputs only JSON on stdout (no extra text)" {
  stub_curl 200 "$(make_api_response PASS 'ok')"
  run bash "$SCRIPT" --diff-file "$DIFF_FILE" --system-prompt "$SYSTEM_PROMPT"
  [ "$status" -eq 0 ]
  # The entire stdout must be parseable as JSON
  echo "$output" | python3 -c 'import sys,json; json.load(sys.stdin)'
}

# ---------------------------------------------------------------------------
# SECTION E: Happy path — stage-2 parsing (Python brace parser)
# ---------------------------------------------------------------------------

@test "succeeds via stage-2 when content is wrapped in markdown fences" {
  # Simulate model wrapping JSON in ```json ... ``` fences
  local inner='{"verdict":"PASS","summary":"Looks fine","concerns":[]}'
  local wrapped
  wrapped=$(printf '```json\n%s\n```' "$inner")
  local escaped
  escaped=$(printf '%s' "$wrapped" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
  local body
  body=$(printf '{"choices":[{"message":{"content":%s}}]}' "$escaped")
  stub_curl 200 "$body"
  run bash "$SCRIPT" --diff-file "$DIFF_FILE" --system-prompt "$SYSTEM_PROMPT"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c 'import sys,json; obj=json.load(sys.stdin); assert obj["verdict"]=="PASS"'
}

@test "succeeds via stage-2 when content has preamble text before JSON" {
  local inner='{"verdict":"WARN","summary":"Check this","concerns":[{"file":"bar.py","line":2,"severity":"warning","message":"consider renaming"}]}'
  local wrapped
  wrapped=$(printf 'Here is my review:\n\n%s' "$inner")
  local escaped
  escaped=$(printf '%s' "$wrapped" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
  local body
  body=$(printf '{"choices":[{"message":{"content":%s}}]}' "$escaped")
  stub_curl 200 "$body"
  run bash "$SCRIPT" --diff-file "$DIFF_FILE" --system-prompt "$SYSTEM_PROMPT"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c 'import sys,json; obj=json.load(sys.stdin); assert obj["verdict"]=="WARN"'
}

@test "succeeds via stage-2 when content has nested JSON objects inside concerns" {
  local inner='{"verdict":"FAIL","summary":"Issues found","concerns":[{"file":"src/main.py","line":10,"severity":"error","message":"Null pointer"}]}'
  local wrapped
  wrapped=$(printf 'Review result:\n%s\n\nPlease address.' "$inner")
  local escaped
  escaped=$(printf '%s' "$wrapped" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
  local body
  body=$(printf '{"choices":[{"message":{"content":%s}}]}' "$escaped")
  stub_curl 200 "$body"
  run bash "$SCRIPT" --diff-file "$DIFF_FILE" --system-prompt "$SYSTEM_PROMPT"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c 'import sys,json; obj=json.load(sys.stdin); assert obj["verdict"]=="FAIL"'
}

# ---------------------------------------------------------------------------
# SECTION F: Parse failure
# ---------------------------------------------------------------------------

@test "exits 1 when API response has no choices" {
  stub_curl 200 '{"error":"no choices"}'
  run bash "$SCRIPT" --diff-file "$DIFF_FILE" --system-prompt "$SYSTEM_PROMPT"
  [ "$status" -eq 1 ]
}

@test "exits 1 when message content is not valid JSON and no brace block found" {
  local escaped
  escaped=$(python3 -c 'import json; print(json.dumps("this is just plain text with no JSON at all"))')
  local body
  body=$(printf '{"choices":[{"message":{"content":%s}}]}' "$escaped")
  stub_curl 200 "$body"
  run bash "$SCRIPT" --diff-file "$DIFF_FILE" --system-prompt "$SYSTEM_PROMPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"failed to parse"* ]] || [[ "$output" == *"no valid JSON"* ]]
}

@test "exits 1 when JSON content is missing verdict field" {
  local inner='{"summary":"ok","concerns":[]}'
  local escaped
  escaped=$(printf '%s' "$inner" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
  local body
  body=$(printf '{"choices":[{"message":{"content":%s}}]}' "$escaped")
  stub_curl 200 "$body"
  run bash "$SCRIPT" --diff-file "$DIFF_FILE" --system-prompt "$SYSTEM_PROMPT"
  [ "$status" -eq 1 ]
}

@test "exits 1 when JSON content is missing concerns field" {
  local inner='{"verdict":"PASS","summary":"ok"}'
  local escaped
  escaped=$(printf '%s' "$inner" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
  local body
  body=$(printf '{"choices":[{"message":{"content":%s}}]}' "$escaped")
  stub_curl 200 "$body"
  run bash "$SCRIPT" --diff-file "$DIFF_FILE" --system-prompt "$SYSTEM_PROMPT"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# SECTION G: User prompt construction
# ---------------------------------------------------------------------------

@test "constructed user prompt contains diff content" {
  # Use a custom diff with unique marker text
  local marker="UNIQUEMARKERDIFF12345"
  printf -- '--- a/x.py\n+++ b/x.py\n@@ -1 +1 @@\n-%s\n+newline\n' "$marker" > "$TEST_TMP/marked.diff"

  # Intercept the request file to inspect it before the curl stub responds
  local stub_dir="$TEST_TMP/stubs2"
  mkdir -p "$stub_dir"
  local response_body
  response_body=$(make_api_response PASS ok)
  # Capture request JSON to a known path then return success
  cat > "$stub_dir/curl" <<STUB
#!/usr/bin/env bash
output_file=""
write_out=""
data_file=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) output_file="\$2"; shift 2 ;;
    -w) write_out="\$2"; shift 2 ;;
    -d) data_file="\${2#@}"; shift 2 ;;
    *)  shift ;;
  esac
done
if [[ -n "\$output_file" ]]; then
  printf '%s' '$response_body' > "\$output_file"
fi
if [[ -n "\$data_file" ]]; then
  cp "\$data_file" "$TEST_TMP/captured-request.json"
fi
if [[ "\$write_out" == "%{http_code}" ]]; then
  printf '200'
fi
STUB
  chmod +x "$stub_dir/curl"
  export PATH="$stub_dir:$PATH"

  run bash "$SCRIPT" \
    --diff-file "$TEST_TMP/marked.diff" \
    --system-prompt "$SYSTEM_PROMPT"
  [ "$status" -eq 0 ]

  # The request JSON must contain the marker in the user message
  python3 -c "
import json, sys
with open('$TEST_TMP/captured-request.json') as f:
    req = json.load(f)
user_content = req['messages'][1]['content']
assert '$marker' in user_content, f'marker not found in user content: {user_content[:200]}'
"
}

@test "explicit --user-prompt file is used verbatim" {
  local custom_prompt="$TEST_TMP/custom.txt"
  printf 'CUSTOM_PROMPT_CONTENT_9999' > "$custom_prompt"

  local stub_dir="$TEST_TMP/stubs3"
  mkdir -p "$stub_dir"
  local response_body
  response_body=$(make_api_response PASS ok)
  cat > "$stub_dir/curl" <<STUB
#!/usr/bin/env bash
output_file=""
write_out=""
data_file=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) output_file="\$2"; shift 2 ;;
    -w) write_out="\$2"; shift 2 ;;
    -d) data_file="\${2#@}"; shift 2 ;;
    *)  shift ;;
  esac
done
if [[ -n "\$output_file" ]]; then
  printf '%s' '$response_body' > "\$output_file"
fi
if [[ -n "\$data_file" ]]; then
  cp "\$data_file" "$TEST_TMP/captured-request2.json"
fi
if [[ "\$write_out" == "%{http_code}" ]]; then
  printf '200'
fi
STUB
  chmod +x "$stub_dir/curl"
  export PATH="$stub_dir:$PATH"

  run bash "$SCRIPT" \
    --diff-file "$DIFF_FILE" \
    --system-prompt "$SYSTEM_PROMPT" \
    --user-prompt "$custom_prompt"
  [ "$status" -eq 0 ]

  python3 -c "
import json
with open('$TEST_TMP/captured-request2.json') as f:
    req = json.load(f)
user_content = req['messages'][1]['content']
assert 'CUSTOM_PROMPT_CONTENT_9999' in user_content, f'custom prompt not found: {user_content[:200]}'
"
}

# ---------------------------------------------------------------------------
# SECTION H: Request JSON structure
# ---------------------------------------------------------------------------

@test "request JSON includes correct model from EXTERNAL_REVIEW_MODEL env var" {
  local stub_dir="$TEST_TMP/stubs4"
  mkdir -p "$stub_dir"
  local response_body
  response_body=$(make_api_response PASS ok)
  export EXTERNAL_REVIEW_MODEL="anthropic/claude-3-5-sonnet"
  cat > "$stub_dir/curl" <<STUB
#!/usr/bin/env bash
output_file=""; write_out=""; data_file=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) output_file="\$2"; shift 2 ;;
    -w) write_out="\$2"; shift 2 ;;
    -d) data_file="\${2#@}"; shift 2 ;;
    *)  shift ;;
  esac
done
[[ -n "\$output_file" ]] && printf '%s' '$response_body' > "\$output_file"
[[ -n "\$data_file" ]]   && cp "\$data_file" "$TEST_TMP/captured-request4.json"
[[ "\$write_out" == "%{http_code}" ]] && printf '200'
STUB
  chmod +x "$stub_dir/curl"
  export PATH="$stub_dir:$PATH"

  run bash "$SCRIPT" --diff-file "$DIFF_FILE" --system-prompt "$SYSTEM_PROMPT"
  [ "$status" -eq 0 ]

  python3 -c "
import json
with open('$TEST_TMP/captured-request4.json') as f:
    req = json.load(f)
assert req['model'] == 'anthropic/claude-3-5-sonnet', f'wrong model: {req[\"model\"]}'
assert req['response_format']['type'] == 'json_schema'
assert req['response_format']['json_schema']['name'] == 'pr_review'
assert req['response_format']['json_schema']['strict'] == True
schema = req['response_format']['json_schema']['schema']
assert set(schema['required']) == {'verdict', 'summary', 'concerns'}
assert schema['additionalProperties'] == False
"
}

@test "request JSON messages array has system then user roles" {
  local stub_dir="$TEST_TMP/stubs5"
  mkdir -p "$stub_dir"
  local response_body
  response_body=$(make_api_response PASS ok)
  cat > "$stub_dir/curl" <<STUB
#!/usr/bin/env bash
output_file=""; write_out=""; data_file=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) output_file="\$2"; shift 2 ;;
    -w) write_out="\$2"; shift 2 ;;
    -d) data_file="\${2#@}"; shift 2 ;;
    *)  shift ;;
  esac
done
[[ -n "\$output_file" ]] && printf '%s' '$response_body' > "\$output_file"
[[ -n "\$data_file" ]]   && cp "\$data_file" "$TEST_TMP/captured-request5.json"
[[ "\$write_out" == "%{http_code}" ]] && printf '200'
STUB
  chmod +x "$stub_dir/curl"
  export PATH="$stub_dir:$PATH"

  run bash "$SCRIPT" --diff-file "$DIFF_FILE" --system-prompt "$SYSTEM_PROMPT"
  [ "$status" -eq 0 ]

  python3 -c "
import json
with open('$TEST_TMP/captured-request5.json') as f:
    req = json.load(f)
msgs = req['messages']
assert len(msgs) == 2, f'expected 2 messages, got {len(msgs)}'
assert msgs[0]['role'] == 'system'
assert msgs[1]['role'] == 'user'
assert 'You are a code reviewer' in msgs[0]['content']
"
}

# ---------------------------------------------------------------------------
# SECTION I: --repo-name flag
# ---------------------------------------------------------------------------

@test "--repo-name is reflected in HTTP-Referer header" {
  local stub_dir="$TEST_TMP/stubs6"
  mkdir -p "$stub_dir"
  local response_body
  response_body=$(make_api_response PASS ok)
  cat > "$stub_dir/curl" <<STUB
#!/usr/bin/env bash
# Save all args to inspect header
printf '%s\n' "\$@" > "$TEST_TMP/curl-args.txt"
output_file=""; write_out=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) output_file="\$2"; shift 2 ;;
    -w) write_out="\$2"; shift 2 ;;
    *)  shift ;;
  esac
done
[[ -n "\$output_file" ]] && printf '%s' '$response_body' > "\$output_file"
[[ "\$write_out" == "%{http_code}" ]] && printf '200'
STUB
  chmod +x "$stub_dir/curl"
  export PATH="$stub_dir:$PATH"

  run bash "$SCRIPT" \
    --diff-file "$DIFF_FILE" \
    --system-prompt "$SYSTEM_PROMPT" \
    --repo-name "myorg/myrepo"
  [ "$status" -eq 0 ]

  grep -q "myorg/myrepo" "$TEST_TMP/curl-args.txt"
}

@test "omitting --repo-name uses 'unknown' in HTTP-Referer" {
  local stub_dir="$TEST_TMP/stubs7"
  mkdir -p "$stub_dir"
  local response_body
  response_body=$(make_api_response PASS ok)
  cat > "$stub_dir/curl" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TEST_TMP/curl-args7.txt"
output_file=""; write_out=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) output_file="\$2"; shift 2 ;;
    -w) write_out="\$2"; shift 2 ;;
    *)  shift ;;
  esac
done
[[ -n "\$output_file" ]] && printf '%s' '$response_body' > "\$output_file"
[[ "\$write_out" == "%{http_code}" ]] && printf '200'
STUB
  chmod +x "$stub_dir/curl"
  export PATH="$stub_dir:$PATH"

  run bash "$SCRIPT" --diff-file "$DIFF_FILE" --system-prompt "$SYSTEM_PROMPT"
  [ "$status" -eq 0 ]

  grep -q "unknown" "$TEST_TMP/curl-args7.txt"
}

# ---------------------------------------------------------------------------
# SECTION J: Error messages go to stderr, not stdout
# ---------------------------------------------------------------------------

@test "error for missing --diff-file goes to stderr not stdout" {
  run --separate-stderr bash "$SCRIPT" --system-prompt "$SYSTEM_PROMPT"
  [ "$status" -eq 1 ]
  # stdout should be empty
  [ -z "$output" ]
}

@test "error for missing EXTERNAL_REVIEW_API_KEY goes to stderr not stdout" {
  unset EXTERNAL_REVIEW_API_KEY
  run --separate-stderr bash "$SCRIPT" --diff-file "$DIFF_FILE" --system-prompt "$SYSTEM_PROMPT"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "HTTP error message goes to stderr not stdout" {
  stub_curl 401 '{"error":"bad key"}'
  run --separate-stderr bash "$SCRIPT" --diff-file "$DIFF_FILE" --system-prompt "$SYSTEM_PROMPT"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# SECTION K: Edge cases
# ---------------------------------------------------------------------------

@test "handles diff file with special characters and backticks" {
  printf -- '--- a/a.sh\n+++ b/a.sh\n@@ -1 +1 @@\n-echo `date`\n+echo $(date)\n' \
    > "$TEST_TMP/special.diff"
  stub_curl 200 "$(make_api_response PASS 'ok')"
  run bash "$SCRIPT" --diff-file "$TEST_TMP/special.diff" --system-prompt "$SYSTEM_PROMPT"
  [ "$status" -eq 0 ]
}

@test "handles empty diff file" {
  printf '' > "$TEST_TMP/empty.diff"
  stub_curl 200 "$(make_api_response PASS 'nothing to review')"
  run bash "$SCRIPT" --diff-file "$TEST_TMP/empty.diff" --system-prompt "$SYSTEM_PROMPT"
  [ "$status" -eq 0 ]
}

@test "handles diff with double-quote characters" {
  printf -- '--- a/cfg.json\n+++ b/cfg.json\n@@ -1 +1 @@\n-{"key":"old"}\n+{"key":"new"}\n' \
    > "$TEST_TMP/quotes.diff"
  stub_curl 200 "$(make_api_response PASS 'ok')"
  run bash "$SCRIPT" --diff-file "$TEST_TMP/quotes.diff" --system-prompt "$SYSTEM_PROMPT"
  [ "$status" -eq 0 ]
}

@test "handles API response with multiple JSON objects in content — picks the right one" {
  # Content has a small JSON snippet first, then the real review JSON
  local preamble='{"status":"ok"}'
  local real='{"verdict":"PASS","summary":"All clear","concerns":[]}'
  local combined
  combined=$(printf 'First: %s\nThen: %s' "$preamble" "$real")
  local escaped
  escaped=$(printf '%s' "$combined" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
  local body
  body=$(printf '{"choices":[{"message":{"content":%s}}]}' "$escaped")
  stub_curl 200 "$body"
  run bash "$SCRIPT" --diff-file "$DIFF_FILE" --system-prompt "$SYSTEM_PROMPT"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c 'import sys,json; obj=json.load(sys.stdin); assert obj["verdict"]=="PASS"; assert "summary" in obj'
}

@test "handles system prompt with special characters" {
  printf 'Review carefully.\n\nKey rule: check for "issues" & <edge-cases>.\n' \
    > "$TEST_TMP/special-system.md"
  stub_curl 200 "$(make_api_response PASS 'ok')"
  run bash "$SCRIPT" --diff-file "$DIFF_FILE" --system-prompt "$TEST_TMP/special-system.md"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# SECTION L: Pre-LLM suppression context injection
# ---------------------------------------------------------------------------

@test "suppress config entries are injected into user prompt" {
  # Create a suppress config
  cat > "$TEST_TMP/suppress.yml" <<'SYML'
suppress:
  - file: "src/main.py"
    keyword: "hardcoded"
    reason: "Known test fixture"
SYML

  local stub_dir="$TEST_TMP/stubs-suppress1"
  mkdir -p "$stub_dir"
  local response_body
  response_body=$(make_api_response PASS ok)
  cat > "$stub_dir/curl" <<STUB
#!/usr/bin/env bash
output_file=""; write_out=""; data_file=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) output_file="\$2"; shift 2 ;;
    -w) write_out="\$2"; shift 2 ;;
    -d) data_file="\${2#@}"; shift 2 ;;
    *)  shift ;;
  esac
done
[[ -n "\$output_file" ]] && printf '%s' '$response_body' > "\$output_file"
[[ -n "\$data_file" ]]   && cp "\$data_file" "$TEST_TMP/captured-suppress1.json"
[[ "\$write_out" == "%{http_code}" ]] && printf '200'
STUB
  chmod +x "$stub_dir/curl"
  export PATH="$stub_dir:$PATH"

  run bash "$SCRIPT" \
    --diff-file "$DIFF_FILE" \
    --system-prompt "$SYSTEM_PROMPT" \
    --suppress-config "$TEST_TMP/suppress.yml"
  [ "$status" -eq 0 ]

  python3 -c "
import json
with open('$TEST_TMP/captured-suppress1.json') as f:
    req = json.load(f)
user_content = req['messages'][1]['content']
assert 'Suppressed concerns' in user_content, f'missing suppress header in: {user_content[:300]}'
assert 'src/main.py' in user_content, f'missing file path in: {user_content[:300]}'
assert 'hardcoded' in user_content, f'missing keyword in: {user_content[:300]}'
"
}

@test "multiple suppress configs are merged into user prompt" {
  cat > "$TEST_TMP/suppress-a.yml" <<'SYML'
suppress:
  - file: "src/a.py"
    keyword: "alpha"
    reason: "reason-a"
SYML
  cat > "$TEST_TMP/suppress-b.yml" <<'SYML'
suppress:
  - file: "src/b.py"
    keyword: "beta"
    reason: "reason-b"
SYML

  local stub_dir="$TEST_TMP/stubs-suppress2"
  mkdir -p "$stub_dir"
  local response_body
  response_body=$(make_api_response PASS ok)
  cat > "$stub_dir/curl" <<STUB
#!/usr/bin/env bash
output_file=""; write_out=""; data_file=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) output_file="\$2"; shift 2 ;;
    -w) write_out="\$2"; shift 2 ;;
    -d) data_file="\${2#@}"; shift 2 ;;
    *)  shift ;;
  esac
done
[[ -n "\$output_file" ]] && printf '%s' '$response_body' > "\$output_file"
[[ -n "\$data_file" ]]   && cp "\$data_file" "$TEST_TMP/captured-suppress2.json"
[[ "\$write_out" == "%{http_code}" ]] && printf '200'
STUB
  chmod +x "$stub_dir/curl"
  export PATH="$stub_dir:$PATH"

  run bash "$SCRIPT" \
    --diff-file "$DIFF_FILE" \
    --system-prompt "$SYSTEM_PROMPT" \
    --suppress-config "$TEST_TMP/suppress-a.yml" \
    --suppress-config "$TEST_TMP/suppress-b.yml"
  [ "$status" -eq 0 ]

  python3 -c "
import json
with open('$TEST_TMP/captured-suppress2.json') as f:
    req = json.load(f)
user_content = req['messages'][1]['content']
assert 'src/a.py' in user_content, 'missing file from config a'
assert 'alpha' in user_content, 'missing keyword from config a'
assert 'src/b.py' in user_content, 'missing file from config b'
assert 'beta' in user_content, 'missing keyword from config b'
"
}

@test "missing suppress config file is silently skipped" {
  stub_curl 200 "$(make_api_response PASS ok)"
  run bash "$SCRIPT" \
    --diff-file "$DIFF_FILE" \
    --system-prompt "$SYSTEM_PROMPT" \
    --suppress-config "/nonexistent/suppress.yml"
  [ "$status" -eq 0 ]
}

@test "suppress context appended to --user-prompt copy, original unchanged" {
  local custom_prompt="$TEST_TMP/original-prompt.txt"
  printf 'MY_ORIGINAL_PROMPT_CONTENT' > "$custom_prompt"
  local original_hash
  original_hash=$(md5 -q "$custom_prompt" 2>/dev/null || md5sum "$custom_prompt" | cut -d' ' -f1)

  cat > "$TEST_TMP/suppress-orig.yml" <<'SYML'
suppress:
  - file: "foo.py"
    keyword: "inject-test"
    reason: "testing"
SYML

  local stub_dir="$TEST_TMP/stubs-suppress-orig"
  mkdir -p "$stub_dir"
  local response_body
  response_body=$(make_api_response PASS ok)
  cat > "$stub_dir/curl" <<STUB
#!/usr/bin/env bash
output_file=""; write_out=""; data_file=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) output_file="\$2"; shift 2 ;;
    -w) write_out="\$2"; shift 2 ;;
    -d) data_file="\${2#@}"; shift 2 ;;
    *)  shift ;;
  esac
done
[[ -n "\$output_file" ]] && printf '%s' '$response_body' > "\$output_file"
[[ -n "\$data_file" ]]   && cp "\$data_file" "$TEST_TMP/captured-suppress-orig.json"
[[ "\$write_out" == "%{http_code}" ]] && printf '200'
STUB
  chmod +x "$stub_dir/curl"
  export PATH="$stub_dir:$PATH"

  run bash "$SCRIPT" \
    --diff-file "$DIFF_FILE" \
    --system-prompt "$SYSTEM_PROMPT" \
    --user-prompt "$custom_prompt" \
    --suppress-config "$TEST_TMP/suppress-orig.yml"
  [ "$status" -eq 0 ]

  # Original file must be unchanged
  local after_hash
  after_hash=$(md5 -q "$custom_prompt" 2>/dev/null || md5sum "$custom_prompt" | cut -d' ' -f1)
  [ "$original_hash" = "$after_hash" ]

  # Request must contain both the original prompt and suppress context
  python3 -c "
import json
with open('$TEST_TMP/captured-suppress-orig.json') as f:
    req = json.load(f)
user_content = req['messages'][1]['content']
assert 'MY_ORIGINAL_PROMPT_CONTENT' in user_content, 'missing original prompt content'
assert 'Suppressed concerns' in user_content, 'missing suppress context'
assert 'inject-test' in user_content, 'missing suppress keyword'
"
}

# ---------------------------------------------------------------------------
# SECTION M: Post-LLM suppression and verdict recalculation
# ---------------------------------------------------------------------------

@test "post-LLM suppression marks matching concerns and recalculates verdict" {
  cat > "$TEST_TMP/suppress-post.yml" <<'SYML'
suppress:
  - file: "src/main.py"
    keyword: "hardcoded credentials"
    reason: "Known test fixture"
SYML

  local inner='{"verdict":"FAIL","summary":"Issues","concerns":[{"file":"src/main.py","line":10,"severity":"error","message":"hardcoded credentials found"}]}'
  local escaped
  escaped=$(printf '%s' "$inner" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
  local body
  body=$(printf '{"choices":[{"message":{"content":%s}}]}' "$escaped")
  stub_curl 200 "$body"

  run bash "$SCRIPT" \
    --diff-file "$DIFF_FILE" \
    --system-prompt "$SYSTEM_PROMPT" \
    --suppress-config "$TEST_TMP/suppress-post.yml"
  [ "$status" -eq 0 ]

  printf '%s' "$output" > "$TEST_TMP/result-post.json"
  python3 -c "
import json
with open('$TEST_TMP/result-post.json') as f:
    obj = json.load(f)
assert obj['verdict'] == 'PASS', f'expected PASS, got {obj[\"verdict\"]}'
assert obj['concerns'][0]['suppressed'] == True
assert obj['concerns'][0]['suppress_reason'] == 'Known test fixture'
"
}

@test "non-matching concerns are not suppressed" {
  cat > "$TEST_TMP/suppress-nomatch.yml" <<'SYML'
suppress:
  - file: "other/file.py"
    keyword: "unrelated"
    reason: "Not relevant"
SYML

  local inner='{"verdict":"FAIL","summary":"Issues","concerns":[{"file":"src/main.py","line":10,"severity":"error","message":"hardcoded credentials found"}]}'
  local escaped
  escaped=$(printf '%s' "$inner" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
  local body
  body=$(printf '{"choices":[{"message":{"content":%s}}]}' "$escaped")
  stub_curl 200 "$body"

  run bash "$SCRIPT" \
    --diff-file "$DIFF_FILE" \
    --system-prompt "$SYSTEM_PROMPT" \
    --suppress-config "$TEST_TMP/suppress-nomatch.yml"
  [ "$status" -eq 0 ]

  printf '%s' "$output" > "$TEST_TMP/result-nomatch.json"
  python3 -c "
import json
with open('$TEST_TMP/result-nomatch.json') as f:
    obj = json.load(f)
assert obj['verdict'] == 'FAIL', f'expected FAIL, got {obj[\"verdict\"]}'
assert 'suppressed' not in obj['concerns'][0], 'concern should not be suppressed'
"
}

@test "verdict recalculated to WARN when errors suppressed but warnings remain" {
  cat > "$TEST_TMP/suppress-warn.yml" <<'SYML'
suppress:
  - file: "src/main.py"
    keyword: "credentials"
    reason: "Test fixture"
SYML

  local inner='{"verdict":"FAIL","summary":"Issues","concerns":[{"file":"src/main.py","line":10,"severity":"error","message":"hardcoded credentials found"},{"file":"src/utils.py","line":5,"severity":"warning","message":"unused import"}]}'
  local escaped
  escaped=$(printf '%s' "$inner" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
  local body
  body=$(printf '{"choices":[{"message":{"content":%s}}]}' "$escaped")
  stub_curl 200 "$body"

  run bash "$SCRIPT" \
    --diff-file "$DIFF_FILE" \
    --system-prompt "$SYSTEM_PROMPT" \
    --suppress-config "$TEST_TMP/suppress-warn.yml"
  [ "$status" -eq 0 ]

  printf '%s' "$output" > "$TEST_TMP/result-warn.json"
  python3 -c "
import json
with open('$TEST_TMP/result-warn.json') as f:
    obj = json.load(f)
assert obj['verdict'] == 'WARN', f'expected WARN, got {obj[\"verdict\"]}'
assert obj['concerns'][0]['suppressed'] == True
assert 'suppressed' not in obj['concerns'][1], 'warning should not be suppressed'
"
}

@test "LLM returns PASS with errors — verdict recalculated to FAIL" {
  # Simulate LLM returning an inconsistent verdict: PASS but with error-severity concerns
  local inner='{"verdict":"PASS","summary":"Looks fine","concerns":[{"file":"src/main.py","line":10,"severity":"error","message":"SQL injection vulnerability"}]}'
  local escaped
  escaped=$(printf '%s' "$inner" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
  local body
  body=$(printf '{"choices":[{"message":{"content":%s}}]}' "$escaped")
  stub_curl 200 "$body"

  run bash "$SCRIPT" \
    --diff-file "$DIFF_FILE" \
    --system-prompt "$SYSTEM_PROMPT"
  [ "$status" -eq 0 ]

  printf '%s' "$output" > "$TEST_TMP/result-inconsistent.json"
  python3 -c "
import json
with open('$TEST_TMP/result-inconsistent.json') as f:
    obj = json.load(f)
assert obj['verdict'] == 'FAIL', f'LLM said PASS with errors but recalculation should give FAIL, got {obj[\"verdict\"]}'
assert len([c for c in obj['concerns'] if c['severity'] == 'error']) == 1
"
}

@test "LLM returns PASS with warnings — verdict recalculated to WARN" {
  local inner='{"verdict":"PASS","summary":"Minor issues","concerns":[{"file":"src/utils.py","line":5,"severity":"warning","message":"unused import"}]}'
  local escaped
  escaped=$(printf '%s' "$inner" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
  local body
  body=$(printf '{"choices":[{"message":{"content":%s}}]}' "$escaped")
  stub_curl 200 "$body"

  run bash "$SCRIPT" \
    --diff-file "$DIFF_FILE" \
    --system-prompt "$SYSTEM_PROMPT"
  [ "$status" -eq 0 ]

  printf '%s' "$output" > "$TEST_TMP/result-warn-inconsistent.json"
  python3 -c "
import json
with open('$TEST_TMP/result-warn-inconsistent.json') as f:
    obj = json.load(f)
assert obj['verdict'] == 'WARN', f'LLM said PASS with warnings but recalculation should give WARN, got {obj[\"verdict\"]}'
"
}

@test "LLM returns FAIL with no errors — verdict recalculated to PASS" {
  local inner='{"verdict":"FAIL","summary":"False alarm","concerns":[{"file":"src/main.py","line":10,"severity":"info","message":"consider adding docs"}]}'
  local escaped
  escaped=$(printf '%s' "$inner" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
  local body
  body=$(printf '{"choices":[{"message":{"content":%s}}]}' "$escaped")
  stub_curl 200 "$body"

  run bash "$SCRIPT" \
    --diff-file "$DIFF_FILE" \
    --system-prompt "$SYSTEM_PROMPT"
  [ "$status" -eq 0 ]

  printf '%s' "$output" > "$TEST_TMP/result-fail-noerrors.json"
  python3 -c "
import json
with open('$TEST_TMP/result-fail-noerrors.json') as f:
    obj = json.load(f)
assert obj['verdict'] == 'PASS', f'LLM said FAIL but only info concerns, recalculation should give PASS, got {obj[\"verdict\"]}'
"
}

@test "suppress config file glob patterns match correctly" {
  cat > "$TEST_TMP/suppress-glob.yml" <<'SYML'
suppress:
  - file: "src/utils/*.py"
    keyword: "helper"
    reason: "Utility pattern"
SYML

  local inner='{"verdict":"FAIL","summary":"Issues","concerns":[{"file":"src/utils/helper.py","line":10,"severity":"error","message":"helper function too complex"}]}'
  local escaped
  escaped=$(printf '%s' "$inner" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
  local body
  body=$(printf '{"choices":[{"message":{"content":%s}}]}' "$escaped")
  stub_curl 200 "$body"

  run bash "$SCRIPT" \
    --diff-file "$DIFF_FILE" \
    --system-prompt "$SYSTEM_PROMPT" \
    --suppress-config "$TEST_TMP/suppress-glob.yml"
  [ "$status" -eq 0 ]

  printf '%s' "$output" > "$TEST_TMP/result-glob.json"
  python3 -c "
import json
with open('$TEST_TMP/result-glob.json') as f:
    obj = json.load(f)
assert obj['verdict'] == 'PASS', f'expected PASS, got {obj[\"verdict\"]}'
assert obj['concerns'][0]['suppressed'] == True
assert obj['concerns'][0]['suppress_reason'] == 'Utility pattern'
"
}

@test "without --suppress-config output is unchanged from LLM response" {
  local inner='{"verdict":"FAIL","summary":"Issues","concerns":[{"file":"src/main.py","line":10,"severity":"error","message":"hardcoded credentials found"}]}'
  local escaped
  escaped=$(printf '%s' "$inner" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
  local body
  body=$(printf '{"choices":[{"message":{"content":%s}}]}' "$escaped")
  stub_curl 200 "$body"

  run bash "$SCRIPT" \
    --diff-file "$DIFF_FILE" \
    --system-prompt "$SYSTEM_PROMPT"
  [ "$status" -eq 0 ]

  printf '%s' "$output" > "$TEST_TMP/result-noconfig.json"
  python3 -c "
import json
with open('$TEST_TMP/result-noconfig.json') as f:
    obj = json.load(f)
assert obj['verdict'] == 'FAIL', f'expected FAIL, got {obj[\"verdict\"]}'
assert 'suppressed' not in obj['concerns'][0], 'no suppressed field expected'
"
}

# ---------------------------------------------------------------------------
# SECTION N: --response-file
# ---------------------------------------------------------------------------

@test "--response-file saves raw API response and stdout is still valid review JSON" {
  stub_curl 200 "$(make_api_response PASS 'response-file test')"
  local raw_file="$TEST_TMP/raw-response.json"
  run bash "$SCRIPT" \
    --diff-file "$DIFF_FILE" \
    --system-prompt "$SYSTEM_PROMPT" \
    --response-file "$raw_file"
  [ "$status" -eq 0 ]
  # Raw response file must exist and contain the API envelope (choices key)
  [ -f "$raw_file" ]
  python3 -c "import json; d=json.load(open('$raw_file')); assert 'choices' in d, 'raw file missing choices key — not the raw API response'"
  # stdout must also be valid review JSON with verdict (parsed, not the envelope)
  echo "$output" | python3 -c 'import sys,json; obj=json.load(sys.stdin); assert obj["verdict"]=="PASS"; assert "choices" not in obj, "stdout should be parsed review, not raw envelope"'
}
