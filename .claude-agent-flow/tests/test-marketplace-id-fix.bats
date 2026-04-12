#!/usr/bin/env bats

# Test file for TASK-35 marketplace ID derivation fixes

load 'lib/bats-support/load'
load 'lib/bats-assert/load'

setup() {
  # Create temporary directories for testing
  TEST_TEMP_DIR="$BATS_TEST_TMPDIR/marketplace-id-test"
  mkdir -p "$TEST_TEMP_DIR"
  cd "$TEST_TEMP_DIR"
}

teardown() {
  # Clean up
  rm -rf "$TEST_TEMP_DIR"
}

@test "bash parameter expansion ##*/ extracts repo name correctly" {
  SOURCE_REPO="timgranlundmarsden/claude-agent-flow"
  MARKETPLACE_ID="${SOURCE_REPO##*/}"
  [[ "$MARKETPLACE_ID" == "claude-agent-flow" ]]
}

@test "bash parameter expansion ##*/ handles different owner names" {
  SOURCE_REPO="testowner/myrepo"
  MARKETPLACE_ID="${SOURCE_REPO##*/}"
  [[ "$MARKETPLACE_ID" == "myrepo" ]]
}

@test "old derivation //\\/-/ produces owner-repo format" {
  SOURCE_REPO="testowner/myrepo"
  OLD_MARKETPLACE_ID="${SOURCE_REPO//\//-}"
  [[ "$OLD_MARKETPLACE_ID" == "testowner-myrepo" ]]
}

@test "new derivation ##*/ differs from old //\\/-/ derivation" {
  SOURCE_REPO="testowner/myrepo"
  OLD_MARKETPLACE_ID="${SOURCE_REPO//\//-}"
  NEW_MARKETPLACE_ID="${SOURCE_REPO##*/}"
  [[ "$OLD_MARKETPLACE_ID" != "$NEW_MARKETPLACE_ID" ]]
  [[ "$OLD_MARKETPLACE_ID" == "testowner-myrepo" ]]
  [[ "$NEW_MARKETPLACE_ID" == "myrepo" ]]
}

@test "single word repo names unchanged by both derivations" {
  SOURCE_REPO="singleword"
  OLD_MARKETPLACE_ID="${SOURCE_REPO//\//-}"
  NEW_MARKETPLACE_ID="${SOURCE_REPO##*/}"
  [[ "$OLD_MARKETPLACE_ID" == "singleword" ]]
  [[ "$NEW_MARKETPLACE_ID" == "singleword" ]]
}

@test "edge case: empty repo name handled" {
  SOURCE_REPO="owner/"
  NEW_MARKETPLACE_ID="${SOURCE_REPO##*/}"
  [[ "$NEW_MARKETPLACE_ID" == "" ]]
}

@test "edge case: no slash in SOURCE_REPO" {
  SOURCE_REPO="justarepo"
  NEW_MARKETPLACE_ID="${SOURCE_REPO##*/}"
  [[ "$NEW_MARKETPLACE_ID" == "justarepo" ]]
}

@test "multiple slashes handled correctly" {
  SOURCE_REPO="org/suborg/repo"
  NEW_MARKETPLACE_ID="${SOURCE_REPO##*/}"
  [[ "$NEW_MARKETPLACE_ID" == "repo" ]]
}

@test "plugin key format combines correctly with new derivation" {
  SOURCE_REPO="testowner/myrepo"
  PLUGIN_NAME="agent-flow"
  MARKETPLACE_ID="${SOURCE_REPO##*/}"
  PLUGIN_KEY="${PLUGIN_NAME}@${MARKETPLACE_ID}"
  [[ "$PLUGIN_KEY" == "agent-flow@myrepo" ]]
}

@test "plugin key format with old derivation produces different result" {
  SOURCE_REPO="testowner/myrepo"
  PLUGIN_NAME="agent-flow"
  OLD_MARKETPLACE_ID="${SOURCE_REPO//\//-}"
  OLD_PLUGIN_KEY="${PLUGIN_NAME}@${OLD_MARKETPLACE_ID}"
  [[ "$OLD_PLUGIN_KEY" == "agent-flow@testowner-myrepo" ]]
}