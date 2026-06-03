#!/usr/bin/env bats
# Consolidated tests for GitHub Pages documentation hosting feature (TASK-19)

setup() {
  load test_helper
  skip_unless_source_repo
  DOCS_PUBLIC="$PROJECT_ROOT/docs/public"
  DEPLOY_WORKFLOW="$PROJECT_ROOT/.claude-agent-flow/plugin-repo-workflows/deploy-pages.yml"
  PUBLISH_MANIFEST="$PROJECT_ROOT/.claude-agent-flow/publish-plugin-manifest.yml"
}

@test "docs/public exists and has expected root HTML files (list-driven)" {
  [[ -d "$DOCS_PUBLIC" ]] || {
    echo "FAIL: missing directory $DOCS_PUBLIC" >&2
    return 1
  }

  local required=(
    index.html
    why-agent-flow.html
    showcase.html
    getting-started.html
    plan-pipeline.html
    build-pipeline.html
    about.html
    review-pipeline.html
    visualiser.html
  )

  local file
  for file in "${required[@]}"; do
    [[ -s "$DOCS_PUBLIC/$file" ]] || {
      echo "FAIL: missing or empty docs page: $file" >&2
      return 1
    }
  done

  local count
  count=$(find "$DOCS_PUBLIC" -maxdepth 1 -name '*.html' | wc -l | tr -d ' ')
  [[ "$count" -eq 9 ]] || {
    echo "FAIL: expected 9 root HTML files, found $count" >&2
    return 1
  }
}

@test "docs/public has only allowed subdirectories" {
  local subdirs
  subdirs=$(find "$DOCS_PUBLIC" -mindepth 1 -maxdepth 1 -type d ! -name 'logs' ! -name 'showcase' ! -name 'img' ! -name '.playwright-cli')
  [[ -z "$subdirs" ]] || {
    echo "FAIL: unexpected subdirectories in docs/public: $subdirs" >&2
    return 1
  }
}

@test "root docs pages are HTML and use relative links" {
  local file
  while IFS= read -r -d '' file; do
    grep -qi '<html\|<!DOCTYPE' "$file" || {
      echo "FAIL: invalid html marker in $(basename "$file")" >&2
      return 1
    }
    ! grep -q '/docs/' "$file" || {
      echo "FAIL: found '/docs/' absolute path in $(basename "$file")" >&2
      return 1
    }
    ! grep -q '\.\./' "$file" || {
      echo "FAIL: found '../' path in root page $(basename "$file")" >&2
      return 1
    }
  done < <(find "$DOCS_PUBLIC" -maxdepth 1 -name '*.html' -print0)
}


@test "deploy workflow exists, parses as YAML, and has core settings" {
  [[ -f "$DEPLOY_WORKFLOW" ]] || {
    echo "FAIL: missing workflow $DEPLOY_WORKFLOW" >&2
    return 1
  }
  command -v python3 >/dev/null || skip "python3 not available"
  python3 -c "import yaml; yaml.safe_load(open('$DEPLOY_WORKFLOW'))" || {
    echo "FAIL: invalid YAML in $DEPLOY_WORKFLOW" >&2
    return 1
  }

  local required=(
    'branches: \[main\]'
    'docs/\*\*'
    'docs/public'
    'GITHUB_OUTPUT'
    'pages: write'
    'id-token: write'
    'concurrency:'
    'group: pages'
  )
  local pattern
  for pattern in "${required[@]}"; do
    grep -Eq "$pattern" "$DEPLOY_WORKFLOW" || {
      echo "FAIL: missing '$pattern' in deploy-pages.yml" >&2
      return 1
    }
  done
}

@test "publish manifest excludes deploy-pages workflow file" {
  grep -q 'plugin-repo-workflows/deploy-pages.yml' "$PUBLISH_MANIFEST" || {
    echo "FAIL: publish manifest should exclude deploy-pages workflow" >&2
    return 1
  }
}
