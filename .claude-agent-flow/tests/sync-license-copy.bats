#!/usr/bin/env bats
# Tests for sync-plugin-skills.sh LICENSE copy functionality

setup() {
  load test_helper

  # Build a minimal fake repo that mirrors the real directory layout so that
  # sync.sh's REPO_ROOT/SETTINGS/SKILLS_DIR/FILTER_FILE paths all resolve
  # within a sandboxed tree — no writes touch the real repo.
  FAKE_REPO="$BATS_TEST_TMPDIR/repo"
  FAKE_HOME="$BATS_TEST_TMPDIR/home"
  PLUGIN_CACHE="$FAKE_HOME/.claude/plugins/cache/test-marketplace/test-plugin"
  SYNC_SCRIPT="$FAKE_REPO/.claude/skills/sync-plugin-skills/sync.sh"

  mkdir -p "$FAKE_REPO/.claude/skills/sync-plugin-skills"
  mkdir -p "$FAKE_REPO/.claude/skills"
  mkdir -p "$PLUGIN_CACHE/skills/test-skill"

  # Copy sync.sh so REPO_ROOT (dirname/$0 ../../..) resolves to FAKE_REPO
  cp "$PROJECT_ROOT/.claude/skills/sync-plugin-skills/sync.sh" "$SYNC_SCRIPT"

  # Minimal settings.json with one enabled plugin
  printf '{"enabledPlugins": {"test-plugin@test-marketplace": true}}\n' \
    > "$FAKE_REPO/.claude/settings.json"

  # Filter file that includes test-skill
  printf 'included:\n  - test-skill\n' \
    > "$FAKE_REPO/.claude/skills/sync-plugin-skills/skills-filter.yaml"

  # Minimal SKILL.md so the skill is recognised
  printf '# Test Skill\nTest skill description\n' \
    > "$PLUGIN_CACHE/skills/test-skill/SKILL.md"

  export FAKE_REPO FAKE_HOME PLUGIN_CACHE SYNC_SCRIPT
}

teardown() {
  true  # BATS_TEST_TMPDIR is cleaned up automatically
}

# Helper: create a plugin-root LICENSE with given content
create_license() {
  printf '%s\n' "$1" > "$PLUGIN_CACHE/LICENSE"
}

# Helper: invoke the real sync.sh with the sandboxed HOME
run_sync() {
  HOME="$FAKE_HOME" run bash "$SYNC_SCRIPT" "$@"
}

# ── SECTION 1: Dry-run tests (tests 1-3) ──────────────────────────────────────

@test "1. dry-run shows would copy for free LICENSE" {
  create_license "MIT License

Copyright (c) 2025 Test Author

Permission is hereby granted, free of charge..."

  run_sync --dry-run
  assert_success
  assert_output --partial "[dry-run] Would copy LICENSE for test-skill"
}

@test "2. dry-run skips when skill already has LICENSE" {
  create_license "MIT License"
  mkdir -p "$FAKE_REPO/.claude/skills/test-skill"
  printf 'Existing LICENSE\n' > "$FAKE_REPO/.claude/skills/test-skill/LICENSE"

  run_sync --dry-run
  assert_success
  refute_output --partial "[dry-run] Would copy LICENSE"
}

@test "3. dry-run skips proprietary LICENSE" {
  create_license "Copyright (c) 2025 Company Inc.
All rights reserved.

This software is proprietary..."

  run_sync --dry-run
  assert_success
  assert_output --partial "[dry-run] Would skip LICENSE for test-skill"
}

# ── SECTION 2: Real copy tests (tests 4-6) ────────────────────────────────────

@test "4. copies free LICENSE to destination" {
  create_license "MIT License

Copyright (c) 2025 Test Author

Permission is hereby granted, free of charge..."

  run_sync
  assert_success
  assert_output --partial "Copied LICENSE for test-skill"
  [[ -f "$FAKE_REPO/.claude/skills/test-skill/LICENSE" ]]
  grep -q "MIT License" "$FAKE_REPO/.claude/skills/test-skill/LICENSE"
}

@test "5. does not overwrite existing LICENSE" {
  create_license "MIT License"
  mkdir -p "$FAKE_REPO/.claude/skills/test-skill"
  printf 'Existing LICENSE content\n' > "$FAKE_REPO/.claude/skills/test-skill/LICENSE"

  run_sync
  assert_success
  refute_output --partial "Copied LICENSE"
  grep -q "Existing LICENSE content" "$FAKE_REPO/.claude/skills/test-skill/LICENSE"
}

@test "6. does not copy proprietary LICENSE" {
  create_license "Copyright (c) 2025 Proprietary Corp.
All rights reserved.

This is proprietary software..."

  run_sync
  assert_success
  assert_output --partial "Skipping LICENSE for test-skill"
  [[ ! -f "$FAKE_REPO/.claude/skills/test-skill/LICENSE" ]]
}
