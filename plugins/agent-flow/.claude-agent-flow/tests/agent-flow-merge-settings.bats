#!/usr/bin/env bats
# Tests for merge-settings-json.sh — ported from test-merge-settings.sh

setup() {
  load test_helper
  setup_temp_dirs
}

run_merge() {
  bash "$SCRIPT_DIR/merge-settings-json.sh" "$1" "$2"
}

# ── SECTION 1: Scenarios 1-5 ─────────────────────────────────────────────────

@test "1. source-wins update: tagged Bash hook command replaced" {
  cat > "$BATS_TEST_TMPDIR/source.json" << 'EOF'
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Bash",
        "_agentFlow": true,
        "hooks": [{"type":"command","command":"new-command"}]
      }
    ]
  }
}
EOF
  cat > "$BATS_TEST_TMPDIR/target.json" << 'EOF'
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Bash",
        "_agentFlow": true,
        "hooks": [{"type":"command","command":"old-command"}]
      }
    ]
  }
}
EOF
  result=$(run_merge "$BATS_TEST_TMPDIR/source.json" "$BATS_TEST_TMPDIR/target.json")
  assert_jq "command is new-command" '.hooks.PostToolUse[0].hooks[0].command' "new-command" "$result"
  assert_jq_count "only one entry" '.hooks.PostToolUse | length' 1 "$result"
}

@test "2. child hook preserved: untagged Write hook kept after merge" {
  cat > "$BATS_TEST_TMPDIR/source.json" << 'EOF'
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Bash",
        "_agentFlow": true,
        "hooks": [{"type":"command","command":"bash-hook"}]
      }
    ]
  }
}
EOF
  cat > "$BATS_TEST_TMPDIR/target.json" << 'EOF'
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write",
        "hooks": [{"type":"command","command":"child-write-hook"}]
      }
    ]
  }
}
EOF
  result=$(run_merge "$BATS_TEST_TMPDIR/source.json" "$BATS_TEST_TMPDIR/target.json")
  assert_jq_count "total entries = 2" '.hooks.PostToolUse | length' 2 "$result"
  assert_jq "Write hook command intact" \
    '[.hooks.PostToolUse[] | select(.matcher=="Write")] | .[0].hooks[0].command' \
    "child-write-hook" "$result"
}

@test "3. new hook appended: Skill hook added to empty hooks" {
  cat > "$BATS_TEST_TMPDIR/source.json" << 'EOF'
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Skill",
        "_agentFlow": true,
        "hooks": [{"type":"command","command":"skill-hook"}]
      }
    ]
  }
}
EOF
  cat > "$BATS_TEST_TMPDIR/target.json" << 'EOF'
{
  "hooks": {}
}
EOF
  result=$(run_merge "$BATS_TEST_TMPDIR/source.json" "$BATS_TEST_TMPDIR/target.json")
  assert_jq_count "PostToolUse has 1 entry" '.hooks.PostToolUse | length' 1 "$result"
  assert_jq "Skill hook present" '.hooks.PostToolUse[0].matcher' "Skill" "$result"
}

@test "4. parent removed hook: tagged Skill in target not in source is dropped" {
  cat > "$BATS_TEST_TMPDIR/source.json" << 'EOF'
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Bash",
        "_agentFlow": true,
        "hooks": [{"type":"command","command":"bash-hook"}]
      }
    ]
  }
}
EOF
  cat > "$BATS_TEST_TMPDIR/target.json" << 'EOF'
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Skill",
        "_agentFlow": true,
        "hooks": [{"type":"command","command":"old-skill-hook"}]
      }
    ]
  }
}
EOF
  result=$(run_merge "$BATS_TEST_TMPDIR/source.json" "$BATS_TEST_TMPDIR/target.json")
  assert_jq_count "only Bash hook remains" '.hooks.PostToolUse | length' 1 "$result"
  assert_jq "Bash hook present" '.hooks.PostToolUse[0].matcher' "Bash" "$result"
  assert_jq "Skill hook absent" \
    '[.hooks.PostToolUse[] | select(.matcher=="Skill")] | length' "0" "$result"
}

@test "5. legacy migration (identical): untagged matching hooks replaced with tagged" {
  cat > "$BATS_TEST_TMPDIR/source.json" << 'EOF'
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Bash",
        "_agentFlow": true,
        "hooks": [{"type":"command","command":"shared-command"}]
      }
    ]
  }
}
EOF
  cat > "$BATS_TEST_TMPDIR/target.json" << 'EOF'
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{"type":"command","command":"shared-command"}]
      }
    ]
  }
}
EOF
  result=$(run_merge "$BATS_TEST_TMPDIR/source.json" "$BATS_TEST_TMPDIR/target.json")
  assert_jq_count "only one entry after merge" '.hooks.PostToolUse | length' 1 "$result"
  assert_jq "entry is tagged _agentFlow" '.hooks.PostToolUse[0]._agentFlow' "true" "$result"
}

# ── SECTION 2: Scenarios 6-10 ────────────────────────────────────────────────

@test "6. legacy migration (diverged): untagged different hooks both preserved" {
  cat > "$BATS_TEST_TMPDIR/source.json" << 'EOF'
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Bash",
        "_agentFlow": true,
        "hooks": [{"type":"command","command":"source-command"}]
      }
    ]
  }
}
EOF
  cat > "$BATS_TEST_TMPDIR/target.json" << 'EOF'
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{"type":"command","command":"diverged-command"}]
      }
    ]
  }
}
EOF
  result=$(run_merge "$BATS_TEST_TMPDIR/source.json" "$BATS_TEST_TMPDIR/target.json")
  assert_jq_count "both entries preserved" '.hooks.PostToolUse | length' 2 "$result"
  assert_jq "diverged-command still present" \
    '[.hooks.PostToolUse[] | select(.hooks[0].command=="diverged-command")] | length' "1" "$result"
}

@test "7. SessionStart child preserved: untagged with different command kept" {
  cat > "$BATS_TEST_TMPDIR/source.json" << 'EOF'
{
  "hooks": {
    "SessionStart": [
      {
        "_agentFlow": true,
        "hooks": [{"type":"command","command":"source-session-start.sh"}]
      }
    ]
  }
}
EOF
  cat > "$BATS_TEST_TMPDIR/target.json" << 'EOF'
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [{"type":"command","command":"child-session-start.sh"}]
      }
    ]
  }
}
EOF
  result=$(run_merge "$BATS_TEST_TMPDIR/source.json" "$BATS_TEST_TMPDIR/target.json")
  assert_jq_count "two entries" '.hooks.SessionStart | length' 2 "$result"
  assert_jq "child command present" \
    '[.hooks.SessionStart[] | select(.hooks[0].command=="child-session-start.sh")] | length' \
    "1" "$result"
}

@test "8. SessionStart legacy replaced: untagged with same command replaced" {
  cat > "$BATS_TEST_TMPDIR/source.json" << 'EOF'
{
  "hooks": {
    "SessionStart": [
      {
        "_agentFlow": true,
        "hooks": [{"type":"command","command":"session-start.sh"}]
      }
    ]
  }
}
EOF
  cat > "$BATS_TEST_TMPDIR/target.json" << 'EOF'
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [{"type":"command","command":"session-start.sh"}]
      }
    ]
  }
}
EOF
  result=$(run_merge "$BATS_TEST_TMPDIR/source.json" "$BATS_TEST_TMPDIR/target.json")
  assert_jq_count "only one entry" '.hooks.SessionStart | length' 1 "$result"
  assert_jq "entry is tagged" '.hooks.SessionStart[0]._agentFlow' "true" "$result"
}

@test "9. empty hooks: source entries added to empty object" {
  cat > "$BATS_TEST_TMPDIR/source.json" << 'EOF'
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Bash",
        "_agentFlow": true,
        "hooks": [{"type":"command","command":"bash-hook"}]
      }
    ]
  }
}
EOF
  cat > "$BATS_TEST_TMPDIR/target.json" << 'EOF'
{
  "hooks": {}
}
EOF
  result=$(run_merge "$BATS_TEST_TMPDIR/source.json" "$BATS_TEST_TMPDIR/target.json")
  assert_jq_count "source entries added" '.hooks.PostToolUse | length' 1 "$result"
}

@test "10. no target file: source copied directly" {
  cat > "$BATS_TEST_TMPDIR/source.json" << 'EOF'
{
  "permissions": {"allow": ["Read"], "defaultMode": "acceptEdits"},
  "hooks": {
    "PostToolUse": [{"matcher":"Bash","_agentFlow":true,"hooks":[{"type":"command","command":"x"}]}]
  }
}
EOF
  result=$(run_merge "$BATS_TEST_TMPDIR/source.json" "$BATS_TEST_TMPDIR/nonexistent.json")
  assert_jq "defaultMode absent from passthrough" '.permissions | has("defaultMode")' "false" "$result"
  assert_jq_count "hooks present" '.hooks.PostToolUse | length' 1 "$result"
}

# ── SECTION 3: Scenarios 11-15 ───────────────────────────────────────────────

@test "11. permissions union dedup sort, defaultMode stripped" {
  cat > "$BATS_TEST_TMPDIR/source.json" << 'EOF'
{
  "permissions": {
    "allow": ["Read","Write","Bash(git:*)"],
    "deny": ["Bash(sudo:*)"],
    "defaultMode": "bypassPermissions"
  },
  "hooks": {}
}
EOF
  cat > "$BATS_TEST_TMPDIR/target.json" << 'EOF'
{
  "permissions": {
    "allow": ["Read","Edit","Bash(npm:*)"],
    "deny": ["Bash(rm -rf:*)","Bash(sudo:*)"],
    "defaultMode": "acceptEdits"
  },
  "hooks": {}
}
EOF
  result=$(run_merge "$BATS_TEST_TMPDIR/source.json" "$BATS_TEST_TMPDIR/target.json")
  assert_jq "Read present" '.permissions.allow | contains(["Read"])' "true" "$result"
  assert_jq "Edit preserved from target" '.permissions.allow | contains(["Edit"])' "true" "$result"
  assert_jq "Write from source" '.permissions.allow | contains(["Write"])' "true" "$result"
  assert_jq "Read appears once" '[.permissions.allow[] | select(.=="Read")] | length' "1" "$result"
  assert_jq "sudo deny deduped" '[.permissions.deny[] | select(.=="Bash(sudo:*)")] | length' "1" "$result"
  assert_jq "defaultMode absent from merged output" '.permissions | has("defaultMode")' "false" "$result"
}

@test "11b. defaultMode stripped when only source has it" {
  cat > "$BATS_TEST_TMPDIR/source.json" << 'EOF'
{
  "permissions": {
    "allow": ["Read"],
    "defaultMode": "bypassPermissions"
  },
  "hooks": {}
}
EOF
  cat > "$BATS_TEST_TMPDIR/target.json" << 'EOF'
{
  "permissions": {
    "allow": ["Edit"]
  },
  "hooks": {}
}
EOF
  result=$(run_merge "$BATS_TEST_TMPDIR/source.json" "$BATS_TEST_TMPDIR/target.json")
  assert_jq "defaultMode absent from output" '.permissions | has("defaultMode")' "false" "$result"
  assert_jq "allow union still works" '.permissions.allow | contains(["Read"])' "true" "$result"
  assert_jq "allow union includes target" '.permissions.allow | contains(["Edit"])' "true" "$result"
}

@test "11c. defaultMode stripped when only target has it" {
  cat > "$BATS_TEST_TMPDIR/source.json" << 'EOF'
{
  "permissions": {
    "allow": ["Read"]
  },
  "hooks": {}
}
EOF
  cat > "$BATS_TEST_TMPDIR/target.json" << 'EOF'
{
  "permissions": {
    "allow": ["Edit"],
    "defaultMode": "acceptEdits"
  },
  "hooks": {}
}
EOF
  result=$(run_merge "$BATS_TEST_TMPDIR/source.json" "$BATS_TEST_TMPDIR/target.json")
  assert_jq "defaultMode absent from output" '.permissions | has("defaultMode")' "false" "$result"
}

@test "12. custom keys preserved from target" {
  cat > "$BATS_TEST_TMPDIR/source.json" << 'EOF'
{
  "permissions": {"allow": ["Read"], "defaultMode": "acceptEdits"},
  "hooks": {},
  "extraKnownMarketplaces": {},
  "enabledPlugins": {}
}
EOF
  cat > "$BATS_TEST_TMPDIR/target.json" << 'EOF'
{
  "permissions": {"allow": ["Read"], "defaultMode": "acceptEdits"},
  "hooks": {},
  "myCustomKey": "child-value",
  "anotherKey": {"nested": true}
}
EOF
  result=$(run_merge "$BATS_TEST_TMPDIR/source.json" "$BATS_TEST_TMPDIR/target.json")
  assert_jq "myCustomKey preserved" '.myCustomKey' "child-value" "$result"
  assert_jq "anotherKey.nested preserved" '.anotherKey.nested' "true" "$result"
}

@test "13. extraKnownMarketplaces deep merge (both present)" {
  cat > "$BATS_TEST_TMPDIR/source.json" << 'EOF'
{
  "extraKnownMarketplaces": {
    "source-market": {"source": {"source": "github", "repo": "org/repo"}}
  },
  "hooks": {}
}
EOF
  cat > "$BATS_TEST_TMPDIR/target.json" << 'EOF'
{
  "extraKnownMarketplaces": {
    "target-market": {"source": {"source": "github", "repo": "other/repo"}}
  },
  "hooks": {}
}
EOF
  result=$(run_merge "$BATS_TEST_TMPDIR/source.json" "$BATS_TEST_TMPDIR/target.json")
  assert_jq "source market present" '.extraKnownMarketplaces | has("source-market")' "true" "$result"
  assert_jq "target market also present (merge not overwrite)" \
    '.extraKnownMarketplaces | has("target-market")' "true" "$result"
}

@test "14. enabledPlugins deep merge (both present)" {
  cat > "$BATS_TEST_TMPDIR/source.json" << 'EOF'
{
  "enabledPlugins": {"pluginA": true},
  "hooks": {}
}
EOF
  cat > "$BATS_TEST_TMPDIR/target.json" << 'EOF'
{
  "enabledPlugins": {"pluginB": true},
  "hooks": {}
}
EOF
  result=$(run_merge "$BATS_TEST_TMPDIR/source.json" "$BATS_TEST_TMPDIR/target.json")
  assert_jq "pluginA (source) present" '.enabledPlugins | has("pluginA")' "true" "$result"
  assert_jq "pluginB (target) preserved (merge not overwrite)" '.enabledPlugins | has("pluginB")' "true" "$result"
}

@test "15. multiple hook types, cross-type isolation" {
  cat > "$BATS_TEST_TMPDIR/source.json" << 'EOF'
{
  "hooks": {
    "PostToolUse": [
      {"matcher":"Bash","_agentFlow":true,"hooks":[{"type":"command","command":"bash-src"}]}
    ],
    "SessionStart": [
      {"_agentFlow":true,"hooks":[{"type":"command","command":"session-src"}]}
    ]
  }
}
EOF
  cat > "$BATS_TEST_TMPDIR/target.json" << 'EOF'
{
  "hooks": {
    "PostToolUse": [
      {"matcher":"Write","hooks":[{"type":"command","command":"child-write"}]}
    ]
  }
}
EOF
  result=$(run_merge "$BATS_TEST_TMPDIR/source.json" "$BATS_TEST_TMPDIR/target.json")
  assert_jq_count "PostToolUse has 2 entries" '.hooks.PostToolUse | length' 2 "$result"
  assert_jq_count "SessionStart has 1 entry" '.hooks.SessionStart | length' 1 "$result"
  assert_jq "child Write hook preserved" \
    '[.hooks.PostToolUse[] | select(.matcher=="Write")] | length' "1" "$result"
}

# ── SECTION 4: Reverse merge (upstream) ─────────────────────────────────────

run_reverse_merge() {
  bash "$SCRIPT_DIR/reverse-merge-settings-json.sh" "$1" "$2"
}

@test "reverse-merge: downstream hook fix replaces source tagged entry" {
  cat > "$BATS_TEST_TMPDIR/downstream.json" << 'EOF'
{
  "hooks": {
    "PostToolUse": [
      {"matcher":"Bash","_agentFlow":true,"hooks":[{"type":"command","command":"fixed-command"}]},
      {"matcher":"Write","hooks":[{"type":"command","command":"child-hook"}]}
    ]
  }
}
EOF
  cat > "$BATS_TEST_TMPDIR/source.json" << 'EOF'
{
  "hooks": {
    "PostToolUse": [
      {"matcher":"Bash","_agentFlow":true,"hooks":[{"type":"command","command":"old-broken-command"}]}
    ]
  }
}
EOF
  result=$(run_reverse_merge "$BATS_TEST_TMPDIR/downstream.json" "$BATS_TEST_TMPDIR/source.json")
  # Source's tagged entry should be replaced with downstream's fix
  assert_jq "tagged hook updated to fixed version" \
    '[.hooks.PostToolUse[] | select(._agentFlow == true)] | .[0].hooks[0].command' "fixed-command" "$result"
  # Child-only hook from downstream should NOT appear in source
  assert_jq "child hook not carried upstream" \
    '[.hooks.PostToolUse[] | select(.matcher == "Write")] | length' "0" "$result"
}

@test "reverse-merge: no diff returns exit code 2" {
  cat > "$BATS_TEST_TMPDIR/downstream.json" << 'EOF'
{
  "hooks": {
    "PostToolUse": [
      {"matcher":"Bash","_agentFlow":true,"hooks":[{"type":"command","command":"same-command"}]}
    ]
  }
}
EOF
  cat > "$BATS_TEST_TMPDIR/source.json" << 'EOF'
{
  "hooks": {
    "PostToolUse": [
      {"matcher":"Bash","_agentFlow":true,"hooks":[{"type":"command","command":"same-command"}]}
    ]
  }
}
EOF
  run run_reverse_merge "$BATS_TEST_TMPDIR/downstream.json" "$BATS_TEST_TMPDIR/source.json"
  assert_failure
  [[ "$status" -eq 2 ]]
}

@test "reverse-merge: preserves source non-hook keys" {
  cat > "$BATS_TEST_TMPDIR/downstream.json" << 'EOF'
{
  "permissions": {"allow": ["Read"], "defaultMode": "askFirst"},
  "hooks": {
    "PostToolUse": [
      {"matcher":"Bash","_agentFlow":true,"hooks":[{"type":"command","command":"fixed"}]}
    ]
  },
  "enabledPlugins": {"downstreamPlugin": true}
}
EOF
  cat > "$BATS_TEST_TMPDIR/source.json" << 'EOF'
{
  "permissions": {"allow": ["Read","Write"], "defaultMode": "bypassPermissions"},
  "hooks": {
    "PostToolUse": [
      {"matcher":"Bash","_agentFlow":true,"hooks":[{"type":"command","command":"old"}]}
    ]
  },
  "enabledPlugins": {"sourcePlugin": true}
}
EOF
  result=$(run_reverse_merge "$BATS_TEST_TMPDIR/downstream.json" "$BATS_TEST_TMPDIR/source.json")
  # Source permissions and plugins preserved — only hooks change
  assert_jq "source defaultMode preserved" '.permissions.defaultMode' "bypassPermissions" "$result"
  assert_jq "source plugins preserved" '.enabledPlugins | has("sourcePlugin")' "true" "$result"
  assert_jq "downstream plugins not carried" '.enabledPlugins | has("downstreamPlugin")' "false" "$result"
  assert_jq "hook updated" \
    '[.hooks.PostToolUse[] | select(._agentFlow == true)] | .[0].hooks[0].command' "fixed" "$result"
}

@test "reverse-merge: multiple hook types handled independently" {
  cat > "$BATS_TEST_TMPDIR/downstream.json" << 'EOF'
{
  "hooks": {
    "PostToolUse": [
      {"matcher":"Bash","_agentFlow":true,"hooks":[{"type":"command","command":"fixed-bash"}]}
    ],
    "SessionStart": [
      {"_agentFlow":true,"hooks":[{"type":"command","command":"fixed-session"}]}
    ]
  }
}
EOF
  cat > "$BATS_TEST_TMPDIR/source.json" << 'EOF'
{
  "hooks": {
    "PostToolUse": [
      {"matcher":"Bash","_agentFlow":true,"hooks":[{"type":"command","command":"old-bash"}]}
    ],
    "SessionStart": [
      {"_agentFlow":true,"hooks":[{"type":"command","command":"old-session"}]}
    ]
  }
}
EOF
  result=$(run_reverse_merge "$BATS_TEST_TMPDIR/downstream.json" "$BATS_TEST_TMPDIR/source.json")
  assert_jq "PostToolUse hook updated" \
    '[.hooks.PostToolUse[] | select(._agentFlow == true)] | .[0].hooks[0].command' "fixed-bash" "$result"
  assert_jq "SessionStart hook updated" \
    '[.hooks.SessionStart[] | select(._agentFlow == true)] | .[0].hooks[0].command' "fixed-session" "$result"
}

@test "reverse-merge: source-only hook type preserved when not in downstream" {
  cat > "$BATS_TEST_TMPDIR/downstream.json" << 'EOF'
{
  "hooks": {
    "PostToolUse": [
      {"matcher":"Bash","_agentFlow":true,"hooks":[{"type":"command","command":"fixed"}]}
    ]
  }
}
EOF
  cat > "$BATS_TEST_TMPDIR/source.json" << 'EOF'
{
  "hooks": {
    "PostToolUse": [
      {"matcher":"Bash","_agentFlow":true,"hooks":[{"type":"command","command":"old"}]}
    ],
    "PreToolUse": [
      {"matcher":"Edit","_agentFlow":true,"hooks":[{"type":"command","command":"pre-edit"}]}
    ]
  }
}
EOF
  result=$(run_reverse_merge "$BATS_TEST_TMPDIR/downstream.json" "$BATS_TEST_TMPDIR/source.json")
  assert_jq "PostToolUse updated" \
    '[.hooks.PostToolUse[] | select(._agentFlow == true)] | .[0].hooks[0].command' "fixed" "$result"
  # PreToolUse only in source — downstream has no tagged entries for it,
  # so source's tagged entries should be preserved unchanged
  assert_jq_count "PreToolUse preserved from source" '.hooks.PreToolUse | length' 1 "$result"
  assert_jq "PreToolUse entry unchanged" \
    '.hooks.PreToolUse[0].hooks[0].command' "pre-edit" "$result"
}
