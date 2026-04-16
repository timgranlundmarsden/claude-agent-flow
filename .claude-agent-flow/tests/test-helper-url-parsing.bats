#!/usr/bin/env bats
# Tests for _parse_owner_repo() in test_helper.bash

setup() {
  load test_helper
}

# ── SSH format ───────────────────────────────────────────────────────────────

@test "1. _parse_owner_repo extracts owner/repo from SSH URL" {
  result=$(_parse_owner_repo "git@github.com:owner/repo")
  [[ "$result" == "owner/repo" ]]
}

@test "2. _parse_owner_repo extracts owner/repo from SSH URL with .git suffix" {
  result=$(_parse_owner_repo "git@github.com:owner/repo.git")
  [[ "$result" == "owner/repo" ]]
}

# ── HTTPS format ─────────────────────────────────────────────────────────────

@test "3. _parse_owner_repo extracts owner/repo from HTTPS URL" {
  result=$(_parse_owner_repo "https://github.com/owner/repo")
  [[ "$result" == "owner/repo" ]]
}

@test "4. _parse_owner_repo extracts owner/repo from HTTPS URL with .git suffix" {
  result=$(_parse_owner_repo "https://github.com/owner/repo.git")
  [[ "$result" == "owner/repo" ]]
}

# ── Local proxy format (Claude Code web env) ─────────────────────────────────

@test "5. _parse_owner_repo extracts owner/repo from local proxy URL" {
  result=$(_parse_owner_repo "http://local_proxy@127.0.0.1:8080/git/timgranlundmarsden/agent-team")
  [[ "$result" == "timgranlundmarsden/agent-team" ]]
}

@test "6. _parse_owner_repo handles different port numbers in proxy URL" {
  result=$(_parse_owner_repo "http://local_proxy@127.0.0.1:54321/git/myorg/myrepo")
  [[ "$result" == "myorg/myrepo" ]]
}

@test "7. _parse_owner_repo handles localhost in proxy URL" {
  result=$(_parse_owner_repo "http://local_proxy@localhost:8080/git/myorg/myrepo")
  [[ "$result" == "myorg/myrepo" ]]
}

@test "8. _parse_owner_repo handles proxy URL with .git suffix" {
  result=$(_parse_owner_repo "http://local_proxy@127.0.0.1:8080/git/myorg/myrepo.git")
  [[ "$result" == "myorg/myrepo" ]]
}

# ── Edge cases ────────────────────────────────────────────────────────────────

@test "9. _parse_owner_repo returns empty for unknown URL format" {
  result=$(_parse_owner_repo "ftp://example.com/repo")
  [[ "$result" == "" ]]
}

@test "10. _parse_owner_repo returns empty for empty input" {
  result=$(_parse_owner_repo "")
  [[ "$result" == "" ]]
}
