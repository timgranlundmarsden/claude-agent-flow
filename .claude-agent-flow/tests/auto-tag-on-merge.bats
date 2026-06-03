#!/usr/bin/env bats
# auto-tag-on-merge.bats — Tests for TASK-51 Auto Tag and Release workflow

setup() {
  load test_helper
  skip_unless_source_repo
  WORKFLOW="$PROJECT_ROOT/.claude-agent-flow/plugin-repo-workflows/auto-tag-on-merge.yml"
}

@test "auto-tag-on-merge.yml is valid YAML" {
  command -v python3 || skip "python3 not available"
  python3 -c "import yaml; yaml.safe_load(open('$WORKFLOW'))" 2>&1 || {
    echo "FAIL: $WORKFLOW is not valid YAML" >&2
    return 1
  }
}

@test "workflow trigger, gate, and security conditions present (list-driven)" {
  local required_patterns=(
    "pull_request"
    "closed"
    "branches"
    "main"
    "merged == true"
    "permissions"
    "contents: write"
    "cancel-in-progress: false"
    "fetch-depth: 0"
    "git fetch --tags --force"
  )
  local pattern
  for pattern in "${required_patterns[@]}"; do
    grep -q "$pattern" "$WORKFLOW" || {
      echo "FAIL: required pattern '$pattern' missing in $WORKFLOW" >&2
      return 1
    }
  done
}

@test "release job uses correct flags and tools (list-driven)" {
  local required_patterns=(
    "jq"
    "plugin.json"
    "PLUGIN_JSON"
    '\.claude-plugin/plugin\.json'
    "rev-parse"
    "gh api"
    "gh release create"
    '\-\-generate-notes'
    '\-\-latest=true'
    "secrets.GITHUB_TOKEN"
    "GH_TOKEN"
  )
  local pattern
  for pattern in "${required_patterns[@]}"; do
    grep -qE "$pattern" "$WORKFLOW" || {
      echo "FAIL: required pattern '$pattern' missing in $WORKFLOW" >&2
      return 1
    }
  done
  # Must NOT use third-party release action
  grep -q 'softprops/action-gh-release' "$WORKFLOW" && {
    echo "FAIL: third-party action softprops/action-gh-release found; use gh CLI instead" >&2
    return 1
  }
  return 0
}

@test "workflow versioning, summary, and fork guard (list-driven)" {
  # actions/checkout@v4 present, not v3 or v5
  grep -q 'actions/checkout@v4' "$WORKFLOW" || {
    echo "FAIL: actions/checkout@v4 missing" >&2; return 1
  }
  local forbidden=("actions/checkout@v3" "actions/checkout@v5")
  local p
  for p in "${forbidden[@]}"; do
    ! grep -q "$p" "$WORKFLOW" || {
      echo "FAIL: forbidden action ref '$p' found in $WORKFLOW" >&2; return 1
    }
  done
  # Target uses merge_commit_sha (not GITHUB_SHA)
  grep -Eq '\-\-target[[:space:]]+"?\$\{MERGE_SHA' "$WORKFLOW" || {
    echo "FAIL: --target must use MERGE_SHA from merge_commit_sha" >&2; return 1
  }
  grep -q 'pull_request.merge_commit_sha' "$WORKFLOW" || {
    echo "FAIL: merge_commit_sha must be the tag target" >&2; return 1
  }
  # Step summaries on both paths
  grep -q 'if: success()' "$WORKFLOW" && grep -q 'if: failure()' "$WORKFLOW" || {
    echo "FAIL: step summary must appear on both success and failure paths" >&2; return 1
  }
  # Skip-in-forks guard (two-job pattern)
  grep -q "github.repository != 'timgranlundmarsden/claude-agent-flow'" "$WORKFLOW" && \
  grep -q "github.repository == 'timgranlundmarsden/claude-agent-flow'" "$WORKFLOW" || {
    echo "FAIL: skip-in-forks two-job pattern missing" >&2; return 1
  }
}
