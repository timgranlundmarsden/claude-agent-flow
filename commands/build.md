---
name: build
description: >
  Build a feature using the adversarial review loop. Runs builder agents, then
  critic, then fixes, then critic again — repeating until critic passes and tests
  are green. Use when quality assurance matters more than speed.
---

**Skills:** agent-flow-init-check

$ARGUMENTS

If `$ARGUMENTS` is empty/whitespace, or contains `--help` as a standalone word, output the following verbatim and STOP:

    Usage: /build <brief or @plans/file.md> [--loops N] [--help]

    Build a feature using the adversarial review loop.

    Arguments:
      <brief>                 Free-text feature description, or @plans/file.md reference

    Flags:
      --loops N               Max adversarial loop iterations (default: 3)
      --help                  Show this help text and exit

    Pipeline: explorer -> architect -> builder(s) -> critic loop -> tester -> reviewer -> author

If you output the help text above, stop here — do not read or execute anything below this line.

Build the following using the adversarial review loop pattern:

If `$ARGUMENTS` contains `--loops N` (e.g. `--loops 2`), extract N as the max
adversarial loop iterations and strip that flag before treating the rest as the
feature description. If no `--loops` flag is present, default to **3 iterations**.

**READ THIS ENTIRE FILE before executing any step.** Do not run the pipeline from memory. Every numbered step must be followed — the completion steps (PR creation, task status, token report) are just as mandatory as the build steps.

## Instructions for orchestrator

Follow this exact sequence. All steps are sequential — complete each before
starting the next.

### Foreground-only rule

Never set `run_in_background: true`. All agents run in foreground sequentially.
Stall detection per `ways-of-working` skill (5 min for builders, any output for others).

### Model override rule

Read `.claude/agents/<agent-name>.md` and pass the `model:` frontmatter value as the `model` parameter
on Agent tool calls. If no `model:` field, value is `inherit`, or the agent file does not exist, omit the parameter.
Note: model overrides may not apply at runtime — all agents may run on the parent model. This is expected; see `ways-of-working` for intended tiers.

### Branch guard (mandatory first step)

Before ANY other action (including task state changes or commits), check the current branch:
```bash
current_branch=$(git branch --show-current)
if [[ "$current_branch" == "main" || "$current_branch" == "master" ]]; then
  git checkout -b claude/<topic-slug>
fi
```
Never commit directly to main. Create a `claude/` feature branch first.

### Phase 0 — Resolve Input

Detect the entry point type from `$ARGUMENTS` and resolve the task ID before doing anything else.

**Input normalisation:** Before detecting the entry point, normalise the raw input using these ordered steps:
1. Strip leading/trailing whitespace from the full input.
2. If the result starts with `task` (case-insensitive), remove that prefix, then greedily strip ALL immediately following `-` and whitespace characters (continue stripping until the first character that is neither `-` nor whitespace).
3. Strip any remaining leading zeros from a purely-digit remainder.
4. If the remainder after steps 2–3 is non-empty and consists only of digits, and its numeric value is greater than 0 (e.g. `41`, `7`), the canonical task ID is `TASK-<digits>` — it IS a task ID.
5. If neither step 4 applies nor the original input is a path or `@`-reference (e.g. remainder contains non-digit characters, is empty, or is `0`), treat as an inline brief or path reference — do NOT convert to a task ID.

Examples: `task 41` → `TASK-41` · `TASK 41` → `TASK-41` · `task41` → `TASK-41` · `TASK-41` → `TASK-41` · `41` → `TASK-41` · `Task-41` → `TASK-41` · `041` → `TASK-41` · `42 ways to improve...` → inline brief (non-digit content present) · `task` → inline brief (empty remainder) · `0` → inline brief (zero is not a valid task ID) · `task 0` → inline brief (zero) · `task-0` → inline brief (zero is not a valid task ID).

**Dual-context output contract:** Phase 0 assembles up to two labelled sections for the downstream pipeline:
- `PLAN CONTEXT:` — the full content of the linked `plans/*.md` file (primary narrative brief)
- `TASK STATUS:` — extracted from `backlog task <id> --plain` output: the AC check-state block: lines formatted `- [x] #N …` or `- [ ] #N …` found within the `Acceptance Criteria:` section (between the `Acceptance Criteria:` header and the next section header); if no `#N`-indexed lines are found there, fall back to capturing all `- [x]` / `- [ ]` lines in that section verbatim; lines with this format outside that section (e.g. in `Definition of Done:`) must be ignored; and the `Implementation Notes:` body (if that header is present in the output: all lines after the header's dashed separator — any line of 3 or more `-` characters — until the first line that is one of the known section headers (`Definition of Done:`, `Implementation Plan:`, `Acceptance Criteria:`, `Description:`, `References:`) or end of output; if the `Implementation Notes:` header is absent in the output, treat notes as empty). If the AC list is empty AND the implementation notes body is empty, omit `TASK STATUS:` entirely.

When both artifacts are available, emit both sections. When only one is available, emit only that section. Never block, error, or warn on a missing artifact — fall back silently.

- **`@plans/filename.md`** — Read the file. Scan for a line matching `## Backlog Task: TASK-XX`. Extract the task ID if found. If a task ID is found, run `backlog task <task_id> --plain`, extract the AC check-state block and Implementation Notes body, and assemble `TASK STATUS:`. Emit `PLAN CONTEXT:` (full plan file) + `TASK STATUS:` (if non-empty). If the `backlog` call fails or yields no AC items and no notes, omit `TASK STATUS:` silently and continue with the plan file alone. If no `## Backlog Task:` header is found, treat as "plan file without task link" (see below).
- **`TASK-XX`** — Run `backlog task <id> --plain` via Bash to load the full task context. Then scan the `--plain` output for a line beginning `References: `. Split on commas, trim whitespace around each entry, drop empty entries, and select the first entry that starts with the literal prefix `plans/` (no leading `./`, `/`, scheme, or `../`), ends with `.md`, contains no `://`, and contains no `..` segment (i.e. no path component that is exactly `..`). If such a path is found and the file is readable, read the plan file and assemble dual-context: emit `PLAN CONTEXT:` (full plan file) and `TASK STATUS:` (AC check-state block + Implementation Notes body from `--plain` output). If no `References:` line is present, no entry passes the path guard, or the file is not readable, fall back silently: use the full `--plain` output as the implementation brief.
- **`@backlog/tasks/task-N - Title.md`** — Derive the task ID from the filename: take the numeric part from `task-N` (the digit run immediately following `task-`, stopping at the first space, `.`, or end of the filename segment), strip any leading zeros (e.g. `task-37 - Title.md` → `TASK-37`). Then run `backlog task <id> --plain` and proceed identically to the `TASK-XX` entry point above: scan for a `References:` plan file, apply the path guard, assemble dual-context if a readable plan file is found, or fall back to `--plain` output alone.
- **Inline brief text** — Create a task on the fly:
  ```
  backlog task create "Brief title" -d "Brief text" -l feature
  ```
  Parse the created task ID from stdout (e.g. "Created task TASK-37"). Store as `task_id`.
  If parsing the task ID fails, set `task_id` to empty and continue without tracking — warn the user once but do not interrupt the pipeline.
  Push: `git push -u origin $(git rev-parse --abbrev-ref HEAD)`

- **Plan file without task link** — Read the plan file and create a fully-populated task using the same field mapping as plan.md (see plan.md Phase 4 step 13): read all sections (title, description from `## What it must do` + `## What it must NOT do`, each AC item as a separate `--ac` flag, `## Technical approach` as `--plan`, `## Edge cases` as `--notes`, priority if present, inferred labels, skills from `**Skills:**` line) and pass them all in the `backlog task create` command.
  First run `backlog search "<title keywords>"` via Bash. If a matching task exists, extract its ID, store as `task_id`, skip the `backlog task create` step, and proceed directly to sub-step 2 (add `## Backlog Task:` header to plan file). Otherwise proceed with task creation. A task matches only if its title closely matches the plan title AND it references the same plan file path (or is clearly the same feature). If uncertain, create a new task rather than reusing an unrelated one.
  1. Run `backlog task create ...` with all extracted fields.
     Parse the created task ID from stdout. Store as `task_id`.
     If parsing the task ID fails, set `task_id` to empty and continue without tracking — warn the user once but do not interrupt the pipeline.
     Push: `git push -u origin $(git rev-parse --abbrev-ref HEAD)`
  2. If `task_id` is non-empty: Update the plan file to add `## Backlog Task: TASK-XX` as a header immediately after the `# Feature:` heading line.
     ```
     git add plans/<filename>.md && git commit -m "Link plan to TASK-XX" && git push -u origin $(git rev-parse --abbrev-ref HEAD)
     ```

If no task ID was found or created, set `task_id` to empty and skip all backlog tracking steps silently throughout execution — no message to the user.

**Context handoff:** Whatever combination of `PLAN CONTEXT:` and `TASK STATUS:` was assembled above is the complete brief passed to explorer, architect, builder(s), critic, tester, and reviewer throughout the rest of the pipeline. Agents must not re-read the plan file or call `backlog task --plain` for content. The orchestrator may still call `backlog task --plain` solely to resolve AC indices for `--check-ac` operations in step 10.

If `task_id` is non-empty: set the task to In Progress now, before any agent work begins:
```
backlog task edit <task_id> -s "In Progress"
git push -u origin $(git rev-parse --abbrev-ref HEAD)
```
This also applies when resuming work on a task that was previously set to "Ready for Review" — if the user requests more changes, set it back to "In Progress" before starting.

### Backlog task tracking

All tracking uses `backlog` CLI via Bash. Double-quoted strings only. The auto-push hook commits but does NOT reliably push — after every status change (`-s`), always run `git push -u origin $(git rev-parse --abbrev-ref HEAD)` immediately after the backlog command.
If `task_id` is empty, skip all tracking steps silently.

### Phase 1 — Prepare
1. Invoke explorer to map all affected files
2. If `task_id` is set: `backlog task edit <task_id> --append-notes "Explorer complete: <one-line summary>"`
2a. **TECHSTACK.md lifecycle** — Use Glob to check whether `TECHSTACK.md` exists at the project root. This is the authoritative check, independent of what the explorer returned.

    **If TECHSTACK.md is missing** (file does not exist):
    - The explorer should have returned a `TECHSTACK DISCOVERY:` section (Case A). Check which outcome:
      - **A2 — Greenfield:** The section contains the note `Greenfield: no stack detected`. Ask the user via `AskUserQuestion`: "No stack was detected from project files. What technology stack do you plan to use?" (open-ended). Use the user's answer to populate a proposed TECHSTACK.md (fill in the relevant sections from the template format), then proceed to confirmation below.
      - **A1 — Stack detected:** The section contains a full proposed TECHSTACK.md. Proceed to confirmation below.
    - If the explorer did NOT return a `TECHSTACK DISCOVERY:` section at all: this is an explorer protocol failure. Ask the user via `AskUserQuestion`: "Explorer did not return TECHSTACK data as required. Retry?" (options: Retry / Continue without stack context). If retry: re-invoke explorer with the same brief. If the second run also returns nothing, warn the user: "Explorer failed to return TECHSTACK data after two attempts. Continuing without stack context — run `/techstack-refresh` later to create it." Set `techstack_context` to empty and continue to step 2b.
    - **Confirmation:** Ask via `AskUserQuestion`: "TECHSTACK.md is missing. Confirm creating it with the proposed content?" (options: Confirm as-is / Review first / Skip for now).
    - If confirmed: invoke the author agent: "Write the following content verbatim to `TECHSTACK.md` at the project root: <paste full proposed content>". Commit: `git add TECHSTACK.md && git commit -m "Add TECHSTACK.md" && git push`.

    **If TECHSTACK.md is stale** (explorer returned a `TECHSTACK DISCOVERY:` section with changes):
    - Read the existing `TECHSTACK.md` in full. Apply these rules to each entry in the explorer's diff:
      - **Net-new entry** (DETECTED section/key has no exact match anywhere in the current file): before auto-adding, scan the full file for any semantically equivalent entry (same concept expressed differently, e.g. "Python 3" vs "Python"). If a semantic match is found, treat it as a **conflicting entry** instead. Only auto-add if no exact or semantic match exists anywhere in the file.
      - **Conflicting entry** (DETECTED value for a key that already exists — exactly or semantically — with a different value): ask via `AskUserQuestion` — show CURRENT vs DETECTED, let the user keep current, accept detected, or skip.
      - **Entry only in CURRENT** (exists in file but not mentioned in DETECTED): leave untouched, always. Never propose removal. It may be user-added or simply undetected — either way it is preserved.
    - If any changes were accepted: invoke the author agent to apply only the accepted changes. Commit: `git add TECHSTACK.md && git commit -m "Update TECHSTACK.md" && git push`.

    **If TECHSTACK.md is fresh** (exists and `last_scanned` < 72 hours ago — the orchestrator determines freshness from frontmatter, not from explorer output):
    - No action needed. Continue.

    **After builders complete (step 10):** If any builder introduced a new technology not in TECHSTACK.md, invoke the author agent to add it to the file. Commit: `git add TECHSTACK.md && git commit -m "Update TECHSTACK.md: add <technology>"`.

2b. **TECHSTACK context load** — If `TECHSTACK.md` exists after step 2a (created, updated, or already fresh), read it in full and store its content as `techstack_context`. Include this content verbatim in the brief for **every agent invoked for the remainder of this pipeline** — architect, storage, frontend, backend, tester, critic, reviewer, and author. Prefix it with the heading `## Project Tech Stack (from TECHSTACK.md)` so agents can find it immediately. If TECHSTACK.md does not exist (user skipped creation, greenfield, or explorer failure), set `techstack_context` to empty and omit the section from briefs.

    **Session-resume rule:** If re-entering this pipeline after a session interruption (i.e., skipping directly to Phase 2 or later), re-read `TECHSTACK.md` now and reload `techstack_context` before invoking any agent. Never invoke any agent in Phase 2 or later without first confirming `techstack_context` is populated (or explicitly empty because the file does not exist).
3. If design decisions exist, invoke architect and wait for the design brief
4. If `task_id` is set: `backlog task edit <task_id> --append-notes "Architect complete: <one-line summary>"`
5. Architect may have already dispatched researcher internally for technical validation.
   If additional library or API research is still needed, invoke researcher explicitly.
6. Present the plan to the human before proceeding (one paragraph summary)

### Phase 2 — Build
7. If schema or storage changes are needed, invoke storage FIRST and wait for completion
8. If the plan contains a `**Skills:**` directive, extract the listed skills and include
   them in the builder agent's brief with this explicit instruction:
   "Before starting work, invoke each skill listed under **Skills:** using the `Skill` tool."
8a. When briefing builders for files expected to exceed 200 lines, include this instruction:
    "For files >200 lines: Write a skeleton with section placeholders first, then fill each
    section with sequential Edit calls (each under 100 lines). See 'Incremental Writing Pattern'
    in the `ways-of-working` skill. Output `[MILESTONE]` markers after each section."
8b. Inline all reference material (CSS tokens, component patterns, schema definitions, sibling
    file content) directly in the builder brief. Include the directive: "Do NOT read additional
    files for context. All reference material is provided below." Target: 0-2 file reads by builder.
8c. Every builder brief MUST include: "Write comprehensive tests for all code changes.
    Tests must cover: happy path, edge cases, error states, and boundary conditions.
    Code without tests will be rejected by the critic and tester."
9. Invoke the relevant builder agent (frontend or backend) — one at a time.
    When invoking **frontend** for any UI/HTML/visual deliverable, your brief MUST include:
    - The design quality bar: distinctive, production-grade, not generic AI aesthetics
    - Any aesthetic constraints or tone from the plan (dark/light, brand colours, technical constraints)
    - Explicit instruction: "Apply your preloaded `frontend-design` principles — commit to a bold aesthetic direction before writing code."
    - Include `techstack_context` verbatim in this brief (loaded at step 2b; reload if session was interrupted).
10. After each builder agent completes:
    - `backlog task edit <task_id> --append-notes "Builder complete: <one-line summary>"`
    - Check off any acceptance criteria the builder satisfied:
      To determine the correct 1-based index for each satisfied criterion, first run `backlog task <task_id> --plain` and match each criterion the builder satisfied by content to its position in the AC list.
      `backlog task edit <task_id> --check-ac <N>` (1-based index, one call per satisfied AC item) then push. Repeat for each satisfied AC item.
11. If both frontend and backend are needed, run the one with fewer dependencies first,
    then the second with the first agent's completion report as context

### Phase 3 — Adversarial loop (repeat until PASS or max iterations)
12. Invoke critic with exactly this context:
    - **Task context (if available):** include the task's acceptance criteria and description so the critic verifies not just code correctness but also that the changes deliver what was asked for — fitness for purpose, not just absence of bugs
    - **First invocation:** the list of new/changed files for the critic to read
    - **Subsequent invocations:** the raw `git diff HEAD` output only — do NOT pass a file list;
      the critic must work from the diff alone, not re-read the full codebase
    - **CRITIC INTEGRITY RULE:** NEVER tell the critic which iteration it is on, how many
      iterations remain, or the max loop count. Do NOT include phrases like "iteration 2 of 3",
      "final review", "last chance", or any other loop-position context. The critic must judge
      code quality in isolation — its verdict must never be influenced by loop position.
    - On the very last allowed iteration, pass the full file list again (not just the diff)
      for a fresh-eyes pass — but do NOT reveal that it is the final iteration.
    - Include `techstack_context` verbatim in this brief (loaded at step 2b; reload if session was interrupted).
13. After each critic iteration (orchestrator tracks internally, not exposed to critic):
    - `backlog task edit <task_id> --append-notes "Critic: PASS/FAIL - <one-line summary>"`
14. If critic returns FAIL:
    a. Pass the specific ISSUE list to the relevant builder agent
    b. Builder fixes ONLY the flagged items — no other changes
    c. Run `git diff HEAD` and pass that output to the next critic invocation
15. If critic returns PASS: proceed to Phase 4

### Phase 4 — Verify
16. Invoke tester with:
    - The full test suite to run
    - **Task context (if available):** the acceptance criteria, so the tester can verify that the implementation satisfies the requirements — not just that tests pass, but that the right things are being tested
    - The list of changed files, so the tester can check import consistency and structural validity even when no formal test suite exists
    - Explicit instruction: "Reject if any code change lacks comprehensive tests. Every function/module added or modified must have tests covering happy path, edge cases, error states, and boundary conditions."
    - Include `techstack_context` verbatim in this brief (loaded at step 2b; reload if session was interrupted).
17. After tester: `backlog task edit <task_id> --append-notes "Tester complete: <one-line summary>"`
18. If tests fail: diagnose each failure before acting. Determine whether the test
    exposes a genuine code bug (pass the failure to the builder to fix the code) or
    the test itself is incorrect/incomplete (fix the test). Never weaken a test just
    to make it pass. Then return to step 12
19. If tests pass: proceed to Phase 5

### Phase 5 — Wrap up
20. Invoke reviewer for a final quality pass equivalent to `/review`. Provide:
    - **Task context (if available):** acceptance criteria, description, and "What it must NOT do" constraints — so the reviewer checks fitness for purpose, not just code standards
    - The full branch diff against main (`git diff <merge_base>...HEAD`) — so the reviewer sees all changes holistically, not just the latest commit
    - The list of all new/changed files for the reviewer to read end-to-end
    - Instruction: "Review for security, correctness, performance, and style. Also verify that the changes satisfy all acceptance criteria and do not violate any negative requirements. Report BLOCKERs, WARNINGs, and SUGGESTIONs."
    - Include `techstack_context` verbatim in this brief (loaded at step 2b; reload if session was interrupted).
21. After reviewer: `backlog task edit <task_id> --append-notes "Reviewer complete: <one-line summary>"`
21a. If reviewer reports BLOCKERs or WARNINGs that should be fixed:
    a. Pass the specific issue list to the relevant builder agent — the orchestrator NEVER applies fixes directly, even for seemingly trivial changes
    b. Builder fixes ONLY the flagged items
    c. Return to step 20 for a re-review of the fix diff (reviewer iteration 2+: pass `git diff HEAD` only)
    d. Repeat until reviewer reports 0 BLOCKERs
22. Invoke author to update docs and CHANGELOG
    - Include `techstack_context` verbatim in this brief (loaded at step 2b; reload if session was interrupted).
23. After author: `backlog task edit <task_id> --append-notes "Author complete: <one-line summary>"`

### Phase 5b — Commit implementation
24. Stage all new and modified implementation files (NOT `.claude/settings.local.json*` or other unrelated files). Commit with a descriptive message summarising the feature. Push to the remote branch:
    ```
    git add <list of implementation files>
    git commit -m "<descriptive message>"
    git push -u origin $(git rev-parse --abbrev-ref HEAD)
    ```
    Also stage and commit any screenshot evidence in `.scratch/evidence/` that was generated during the pipeline.

### Phase 5c — Create PR
24a. If `task_id` is set and the current branch is NOT main/master:
    1. Use `ToolSearch` to load `mcp__github__list_pull_requests` and `mcp__github__create_pull_request` tools:
       ```
       ToolSearch query: "select:mcp__github__list_pull_requests,mcp__github__create_pull_request"
       ```
    2. **Set task to "Ready for Review" and push — this MUST be the last push before PR creation:**
       ```
       backlog task edit <task_id> -s "Ready for Review"
       git push -u origin $(git rev-parse --abbrev-ref HEAD)
       ```
       IMPORTANT: Do NOT set "Ready for Review" until ALL prior phases have completed
       successfully — including the final commit, push, and all agent work.
       This status signals to the user that the work is truly done and ready for human review.
    3. Check if a PR already exists for the current branch:
       ```
       mcp__github__list_pull_requests(owner, repo, head: "owner:branch", state: "open")
       ```
    4. If no PR exists, create one:
       - Title: `TASK-ID - Task Title` (e.g., `TASK-6 - Git Merge Conflict Prevention`)
       - Body: auto-generated summary of what was built, acceptance criteria checklist, and test results
       - **IMPORTANT:** The `body` parameter must use actual newlines, NOT `\n` escape sequences.
         MCP tool string parameters are passed literally — `\n` renders as the text `\n` on GitHub,
         not as a line break. Write the body as a multi-line string with real line breaks.
       ```
       mcp__github__create_pull_request(owner, repo, title, body, head: branch, base: "main")
       ```
    5. Store the PR URL
    6. If GitHub MCP tools are unavailable or ToolSearch fails, skip PR creation with a warning — do not block the pipeline

### Phase 6 — Report
25. Report to human (no push in this step — "Ready for Review" was already set in Phase 5c):
26. Report to human:
    - What was built
    - How many adversarial loop iterations it took
    - Any WARNINGs from reviewer that were not fixed (with reasoning)
    - Test pass/fail summary
    - **Token cost summary:** Run the token analyser CLI (basic mode, no `--breakdown` or `--models`) and include the summary table in the report:
      ```bash
      python3 .claude/skills/token-analyser/token-analyser
      ```
      Display only the first output block (summary table with model, health, calls, duration, tokens, cost). Do not include the call breakdown, model breakdown, or savings sections — keep the report concise.

## Hard limit
If still failing after the max adversarial loop iterations (default 3, or the value
from `--loops N`): STOP.
Set task to Blocked: `backlog task edit <task_id> -s "Blocked" --append-notes "Blocked: max iterations reached - <remaining issues>"` then `git push -u origin $(git rev-parse --abbrev-ref HEAD)`.
Report to human with the remaining issues. Do not continue looping.
The problem is likely a design issue, not an implementation issue.

If blocked for any other reason (missing dependency, unresolvable failure, needs user input):
`backlog task edit <task_id> -s "Blocked" --append-notes "Blocked: <reason>"` then `git push -u origin $(git rev-parse --abbrev-ref HEAD)`.

## Rules
- `backlog` CLI via Bash, double-quoted strings only. After every `-s` status change, always run `git push -u origin $(git rev-parse --abbrev-ref HEAD)` — hooks commit but do not reliably push.
- Never auto-set tasks to Done — only a human moves a task to Done
- If `task_id` is empty, skip all tracking steps silently

### Skill collision rules
- `backlog-md`: reference only — /build owns control flow. `backlog-tpm`: never invoked.
