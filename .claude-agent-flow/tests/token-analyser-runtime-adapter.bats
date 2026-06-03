#!/usr/bin/env bats

setup() {
  load test_helper
  TOKEN_ANALYSER="$PROJECT_ROOT/.claude/skills/token-analyser/token-analyser"
  PARSER_PATH="$PROJECT_ROOT/.claude/skills/token-analyser"
}

write_codex_fixture() {
  CODEX_LOG_DIR="$BATS_TEST_TMPDIR/codex-logs"
  mkdir -p "$CODEX_LOG_DIR"
  local ts
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  cat > "$CODEX_LOG_DIR/codex-session.jsonl" <<JSONL
{"timestamp":"$ts","response":{"model":"gpt-5.4-mini","usage":{"input_tokens":1000,"output_tokens":200,"cache_read_tokens":"n/a"}}}
{"timestamp":"$ts","model":"gpt-5.4-mini","usage":{"input_tokens":500,"output_tokens":100,"input_tokens_details":{"cached_tokens":50}}}
JSONL
}

write_codex_archive_fixture() {
  CODEX_ARCHIVE_DIR="$BATS_TEST_TMPDIR/codex-archive"
  mkdir -p "$CODEX_ARCHIVE_DIR"
  local ts
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  cat > "$CODEX_ARCHIVE_DIR/rollout-$ts-archive-thread.jsonl" <<JSONL
{"timestamp":"$ts","type":"session_meta","payload":{"id":"archive-thread","cwd":"$BATS_TEST_TMPDIR/project","model_provider":"openai"}}
{"timestamp":"$ts","type":"turn_context","payload":{"model":"gpt-5.5","cwd":"$BATS_TEST_TMPDIR/project","turn_id":"turn-1"}}
{"timestamp":"$ts","type":"event_msg","payload":{"type":"token_usage","info":{"last_token_usage":{"input_tokens":700,"cached_input_tokens":200,"output_tokens":50,"reasoning_output_tokens":10,"total_tokens":750},"total_token_usage":{"input_tokens":700,"cached_input_tokens":200,"output_tokens":50,"total_tokens":750}}}}
JSONL
}

write_codex_metadata_fixture() {
  CODEX_METADATA_DIR="$BATS_TEST_TMPDIR/codex-metadata"
  mkdir -p "$CODEX_METADATA_DIR"
  cat > "$CODEX_METADATA_DIR/metadata-session.jsonl" <<JSONL
{"timestamp":"2026-04-28T12:00:00Z","model":"gpt-5.5","usage":{"input_tokens":100,"output_tokens":10,"cached_input_tokens":20}}
{"timestamp":"2026-04-28T12:02:00Z","type":"turn_context","payload":{"model":"gpt-5.5","context_size":2000,"turn_id":"turn-context-only"}}
{"timestamp":"2026-04-28T12:03:00Z","type":"unrelated_status","payload":{"context_size":9999}}
{"timestamp":"2026-04-28T12:04:00Z","type":"auxiliary_metric","payload":{"context_size":8888,"request_id":"req-1","response_id":"resp-1"}}
JSONL
}

write_codex_sqlite_fixture() {
  CODEX_DB="$BATS_TEST_TMPDIR/logs_2.sqlite"
  sqlite3 "$CODEX_DB" <<SQL
CREATE TABLE logs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts INTEGER NOT NULL,
  ts_nanos INTEGER NOT NULL,
  level TEXT NOT NULL,
  target TEXT NOT NULL,
  feedback_log_body TEXT,
  module_path TEXT,
  file TEXT,
  line INTEGER,
  thread_id TEXT,
  process_uuid TEXT,
  estimated_bytes INTEGER NOT NULL DEFAULT 0
);
SQL
  local now
  now="$(date +%s)"
  sqlite3 "$CODEX_DB" "insert into logs (ts, ts_nanos, level, target, feedback_log_body, thread_id) values ($now, 1, 'INFO', 'codex_core::session::turn', 'turn{turn.id=turn-1 model=gpt-5.5}:run_turn: post sampling token usage turn_id=turn-1 total_usage_tokens=1200 estimated_token_count=Some(1100)', 'sqlite-thread');"
  sqlite3 "$CODEX_DB" "insert into logs (ts, ts_nanos, level, target, feedback_log_body, thread_id) values ($now, 2, 'INFO', 'codex_core::session::turn', 'turn{turn.id=turn-2 model=gpt-5.5}:run_turn: post sampling token usage turn_id=turn-2 total_usage_tokens=1800 estimated_token_count=Some(1700)', 'sqlite-thread');"
}

write_claude_fixture() {
  CLAUDE_HOME="$BATS_TEST_TMPDIR/home"
  CLAUDE_PROJECT="$BATS_TEST_TMPDIR/project"
  mkdir -p "$CLAUDE_PROJECT"
  local encoded
  encoded="${CLAUDE_PROJECT//\//-}"
  encoded="${encoded//./-}"
  CLAUDE_PROJECT_DIR="$CLAUDE_HOME/.claude/projects/$encoded"
  mkdir -p "$CLAUDE_PROJECT_DIR"
  local ts
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  cat > "$CLAUDE_PROJECT_DIR/claude-session.jsonl" <<JSONL
{"timestamp":"$ts","type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":100,"cache_creation_input_tokens":10,"cache_read_input_tokens":20,"output_tokens":50},"content":[{"type":"text","text":"ok"}]}}
JSONL
}

@test "token-analyser selects runtime from startup-compatible environment signals" {
  run env PYTHONPATH="$PARSER_PATH" python3 -c 'from runtime import select_runtime; print(select_runtime({"CLAUDECODE":"1"})); print(select_runtime({"CODEX_THREAD_ID":"thread"})); print(select_runtime({"AI_FLAVOUR":"none"}))'
  [ "$status" -eq 0 ]
  [[ "$output" == $'claude\ncodex\nclaude' ]]
}

@test "OpenAI cached input is charged separately from normalized input" {
  run env PYTHONPATH="$PARSER_PATH" python3 -c 'from schema import calc_cost; print("%.5f" % calc_cost("gpt-5.5", 100, 100, 900, 0)); print("%.5f" % calc_cost("claude-sonnet-4-6", 1000, 100, 900, 0))'
  [ "$status" -eq 0 ]
  [[ "$output" == $'0.00395\n0.00477' ]]
}

@test "Codex cloud model variants normalize to public Codex pricing" {
  run env PYTHONPATH="$PARSER_PATH" python3 -c 'from schema import calc_cost, normalize_model_key; model = "gpt-5.3-codex-2s-1p-codexswic-ev3"; print(normalize_model_key(model)); print("%.5f" % calc_cost(model, 100, 100, 900, 0))'
  [ "$status" -eq 0 ]
  [[ "$output" == $'gpt-5.3-codex\n0.00173' ]]
}

@test "Codex adapter parses local JSONL artifacts through the existing CLI" {
  write_codex_fixture

  run env CODEX_TOKEN_ANALYSER_RUNTIME=codex CODEX_TOKEN_ANALYSER_LOG_DIRS="$CODEX_LOG_DIR" \
    python3 "$TOKEN_ANALYSER" --project-path "$BATS_TEST_TMPDIR/project" --session codex-session --json

  [ "$status" -eq 0 ]
  assert_jq "runtime" ".runtime" "codex" "$output"
  assert_jq "api calls" ".sessions[0].api_calls" "2" "$output"
  assert_jq "input tokens exclude cached reads when available" ".sessions[0].input_tokens" "1450" "$output"
  assert_jq "output tokens" ".sessions[0].output_tokens" "300" "$output"
  assert_jq "nested cached tokens" ".sessions[0].cache_read_tokens" "50" "$output"
  assert_jq "malformed cache is unsupported" '.sessions[0].per_call[0].unsupported | index("cache_read") != null' "true" "$output"
  assert_jq "unsupported cache" '.sessions[0].unsupported_fields | index("cache_read_tokens") != null' "true" "$output"
}

@test "Codex adapter parses archived rollout JSONL token usage shape" {
  write_codex_archive_fixture

  run env CODEX_TOKEN_ANALYSER_RUNTIME=codex CODEX_TOKEN_ANALYSER_LOG_DIRS="$CODEX_ARCHIVE_DIR" \
    python3 "$TOKEN_ANALYSER" --project-path "$BATS_TEST_TMPDIR/project" --session archive-thread --json

  [ "$status" -eq 0 ]
  assert_jq "runtime" ".runtime" "codex" "$output"
  assert_jq "session id" ".sessions[0].id" "archive-thread" "$output"
  assert_jq "input tokens exclude cached reads" ".sessions[0].input_tokens" "500" "$output"
  assert_jq "output tokens" ".sessions[0].output_tokens" "50" "$output"
  assert_jq "cached tokens" ".sessions[0].cache_read_tokens" "200" "$output"
  assert_jq "gpt-5.5 cost is known" '.sessions[0].est_cost_usd != null' "true" "$output"
  assert_jq "gpt-5.5 is not listed as unknown cost" '.sessions[0].unknown_cost_models | length' "0" "$output"
}

@test "Codex adapter keeps metadata-only JSONL records with context telemetry" {
  write_codex_metadata_fixture

  run env CODEX_TOKEN_ANALYSER_RUNTIME=codex CODEX_TOKEN_ANALYSER_LOG_DIRS="$CODEX_METADATA_DIR" \
    python3 "$TOKEN_ANALYSER" --project-path "$BATS_TEST_TMPDIR/project" --session metadata-session --json

  [ "$status" -eq 0 ]
  assert_jq "runtime" ".runtime" "codex" "$output"
  assert_jq "metadata record counted" ".sessions[0].api_calls" "2" "$output"
  assert_jq "duration uses metadata timestamp" ".sessions[0].duration_min" "2" "$output"
  assert_jq "input excludes cached read" ".sessions[0].input_tokens" "80" "$output"
  assert_jq "metadata context preserved" ".sessions[0].per_call[1].context_size" "2000" "$output"
  assert_jq "metadata cache read unavailable" '.sessions[0].per_call[1].unsupported | index("cache_read") != null' "true" "$output"
}

@test "Codex adapter parses live SQLite totals for current session and time windows" {
  write_codex_sqlite_fixture

  for flag in "--session sqlite-thread" --today --24h --week; do
    run env CODEX_TOKEN_ANALYSER_RUNTIME=codex CODEX_TOKEN_ANALYSER_DB="$CODEX_DB" CODEX_THREAD_ID=sqlite-thread CODEX_TOKEN_ANALYSER_LOG_DIRS="$BATS_TEST_TMPDIR/no-jsonl" \
      python3 "$TOKEN_ANALYSER" --project-path "$BATS_TEST_TMPDIR/project" $flag --json
    [ "$status" -eq 0 ]
    assert_jq "runtime for $flag" ".runtime" "codex" "$output"
    assert_jq "sqlite session present for $flag" '.sessions | length' "1" "$output"
    assert_jq "delta totals for $flag" ".sessions[0].input_tokens" "1800" "$output"
    assert_jq "sqlite turn ids group separately for $flag" '.sessions[0].per_call | length' "2" "$output"
    assert_jq "sqlite split-less totals do not fabricate cost for $flag" '.sessions[0].est_cost_usd == null' "true" "$output"
    assert_jq "sqlite cost absence is not an unknown model for $flag" '.sessions[0].unknown_cost_models | length' "0" "$output"
    assert_jq "sqlite telemetry note for $flag" '.sessions[0].unsupported_fields | index("output_token_split") != null' "true" "$output"
  done
}

@test "Codex mode clearly labels unavailable cache and context telemetry" {
  write_codex_fixture

  run env CODEX_TOKEN_ANALYSER_RUNTIME=codex CODEX_TOKEN_ANALYSER_LOG_DIRS="$CODEX_LOG_DIR" \
    python3 "$TOKEN_ANALYSER" --project-path "$BATS_TEST_TMPDIR/project" --session codex-session --breakdown

  [ "$status" -eq 0 ]
  [[ "$output" == *"Cache reads unavailable"* ]]
  [[ "$output" == *"unavailable"* ]]
  [[ "$output" == *"USD"* ]]
}

@test "runtime override is honored through the CLI command path" {
  write_codex_fixture

  run env AI_FLAVOUR=claude CODEX_TOKEN_ANALYSER_RUNTIME=codex CODEX_TOKEN_ANALYSER_LOG_DIRS="$CODEX_LOG_DIR" \
    python3 "$TOKEN_ANALYSER" --project-path "$BATS_TEST_TMPDIR/project" --session codex-session --json

  [ "$status" -eq 0 ]
  assert_jq "override runtime" ".runtime" "codex" "$output"
}

@test "Claude runtime keeps the existing Claude log parsing path" {
  write_claude_fixture

  run env HOME="$CLAUDE_HOME" CODEX_TOKEN_ANALYSER_RUNTIME=claude \
    python3 "$TOKEN_ANALYSER" --project-path "$CLAUDE_PROJECT" --session claude-session --json

  [ "$status" -eq 0 ]
  assert_jq "runtime" ".runtime" "claude" "$output"
  assert_jq "api calls" ".sessions[0].api_calls" "1" "$output"
  assert_jq "input includes cache write" ".sessions[0].input_tokens" "110" "$output"
  assert_jq "cache read preserved" ".sessions[0].cache_read_tokens" "20" "$output"
}

@test "existing flags execute in Codex and Claude runtimes" {
  write_codex_fixture
  write_claude_fixture

  for flag in --today --24h --week "--session codex-session"; do
    run env CODEX_TOKEN_ANALYSER_RUNTIME=codex CODEX_TOKEN_ANALYSER_LOG_DIRS="$CODEX_LOG_DIR" \
      python3 "$TOKEN_ANALYSER" --project-path "$BATS_TEST_TMPDIR/project" $flag --json
    [ "$status" -eq 0 ]
    assert_jq "codex runtime for $flag" ".runtime" "codex" "$output"
  done

  for flag in --today --24h --week "--session claude-session"; do
    run env HOME="$CLAUDE_HOME" CODEX_TOKEN_ANALYSER_RUNTIME=claude \
      python3 "$TOKEN_ANALYSER" --project-path "$CLAUDE_PROJECT" $flag --json
    [ "$status" -eq 0 ]
    assert_jq "claude runtime for $flag" ".runtime" "claude" "$output"
  done
}
