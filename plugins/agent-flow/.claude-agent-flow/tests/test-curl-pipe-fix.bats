#!/usr/bin/env bats

# Test file for TASK-35 RTK curl pipe compatibility fixes

load 'lib/bats-support/load'
load 'lib/bats-assert/load'

setup() {
  # Use BATS_TEST_TMPDIR for isolation — unique per test, safe for parallel runs
  TEST_TEMP_DIR="$BATS_TEST_TMPDIR/curl-pipe-test"
  mkdir -p "$TEST_TEMP_DIR"
}

@test "download to temp directory is writable" {
  local f="$TEST_TEMP_DIR/test-write.txt"
  echo "test content" > "$f"
  [[ -f "$f" ]]
  [[ "$(cat "$f")" == "test content" ]]
}

@test "bash execution from temp dir works correctly" {
  local script="$TEST_TEMP_DIR/test-exec.sh"
  cat > "$script" << 'EOF'
#!/bin/bash
echo "executed from tmp"
exit 0
EOF
  chmod +x "$script"
  run bash "$script"
  assert_success
  [[ "$output" == "executed from tmp" ]]
}

@test "error handling: script execution failure propagates" {
  local script="$TEST_TEMP_DIR/test-error.sh"
  cat > "$script" << 'EOF'
#!/bin/bash
echo "before error"
exit 1
EOF
  chmod +x "$script"
  run bash "$script"
  assert_failure
  [[ "$output" =~ "before error" ]]
}

@test "download-then-run pattern with && operator works correctly" {
  local script="$TEST_TEMP_DIR/test-pattern2.sh"
  run bash -c "echo 'echo pattern works' > '$script' && bash '$script'"
  assert_success
  [[ "$output" == "pattern works" ]]
}

@test "parameter passing works with download-then-run pattern" {
  local script="$TEST_TEMP_DIR/test-params.sh"
  cat > "$script" << 'EOF'
#!/bin/bash
if [[ "$1" == "--scope" && "$2" == "test-scope" ]]; then
  echo "parameters received correctly"
  exit 0
else
  echo "parameters not received: $*"
  exit 1
fi
EOF
  chmod +x "$script"
  run bash "$script" --scope test-scope
  assert_success
  [[ "$output" == "parameters received correctly" ]]
}

@test "curl -o option syntax is valid" {
  local src="$TEST_TEMP_DIR/local-file.sh"
  local dst="$TEST_TEMP_DIR/downloaded.sh"
  echo "test content" > "$src"
  run curl -fsSL "file://$src" -o "$dst"
  assert_success
  [[ -f "$dst" ]]
  [[ "$(cat "$dst")" == "test content" ]]
}
