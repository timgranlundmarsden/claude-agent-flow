---
name: review
description: >
  Run the adversarial critic against existing code without rebuilding.
  Use when you want to harden code that already exists, or run a quality
  pass on a completed feature before shipping.
---

**Skills:** agent-flow-init-check

$ARGUMENTS

If `$ARGUMENTS` contains `--help` as a standalone word, output the following verbatim and STOP:

    Usage: /review [target] [--loops N] [--help]

    Run the adversarial critic against existing code without rebuilding.

    Arguments:
      [target]                Task ID (TASK-XX), plan file path, or free-text scope description.
                              If omitted, reviews all changes on the current branch vs main
                              and auto-detects the linked backlog task from the branch.

    Flags:
      --loops N               Number of critic iterations (default: 3, max: 5)
      --help                  Show this help text and exit

    Pipeline: explorer -> critic loop -> tester (on critic PASS) -> reviewer (+ external) -> commit/push/PR -> report

If you output the help text above, stop here — do not read or execute anything below this line.

Run the adversarial review loop on the following:

## Instructions for orchestrator

All steps are sequential.

### Parse flags

Before anything else, parse `$ARGUMENTS` for the `--loops` flag:

1. If `$ARGUMENTS` contains `--loops` followed by a number N: set `max_loops` to N (clamped to 1–5). Remove `--loops N` from the arguments string — the remainder is the target.
2. If `--loops` is not present: set `max_loops` to **3**.

### Model override rule

Read `.claude/agents/<agent-name>.md` and pass the `model:` frontmatter value as the `model` parameter
on Agent tool calls. If no `model:` field, value is `inherit`, or the agent file does not exist, omit the parameter.

### Branch guard (mandatory first step)

Before ANY other action (including task state changes or commits), check the current branch:
```bash
current_branch=$(git branch --show-current)
if [[ "$current_branch" == "main" || "$current_branch" == "master" ]]; then
  git checkout -b claude/<topic-slug>
fi
```
Never commit directly to main. Create a `claude/` feature branch first.

### Phase 0 — Resolve scope and task (silent)

This step is silent — never interrupt or message the user about it.

#### 0a. Determine review scope

If `$ARGUMENTS` is empty or contains only whitespace:

1. Detect the **base branch** by running: `git merge-base HEAD main 2>/dev/null || git merge-base HEAD master 2>/dev/null`. Call the result `merge_base`.
2. Get the list of changed files: `git diff --name-only <merge_base>...HEAD`.
3. Get the full diff: `git diff <merge_base>...HEAD`.
4. These become the **review scope** — all changes on the current branch compared to main.
5. Attempt to find a linked task by scanning `backlog/tasks/` for a task whose title or branch field matches the current branch name (`git rev-parse --abbrev-ref HEAD`). If found, extract `task_id`. If not found, check if any plan file in `plans/` references this branch or was recently modified on this branch (appears in the changed files list) and scan it for `## Backlog Task: TASK-XX`.

If `$ARGUMENTS` is NOT empty, use it to resolve the scope as before:

- **`@plans/filename.md`** — Read the file. Scan for `## Backlog Task: TASK-XX`. Extract ID. Use the plan to understand what was requested, then get the branch diff against main as described above for the review scope.
- **`TASK-XX`** — Use the ID directly. Read the task file for context on what was requested. Get the branch diff against main for the review scope.
- **`@backlog/tasks/task-N - Title.md`** — Read the file. Extract the task ID from the `id:` field in file content if present (authoritative). Otherwise derive from the filename: the numeric part before the first space is the task ID with no padding (e.g. `task-37 - Backlog.md-Agent-Flow-Integration.md` → `TASK-37`). Get the branch diff against main for the review scope.
- **Inline free-text** — No task; set `task_id` to empty. Use the text as context for the review. Get the branch diff against main for the review scope.

#### 0b. Cross-reference with task

If a `task_id` was found, read the task file to understand the acceptance criteria and what was requested. Pass this context to the critic so it can verify that the changes satisfy the requirements — not just that the code is correct, but that it delivers what was asked for.

If no task ID is found: set `task_id` to empty and proceed without tracking. No message to user.

### Phase 1 — Review

1. Invoke explorer to map the relevant files (use the changed files list from Phase 0 as the starting point)
2. Invoke critic with exactly this context:
   - **Task context (if available):** include the task's acceptance criteria and description so the critic can verify the changes deliver what was requested — not just code quality but also completeness against requirements
   - **First invocation:** pass the list of new/changed files for the critic to read (from the branch diff against main)
   - **Subsequent invocations:** pass only the raw `git diff HEAD` output — do NOT re-pass the file list; the critic works from the diff alone
   - **CRITIC INTEGRITY RULE:** NEVER tell the critic which iteration it is on, how many
     iterations remain, or the max loop count. Do NOT include phrases like "iteration 2 of 3",
     "final review", "last chance", or any other loop-position context. The critic must judge
     code quality in isolation — its verdict must never be influenced by loop position.
3. After each critic iteration (orchestrator tracks internally, not exposed to critic):
   - If `task_id` is set: `backlog task edit <task_id> --append-notes "Review critic: PASS/FAIL - <one-line summary>"`
4. If critic returns FAIL:
   a. Pass ISSUE list to the relevant builder agent (frontend or backend)
   b. Builder fixes flagged items only
   c. Run `git diff HEAD` and pass that output to the next critic invocation (step 2)
5. Repeat until PASS or `max_loops` iterations (then stop and report).
   If `task_id` is set and the iteration limit was reached: `backlog task edit <task_id> --append-notes "Review hit max iterations: <remaining issues summary>"`
6. On PASS: invoke tester to verify nothing broke. The tester MUST run the **entire** test suite — never filter or scope tests to only the changed files. The point is to catch regressions, which by definition are in code you didn't change. Tell the tester to run all tests and report the full results (pass count, fail count, any failures).
7. After tester: if `task_id` is set: `backlog task edit <task_id> --append-notes "Tester complete: <one-line summary>"`

### Phase 2 — Reviewer (+ external review)

8. Invoke reviewer for a final quality pass. Provide:
   - **Task context (if available):** acceptance criteria, description, and constraints — so the reviewer checks fitness for purpose, not just code standards
   - The full branch diff against main (`git diff <merge_base>...HEAD`) — so the reviewer sees all changes holistically
   - The list of all new/changed files for the reviewer to read end-to-end
   The reviewer agent will:
   - Perform its own internal review (BLOCKER / WARNING / SUGGESTION)
   - Run 2x external review API calls (mandatory — check env vars first, then `.env` file; only skip if neither provides credentials)
   - Aggregate and deduplicate findings across all 3 reviews (internal + 2 external)
   - Log disagreements with external reviews and add suppressions to `external-review-config.repo.yml`
9. After reviewer: if `task_id` is set: `backlog task edit <task_id> --append-notes "Reviewer complete: <one-line summary>"`
10. If reviewer reports BLOCKERs:
    a. Pass BLOCKER + WARNING list to the relevant builder agent (frontend or backend)
    b. Builder fixes flagged items only
    c. Builder stages only the files changed by the fix and commits with a descriptive message.
    d. Return to step 8 for a re-review — pass the full branch diff (`git diff <merge_base>...HEAD`) for full context, consistent with the first reviewer invocation
    e. Repeat until reviewer reports 0 BLOCKERs (max 2 total reviewer invocations: the initial review plus at most 1 re-review)
11. If 2 total reviewer invocations have been made and BLOCKERs remain: stop the reviewer loop and proceed to step 12 with remaining BLOCKERs noted in the report.
    If `task_id` is set: `backlog task edit <task_id> --append-notes "Reviewer hit max iterations: <remaining BLOCKERs summary>"`
12. Report: critic iteration count, issues found, issues resolved, test result, reviewer findings, external review results
13. At completion: if `task_id` is set: `backlog task edit <task_id> --append-notes "Review complete: <final one-line summary>"`

### Phase 3 — Commit, push, and PR

14. If the current branch is NOT main/master:
   1. **Commit** any uncommitted changes (from critic fix iterations):
      Stage only the files touched during the review (use `git diff --name-only` to identify them), then commit with a descriptive message.
      Skip if working tree is clean.
   2. **Push** the branch:
      ```
      git push -u origin $(git rev-parse --abbrev-ref HEAD)
      ```
   3. **Create or update PR** using GitHub MCP tools:
      1. Use `ToolSearch` to load `mcp__github__list_pull_requests` and `mcp__github__create_pull_request` tools:
         ```
         ToolSearch query: "select:mcp__github__list_pull_requests,mcp__github__create_pull_request"
         ```
      2. Check if a PR already exists for the current branch
      3. If no PR exists, create one:
         - Title: `TASK-ID - Task Title` (or `Review: <branch-name>` if no task)
         - Body: summary of review findings, fixes applied (if any), and test results
      4. If a PR already exists, skip creation (the push already updated it)
      5. If `task_id` is set: `backlog task edit <task_id> --append-notes "PR created: <pr_url>"`
      6. If GitHub MCP tools are unavailable, skip silently

## Rules
- `backlog` CLI via Bash, double-quoted strings only. Hooks auto-push after backlog ops.
- **Never change task status** — review is inspection only; /build owns status
- Proceed silently if no task found

### Skill collision rules
- `backlog-md`: reference only — `backlog-tpm`: never invoked
