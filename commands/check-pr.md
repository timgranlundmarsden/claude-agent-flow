---
name: check-pr
description: >
  Check the current branch's PR for external review feedback, fix errors and
  warnings, run a final external review, and push.
---

**Skills:** agent-flow-init-check

$ARGUMENTS

If `$ARGUMENTS` contains `--help` as a standalone word, output the following verbatim and STOP:

    Usage: /check-pr [--help]

    Check the current branch's PR for external review bot feedback.
    Extract errors and warnings, fix them, run a final /external-review, and push.

    Prerequisites:
      - Current branch has a PR open on GitHub
      - External review bot has posted a review (marker: <!-- pr-review-bot -->)

    What it does:
      1. Finds the PR for the current branch
      2. Checks CI status — if tests are failing, reads logs, diagnoses, and fixes
      3. Reads the external review bot's review (errors + warnings)
      4. Evaluates each concern — fixes real issues, suppresses false positives
      5. Runs /external-review to verify fixes
      6. Commits and pushes

If you output the help text above, stop here — do not read or execute anything below this line.

## Instructions for orchestrator

All steps are sequential. Do NOT skip steps.

### Step 1 — Find the PR

Use GitHub MCP tools to find an open PR for the current branch:

```
ToolSearch query: "select:mcp__github__list_pull_requests,mcp__github__pull_request_read"
```

1. Get the current branch name: `git rev-parse --abbrev-ref HEAD`
2. Get the repo owner/name from the git remote: `git remote get-url origin | sed 's/.*github.com[:/]\(.*\)\.git/\1/' | sed 's/.*github.com[:/]\(.*\)/\1/'`
3. Call `mcp__github__list_pull_requests` with `head: "<owner>:<branch>"` and `state: "open"`
4. If no PR found, report "No open PR found for branch `<branch>`" and STOP.
5. Note the PR number.

### Step 2 — Check CI status

Check if all CI checks are passing on the PR:

```bash
GH_TOKEN="" gh pr checks <PR_NUMBER>
```

1. If all checks pass, proceed to Step 3.
2. If any check is failing:
   a. Get the failed run logs:
      ```bash
      GH_TOKEN="" gh run view <RUN_ID> --log-failed
      ```
   b. Analyse the failure output to identify:
      - **Test failures**: which test(s) failed and why (e.g. shellcheck warnings, assertion failures, missing fixtures)
      - **Build failures**: missing dependencies, syntax errors, workflow issues
   c. Read the relevant source file(s) to understand the root cause.
   d. Fix the issue in the code — not the test (unless the test itself is wrong).
   e. Stage and commit the fix:
      ```
      fix: resolve CI test failure — <brief description>
      ```
   f. Push and wait for CI to re-run:
      ```bash
      git push -u origin $(git rev-parse --abbrev-ref HEAD)
      ```
   g. Re-check CI status. If still failing, repeat from (a). Max 3 fix iterations — if still failing after 3 attempts, report the remaining failures to the user and continue to Step 3.
3. Report CI status to the user before proceeding.

### Step 3 — Read the external review (skip if GitHub MCP tools unavailable)

Use GitHub MCP tools to read the PR review:

```
ToolSearch query: "select:mcp__github__pull_request_read"
```

1. Call `mcp__github__pull_request_read` with the PR number to get reviews and comments.
2. Look for review(s) from `github-actions[bot]` whose body contains `<!-- pr-review-bot -->`.
3. If no external review found, try reading via `gh` CLI instead:
   ```bash
   GH_TOKEN="" gh api repos/<owner>/<repo>/pulls/<PR>/reviews --jq '[.[] | select(.body | contains("pr-review-bot"))] | sort_by(.submitted_at) | last'
   ```
   If still no review found, report "No external review bot comment found on PR #N" and proceed to Step 5 (skip review evaluation).
4. Extract the **most recent** external review (by date).
5. Parse the review body and any inline comments to build a list of concerns:
   - **Errors**: lines/comments containing `**error:**` or severity "error"
   - **Warnings**: lines/comments containing `**warning:**` or severity "warning"
   - **Info**: lines/comments containing `**info:**` — note but do not action
6. If the verdict is PASS and there are no unsuppressed errors or warnings, report "PR review is clean — nothing to fix" and proceed to Step 5.

### Step 4 — Evaluate and fix concerns

For each error and warning extracted in Step 3:

1. **Read the referenced file and line** to understand the context.
2. **Evaluate** whether the concern is:
   - **Actionable**: A real bug, security issue, or code quality problem that should be fixed
   - **False positive**: The reviewer misunderstood the code, missed a guard/return, or flagged something that isn't actually an issue
   - **Pre-existing**: The issue exists in code not changed by this PR

3. For **actionable** concerns:
   - Fix the issue in the code
   - If the fix requires tests, add or update tests
   - Stage the changed files

4. For **false positives** or **pre-existing** concerns:
   - Add a suppression entry to the appropriate config file:
     - Agent-flow infrastructure files → `.claude-agent-flow/external-review-config.yml`
     - Repo-specific files → `external-review-config.repo.yml`
   - Format:
     ```yaml
     - file: "path/to/file.ext"
       keyword: "word from the concern message"
       reason: "Brief explanation of why this is suppressed"
     ```
   - Stage the config file

5. Report a summary table to the user:
   ```
   | # | File | Concern | Action |
   |---|------|---------|--------|
   | 1 | path:line | brief message | Fixed / Suppressed (reason) / Skipped (info) |
   ```

### Step 5 — Run external review

Run the external review to verify fixes. Invoke the `/external-review` skill:

```
Skill: "external-review"
```

If the external review returns FAIL with new unsuppressed errors:
- Evaluate and fix the new errors (same logic as Step 4)
- Run the external review again (max 2 total external review runs)
- If still failing after 2 runs, report the remaining issues to the user and STOP (do not push)

If the external review returns PASS or WARN: proceed to Step 6.

### Step 6 — Commit and push

1. Check for uncommitted changes: `git status --short`
2. If there are changes:
   - Stage all modified files (be specific — `git add <file1> <file2> ...`)
   - Commit with a descriptive message:
     ```
     fix: address external review feedback on PR #N

     - <brief summary of fixes>
     - <brief summary of suppressions>
     ```
3. Rebase before push:
   ```bash
   git fetch origin
   git rebase origin/$(git rev-parse --abbrev-ref HEAD)
   ```
4. Push:
   ```bash
   git push -u origin $(git rev-parse --abbrev-ref HEAD)
   ```

### Step 7 — Report

Report to the user:
- PR number and link
- CI status (pass/fail, number of fix iterations if any)
- Number of concerns found (errors, warnings, info)
- Number fixed vs suppressed vs skipped
- External review final verdict
- Whether push succeeded

## Rules

- **Fix first, suppress last.** Always try to fix the issue before adding a suppression.
- **Never suppress actual bugs or security issues.**
- **Use the correct suppression config file** per CLAUDE.md rules (agent-flow infra → shared config, repo-specific → repo config). Since this IS the agent-flow source repo, all suppressions go in the shared file.
- **Do not force-push** unless explicitly instructed.
- **Do not modify code unrelated to the flagged concerns.**
- **Read the file before fixing** — understand the context, not just the error message.
