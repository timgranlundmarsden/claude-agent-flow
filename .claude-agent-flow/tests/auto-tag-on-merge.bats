#!/usr/bin/env bats
# auto-tag-on-merge.bats — Tests for TASK-51 Auto Tag and Release workflow

setup() {
  load test_helper
  skip_unless_source_repo
  WORKFLOW="$PROJECT_ROOT/.claude-agent-flow/plugin-repo-workflows/auto-tag-on-merge.yml"
}

@test "1. auto-tag-on-merge.yml exists at correct path" {
  [[ -f "$WORKFLOW" ]] || {
    echo "FAIL: $WORKFLOW does not exist" >&2
    return 1
  }
}

@test "2. auto-tag-on-merge.yml is valid YAML" {
  command -v python3 || skip "python3 not available"
  python3 -c "import yaml; yaml.safe_load(open('$WORKFLOW'))" 2>&1 || {
    echo "FAIL: $WORKFLOW is not valid YAML" >&2
    return 1
  }
}

@test "3. workflow triggers on pull_request with types: [closed]" {
  grep -q 'pull_request' "$WORKFLOW" || {
    echo "FAIL: pull_request trigger missing in $WORKFLOW" >&2
    return 1
  }
  grep -q 'closed' "$WORKFLOW" || {
    echo "FAIL: types: [closed] missing in $WORKFLOW" >&2
    return 1
  }
}

@test "4. workflow triggers on branches: [main]" {
  grep -q 'branches' "$WORKFLOW" || {
    echo "FAIL: branches trigger missing in $WORKFLOW" >&2
    return 1
  }
  grep -q 'main' "$WORKFLOW" || {
    echo "FAIL: main branch not referenced in $WORKFLOW" >&2
    return 1
  }
}

@test "5. job is gated by merged == true condition" {
  grep -q 'merged' "$WORKFLOW" || {
    echo "FAIL: merged condition not found in $WORKFLOW" >&2
    return 1
  }
  grep -q 'merged == true' "$WORKFLOW" || {
    echo "FAIL: 'merged == true' gate not found in $WORKFLOW" >&2
    return 1
  }
}

@test "6. permissions: contents: write is present" {
  grep -q 'permissions' "$WORKFLOW" || {
    echo "FAIL: permissions block missing in $WORKFLOW" >&2
    return 1
  }
  grep -q 'contents: write' "$WORKFLOW" || {
    echo "FAIL: 'contents: write' not found in $WORKFLOW" >&2
    return 1
  }
}

@test "7. concurrency uses cancel-in-progress: false" {
  grep -q 'concurrency' "$WORKFLOW" || {
    echo "FAIL: concurrency block missing in $WORKFLOW" >&2
    return 1
  }
  grep -q 'cancel-in-progress: false' "$WORKFLOW" || {
    echo "FAIL: 'cancel-in-progress: false' not found in $WORKFLOW" >&2
    return 1
  }
}

@test "8. version is read from plugin.json using jq" {
  grep -q 'jq' "$WORKFLOW" || {
    echo "FAIL: jq command not found in $WORKFLOW" >&2
    return 1
  }
  grep -q 'plugin.json' "$WORKFLOW" || {
    echo "FAIL: plugin.json reference not found in $WORKFLOW" >&2
    return 1
  }
}

@test "9. PLUGIN_JSON env var is set at job level" {
  grep -q 'PLUGIN_JSON' "$WORKFLOW" || {
    echo "FAIL: PLUGIN_JSON env var not found in $WORKFLOW" >&2
    return 1
  }
  grep -q '\.claude-plugin/plugin\.json' "$WORKFLOW" || {
    echo "FAIL: PLUGIN_JSON path '.claude-plugin/plugin.json' not found in $WORKFLOW" >&2
    return 1
  }
}

@test "10. workflow fails if tag exists locally via git rev-parse" {
  grep -q 'rev-parse' "$WORKFLOW" || {
    echo "FAIL: 'rev-parse' local tag check not found in $WORKFLOW" >&2
    return 1
  }
}

@test "11. workflow checks remote tag via gh api" {
  grep -q 'gh api' "$WORKFLOW" || {
    echo "FAIL: 'gh api' remote tag check not found in $WORKFLOW" >&2
    return 1
  }
}

@test "12. gh release create is used (not third-party release actions)" {
  grep -q 'gh release create' "$WORKFLOW" || {
    echo "FAIL: 'gh release create' not found in $WORKFLOW" >&2
    return 1
  }
  grep -q 'softprops/action-gh-release' "$WORKFLOW" && {
    echo "FAIL: third-party action softprops/action-gh-release found; use gh CLI instead" >&2
    return 1
  }
  return 0
}

@test "13. --generate-notes flag is present" {
  grep -q '\-\-generate-notes' "$WORKFLOW" || {
    echo "FAIL: '--generate-notes' flag not found in $WORKFLOW" >&2
    return 1
  }
}

@test "14. --latest=true flag is present" {
  grep -q '\-\-latest=true' "$WORKFLOW" || {
    echo "FAIL: '--latest=true' flag not found in $WORKFLOW" >&2
    return 1
  }
}

@test "15. --target pointing at merge commit SHA is used" {
  grep -Eq '\-\-target[[:space:]]+"?\$\{MERGE_SHA' "$WORKFLOW" || {
    echo "FAIL: '--target \"\${MERGE_SHA}\"' not found in $WORKFLOW (must use merge_commit_sha, not GITHUB_SHA)" >&2
    return 1
  }
}

@test "16. GH_TOKEN is set from secrets.GITHUB_TOKEN" {
  grep -q 'secrets.GITHUB_TOKEN' "$WORKFLOW" || {
    echo "FAIL: 'secrets.GITHUB_TOKEN' not found in $WORKFLOW" >&2
    return 1
  }
  grep -q 'GH_TOKEN' "$WORKFLOW" || {
    echo "FAIL: 'GH_TOKEN' not found in $WORKFLOW" >&2
    return 1
  }
}

@test "17. step summary is posted on success via success() condition" {
  grep -q 'success()' "$WORKFLOW" || {
    echo "FAIL: 'success()' condition not found in $WORKFLOW" >&2
    return 1
  }
}

@test "18. step summary posted on both success and failure paths" {
  grep -q 'if: success()' "$WORKFLOW" || {
    echo "FAIL: no 'if: success()' step found for success-path summary" >&2
    return 1
  }
  grep -q 'if: failure()' "$WORKFLOW" || {
    echo "FAIL: no 'if: failure()' step found for failure-path summary" >&2
    return 1
  }
}

@test "19. fetch-depth: 0 is used in checkout" {
  grep -q 'fetch-depth: 0' "$WORKFLOW" || {
    echo "FAIL: 'fetch-depth: 0' not found in $WORKFLOW" >&2
    return 1
  }
}

@test "20. git fetch --tags --force step exists" {
  grep -q 'git fetch --tags --force' "$WORKFLOW" || {
    echo "FAIL: 'git fetch --tags --force' step not found in $WORKFLOW" >&2
    return 1
  }
}

@test "21. actions/checkout@v4 is used (not v3, v5, etc.)" {
  grep -q 'actions/checkout@v4' "$WORKFLOW" || {
    echo "FAIL: 'actions/checkout@v4' not found in $WORKFLOW" >&2
    return 1
  }
  grep -q 'actions/checkout@v3' "$WORKFLOW" && {
    echo "FAIL: outdated 'actions/checkout@v3' found; use @v4" >&2
    return 1
  }
  grep -q 'actions/checkout@v5' "$WORKFLOW" && {
    echo "FAIL: unsupported 'actions/checkout@v5' found; use @v4" >&2
    return 1
  }
  return 0
}

@test "22. merge_commit_sha is used for tag target (not GITHUB_SHA)" {
  grep -q 'pull_request.merge_commit_sha' "$WORKFLOW" || {
    echo "FAIL: tag target must use github.event.pull_request.merge_commit_sha, not GITHUB_SHA" >&2
    return 1
  }
}

@test "23. auto-tag-on-merge.yml has skip-in-forks guard (two-job pattern)" {
  # CI-only workflows must skip cleanly in forks rather than failing or running unintended side effects
  grep -q "github.repository != 'timgranlundmarsden/claude-agent-flow'" "$WORKFLOW" || {
    echo "FAIL: skip-in-forks job missing — workflow must skip when not in canonical repo" >&2
    return 1
  }
  grep -q "github.repository == 'timgranlundmarsden/claude-agent-flow'" "$WORKFLOW" || {
    echo "FAIL: real job guard missing — tag-and-release must only run in canonical repo" >&2
    return 1
  }
  # Both conditions must be present (two-job pattern, not a single negated condition)
  local ne_count eq_count
  ne_count=$(grep -c "github.repository != 'timgranlundmarsden/claude-agent-flow'" "$WORKFLOW" || true)
  eq_count=$(grep -c "github.repository == 'timgranlundmarsden/claude-agent-flow'" "$WORKFLOW" || true)
  [[ "$ne_count" -ge 1 && "$eq_count" -ge 1 ]] || {
    echo "FAIL: expected both != and == conditions for two-job skip-in-forks pattern" >&2
    return 1
  }
}
