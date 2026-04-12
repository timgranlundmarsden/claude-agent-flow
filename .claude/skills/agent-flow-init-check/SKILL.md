---
name: agent-flow-init-check
description: >
  Guard skill that halts command execution if the agent-flow system is not
  initialized. Checks for .claude-agent-flow/sync-state.json and stops with
  a clear message to run /install if absent.
---

# Init Guard

Before executing the command, check whether the agent-flow system has been initialized in this repository.

## Check

1. Look for the file `.claude-agent-flow/repo-sync-manifest.yml` in the repository root
   - **If it exists:** This is the **master (source) repo** — skip all further checks and continue silently
2. Look for the file `.claude-agent-flow/sync-state.json` in the repository root
3. **If the file does NOT exist:** Output the following message and **STOP immediately** — do not continue with the command:

   > Agent-flow is not initialized in this repository. Run `/install` to set up.

4. **If the file exists:** Continue silently — do not output anything about this check.

## Important

- This check is **imperative, not advisory** — if the file is missing, the command MUST halt
- Do not suggest workarounds or alternatives — just tell the user to run `/install`
- This skill must NOT be added to `install.md` or `help.md` — install is the bootstrapper and help is user discovery; both must work before initialization
