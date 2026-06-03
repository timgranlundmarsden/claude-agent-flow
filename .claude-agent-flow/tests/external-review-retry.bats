#!/usr/bin/env bats
# Tests for external-review.sh — 503 retry logic (AC #1-6)

TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
SCRIPT="$PROJECT_ROOT/.claude/skills/external-code-review/external-review.sh"

setup() {
  export ORIG_PATH="$PATH"
  TEST_TMP=$(mktemp -d)

  DIFF_FILE="$TEST_TMP/test.diff"
  printf -- '--- a/foo.py\n+++ b/foo.py\n@@ -1,3 +1,4 @@\n def bar():\n-    pass\n+    return 1\n' > "$DIFF_FILE"

  SYSTEM_PROMPT="$TEST_TMP/system-prompt.md"
  printf 'You are a code reviewer.\n' > "$SYSTEM_PROMPT"

  export GIT_CEILING_DIRECTORIES="${TEST_TMP%/*}"
  cd "$TEST_TMP"

  export EXTERNAL_REVIEW_API_KEY="test-api-key"
  export EXTERNAL_REVIEW_MODEL="openai/gpt-4o"
  export EXTERNAL_REVIEW_API_BASE_URL="https://api.example.com/v1"
}

teardown() {
  export PATH="$ORIG_PATH"
  rm -rf "$TEST_TMP"
}

# Build a valid API response JSON wrapping a review object.
make_api_response() {
  local verdict="${1:-PASS}"
  local summary="${2:-Looks good}"
  local inner
  inner=$(printf '{"verdict":"%s","summary":"%s","concerns":[]}' "$verdict" "$summary")
  local escaped
  escaped=$(printf '%s' "$inner" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
  printf '{"choices":[{"message":{"content":%s}}]}' "$escaped"
}

# Create a stateful curl stub that returns the given sequence of HTTP codes.
# Successive calls consume the sequence; extra calls repeat the last code.
# Also stubs `sleep` as a no-op so tests run instantly.
# Args: HTTP codes in order (e.g. 503 503 200)
make_multi_call_stub() {
  local stub_dir="$TEST_TMP/stubs"
  mkdir -p "$stub_dir"

  local i=0
  for code in "$@"; do
    printf '%s' "$code" > "$stub_dir/resp_${i}"
    i=$(( i + 1 ))
  done
  printf '0' > "$stub_dir/count"
  printf '%d' "$i" > "$stub_dir/total"

  make_api_response PASS 'All good' > "$stub_dir/success_body.json"

  cat > "$stub_dir/curl" <<'STUB'
#!/usr/bin/env bash
_sd="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
output_file=""
write_out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) output_file="$2"; shift 2 ;;
    -w) write_out="$2"; shift 2 ;;
    *)  shift ;;
  esac
done
count=$(cat "$_sd/count")
total=$(cat "$_sd/total")
idx=$count
[[ $idx -ge $total ]] && idx=$(( total - 1 ))
code=$(cat "$_sd/resp_${idx}")
printf '%d' $(( count + 1 )) > "$_sd/count"
if [[ -n "$output_file" ]]; then
  if [[ "$code" == "200" ]]; then
    cat "$_sd/success_body.json" > "$output_file"
  else
    printf '{"error":"HTTP %s"}' "$code" > "$output_file"
  fi
fi
if [[ "$write_out" == "%{http_code}" ]]; then
  printf '%s' "$code"
fi
STUB
  chmod +x "$stub_dir/curl"

  printf '#!/usr/bin/env bash\n# no-op\n' > "$stub_dir/sleep"
  chmod +x "$stub_dir/sleep"

  export PATH="$stub_dir:$PATH"
}

# Create a curl stub that simulates a network-level failure (exits non-zero).
make_network_failure_stub() {
  local stub_dir="$TEST_TMP/stubs"
  mkdir -p "$stub_dir"

  cat > "$stub_dir/curl" <<'STUB'
#!/usr/bin/env bash
output_file=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) output_file="$2"; shift 2 ;;
    *)  shift ;;
  esac
done
printf 'curl: (7) Failed to connect to host' >&2
[[ -n "$output_file" ]] && printf '' > "$output_file"
exit 7
STUB
  chmod +x "$stub_dir/curl"

  printf '#!/usr/bin/env bash\n# no-op\n' > "$stub_dir/sleep"
  chmod +x "$stub_dir/sleep"

  export PATH="$stub_dir:$PATH"
}

# ---------------------------------------------------------------------------
# AC #2: first-try success
# ---------------------------------------------------------------------------

@test "AC2: 200 on first try exits 0 with PASS and no retry warnings" {
  make_multi_call_stub 200
  run bash "$SCRIPT" --diff-file "$DIFF_FILE" --system-prompt "$SYSTEM_PROMPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"WARNING"* ]]
  [[ "$output" == *"PASS"* ]]
}

# ---------------------------------------------------------------------------
# AC #1: 503 retries — success on 2nd attempt
# ---------------------------------------------------------------------------

@test "AC1/AC4/AC6: 503 then 200 retries once with warning and exits 0" {
  make_multi_call_stub 503 200
  run bash "$SCRIPT" --diff-file "$DIFF_FILE" --system-prompt "$SYSTEM_PROMPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
  count=$(printf '%s' "$output" | grep -c "WARNING: HTTP 503 received" || true)
  [ "$count" -eq 1 ]
  [[ "$output" == *"attempt 1/3"* ]]
  [[ "$output" == *"after 2s"* ]]
}

# ---------------------------------------------------------------------------
# AC #1: 503 retries — success on 3rd attempt (boundary case)
# ---------------------------------------------------------------------------

@test "AC1/AC4: 503 then 503 then 200 succeeds with two retry warnings" {
  make_multi_call_stub 503 503 200
  run bash "$SCRIPT" --diff-file "$DIFF_FILE" --system-prompt "$SYSTEM_PROMPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
  count=$(printf '%s' "$output" | grep -c "WARNING: HTTP 503 received" || true)
  [ "$count" -eq 2 ]
  [[ "$output" == *"attempt 1/3"* ]]
  [[ "$output" == *"after 2s"* ]]
  [[ "$output" == *"attempt 2/3"* ]]
  [[ "$output" == *"after 4s"* ]]
}

# ---------------------------------------------------------------------------
# AC #1: 503 x3 — exhausts retries, exits 1
# ---------------------------------------------------------------------------

@test "AC1/AC4/AC6: 503 x3 exhausts retries and reports only attempts 1 and 2" {
  make_multi_call_stub 503 503 503
  run bash "$SCRIPT" --diff-file "$DIFF_FILE" --system-prompt "$SYSTEM_PROMPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"503"* ]]
  count=$(printf '%s' "$output" | grep -c "WARNING: HTTP 503 received" || true)
  [ "$count" -eq 2 ]
  [[ "$output" == *"attempt 1/3"* ]]
  [[ "$output" == *"attempt 2/3"* ]]
  [[ "$output" != *"attempt 3/3"* ]]
}

# ---------------------------------------------------------------------------
# AC #3: non-503 errors — fail immediately, no retry
# ---------------------------------------------------------------------------

@test "AC3/AC6: non-503 HTTP errors fail immediately without retry" {
  local code
  for code in 400 401 500 429; do
    make_multi_call_stub "$code"
    run bash "$SCRIPT" --diff-file "$DIFF_FILE" --system-prompt "$SYSTEM_PROMPT"
    [ "$status" -eq 1 ] || {
      echo "FAIL: HTTP $code expected status 1, got $status" >&2
      return 1
    }
    [[ "$output" != *"WARNING"* ]] || {
      echo "FAIL: HTTP $code emitted retry warning" >&2
      return 1
    }
    [[ "$output" == *"$code"* ]] || {
      echo "FAIL: HTTP $code not surfaced in output" >&2
      return 1
    }
  done
}

@test "AC3: 503 then 400 — retries after 503, then stops immediately on 400" {
  make_multi_call_stub 503 400
  run bash "$SCRIPT" --diff-file "$DIFF_FILE" --system-prompt "$SYSTEM_PROMPT"
  [ "$status" -eq 1 ]
  count=$(printf '%s' "$output" | grep -c "WARNING: HTTP 503 received" || true)
  [ "$count" -eq 1 ]
  [[ "$output" == *"400"* ]]
}

# ---------------------------------------------------------------------------
# AC #5: curl network failure
# ---------------------------------------------------------------------------

@test "AC5/AC6: curl network failure — exits 1 immediately, no retry WARNING" {
  make_network_failure_stub
  run bash "$SCRIPT" --diff-file "$DIFF_FILE" --system-prompt "$SYSTEM_PROMPT"
  [ "$status" -eq 1 ]
  [[ "$output" != *"WARNING"* ]]
}
