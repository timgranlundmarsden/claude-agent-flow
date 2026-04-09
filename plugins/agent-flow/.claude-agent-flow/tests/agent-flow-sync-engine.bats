#!/usr/bin/env bats
# Integration tests for repo-sync-files.sh

setup() {
  load test_helper
  setup_temp_dirs
}

# Helper: write a minimal manifest to source dir
write_manifest() {
  local dir="$1"
  local content="$2"
  mkdir -p "$dir/.claude-agent-flow"
  printf '%s\n' "$content" > "$dir/.claude-agent-flow/repo-sync-manifest.yml"
}

# ── SECTION 1: Error handling (tests 1-2) ────────────────────────────────────

@test "1. exits with error when no args" {
  run bash "$SCRIPT_DIR/repo-sync-files.sh"
  assert_failure
}

@test "2. exits with error when manifest missing" {
  run bash "$SCRIPT_DIR/repo-sync-files.sh" "$SOURCE_DIR" "$TARGET_DIR"
  assert_failure
}

# ── SECTION 2: File copying (tests 3-8) ──────────────────────────────────────

@test "3. copies literal file path" {
  echo "hello" > "$SOURCE_DIR/test.txt"
  write_manifest "$SOURCE_DIR" 'version: 1
source_repo: org/source
managed_files:
  - test.txt
targets: []'
  run bash "$SCRIPT_DIR/repo-sync-files.sh" "$SOURCE_DIR" "$TARGET_DIR"
  assert_success
  [[ -f "$TARGET_DIR/test.txt" ]]
}

@test "4. expands glob pattern" {
  echo "aaa" > "$SOURCE_DIR/a.txt"
  echo "bbb" > "$SOURCE_DIR/b.txt"
  write_manifest "$SOURCE_DIR" 'version: 1
source_repo: org/source
managed_files:
  - "*.txt"
targets: []'
  run bash "$SCRIPT_DIR/repo-sync-files.sh" "$SOURCE_DIR" "$TARGET_DIR"
  assert_success
  [[ -f "$TARGET_DIR/a.txt" ]]
  [[ -f "$TARGET_DIR/b.txt" ]]
}

@test "5. skips sync-state.json even when .claude-agent-flow/ in manifest" {
  mkdir -p "$SOURCE_DIR/.claude-agent-flow"
  echo '{"synced": true}' > "$SOURCE_DIR/.claude-agent-flow/sync-state.json"
  echo "other" > "$SOURCE_DIR/.claude-agent-flow/other.txt"
  write_manifest "$SOURCE_DIR" 'version: 1
source_repo: org/source
managed_files:
  - .claude-agent-flow/other.txt
targets: []'
  run bash "$SCRIPT_DIR/repo-sync-files.sh" "$SOURCE_DIR" "$TARGET_DIR"
  assert_success
  [[ ! -f "$TARGET_DIR/.claude-agent-flow/sync-state.json" ]]
}

@test "6. copies directory with trailing slash" {
  mkdir -p "$SOURCE_DIR/mydir"
  echo "file1" > "$SOURCE_DIR/mydir/file1.txt"
  echo "file2" > "$SOURCE_DIR/mydir/file2.txt"
  write_manifest "$SOURCE_DIR" 'version: 1
source_repo: org/source
managed_files:
  - mydir/
targets: []'
  run bash "$SCRIPT_DIR/repo-sync-files.sh" "$SOURCE_DIR" "$TARGET_DIR"
  assert_success
  [[ -f "$TARGET_DIR/mydir/file1.txt" ]]
  [[ -f "$TARGET_DIR/mydir/file2.txt" ]]
}

@test "7. copies nested file under directory" {
  mkdir -p "$SOURCE_DIR/subdir"
  echo "nested" > "$SOURCE_DIR/subdir/nested.txt"
  write_manifest "$SOURCE_DIR" 'version: 1
source_repo: org/source
managed_files:
  - subdir/nested.txt
targets: []'
  run bash "$SCRIPT_DIR/repo-sync-files.sh" "$SOURCE_DIR" "$TARGET_DIR"
  assert_success
  [[ -f "$TARGET_DIR/subdir/nested.txt" ]]
}

@test "8. skips missing source file without error" {
  write_manifest "$SOURCE_DIR" 'version: 1
source_repo: org/source
managed_files:
  - nonexistent.txt
targets: []'
  run bash "$SCRIPT_DIR/repo-sync-files.sh" "$SOURCE_DIR" "$TARGET_DIR"
  assert_success
  [[ ! -f "$TARGET_DIR/nonexistent.txt" ]]
}

# ── SECTION 3: Merge operations (tests 9-10) ─────────────────────────────────

@test "9. merges settings.json" {
  # Sync script hardcodes .claude/settings.json path
  mkdir -p "$SOURCE_DIR/.claude" "$TARGET_DIR/.claude"
  cat > "$SOURCE_DIR/.claude/settings.json" << 'EOF'
{
  "permissions": {"allow": ["Read"], "defaultMode": "bypassPermissions"},
  "hooks": {
    "PostToolUse": [
      {"matcher":"Bash","_agentFlow":true,"hooks":[{"type":"command","command":"src-cmd"}]}
    ]
  }
}
EOF
  cat > "$TARGET_DIR/.claude/settings.json" << 'EOF'
{
  "permissions": {"allow": ["Edit"], "defaultMode": "acceptEdits"},
  "hooks": {},
  "myCustomKey": "preserved"
}
EOF
  write_manifest "$SOURCE_DIR" 'version: 1
source_repo: org/source
managed_files: []
targets: []'
  run bash "$SCRIPT_DIR/repo-sync-files.sh" "$SOURCE_DIR" "$TARGET_DIR"
  assert_success
  result=$(cat "$TARGET_DIR/.claude/settings.json")
  # source defaultMode wins
  [[ "$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['permissions']['defaultMode'])")" == "bypassPermissions" ]]
  # custom key preserved
  [[ "$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['myCustomKey'])")" == "preserved" ]]
}

@test "10. patches CLAUDE.md with managed sections" {
  cat > "$SOURCE_DIR/CLAUDE.md" << 'EOF'
## Agent Flow

New agent team content.
EOF
  cat > "$TARGET_DIR/CLAUDE.md" << 'EOF'
## Project: TestProject

My preamble.

## Agent Flow

Old agent team content.
EOF
  write_manifest "$SOURCE_DIR" 'version: 1
source_repo: org/source
managed_files: []
merge_files:
  - path: CLAUDE.md
    strategy: section-patch
    managed_sections:
      - "Agent Flow"
targets: []'
  run bash "$SCRIPT_DIR/repo-sync-files.sh" "$SOURCE_DIR" "$TARGET_DIR"
  assert_success
  result=$(cat "$TARGET_DIR/CLAUDE.md")
  [[ "$result" == *"New agent team content."* ]]
  [[ "$result" != *"Old agent team content."* ]]
  [[ "$result" == *"My preamble."* ]]
}

# ── SECTION 4: Gitignore / gitattributes (tests 11-14) ───────────────────────

@test "11. appends missing gitignore lines" {
  cat > "$TARGET_DIR/.gitignore" << 'EOF'
node_modules/
*.log
EOF
  echo "# source gitignore" > "$SOURCE_DIR/.gitignore"
  write_manifest "$SOURCE_DIR" 'version: 1
source_repo: org/source
managed_files: []
merge_files:
  - path: .gitignore
    strategy: append-missing
    managed_lines:
      - ".claude-agent-flow/sync-state.json"
targets: []'
  run bash "$SCRIPT_DIR/repo-sync-files.sh" "$SOURCE_DIR" "$TARGET_DIR"
  assert_success
  # Verify markers were appended
  [[ -f "$TARGET_DIR/.gitignore" ]]
  result=$(cat "$TARGET_DIR/.gitignore")
  [[ "$result" == *"agent-flow"* ]]
}

@test "12. replaces existing gitignore managed block and does not duplicate" {
  cat > "$TARGET_DIR/.gitignore" << 'EOF'
node_modules/
# --- Agent Flow (managed) ---
.old-managed-line
# --- End Agent Flow ---
EOF
  echo "# source gitignore" > "$SOURCE_DIR/.gitignore"
  write_manifest "$SOURCE_DIR" 'version: 1
source_repo: org/source
managed_files: []
merge_files:
  - path: .gitignore
    strategy: append-missing
    managed_lines:
      - ".claude-agent-flow/sync-state.json"
targets: []'
  run bash "$SCRIPT_DIR/repo-sync-files.sh" "$SOURCE_DIR" "$TARGET_DIR"
  assert_success
  result=$(cat "$TARGET_DIR/.gitignore")
  # only one managed block
  count=$(echo "$result" | grep -c "Agent Flow (managed)" || true)
  [[ "$count" -eq 1 ]]
}

@test "13. appends missing gitattributes merge driver line" {
  echo "* merge=mergiraf" > "$SOURCE_DIR/.gitattributes"
  write_manifest "$SOURCE_DIR" 'version: 1
source_repo: org/source
managed_files: []
merge_files:
  - path: .gitattributes
    strategy: append-missing
    managed_lines:
      - "* merge=mergiraf"
targets: []'
  run bash "$SCRIPT_DIR/repo-sync-files.sh" "$SOURCE_DIR" "$TARGET_DIR"
  assert_success
  [[ -f "$TARGET_DIR/.gitattributes" ]]
  result=$(cat "$TARGET_DIR/.gitattributes")
  [[ "$result" == *"mergiraf"* ]]
}

@test "14. skips gitattributes line when already present" {
  echo "* merge=mergiraf" > "$TARGET_DIR/.gitattributes"
  echo "* merge=mergiraf" > "$SOURCE_DIR/.gitattributes"
  write_manifest "$SOURCE_DIR" 'version: 1
source_repo: org/source
managed_files: []
merge_files:
  - path: .gitattributes
    strategy: append-missing
    managed_lines:
      - "* merge=mergiraf"
targets: []'
  run bash "$SCRIPT_DIR/repo-sync-files.sh" "$SOURCE_DIR" "$TARGET_DIR"
  assert_success
  count=$(grep -c "merge=mergiraf" "$TARGET_DIR/.gitattributes" || true)
  [[ "$count" -eq 1 ]]
}

# ── SECTION 5: Config and misc (tests 15-20) ─────────────────────────────────

@test "15. templates backlog config.yml with project name" {
  mkdir -p "$SOURCE_DIR/.claude-agent-flow/templates/backlog" "$TARGET_DIR/backlog"
  cat > "$SOURCE_DIR/.claude-agent-flow/templates/backlog/config.yml" << 'EOF'
project_name: CHANGEME
board_columns:
  - To Do
EOF
  cat > "$TARGET_DIR/backlog/config.yml" << 'EOF'
project_name: CHANGEME
board_columns:
  - To Do
EOF
  write_manifest "$SOURCE_DIR" 'version: 1
source_repo: org/source
managed_files: []
targets: []'
  run bash "$SCRIPT_DIR/repo-sync-files.sh" "$SOURCE_DIR" "$TARGET_DIR" --project-name "My Project"
  assert_success
  result=$(cat "$TARGET_DIR/backlog/config.yml")
  [[ "$result" == *"My Project"* ]]
  [[ "$result" != *"CHANGEME"* ]]
}

@test "16. preserves existing customized backlog config name" {
  mkdir -p "$SOURCE_DIR/.claude-agent-flow/templates/backlog" "$TARGET_DIR/backlog"
  cat > "$SOURCE_DIR/.claude-agent-flow/templates/backlog/config.yml" << 'EOF'
project_name: CHANGEME
board_columns:
  - To Do
EOF
  cat > "$TARGET_DIR/backlog/config.yml" << 'EOF'
project_name: Already Set
board_columns:
  - To Do
EOF
  write_manifest "$SOURCE_DIR" 'version: 1
source_repo: org/source
managed_files: []
targets: []'
  run bash "$SCRIPT_DIR/repo-sync-files.sh" "$SOURCE_DIR" "$TARGET_DIR" --project-name "Other"
  assert_success
  result=$(cat "$TARGET_DIR/backlog/config.yml")
  [[ "$result" == *"Already Set"* ]]
}

@test "17. session-start.sh is handled during sync" {
  mkdir -p "$SOURCE_DIR/.claude"
  cat > "$SOURCE_DIR/.claude/session-start.sh" << 'EOF'
#!/bin/bash
echo "session start"
EOF
  write_manifest "$SOURCE_DIR" 'version: 1
source_repo: org/source
managed_files:
  - .claude/session-start.sh
targets: []'
  run bash "$SCRIPT_DIR/repo-sync-files.sh" "$SOURCE_DIR" "$TARGET_DIR"
  assert_success
  [[ -f "$TARGET_DIR/.claude/session-start.sh" ]]
}

@test "18. full end-to-end sync with multiple files and merges" {
  # Files to copy
  echo "file1 content" > "$SOURCE_DIR/file1.txt"
  mkdir -p "$SOURCE_DIR/scripts"
  echo "#!/bin/bash" > "$SOURCE_DIR/scripts/helper.sh"
  # settings.json to merge (must be at .claude/settings.json)
  mkdir -p "$SOURCE_DIR/.claude" "$TARGET_DIR/.claude"
  cat > "$SOURCE_DIR/.claude/settings.json" << 'EOF'
{
  "permissions": {"allow": ["Read"], "defaultMode": "acceptEdits"},
  "hooks": {}
}
EOF
  cat > "$TARGET_DIR/.claude/settings.json" << 'EOF'
{
  "permissions": {"allow": ["Edit"]},
  "hooks": {}
}
EOF
  # CLAUDE.md to patch
  cat > "$SOURCE_DIR/CLAUDE.md" << 'EOF'
## Agent Flow

Source agent section.
EOF
  cat > "$TARGET_DIR/CLAUDE.md" << 'EOF'
## Project: TestProject

Preamble.

## Agent Flow

Old agent section.
EOF
  write_manifest "$SOURCE_DIR" 'version: 1
source_repo: org/source
managed_files:
  - file1.txt
  - scripts/helper.sh
merge_files:
  - path: CLAUDE.md
    strategy: section-patch
    managed_sections:
      - "Agent Flow"
targets: []'
  run bash "$SCRIPT_DIR/repo-sync-files.sh" "$SOURCE_DIR" "$TARGET_DIR"
  assert_success
  [[ -f "$TARGET_DIR/file1.txt" ]]
  [[ -f "$TARGET_DIR/scripts/helper.sh" ]]
  [[ -f "$TARGET_DIR/.claude/settings.json" ]]
  claude_content=$(cat "$TARGET_DIR/CLAUDE.md")
  [[ "$claude_content" == *"Source agent section."* ]]
}

@test "19. yaml_list extracts list items via manifest parsing" {
  # Verify that multiple separate entries in managed_files are all processed
  echo "alpha" > "$SOURCE_DIR/alpha.txt"
  echo "beta"  > "$SOURCE_DIR/beta.txt"
  echo "gamma" > "$SOURCE_DIR/gamma.txt"
  write_manifest "$SOURCE_DIR" 'version: 1
source_repo: org/source
managed_files:
  - alpha.txt
  - beta.txt
  - gamma.txt
targets: []'
  run bash "$SCRIPT_DIR/repo-sync-files.sh" "$SOURCE_DIR" "$TARGET_DIR"
  assert_success
  [[ -f "$TARGET_DIR/alpha.txt" ]]
  [[ -f "$TARGET_DIR/beta.txt" ]]
  [[ -f "$TARGET_DIR/gamma.txt" ]]
}

# ── SECTION 6: Vendored skills sync (tests 21-24) ───────────────────────────

@test "21. copies vendored skills listed in skills-filter.yaml" {
  mkdir -p "$SOURCE_DIR/.claude/skills/brainstorming/scripts"
  echo "# Brainstorming" > "$SOURCE_DIR/.claude/skills/brainstorming/SKILL.md"
  echo "helper()" > "$SOURCE_DIR/.claude/skills/brainstorming/scripts/helper.js"
  mkdir -p "$SOURCE_DIR/.claude/skills/frontend-design"
  echo "# Design" > "$SOURCE_DIR/.claude/skills/frontend-design/SKILL.md"
  mkdir -p "$SOURCE_DIR/.claude/skills/sync-plugin-skills"
  cat > "$SOURCE_DIR/.claude/skills/sync-plugin-skills/skills-filter.yaml" << 'EOF'
included:
  - brainstorming
  - frontend-design
available:
  - other-skill
EOF
  write_manifest "$SOURCE_DIR" 'version: 1
source_repo: org/source
managed_files: []
vendored_skills_source: .claude/skills/sync-plugin-skills/skills-filter.yaml
targets: []'
  run bash "$SCRIPT_DIR/repo-sync-files.sh" "$SOURCE_DIR" "$TARGET_DIR"
  assert_success
  [[ -f "$TARGET_DIR/.claude/skills/brainstorming/SKILL.md" ]]
  [[ -f "$TARGET_DIR/.claude/skills/brainstorming/scripts/helper.js" ]]
  [[ -f "$TARGET_DIR/.claude/skills/frontend-design/SKILL.md" ]]
  # available skills should NOT be copied
  [[ ! -d "$TARGET_DIR/.claude/skills/other-skill" ]]
}

@test "22. skips vendored skills when skills-filter.yaml missing" {
  write_manifest "$SOURCE_DIR" 'version: 1
source_repo: org/source
managed_files: []
vendored_skills_source: .claude/skills/sync-plugin-skills/skills-filter.yaml
targets: []'
  run bash "$SCRIPT_DIR/repo-sync-files.sh" "$SOURCE_DIR" "$TARGET_DIR"
  assert_success
  # No skills dirs should be created
  [[ ! -d "$TARGET_DIR/.claude/skills/brainstorming" ]]
}

@test "23. skips vendored skill when directory missing in source" {
  mkdir -p "$SOURCE_DIR/.claude/skills/sync-plugin-skills"
  cat > "$SOURCE_DIR/.claude/skills/sync-plugin-skills/skills-filter.yaml" << 'EOF'
included:
  - nonexistent-skill
EOF
  write_manifest "$SOURCE_DIR" 'version: 1
source_repo: org/source
managed_files: []
vendored_skills_source: .claude/skills/sync-plugin-skills/skills-filter.yaml
targets: []'
  run bash "$SCRIPT_DIR/repo-sync-files.sh" "$SOURCE_DIR" "$TARGET_DIR"
  assert_success
  [[ ! -d "$TARGET_DIR/.claude/skills/nonexistent-skill" ]]
  [[ "$output" == *"[skip]"* ]]
}

@test "24. vendored skills sync works alongside managed_files" {
  # Regular managed file
  echo "agent content" > "$SOURCE_DIR/agent.md"
  # Vendored skill
  mkdir -p "$SOURCE_DIR/.claude/skills/brainstorming"
  echo "# Brainstorming" > "$SOURCE_DIR/.claude/skills/brainstorming/SKILL.md"
  mkdir -p "$SOURCE_DIR/.claude/skills/sync-plugin-skills"
  cat > "$SOURCE_DIR/.claude/skills/sync-plugin-skills/skills-filter.yaml" << 'EOF'
included:
  - brainstorming
EOF
  write_manifest "$SOURCE_DIR" 'version: 1
source_repo: org/source
managed_files:
  - agent.md
vendored_skills_source: .claude/skills/sync-plugin-skills/skills-filter.yaml
targets: []'
  run bash "$SCRIPT_DIR/repo-sync-files.sh" "$SOURCE_DIR" "$TARGET_DIR"
  assert_success
  # Both regular and vendored files should be present
  [[ -f "$TARGET_DIR/agent.md" ]]
  [[ -f "$TARGET_DIR/.claude/skills/brainstorming/SKILL.md" ]]
}

@test "25. handles empty/invalid skills-filter.yaml without crashing" {
  mkdir -p "$SOURCE_DIR/.claude/skills/sync-plugin-skills"
  # Empty file parses to null, not a dict
  echo "" > "$SOURCE_DIR/.claude/skills/sync-plugin-skills/skills-filter.yaml"
  write_manifest "$SOURCE_DIR" 'version: 1
source_repo: org/source
managed_files: []
vendored_skills_source: .claude/skills/sync-plugin-skills/skills-filter.yaml
targets: []'
  run bash "$SCRIPT_DIR/repo-sync-files.sh" "$SOURCE_DIR" "$TARGET_DIR"
  assert_success
}

@test "26. rejects vendored skill names with path traversal" {
  mkdir -p "$SOURCE_DIR/.claude/skills/sync-plugin-skills"
  cat > "$SOURCE_DIR/.claude/skills/sync-plugin-skills/skills-filter.yaml" << 'EOF'
included:
  - ../../etc/passwd
  - legit/../../../tmp
  - foo\bar
  - .
EOF
  write_manifest "$SOURCE_DIR" 'version: 1
source_repo: org/source
managed_files: []
vendored_skills_source: .claude/skills/sync-plugin-skills/skills-filter.yaml
targets: []'
  run bash "$SCRIPT_DIR/repo-sync-files.sh" "$SOURCE_DIR" "$TARGET_DIR"
  assert_success
  [[ ! -d "$TARGET_DIR/etc" ]]
  [[ ! -d "$TARGET_DIR/tmp" ]]
  [[ ! -d "$TARGET_DIR/.claude/skills/foo" ]]
}

@test "27. yaml_list strips inline YAML comments" {
  mkdir -p "$SOURCE_DIR/mydir"
  echo "content" > "$SOURCE_DIR/mydir/file.txt"
  write_manifest "$SOURCE_DIR" 'version: 1
source_repo: org/source
managed_files:
  - mydir/  # this is a comment
targets: []'
  run bash "$SCRIPT_DIR/repo-sync-files.sh" "$SOURCE_DIR" "$TARGET_DIR"
  assert_success
  [[ -f "$TARGET_DIR/mydir/file.txt" ]]
}

@test "28. yaml_list preserves single-space-hash in values" {
  # The comment stripping requires TWO spaces before # (YAML convention for inline comments)
  # A single-space-hash embedded in a value (e.g. a version tag) must be preserved
  # Extract the yaml_list function definition from the production script and invoke it
  local manifest="$BATS_TEST_TMPDIR/test-manifest.yml"
  cat > "$manifest" << 'EOF'
managed_files:
  - path/to/file #version
  - another/path  # this is a comment
EOF

  # Run yaml_list by sourcing only the function block from the production script
  local result
  result=$(bash -c "
    $(sed -n '/^yaml_list()/,/^}/p' "$SCRIPT_DIR/repo-sync-files.sh")
    yaml_list '$manifest' 'managed_files'
  ")
  echo "$result" | grep -q "path/to/file #version"
  echo "$result" | grep -q "another/path"
  # Ensure the inline comment was stripped from the second entry
  ! echo "$result" | grep -q "this is a comment"
}

@test "20. handles multiple managed_files entries of mixed types" {
  echo "plain" > "$SOURCE_DIR/plain.txt"
  mkdir -p "$SOURCE_DIR/subdir"
  echo "deep" > "$SOURCE_DIR/subdir/deep.txt"
  write_manifest "$SOURCE_DIR" 'version: 1
source_repo: org/source
managed_files:
  - plain.txt
  - subdir/deep.txt
targets: []'
  run bash "$SCRIPT_DIR/repo-sync-files.sh" "$SOURCE_DIR" "$TARGET_DIR"
  assert_success
  [[ -f "$TARGET_DIR/plain.txt" ]]
  [[ -f "$TARGET_DIR/subdir/deep.txt" ]]
}
