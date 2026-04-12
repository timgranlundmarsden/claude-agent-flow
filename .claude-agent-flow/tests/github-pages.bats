#!/usr/bin/env bats
# github-pages.bats — Tests for GitHub Pages documentation hosting feature (TASK-19)

setup() {
  load test_helper
  skip_unless_source_repo
  DOCS_PUBLIC="$PROJECT_ROOT/docs/public"
  DEPLOY_WORKFLOW="$PROJECT_ROOT/.claude-agent-flow/plugin-repo-workflows/deploy-pages.yml"
  PUBLISH_MANIFEST="$PROJECT_ROOT/.claude-agent-flow/publish-plugin-manifest.yml"
}

# ── Step 1: File presence ─────────────────────────────────────────────────────

@test "1. docs/public/ directory exists" {
  [[ -d "$DOCS_PUBLIC" ]] || {
    echo "FAIL: $DOCS_PUBLIC does not exist" >&2
    return 1
  }
}

@test "2. docs/public/ contains exactly 9 HTML files at top level" {
  local count
  count=$(find "$DOCS_PUBLIC" -maxdepth 1 -name "*.html" | wc -l | tr -d ' ')
  [[ "$count" -eq 9 ]] || {
    echo "FAIL: expected 9 HTML files at maxdepth 1, found $count" >&2
    find "$DOCS_PUBLIC" -maxdepth 1 -name "*.html" >&2
    return 1
  }
}

@test "3. docs/public/index.html exists" {
  [[ -f "$DOCS_PUBLIC/index.html" ]] || {
    echo "FAIL: index.html missing from docs/public/" >&2
    return 1
  }
}

@test "4. docs/public/why-agent-flow.html exists" {
  [[ -f "$DOCS_PUBLIC/why-agent-flow.html" ]] || {
    echo "FAIL: why-agent-flow.html missing" >&2
    return 1
  }
}

@test "5. docs/public/showcase.html exists" {
  [[ -f "$DOCS_PUBLIC/showcase.html" ]] || {
    echo "FAIL: showcase.html missing" >&2
    return 1
  }
}

@test "6. docs/public/getting-started.html exists" {
  [[ -f "$DOCS_PUBLIC/getting-started.html" ]] || {
    echo "FAIL: getting-started.html missing" >&2
    return 1
  }
}

@test "7. docs/public/plan-pipeline.html exists" {
  [[ -f "$DOCS_PUBLIC/plan-pipeline.html" ]] || {
    echo "FAIL: plan-pipeline.html missing" >&2
    return 1
  }
}

@test "8. docs/public/build-pipeline.html exists" {
  [[ -f "$DOCS_PUBLIC/build-pipeline.html" ]] || {
    echo "FAIL: build-pipeline.html missing" >&2
    return 1
  }
}

@test "9. docs/public/about.html exists" {
  [[ -f "$DOCS_PUBLIC/about.html" ]] || {
    echo "FAIL: about.html missing" >&2
    return 1
  }
}

@test "10. docs/public/review-pipeline.html exists" {
  [[ -f "$DOCS_PUBLIC/review-pipeline.html" ]] || {
    echo "FAIL: review-pipeline.html missing" >&2
    return 1
  }
}

@test "11. docs/public/showcase/ subdirectory is valid when present" {
  # showcase/ is optional — removed when pharma analysis card was deleted (b3cfed0)
  [[ -d "$DOCS_PUBLIC/showcase" ]] || skip "showcase/ not present (optional)"
}


@test "13. docs/public/visualiser.html exists" {
  [[ -f "$DOCS_PUBLIC/visualiser.html" ]] || {
    echo "FAIL: visualiser.html missing from docs/public/" >&2
    return 1
  }
}

@test "14. docs/public/ has no unexpected subdirectories (only logs/, showcase/, and img/ allowed)" {
  local subdirs
  subdirs=$(find "$DOCS_PUBLIC" -mindepth 1 -maxdepth 1 -type d ! -name "logs" ! -name "showcase" ! -name "img" ! -name ".playwright-cli")
  [[ -z "$subdirs" ]] || {
    echo "FAIL: docs/public/ contains unexpected subdirectories: $subdirs" >&2
    return 1
  }
}

@test "15. all files in docs/public/ are non-empty" {
  local failed=0
  while IFS= read -r -d '' f; do
    [[ -s "$f" ]] || {
      echo "FAIL: $f is empty" >&2
      failed=1
    }
  done < <(find "$DOCS_PUBLIC" -maxdepth 1 -name "*.html" -print0)
  [[ "$failed" -eq 0 ]]
}

@test "16. all files in docs/public/ are valid HTML (contain <html or <!DOCTYPE)" {
  local failed=0
  while IFS= read -r -d '' f; do
    if ! grep -qi '<html\|<!DOCTYPE' "$f"; then
      echo "FAIL: $f does not appear to be a valid HTML file" >&2
      failed=1
    fi
  done < <(find "$DOCS_PUBLIC" -maxdepth 1 -name "*.html" -print0)
  [[ "$failed" -eq 0 ]]
}

# ── Step 2: Link rewrites ─────────────────────────────────────────────────────

@test "17. index.html has no absolute /docs/ paths" {
  grep -q '/docs/' "$DOCS_PUBLIC/index.html" && {
    echo "FAIL: index.html still contains /docs/ absolute path" >&2
    grep -n '/docs/' "$DOCS_PUBLIC/index.html" >&2
    return 1
  }
  return 0
}

@test "18. index.html links to showcase.html" {
  local count
  count=$(grep -o 'showcase\.html' "$DOCS_PUBLIC/index.html" | wc -l | tr -d ' ')
  [[ "$count" -ge 1 ]] || {
    echo "FAIL: index.html has no links to showcase.html (expected >= 1)" >&2
    return 1
  }
}

@test "20. showcase.html links to visualiser.html at least once" {
  local count
  count=$(grep -o 'visualiser\.html' "$DOCS_PUBLIC/showcase.html" | wc -l | tr -d ' ')
  [[ "$count" -ge 1 ]] || {
    echo "FAIL: showcase.html has no links to visualiser.html (expected >= 1)" >&2
    return 1
  }
}

@test "21. no /docs/ absolute paths in any file under docs/public/" {
  local files_with_abs_paths
  files_with_abs_paths=$(grep -rl '/docs/' "$DOCS_PUBLIC/" 2>/dev/null || true)
  [[ -z "$files_with_abs_paths" ]] || {
    echo "FAIL: the following files contain /docs/ absolute paths:" >&2
    echo "$files_with_abs_paths" >&2
    return 1
  }
}

@test "22. no ../ relative paths in root-level docs/public/ files" {
  # Subdirectory files (e.g. showcase/*.html) legitimately use ../ to navigate up.
  # Only root-level HTML files should avoid ../ paths.
  local files_with_rel_paths
  files_with_rel_paths=$(find "$DOCS_PUBLIC" -maxdepth 1 -name "*.html" -print0 \
    | xargs -0 grep -l '\.\.\/' 2>/dev/null || true)
  [[ -z "$files_with_rel_paths" ]] || {
    echo "FAIL: the following root-level files contain ../ relative paths:" >&2
    echo "$files_with_rel_paths" >&2
    return 1
  }
}

# ── Step 3: deploy-pages.yml workflow (single smart workflow) ────────────────

@test "23. plugin-repo deploy-pages.yml exists" {
  [[ -f "$DEPLOY_WORKFLOW" ]] || {
    echo "FAIL: $DEPLOY_WORKFLOW missing" >&2
    return 1
  }
}

@test "24. deploy-pages.yml is valid YAML" {
  command -v python3 || skip "python3 not available"
  python3 -c "import yaml; yaml.safe_load(open('$DEPLOY_WORKFLOW'))" 2>&1 || {
    echo "FAIL: $DEPLOY_WORKFLOW is not valid YAML" >&2
    return 1
  }
}

@test "25. deploy-pages.yml triggers on push to main" {
  grep -q 'branches:' "$DEPLOY_WORKFLOW" || {
    echo "FAIL: deploy-pages.yml missing branches: trigger" >&2
    return 1
  }
  grep -q 'main' "$DEPLOY_WORKFLOW" || {
    echo "FAIL: deploy-pages.yml does not trigger on main branch" >&2
    return 1
  }
}

@test "26. deploy-pages.yml paths filter scopes to docs/**" {
  grep -q "docs/\*\*" "$DEPLOY_WORKFLOW" || {
    echo "FAIL: deploy-pages.yml paths filter must target docs/**" >&2
    return 1
  }
}

@test "27. deploy-pages.yml detects docs path dynamically" {
  grep -q 'docs/public' "$DEPLOY_WORKFLOW" || {
    echo "FAIL: deploy-pages.yml must detect docs/public path" >&2
    return 1
  }
  grep -q 'GITHUB_OUTPUT' "$DEPLOY_WORKFLOW" || {
    echo "FAIL: deploy-pages.yml must output detected path via GITHUB_OUTPUT" >&2
    return 1
  }
}

@test "28. deploy-pages.yml has required permissions" {
  grep -q 'pages: write' "$DEPLOY_WORKFLOW" || {
    echo "FAIL: deploy-pages.yml missing pages: write permission" >&2
    return 1
  }
  grep -q 'id-token: write' "$DEPLOY_WORKFLOW" || {
    echo "FAIL: deploy-pages.yml missing id-token: write permission" >&2
    return 1
  }
}

@test "29. deploy-pages.yml uses concurrency group 'pages'" {
  grep -q "group: pages" "$DEPLOY_WORKFLOW" || {
    echo "FAIL: deploy-pages.yml missing concurrency group 'pages'" >&2
    return 1
  }
}

@test "30. deploy-pages.yml uses actions/checkout@v4" {
  grep -q 'actions/checkout@v4' "$DEPLOY_WORKFLOW" || {
    echo "FAIL: deploy-pages.yml must use actions/checkout@v4" >&2
    return 1
  }
}

@test "31. deploy-pages.yml uses actions/configure-pages@v5" {
  grep -q 'actions/configure-pages@v5' "$DEPLOY_WORKFLOW" || {
    echo "FAIL: deploy-pages.yml must use actions/configure-pages@v5" >&2
    return 1
  }
}

@test "32. deploy-pages.yml uses actions/upload-pages-artifact@v4" {
  grep -q 'actions/upload-pages-artifact@v4' "$DEPLOY_WORKFLOW" || {
    echo "FAIL: deploy-pages.yml must use actions/upload-pages-artifact@v4" >&2
    return 1
  }
}

@test "33. deploy-pages.yml uses actions/deploy-pages@v5" {
  grep -q 'actions/deploy-pages@v5' "$DEPLOY_WORKFLOW" || {
    echo "FAIL: deploy-pages.yml must use actions/deploy-pages@v5" >&2
    return 1
  }
}

@test "34. deploy-pages.yml has github-pages environment" {
  grep -q 'name: github-pages' "$DEPLOY_WORKFLOW" || {
    echo "FAIL: deploy-pages.yml must declare github-pages environment" >&2
    return 1
  }
}

@test "35. deploy-pages.yml passes actionlint" {
  command -v actionlint || skip "actionlint not installed"
  local al_output
  al_output=$(actionlint -shellcheck="" "$DEPLOY_WORKFLOW" 2>&1) || {
    echo "$al_output" >&2
    return 1
  }
}

@test "36. deploy-pages.yml declares cancel-in-progress: false" {
  grep -q 'cancel-in-progress: false' "$DEPLOY_WORKFLOW" || {
    echo "FAIL: deploy-pages.yml must have cancel-in-progress: false" >&2
    return 1
  }
}

@test "37. plugin-repo deploy-pages workflow exists" {
  [[ -f "$PROJECT_ROOT/.claude-agent-flow/plugin-repo-workflows/deploy-pages.yml" ]] || {
    echo "FAIL: plugin-repo deploy-pages workflow missing" >&2
    return 1
  }
}

# ── Step 4: publish-plugin-manifest.yml ──────────────────────────────────────

@test "38. publish-plugin-manifest.yml contains docs/public/ repo_mapping entry" {
  grep -q 'docs/public/' "$PUBLISH_MANIFEST" || {
    echo "FAIL: publish-plugin-manifest.yml missing docs/public/ entry in repo_mappings" >&2
    return 1
  }
}

@test "39. docs/public/ entry has correct target: docs/" {
  local found=0
  while IFS= read -r line; do
    if [[ "$line" == *'source: "docs/public/"'* ]]; then
      found=1
    fi
    if [[ "$found" -eq 1 ]] && [[ "$line" == *'target: "docs/"'* ]]; then
      found=2
      break
    fi
  done < "$PUBLISH_MANIFEST"
  [[ "$found" -eq 2 ]] || {
    echo "FAIL: docs/public/ entry does not have target: docs/ immediately following" >&2
    return 1
  }
}

@test "40. docs/public/ entry has type: directory" {
  local in_entry=0
  while IFS= read -r line; do
    if [[ "$line" == *'source: "docs/public/"'* ]]; then
      in_entry=1
    fi
    if [[ "$in_entry" -eq 1 ]] && [[ "$line" == *'type: directory'* ]]; then
      in_entry=2
      break
    fi
    if [[ "$in_entry" -eq 1 ]] && [[ "$line" == *'- source:'* ]] && [[ "$line" != *'docs/public/'* ]]; then
      break
    fi
  done < "$PUBLISH_MANIFEST"
  [[ "$in_entry" -eq 2 ]] || {
    echo "FAIL: docs/public/ entry does not have type: directory" >&2
    return 1
  }
}

@test "41. docs/public/ entry is inside repo_mappings section (not plugin_mappings)" {
  local repo_mappings_line global_excludes_line docs_public_line
  repo_mappings_line=$(grep -n '^repo_mappings:' "$PUBLISH_MANIFEST" | cut -d: -f1)
  global_excludes_line=$(grep -n '^global_excludes:' "$PUBLISH_MANIFEST" | cut -d: -f1)
  docs_public_line=$(grep -n 'docs/public/' "$PUBLISH_MANIFEST" | cut -d: -f1)

  [[ -n "$repo_mappings_line" ]] || { echo "FAIL: repo_mappings: not found"; return 1; }
  [[ -n "$global_excludes_line" ]] || { echo "FAIL: global_excludes: not found"; return 1; }
  [[ -n "$docs_public_line" ]] || { echo "FAIL: docs/public/ not found in manifest"; return 1; }

  [[ "$docs_public_line" -gt "$repo_mappings_line" ]] || {
    echo "FAIL: docs/public/ entry appears before repo_mappings section" >&2
    return 1
  }
  [[ "$docs_public_line" -lt "$global_excludes_line" ]] || {
    echo "FAIL: docs/public/ entry appears after global_excludes section" >&2
    return 1
  }
}

@test "42. deploy-pages.yml is NOT in global_excludes" {
  local global_excludes_block
  global_excludes_block=$(sed -n '/^global_excludes:/,$p' "$PUBLISH_MANIFEST")
  echo "$global_excludes_block" | grep -q 'deploy-pages' && {
    echo "FAIL: deploy-pages.yml appears in global_excludes — should not be excluded" >&2
    return 1
  }
  return 0
}

@test "43. publish-plugin-manifest.yml is valid YAML after update" {
  command -v python3 || skip "python3 not available"
  python3 -c "import yaml; yaml.safe_load(open('$PUBLISH_MANIFEST'))" 2>&1 || {
    echo "FAIL: publish-plugin-manifest.yml is not valid YAML after update" >&2
    return 1
  }
}

@test "44. publish-plugin-manifest.yml version field is unchanged (still 1)" {
  local version
  version=$(grep '^version:' "$PUBLISH_MANIFEST" | awk '{print $2}')
  [[ "$version" == "1" ]] || {
    echo "FAIL: publish-plugin-manifest.yml version changed; expected 1, got $version" >&2
    return 1
  }
}

# ── Constraint checks ─────────────────────────────────────────────────────────

@test "45. docs/plugin-testing-guide.md still exists and is unchanged (not empty)" {
  local guide="$PROJECT_ROOT/docs/plugin-testing-guide.md"
  [[ -f "$guide" ]] || {
    echo "FAIL: docs/plugin-testing-guide.md was deleted" >&2
    return 1
  }
  [[ -s "$guide" ]] || {
    echo "FAIL: docs/plugin-testing-guide.md is now empty" >&2
    return 1
  }
}

@test "46. .claude-agent-flow/docs/ directory exists and is unchanged" {
  local af_docs="$PROJECT_ROOT/.claude-agent-flow/docs"
  [[ -d "$af_docs" ]] || {
    echo "FAIL: .claude-agent-flow/docs/ directory missing" >&2
    return 1
  }
  local count
  count=$(find "$af_docs" -maxdepth 1 -type f | wc -l | tr -d ' ')
  [[ "$count" -gt 0 ]] || {
    echo "FAIL: .claude-agent-flow/docs/ appears to have been cleared" >&2
    return 1
  }
}

@test "47. docs/public/ does not contain _config.yml" {
  [[ ! -f "$DOCS_PUBLIC/_config.yml" ]] || {
    echo "FAIL: _config.yml must not exist in docs/public/" >&2
    return 1
  }
}

@test "48. docs/public/ does not contain .nojekyll" {
  [[ ! -f "$DOCS_PUBLIC/.nojekyll" ]] || {
    echo "FAIL: .nojekyll must not exist in docs/public/" >&2
    return 1
  }
}

@test "49. docs/public/ contains only expected file types (HTML, robots.txt, sitemap.xml)" {
  local unexpected
  unexpected=$(find "$DOCS_PUBLIC" -maxdepth 1 -type f ! -name "*.html" ! -name ".DS_Store" ! -name ".gitignore" ! -name "robots.txt" ! -name "sitemap.xml")
  [[ -z "$unexpected" ]] || {
    echo "FAIL: docs/public/ contains unexpected files: $unexpected" >&2
    return 1
  }
}

# ── Boundary / regression guards ──────────────────────────────────────────────

@test "50. docs/public/ nested HTML only exists under showcase/ (flat structure elsewhere)" {
  local nested
  nested=$(find "$DOCS_PUBLIC" -mindepth 2 -name "*.html" ! -path "*/showcase/*")
  [[ -z "$nested" ]] || {
    echo "FAIL: unexpected nested HTML files found outside showcase/: $nested" >&2
    return 1
  }
}

@test "51. all main pages use 'Why Agent Flow' nav label (not bare 'Why')" {
  local failed=0
  for page in index.html why-agent-flow.html showcase.html getting-started.html about.html build-pipeline.html plan-pipeline.html review-pipeline.html; do
    local f="$DOCS_PUBLIC/$page"
    [[ -f "$f" ]] || continue
    if grep -q '>Why<' "$f"; then
      echo "FAIL: $page uses bare '>Why<' nav label — should be 'Why Agent Flow'" >&2
      failed=1
    fi
  done
  [[ "$failed" -eq 0 ]]
}

# ── SEO & Social Preview tests ──────────────────────────────────────────────

@test "52. robots.txt exists in docs/public/" {
  [[ -f "$DOCS_PUBLIC/robots.txt" ]] || {
    echo "FAIL: docs/public/robots.txt missing" >&2
    return 1
  }
}

@test "53. robots.txt contains Sitemap directive" {
  grep -qi 'Sitemap:' "$DOCS_PUBLIC/robots.txt" || {
    echo "FAIL: robots.txt missing Sitemap directive" >&2
    return 1
  }
}

@test "54. sitemap.xml exists in docs/public/" {
  [[ -f "$DOCS_PUBLIC/sitemap.xml" ]] || {
    echo "FAIL: docs/public/sitemap.xml missing" >&2
    return 1
  }
}

@test "55. sitemap.xml is valid XML" {
  command -v python3 || skip "python3 not available"
  python3 -c "
import xml.etree.ElementTree as ET
ET.parse('$DOCS_PUBLIC/sitemap.xml')
" 2>&1 || {
    echo "FAIL: sitemap.xml is not valid XML" >&2
    return 1
  }
}

@test "56. all root HTML pages contain og:title meta tag" {
  local failed=0
  while IFS= read -r -d '' f; do
    if ! grep -q 'og:title' "$f"; then
      echo "FAIL: $(basename "$f") missing og:title" >&2
      failed=1
    fi
  done < <(find "$DOCS_PUBLIC" -maxdepth 1 -name "*.html" -print0)
  [[ "$failed" -eq 0 ]]
}

@test "57. all root HTML pages contain og:description meta tag" {
  local failed=0
  while IFS= read -r -d '' f; do
    if ! grep -q 'og:description' "$f"; then
      echo "FAIL: $(basename "$f") missing og:description" >&2
      failed=1
    fi
  done < <(find "$DOCS_PUBLIC" -maxdepth 1 -name "*.html" -print0)
  [[ "$failed" -eq 0 ]]
}

@test "58. all HTML pages use consistent og:image URL" {
  local expected_image="https://timgranlundmarsden.github.io/claude-agent-flow/img/og-image-v2.png"
  local failed=0
  while IFS= read -r -d '' f; do
    if ! grep -q "$expected_image" "$f"; then
      echo "FAIL: $(basename "$f") has wrong or missing og:image URL" >&2
      failed=1
    fi
  done < <(find "$DOCS_PUBLIC" -name "*.html" -print0)
  [[ "$failed" -eq 0 ]]
}

@test "59. og-image.png exists in docs/public/img/" {
  [[ -f "$DOCS_PUBLIC/img/og-image-v2.png" ]] || {
    echo "FAIL: docs/public/img/og-image.png missing" >&2
    return 1
  }
}


@test "61. all HTML pages contain twitter:card meta tag" {
  local failed=0
  while IFS= read -r -d '' f; do
    if ! grep -q 'twitter:card' "$f"; then
      echo "FAIL: $(basename "$f") missing twitter:card" >&2
      failed=1
    fi
  done < <(find "$DOCS_PUBLIC" -name "*.html" -print0)
  [[ "$failed" -eq 0 ]]
}

@test "62. all HTML pages contain twitter:image meta tag" {
  local failed=0
  while IFS= read -r -d '' f; do
    if ! grep -q 'twitter:image' "$f"; then
      echo "FAIL: $(basename "$f") missing twitter:image" >&2
      failed=1
    fi
  done < <(find "$DOCS_PUBLIC" -name "*.html" -print0)
  [[ "$failed" -eq 0 ]]
}

@test "63. all HTML pages contain canonical link" {
  local failed=0
  while IFS= read -r -d '' f; do
    if ! grep -q 'rel="canonical"' "$f"; then
      echo "FAIL: $(basename "$f") missing canonical link" >&2
      failed=1
    fi
  done < <(find "$DOCS_PUBLIC" -name "*.html" -print0)
  [[ "$failed" -eq 0 ]]
}

@test "64. all root HTML pages contain meta name=description" {
  local failed=0
  while IFS= read -r -d '' f; do
    if ! grep -q 'name="description"' "$f"; then
      echo "FAIL: $(basename "$f") missing meta description" >&2
      failed=1
    fi
  done < <(find "$DOCS_PUBLIC" -maxdepth 1 -name "*.html" -print0)
  [[ "$failed" -eq 0 ]]
}

@test "65. sitemap.xml lists exactly 9 URLs" {
  local count
  count=$(grep -c '<loc>' "$DOCS_PUBLIC/sitemap.xml")
  [[ "$count" -eq 9 ]] || {
    echo "FAIL: sitemap.xml lists $count URLs, expected 9" >&2
    return 1
  }
}

@test "66. all HTML pages contain og:url meta tag" {
  local failed=0
  while IFS= read -r -d '' f; do
    if ! grep -q 'og:url' "$f"; then
      echo "FAIL: $(basename "$f") missing og:url" >&2
      failed=1
    fi
  done < <(find "$DOCS_PUBLIC" -name "*.html" -print0)
  [[ "$failed" -eq 0 ]]
}

@test "67. all HTML pages contain og:type meta tag" {
  local failed=0
  while IFS= read -r -d '' f; do
    if ! grep -q 'og:type' "$f"; then
      echo "FAIL: $(basename "$f") missing og:type" >&2
      failed=1
    fi
  done < <(find "$DOCS_PUBLIC" -name "*.html" -print0)
  [[ "$failed" -eq 0 ]]
}

@test "68. all HTML pages contain og:site_name meta tag" {
  local failed=0
  while IFS= read -r -d '' f; do
    if ! grep -q 'og:site_name' "$f"; then
      echo "FAIL: $(basename "$f") missing og:site_name" >&2
      failed=1
    fi
  done < <(find "$DOCS_PUBLIC" -name "*.html" -print0)
  [[ "$failed" -eq 0 ]]
}

@test "69. index.html contains hero-intro paragraph" {
  grep -q 'class="hero-intro"' "$DOCS_PUBLIC/index.html" || {
    echo "FAIL: index.html missing hero-intro paragraph" >&2
    return 1
  }
  grep -q '12 specialized AI agents' "$DOCS_PUBLIC/index.html" || {
    echo "FAIL: index.html hero-intro missing expected text" >&2
    return 1
  }
}

# ── Step 8: Log file PII checks ─────────────────────────────────────────────

@test "70. log JSON files contain no real GitHub owner" {
  local remote_url
  remote_url=$(git remote get-url origin 2>/dev/null) || skip "no git origin remote"
  local real_owner
  real_owner=$(printf '%s' "$remote_url" | sed -E 's|.*[:/]([^/]+)/[^/]+$|\1|; s|\.git$||')
  [[ -z "$real_owner" || "$real_owner" == "$remote_url" ]] && skip "cannot parse owner from remote URL"
  local failed=0
  while IFS= read -r -d '' f; do
    if grep -qiF "$real_owner" "$f"; then
      echo "FAIL: $(basename "$f") contains real owner '$real_owner'" >&2
      grep -inF "$real_owner" "$f" | head -3 >&2
      failed=1
    fi
  done < <(find "$DOCS_PUBLIC/logs" -name "*.json" -print0 2>/dev/null)
  [[ "$failed" -eq 0 ]]
}

@test "71. log JSON files contain no /Users/ or real home directory paths" {
  [[ -d "$DOCS_PUBLIC/logs" ]] || skip "no logs directory"
  local failed=0
  local file_count=0
  while IFS= read -r -d '' f; do
    ((file_count++)) || true
    # /Users/ is always PII (macOS home dirs). /home/ alone is too broad —
    # sanitised logs use /home/user/my-project as the placeholder.
    # Detect real home dirs: /home/<name>/ where <name> is NOT the sanitised "user".
    local has_pii=false
    if grep -q '/Users/' "$f"; then
      has_pii=true
    elif grep -qE '/home/[a-zA-Z0-9._-]+/' "$f" && grep -E '/home/[a-zA-Z0-9._-]+/' "$f" | grep -qvF '/home/user/'; then
      has_pii=true
    fi
    if [[ "$has_pii" == true ]]; then
      echo "FAIL: $(basename "$f") contains home directory path" >&2
      grep -nE '/Users/|/home/[a-zA-Z0-9._-]+/' "$f" | grep -vF '/home/user/' | head -3 >&2
      failed=1
    fi
  done < <(find "$DOCS_PUBLIC/logs" -name "*.json" -print0 2>/dev/null)
  [[ "$file_count" -gt 0 ]] || skip "no log JSON files found"
  [[ "$failed" -eq 0 ]]
}

@test "72. log JSON files contain no /docs/ absolute host paths" {
  # Match absolute host paths like /Users/x/project/docs/ or /home/x/project/docs/
  # but not relative refs like "./docs/" or documentation URLs like "example.com/docs/"
  local failed=0
  while IFS= read -r -d '' f; do
    # Absolute path pattern: starts a value and leads with / into a dir tree containing /docs/
    if grep -qE '(^|[" ])/[a-zA-Z0-9._-]+(/[a-zA-Z0-9._-]+)*/docs/' "$f"; then
      echo "FAIL: $(basename "$f") contains absolute /docs/ host path" >&2
      grep -nE '(^|[" ])/[a-zA-Z0-9._-]+(/[a-zA-Z0-9._-]+)*/docs/' "$f" | head -3 >&2
      failed=1
    fi
  done < <(find "$DOCS_PUBLIC/logs" -name "*.json" -print0 2>/dev/null)
  [[ "$failed" -eq 0 ]]
}

@test "73. log JSON files contain no Claude session URLs" {
  local failed=0
  while IFS= read -r -d '' f; do
    if grep -qE 'claude\.ai/code/session_[A-Za-z0-9]{10,}' "$f"; then
      echo "FAIL: $(basename "$f") contains real Claude session URL" >&2
      grep -oE 'claude\.ai/code/session_[A-Za-z0-9]+' "$f" | head -3 >&2
      failed=1
    fi
  done < <(find "$DOCS_PUBLIC/logs" -name "*.json" -print0 2>/dev/null)
  [[ "$failed" -eq 0 ]]
}

@test "74. log JSON files contain no raw AskUserQuestion tool-calls" {
  local failed=0
  while IFS= read -r -d '' f; do
    # Check top-level events only — raw tool-call/tool-result events with AskUserQuestion
    # should have been converted to 'question' kind by the converter
    if python3 -c "
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
for i, ev in enumerate(data.get('events', [])):
    if ev.get('kind') in ('tool-call', 'tool-result') and ev.get('tool') == 'AskUserQuestion':
        print(f'events[{i}]: raw AskUserQuestion {ev[\"kind\"]}', file=sys.stderr)
        sys.exit(1)
" "$f" 2>&1; then
      :
    else
      echo "FAIL: $(basename "$f") has raw AskUserQuestion tool-call (should be question event)" >&2
      failed=1
    fi
  done < <(find "$DOCS_PUBLIC/logs" -name "*.json" -print0 2>/dev/null)
  [[ "$failed" -eq 0 ]]
}

@test "75. log JSON transition events use transition IDs not agent names" {
  local failed=0
  while IFS= read -r -d '' f; do
    local result
    result=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as fh:
        data = json.load(fh)
except (json.JSONDecodeError, IOError) as e:
    print(f'PARSE_ERROR: {e}', file=sys.stderr)
    sys.exit(2)

valid_ids = {t['id'] for t in data.get('transitions', []) if 'id' in t}
errors = []
for i, ev in enumerate(data.get('events', [])):
    if ev.get('kind') != 'transition':
        continue
    if 'transition' not in ev:
        errors.append(f'events[{i}]: missing transition ID (has to={ev.get(\"to\",\"?\")})')
    elif valid_ids and ev['transition'] not in valid_ids:
        errors.append(f'events[{i}]: transition={ev[\"transition\"]!r} not in transitions[] IDs')
    if 'to' in ev:
        errors.append(f'events[{i}]: legacy to={ev[\"to\"]!r} field should be removed')
if errors:
    for e in errors:
        print(e, file=sys.stderr)
    sys.exit(1)
" "$f" 2>&1)
    local rc=$?
    if [[ "$rc" -eq 2 ]]; then
      echo "SKIP: $(basename "$f") could not be parsed: $result" >&2
    elif [[ "$rc" -ne 0 ]]; then
      echo "FAIL: $(basename "$f") transition validation errors:" >&2
      echo "$result" >&2
      failed=1
    fi
  done < <(find "$DOCS_PUBLIC/logs" -name "*.json" -print0 2>/dev/null)
  [[ "$failed" -eq 0 ]]
}
