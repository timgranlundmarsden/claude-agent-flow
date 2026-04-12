---
name: diagnostic
description: Report the health of the agent-flow installation
---

<!-- This command is exempt from agent-flow-init-check. It checks the guard
     condition itself (Check 1: Initialised) rather than enforcing it.
     Same exemption category as install.md and help.md. -->

# /diagnostic

You are running the agent-flow diagnostic. Follow these steps to produce a health report.

## Instructions

### Step 1: Read state files

Read these files (some may not exist — that's a valid check result):

1. `.claude-agent-flow/sync-state.json`
2. `.claude-agent-flow/repo-sync-manifest.yml`
3. `.claude/settings.json`
4. `CLAUDE.md`
5. `.claude-agent-flow/scripts/session-start.sh`

### Step 2: Build header block

Output this header block using data from the files above:

```
Agent Flow Diagnostic
─────────────────────
Mode: <mode>
Version: <version>
Source repo: <source_repo>
Synced at: <synced_at>
Plugin path: <plugin_path>
```

**Field mapping:**
- **Mode:** Read `scope` from sync-state.json. Map: `plugin` → "Plugin", `plugin+github` → "Plugin + GitHub Actions", `sandbox` → "Sandbox". If sync-state.json missing or scope missing, show "Unknown".
- **Version:** Read `last_synced_version` from sync-state.json. If missing, try `version` field. If still missing, show "Unknown".
- **Source repo:** Read `source_repo` from sync-state.json. If missing, try `source_repo` from `repo-sync-manifest.yml`. If still missing, show "Unknown".
- **Synced at:** Read `synced_at` from sync-state.json. If missing, try `installedAt`. If still missing, show "Unknown".
- **Plugin path / Install path:** For sandbox mode, run `git rev-parse --show-toplevel` via Bash to get the repo root and show it with label "Install path". For plugin/plugin+github modes, read the `enabledPlugins` keys from `.claude/settings.json` — find the key containing "agent-flow", then show `~/.claude/plugins/<plugin-key>` with label "Plugin path". If no agent-flow key found, show "Unknown". 

**Sync role line** (conditional — only show if one applies):
- If current repo has `.claude-agent-flow/repo-sync-manifest.yml` with a `targets:` section containing entries → add line: `Sync role: Source (upstream master)`
- If sync-state.json has `source_repo` that differs from the current repo's GitHub remote → add line: `Sync role: Downstream target of: <source_repo>`
- If neither applies → do NOT show a Sync role line

### Step 3: Run checks

Run each check in order. Output `[PASS]` or `[FAIL]` for each.

**Check 1: Initialised**
Verify `.claude-agent-flow/sync-state.json` exists and is valid JSON. Then apply scope-specific validation:
- **If `.claude-agent-flow/repo-sync-manifest.yml` exists with a `targets:` section** (source repo): pass if file is valid JSON AND has EITHER `installed: true` OR `source_repo` field present.
- **Otherwise** (downstream install): require fields `source_repo`, `scope`, and `synced_at` to be present and non-empty.

```
[PASS] Initialised: sync-state.json valid
```
or
```
[FAIL] Initialised: <reason>
```

**Check 2: CLAUDE.md**
Verify CLAUDE.md exists and contains these managed section headings: `## Backlog Management`, `## Git Workflow`, `## Agent Flow`.
```
[PASS] CLAUDE.md: managed sections present
```

**Check 3: Plugin registration**
For Plugin/Plugin+GH modes (plugin/plugin+github scope): Check `.claude/settings.json` has an `enabledPlugins` key with at least one agent-flow-related entry (key containing "agent-flow").
For Sandbox mode: Output `[N/A ] Plugin registration: sandbox mode uses vendored local files`.
```
[PASS] Plugin registration: agent-flow plugin enabled
```

**Check 4: Session start tools**

First, resolve the path to `session-start.sh` using this priority order:

1. **Local (sandbox)**: Read `.claude-agent-flow/scripts/session-start.sh` — exists when vendored into the repo.
2. **Plugin env var**: Run via Bash: `echo "${CLAUDE_PLUGIN_ROOT:-}"`. If non-empty, read `$CLAUDE_PLUGIN_ROOT/.claude-agent-flow/scripts/session-start.sh`.
3. **Hook-derived path**: Read `.claude/settings.json` and find the `hooks.SessionStart` command. Extract the script path from it (the path ending in `session-start.sh`). Resolve `$CLAUDE_PROJECT_DIR` to the result of `git rev-parse --show-toplevel` via Bash. Check if that resolved path exists.
4. **Settings-derived plugin cache**: Read `.claude/settings.json`, find any `enabledPlugins` key containing "agent-flow". Extract the plugin key. Check `~/.claude/plugins/cache/<plugin-key>/agent-flow/.claude-agent-flow/scripts/session-start.sh`.
5. **Broad cache scan**: Run via Bash: `find ~/.claude/plugins/cache -path '*/agent-flow/.claude-agent-flow/scripts/session-start.sh' -print -quit 2>/dev/null`
6. **If NONE found**: Output `[FAIL] Tools: session-start.sh not found (checked local, plugin env, hook path, and cache)` and skip all individual tool checks. This is a REAL failure, not a skip.

Once found, extract the `EXPECTED_TOOLS` array values from session-start.sh.

Then, detect the platform by running `uname -s` and `uname -m` via Bash before tool checks.

For each tool, check if its binary is available using the Bash tool with `command -v` or path check.

Tool-name-to-binary mapping:
- "Backlog CLI" → run `command -v backlog`
- "Playwright CLI" → run `command -v playwright-cli`
- "Chromium" → on macOS: check `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome` exists; on Linux: `command -v google-chrome || command -v chromium-browser`
- "Mergiraf" → **Platform check first**: supported on Linux x86_64, Darwin arm64, and Darwin x86_64. If the platform is none of these, output `[SKIP] Tool installed: Mergiraf (unsupported platform)` and move to next tool. Otherwise run `command -v mergiraf`.
- "ShellCheck" → run `command -v shellcheck`
- "rsync" → run `command -v rsync`
- "GNU parallel" → run `command -v parallel`
- **Default rule (for any tool not explicitly listed above):** replace every non-alphanumeric character with nothing, then lowercase the result, and run `command -v <result>`. Example: `"RTK"` → `command -v rtk`.

For each tool, output one line:
```
[PASS] Tool installed: <name> (<version or path>)
```
or
```
[FAIL] Tool installed: <name> (not found)
```
or (for platform-unsupported tools only):
```
[SKIP] Tool installed: <name> (<platform requirement>)
```

Get version where available: `backlog --version`, `shellcheck --version | head -2`, `rsync --version | head -1`, `parallel --version | head -1`.

**Check 5: Backlog CLI functional**
Run `backlog task list` via Bash and check exit code is 0.
```
[PASS] Backlog CLI: task list succeeded
```

**Check 6: Backlog MCP functional**
Invoke the `mcp__backlog__definition_of_done_defaults_get` MCP tool and verify a response is received.
```
[PASS] Backlog MCP: definition_of_done_defaults_get responded
```

### Step 4: Summary

Count passes and total checks. Each tool line in Check 4 counts as one check towards the total. `[SKIP]` and `[N/A ]` lines do NOT count towards either the pass count (N) or the total count (M). Output:
```
Result: N/M passed
```
If any checks were skipped or not applicable, append a suffix (K = total of `[SKIP]` and `[N/A ]` lines):
```
Result: N/M passed (K skipped)
```

**Important rules:**
- No fix suggestions — clean status output only
- Do NOT use `agent-flow-init-check` as a guard skill
- The tool list must be read dynamically from session-start.sh's EXPECTED_TOOLS array — do NOT hardcode the list
- Use `command -v` for binary checks, not `which`
