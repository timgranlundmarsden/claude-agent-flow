#!/usr/bin/env bats
# Tests for manifest-driven file change detection
#
# Validates that given a filename, the workflow detection logic correctly
# identifies whether it matches a managed_files glob or merge_files path
# in the manifest — i.e., whether a commit touching that file would trigger
# a downstream sync PR.

setup() {
  load test_helper
  setup_temp_dirs
  # Build a realistic source tree matching the production manifest patterns
  mkdir -p "$SOURCE_DIR/.claude/agents"
  mkdir -p "$SOURCE_DIR/.claude/commands"
  mkdir -p "$SOURCE_DIR/.claude/skills/ways-of-working"
  mkdir -p "$SOURCE_DIR/.claude/skills/brainstorming"
  mkdir -p "$SOURCE_DIR/.claude-plugin"
  mkdir -p "$SOURCE_DIR/.claude-agent-flow/bin"
  mkdir -p "$SOURCE_DIR/.claude-agent-flow/scripts"
  mkdir -p "$SOURCE_DIR/.claude-agent-flow/tests"
  mkdir -p "$SOURCE_DIR/.github/workflows"
  # Create files that match the production glob patterns
  touch "$SOURCE_DIR/.claude/agents/frontend.md"
  touch "$SOURCE_DIR/.claude/agents/backend.md"
  touch "$SOURCE_DIR/.claude/commands/build.md"
  touch "$SOURCE_DIR/.claude/commands/plan.md"
  touch "$SOURCE_DIR/.claude/commands/review.md"
  touch "$SOURCE_DIR/.claude/commands/rebase.md"
  touch "$SOURCE_DIR/.claude/commands/token-analyser.md"
  touch "$SOURCE_DIR/.claude/skills/ways-of-working/SKILL.md"
  touch "$SOURCE_DIR/.claude/skills/brainstorming/SKILL.md"
  touch "$SOURCE_DIR/.claude-plugin/plugin.json"
  touch "$SOURCE_DIR/.mcp.json"
  touch "$SOURCE_DIR/.claude-agent-flow/bin/mergiraf-linux.tar.gz"
  touch "$SOURCE_DIR/.claude-agent-flow/repo-sync-manifest.yml"
  touch "$SOURCE_DIR/.claude-agent-flow/scripts/repo-sync-files.sh"
  touch "$SOURCE_DIR/.claude-agent-flow/tests/test_helper.bash"
  touch "$SOURCE_DIR/.github/workflows/agent-flow-downstream.yml"
  touch "$SOURCE_DIR/.github/workflows/agent-flow-upstream.yml"
  touch "$SOURCE_DIR/.github/workflows/agent-flow-tests.yml"
}

# Helper: extract managed paths from manifest using the same Python logic as the workflows
# Returns one path per line (expanded globs + merge_files paths)
extract_managed_paths() {
  local manifest_dir="$1"
  pushd "$manifest_dir" > /dev/null
  python3 -c "
import yaml, glob, os
with open('.claude-agent-flow/repo-sync-manifest.yml') as f:
    manifest = yaml.safe_load(f)
paths = []
for entry in manifest.get('managed_files', []):
    if isinstance(entry, str):
        expanded = glob.glob(entry, recursive=True)
        if expanded:
            paths.extend(expanded)
        else:
            paths.append(entry)
for entry in manifest.get('merge_files', []):
    if isinstance(entry, dict) and 'path' in entry:
        paths.append(entry['path'])
for p in sorted(set(paths)):
    print(p)
"
  popd > /dev/null
}

# Helper: check if a filename would be detected as a managed file change
# Returns 0 (true) if it would trigger sync, 1 (false) if not
# Mirrors the real workflow: managed paths are passed to `git diff --name-only ... -- <paths>`
# which matches files exactly OR files under directory prefixes
would_trigger_sync() {
  local manifest_dir="$1"
  local filename="$2"
  local managed_paths
  managed_paths=$(extract_managed_paths "$manifest_dir")
  # Check exact match first
  if echo "$managed_paths" | grep -qxF "$filename"; then
    return 0
  fi
  # Check if filename is under a managed directory (trailing-slash paths)
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    if [[ "$path" == */ ]]; then
      # Directory path: check if filename is under it or matches the dir itself
      local dir_prefix="${path%/}"
      if [[ "$filename" == "${path}"* ]] || [[ "$filename" == "$dir_prefix" ]]; then
        return 0
      fi
    fi
  done <<< "$managed_paths"
  return 1
}

# Write the production-like manifest
write_production_manifest() {
  cat > "$SOURCE_DIR/.claude-agent-flow/repo-sync-manifest.yml" << 'EOF'
version: 2
source_repo: "testorg/source"
managed_files:
  - .claude/agents/*.md
  - .claude/commands/*.md
  - .claude/skills/*/
  - .claude-plugin/
  - .mcp.json
  - .claude-agent-flow/bin/mergiraf-*.tar.gz
  - .claude-agent-flow/
  - .github/workflows/agent-flow-*.yml
  - .github/workflows/agent-flow-tests.yml
merge_files:
  - path: .claude/settings.json
    strategy: json-deep-merge
  - path: CLAUDE.md
    strategy: section-patch
  - path: .gitignore
    strategy: append-missing
  - path: .gitattributes
    strategy: append-missing
  - path: backlog/config.yml
    strategy: template
  - path: .claude-agent-flow/hooks/session-start.sh
    strategy: overwrite
targets: []
EOF
}

# ── SECTION 1: Managed files — positive matches (list-driven) ──────────────

@test "1. agent .md and command .md files match glob (list-driven)" {
  write_production_manifest
  touch "$SOURCE_DIR/.claude/agents/custom-agent.md"
  touch "$SOURCE_DIR/.claude/commands/my-custom-cmd.md"
  local should_match=(
    ".claude/agents/frontend.md"
    ".claude/agents/backend.md"
    ".claude/agents/custom-agent.md"
    ".claude/commands/build.md"
    ".claude/commands/plan.md"
    ".claude/commands/review.md"
    ".claude/commands/rebase.md"
    ".claude/commands/token-analyser.md"
    ".claude/commands/my-custom-cmd.md"
  )
  local f
  for f in "${should_match[@]}"; do
    run would_trigger_sync "$SOURCE_DIR" "$f"
    assert_success || { echo "FAIL: $f should trigger sync but did not" >&2; return 1; }
  done
}

@test "2. skill directories match glob (list-driven)" {
  write_production_manifest
  mkdir -p "$SOURCE_DIR/.claude/skills/my-custom-skill"
  local should_match=(
    ".claude/skills/ways-of-working"
    ".claude/skills/ways-of-working/SKILL.md"
    ".claude/skills/my-custom-skill"
  )
  local f
  for f in "${should_match[@]}"; do
    run would_trigger_sync "$SOURCE_DIR" "$f"
    assert_success || { echo "FAIL: $f should trigger sync but did not" >&2; return 1; }
  done
}

@test "3. plugin, mcp.json, and bin files match (list-driven)" {
  write_production_manifest
  local should_match=(
    ".claude-plugin/plugin.json"
    ".mcp.json"
    ".claude-agent-flow/bin/mergiraf-linux.tar.gz"
    ".claude-agent-flow/scripts/repo-sync-files.sh"
    ".claude-agent-flow/repo-sync-manifest.yml"
    ".claude-agent-flow/tests/test_helper.bash"
  )
  local f
  for f in "${should_match[@]}"; do
    run would_trigger_sync "$SOURCE_DIR" "$f"
    assert_success || { echo "FAIL: $f should trigger sync but did not" >&2; return 1; }
  done
}

@test "4. workflow files match glob; agent-flow-tests.yml matches via explicit entry" {
  # Note: agent-flow-tests.yml uses plural 'tests' so it does NOT match agent-flow-*.yml glob,
  # but IS explicitly listed as a separate managed_files entry.
  write_production_manifest
  local should_match=(
    ".github/workflows/agent-flow-downstream.yml"
    ".github/workflows/agent-flow-upstream.yml"
    ".github/workflows/agent-flow-tests.yml"
  )
  local f
  for f in "${should_match[@]}"; do
    run would_trigger_sync "$SOURCE_DIR" "$f"
    assert_success || { echo "FAIL: $f should trigger sync but did not" >&2; return 1; }
  done
}

@test "5. non-agent-flow workflow files do NOT match (list-driven)" {
  write_production_manifest
  local should_not_match=(
    ".github/workflows/ci.yml"
    ".github/workflows/deploy.yml"
  )
  local f
  for f in "${should_not_match[@]}"; do
    run would_trigger_sync "$SOURCE_DIR" "$f"
    assert_failure || { echo "FAIL: $f should NOT trigger sync but did" >&2; return 1; }
  done
}

# ── SECTION 2: Merge files path matching ────────────────────────────────────

@test "6. merge_files paths are included in managed paths (list-driven)" {
  write_production_manifest
  local should_match=(
    ".claude/settings.json"
    "CLAUDE.md"
    ".gitignore"
    ".gitattributes"
    "backlog/config.yml"
    ".claude-agent-flow/hooks/session-start.sh"
  )
  local f
  for f in "${should_match[@]}"; do
    run would_trigger_sync "$SOURCE_DIR" "$f"
    assert_success || { echo "FAIL: $f should trigger sync but did not" >&2; return 1; }
  done
}

# ── SECTION 3: Negative cases — files that must NOT trigger sync (list-driven)

@test "7. application code and config files do NOT trigger sync (list-driven)" {
  write_production_manifest
  local should_not_match=(
    "README.md"
    "src/index.ts"
    "src/components/App.tsx"
    "package.json"
    "tsconfig.json"
    ".eslintrc.js"
    ".claude/settings.local.json"
  )
  local f
  for f in "${should_not_match[@]}"; do
    run would_trigger_sync "$SOURCE_DIR" "$f"
    assert_failure || { echo "FAIL: $f should NOT trigger sync but did" >&2; return 1; }
  done
}

# ── SECTION 4: Edge cases ───────────────────────────────────────────────────

@test "8. empty manifest returns no managed paths" {
  cat > "$SOURCE_DIR/.claude-agent-flow/repo-sync-manifest.yml" << 'EOF'
version: 1
source_repo: org/source
managed_files: []
merge_files: []
targets: []
EOF
  result=$(extract_managed_paths "$SOURCE_DIR")
  [[ -z "$result" ]]
}

@test "9. manifest with only merge_files still detects those paths" {
  cat > "$SOURCE_DIR/.claude-agent-flow/repo-sync-manifest.yml" << 'EOF'
version: 1
source_repo: org/source
managed_files: []
merge_files:
  - path: CLAUDE.md
    strategy: section-patch
targets: []
EOF
  run would_trigger_sync "$SOURCE_DIR" "CLAUDE.md"
  assert_success
}

@test "10. glob that matches nothing still keeps literal pattern" {
  cat > "$SOURCE_DIR/.claude-agent-flow/repo-sync-manifest.yml" << 'EOF'
version: 1
source_repo: org/source
managed_files:
  - "nonexistent-pattern-*.xyz"
merge_files: []
targets: []
EOF
  # The literal unexpanded pattern should still appear in managed paths
  result=$(extract_managed_paths "$SOURCE_DIR")
  [[ "$result" == *"nonexistent-pattern-*.xyz"* ]]
}

@test "11. downstream detection includes both managed_files and merge_files" {
  write_production_manifest
  result=$(extract_managed_paths "$SOURCE_DIR")
  # Should have both glob-expanded managed files AND merge file paths
  [[ "$result" == *"agent-flow"* ]]
  [[ "$result" == *"CLAUDE.md"* ]]
  [[ "$result" == *".claude/settings.json"* ]]
}
