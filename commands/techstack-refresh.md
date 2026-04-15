---
name: techstack-refresh
description: >
  View, create, or update TECHSTACK.md for the current project. Runs the
  Technology Discovery Protocol to detect the project's stack from source files,
  package manifests, and CI/CD config. Safe to run at any time — existing
  user-added content is always preserved. Use --force to bypass the 72-hour
  freshness check and trigger a full rescan.
---

**Skills:** agent-flow-init-check

If `$ARGUMENTS` contains `--help` as a standalone word, output the following verbatim and STOP:

    Usage: /techstack-refresh [--force] [--help]

    View, create, or update TECHSTACK.md for the current project.

    Safe to run at any time. Existing user-added content is always preserved.
    No build or plan required.

    Flags:
      --force   Bypass the 72-hour freshness check and perform a full rescan
      --help    Show this help text and exit

If you output the help text above, stop here — do not read or execute anything below this line.

## Instructions

### Branch guard (mandatory first step)

Before ANY other action, check the current branch:
```bash
current_branch=$(git branch --show-current)
if [[ "$current_branch" == "main" || "$current_branch" == "master" ]]; then
  git checkout -b claude/update-techstack
fi
```

### Flag parsing

Set `force_mode` to false. If `$ARGUMENTS` contains `--force` as a standalone word, set `force_mode` to true.

### Step 1 — Check current state

Use Glob to check whether `TECHSTACK.md` exists at the project root. This is the authoritative check.

**If TECHSTACK.md is fresh** (exists and `last_scanned` < 72 hours ago) AND `force_mode` is false:
- Read and display the file contents to the user.
- Report: "TECHSTACK.md is up to date (last scanned: <datetime>). Run `/techstack-refresh --force` to trigger a fresh scan."
- Stop here.

**If TECHSTACK.md is missing, stale, or `force_mode` is true**: continue to Step 2.

### Step 2 — Run explorer

Invoke the **Explorer** (subagent_type="explorer") with this explicit brief:
"Run the Technology Discovery Protocol for this project. TECHSTACK.md is [missing / stale — last scanned: <datetime> / fresh (last_scanned: <datetime>) but --force was passed — treat as Case C and return a diff]. Override your internal Case B/C timestamp routing for this invocation — the orchestrator has already determined freshness; follow the case stated in the brackets above, not the timestamp. Follow the matching case (A or C) exactly and return a `TECHSTACK DISCOVERY:` section with the required output. If TECHSTACK.md is missing, return either A1 (full proposed content) or A2 (greenfield note) — never skip."

### Step 3 — Handle explorer output

**If the explorer did NOT return a TECHSTACK DISCOVERY section:**
- This is an explorer protocol failure. Ask via `AskUserQuestion`: "Explorer did not return discovery data as required. Retry?" (options: Retry / Skip).
- If retry: re-run the explorer with the same brief. If second run also returns nothing, stop and tell the user: "Explorer failed to return stack data. Try running `/build` or `/plan` which include additional recovery steps."
- If skip: stop.

**If the TECHSTACK DISCOVERY section contains "Greenfield: no stack detected" (A2 — greenfield):**
- Ask the user via `AskUserQuestion`: "No existing tech stack was detected from the project files. What technology stack do you plan to use?" (open-ended — user types their answer).
- Use the user's answer to populate the relevant TECHSTACK.md sections, then proceed to Step 4 with that content.

**If TECHSTACK.md is missing and explorer returned full proposed content (A1 — stack detected):**
- Present a brief summary of what was detected (languages, frameworks, test runner — 3-5 key findings).
- Ask via `AskUserQuestion`: "Confirm creating TECHSTACK.md with detected content?" (options: Confirm as-is / Review first / Skip).
- If "Review first": display the full proposed content, then ask again (Confirm / Edit manually / Skip).
- If confirmed: proceed to Step 4.

**If TECHSTACK.md is stale or `force_mode` is true (Case C) and explorer returned a diff:**
- Read the existing `TECHSTACK.md` in full.
- Apply these rules to each entry in the diff:
  - **Net-new entry** (DETECTED section/key has no exact match — same section heading AND same key text — anywhere in the current file): before auto-adding, scan the full file for any semantically equivalent entry (same concept expressed differently, e.g. "Python 3" vs "Python"). If a semantic match is found, treat it as a **conflicting entry** instead. Only auto-add if no exact or semantic match exists anywhere in the file.
  - **Conflicting entry** (DETECTED value for a key that already exists — exactly or semantically — with a different value): ask via `AskUserQuestion` — show CURRENT vs DETECTED, let the user keep current, accept detected, or skip.
  - **Entry only in CURRENT** (exists in file but not mentioned in DETECTED): leave untouched, always. Never propose removal.
- Summarise accepted changes.
- **If no changes were accepted:**
  - If `force_mode` is true: update `last_scanned` in TECHSTACK.md to the current UTC datetime, commit with message "Update TECHSTACK.md last_scanned (forced rescan, no changes)", push with `git push -u origin $(git rev-parse --abbrev-ref HEAD)`. **Stop here — do not proceed to Step 4.**
  - Otherwise: report "TECHSTACK.md is unchanged." **Stop here — do not proceed to Step 4.**
- **If changes were accepted:** proceed to Step 4.

### Step 4 — Write

**If TECHSTACK.md is missing:** Invoke the author agent: "Write the following content verbatim to `TECHSTACK.md` at the project root: <paste full proposed content>".

**If TECHSTACK.md is stale or `force_mode` is true:** Invoke the author agent: "Edit `TECHSTACK.md` at the project root — apply only the following accepted changes: <list accepted changes>. Do not modify any other content."

Commit and push:
```bash
git add TECHSTACK.md && git commit -m "Add TECHSTACK.md" && git push -u origin $(git rev-parse --abbrev-ref HEAD)
```
(Use "Update TECHSTACK.md" as the commit message if updating an existing file.)

### Step 5 — Report

Display the final TECHSTACK.md contents and confirm: "TECHSTACK.md written successfully."
