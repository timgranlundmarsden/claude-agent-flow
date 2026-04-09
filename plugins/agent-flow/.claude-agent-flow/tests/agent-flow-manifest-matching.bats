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

# ── SECTION 1: Managed files glob matching ──────────────────────────────────

@test "1. agent-flow agent .md files match glob" {
  write_production_manifest
  run would_trigger_sync "$SOURCE_DIR" ".claude/agents/frontend.md"
  assert_success
  run would_trigger_sync "$SOURCE_DIR" ".claude/agents/backend.md"
  assert_success
}

@test "2. .claude/agents/ .md files DO match" {
  write_production_manifest
  # Create the file so glob.glob() can find it
  touch "$SOURCE_DIR/.claude/agents/custom-agent.md"
  run would_trigger_sync "$SOURCE_DIR" ".claude/agents/custom-agent.md"
  assert_success
}

@test "3. agent-flow command files match glob" {
  write_production_manifest
  run would_trigger_sync "$SOURCE_DIR" ".claude/commands/build.md"
  assert_success
}

@test "4. command files in .claude/commands/ match (build, plan, review, rebase, token-analyser)" {
  write_production_manifest
  run would_trigger_sync "$SOURCE_DIR" ".claude/commands/build.md"
  assert_success
  run would_trigger_sync "$SOURCE_DIR" ".claude/commands/plan.md"
  assert_success
  run would_trigger_sync "$SOURCE_DIR" ".claude/commands/review.md"
  assert_success
  run would_trigger_sync "$SOURCE_DIR" ".claude/commands/rebase.md"
  assert_success
  run would_trigger_sync "$SOURCE_DIR" ".claude/commands/token-analyser.md"
  assert_success
}

@test "5. .claude/commands/ files DO match" {
  write_production_manifest
  touch "$SOURCE_DIR/.claude/commands/my-custom-cmd.md"
  run would_trigger_sync "$SOURCE_DIR" ".claude/commands/my-custom-cmd.md"
  assert_success
}

@test "6. agent-flow skill directories match glob" {
  write_production_manifest
  run would_trigger_sync "$SOURCE_DIR" ".claude/skills/ways-of-working"
  assert_success
  run would_trigger_sync "$SOURCE_DIR" ".claude/skills/ways-of-working/SKILL.md"
  assert_success
}

@test "7. .claude/skills/ dirs DO match managed_files" {
  write_production_manifest
  mkdir -p "$SOURCE_DIR/.claude/skills/my-custom-skill"
  run would_trigger_sync "$SOURCE_DIR" ".claude/skills/my-custom-skill"
  assert_success
}

@test "8. .claude-plugin/ directory contents match" {
  write_production_manifest
  run would_trigger_sync "$SOURCE_DIR" ".claude-plugin/plugin.json"
  assert_success
}

@test "9. .mcp.json matches managed_files" {
  write_production_manifest
  run would_trigger_sync "$SOURCE_DIR" ".mcp.json"
  assert_success
}

@test "10. mergiraf binary glob matches" {
  write_production_manifest
  run would_trigger_sync "$SOURCE_DIR" ".claude-agent-flow/bin/mergiraf-linux.tar.gz"
  assert_success
}

@test "11. .claude-agent-flow/ directory contents match" {
  write_production_manifest
  run would_trigger_sync "$SOURCE_DIR" ".claude-agent-flow/scripts/repo-sync-files.sh"
  assert_success
  run would_trigger_sync "$SOURCE_DIR" ".claude-agent-flow/repo-sync-manifest.yml"
  assert_success
  run would_trigger_sync "$SOURCE_DIR" ".claude-agent-flow/tests/test_helper.bash"
  assert_success
}

@test "12. agent-flow workflow files match glob" {
  write_production_manifest
  run would_trigger_sync "$SOURCE_DIR" ".github/workflows/agent-flow-downstream.yml"
  assert_success
  run would_trigger_sync "$SOURCE_DIR" ".github/workflows/agent-flow-upstream.yml"
  assert_success
}

@test "12b. agent-flow-tests.yml matches via explicit manifest entry" {
  # agent-flow-tests.yml uses plural 'teams' so doesn't match agent-flow-*.yml glob
  # but it IS explicitly listed in the manifest as a separate managed_files entry
  write_production_manifest
  run would_trigger_sync "$SOURCE_DIR" ".github/workflows/agent-flow-tests.yml"
  assert_success
}

@test "13. non-agent-flow workflow does NOT match" {
  write_production_manifest
  run would_trigger_sync "$SOURCE_DIR" ".github/workflows/ci.yml"
  assert_failure
  run would_trigger_sync "$SOURCE_DIR" ".github/workflows/deploy.yml"
  assert_failure
}

# ── SECTION 2: Merge files path matching ────────────────────────────────────

@test "14. merge_files paths are included in managed paths" {
  write_production_manifest
  run would_trigger_sync "$SOURCE_DIR" ".claude/settings.json"
  assert_success
  run would_trigger_sync "$SOURCE_DIR" "CLAUDE.md"
  assert_success
  run would_trigger_sync "$SOURCE_DIR" ".gitignore"
  assert_success
  run would_trigger_sync "$SOURCE_DIR" ".gitattributes"
  assert_success
  run would_trigger_sync "$SOURCE_DIR" "backlog/config.yml"
  assert_success
  run would_trigger_sync "$SOURCE_DIR" ".claude-agent-flow/hooks/session-start.sh"
  assert_success
}

# ── SECTION 3: Negative cases — files that must NOT trigger sync ────────────

@test "15. README.md does NOT trigger sync" {
  write_production_manifest
  run would_trigger_sync "$SOURCE_DIR" "README.md"
  assert_failure
}

@test "16. src/ application code does NOT trigger sync" {
  write_production_manifest
  run would_trigger_sync "$SOURCE_DIR" "src/index.ts"
  assert_failure
  run would_trigger_sync "$SOURCE_DIR" "src/components/App.tsx"
  assert_failure
}

@test "17. package.json does NOT trigger sync" {
  write_production_manifest
  run would_trigger_sync "$SOURCE_DIR" "package.json"
  assert_failure
}

@test "18. random top-level files do NOT trigger sync" {
  write_production_manifest
  run would_trigger_sync "$SOURCE_DIR" "tsconfig.json"
  assert_failure
  run would_trigger_sync "$SOURCE_DIR" ".eslintrc.js"
  assert_failure
}

@test "19. .claude/settings.local.json does NOT trigger sync" {
  write_production_manifest
  run would_trigger_sync "$SOURCE_DIR" ".claude/settings.local.json"
  assert_failure
}

# ── SECTION 4: Edge cases ───────────────────────────────────────────────────

@test "20. empty manifest returns no managed paths" {
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

@test "21. manifest with only merge_files still detects those paths" {
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

@test "22. glob that matches nothing still keeps literal pattern" {
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

@test "23. downstream detection includes both managed_files and merge_files" {
  write_production_manifest
  result=$(extract_managed_paths "$SOURCE_DIR")
  # Should have both glob-expanded managed files AND merge file paths
  [[ "$result" == *"agent-flow"* ]]
  [[ "$result" == *"CLAUDE.md"* ]]
  [[ "$result" == *".claude/settings.json"* ]]
}
