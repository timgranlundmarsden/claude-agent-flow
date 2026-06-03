---
name: review
description: >
  Run the adversarial critic against existing code. Default: parent reviews
  inline, zero subagent spawns. --strict: critic subagent + external review.
---

**Skills:** agent-flow-init-check

```bash
bash .claude-agent-flow/scripts/ensure-feature-branch.sh || exit $?
```

$ARGUMENTS

If `$ARGUMENTS` contains `--help`, output the following verbatim and STOP:

    Usage: /review [target] [--loops N] [--strict] [--help]
    Flags:
      --loops N          Critic iterations (default: 3). --loops 0 skips critic.
      --strict           Spawn critic once (max_loops=1).
    Default: 3 critic loops + external review (if EXTERNAL_REVIEW_API_KEY set) + AC self-review.

`--loops N`: `max_loops=N` (default: **3**). `--loops 0` = skip critic. `--strict` → `max_loops=1`.

**External review** — always attempted in Phase 2. Checks `EXTERNAL_REVIEW_API_KEY` in env and `.env`; skips gracefully with a note if not configured.

**Execution gate** — resolve once, apply throughout:
- `max_loops=0` → critic loop skipped.
- `max_loops>0` → critic loop runs up to N times.

## Phase 0 — Scope

Resolve target from `$ARGUMENTS`: `@plans/filename.md`, `TASK-XX`, or branch diff if empty. Find linked `task_id` from branch name or plan file `## Backlog Task:` header. Read task ACs if found. Get `merge_base` and changed files list.

## Phase 1 — Review

Read changed files. **Default tier:** skip to step 6.

**Strict tier:** spawn critic subagent (fresh context, diff only, `run_in_background=False` unless external review also enabled). Never expose iteration count. On FAIL: fix flagged items only, pass diff to next critic. Repeat until PASS or `max_loops`.

If external review is also enabled, critic and external review both consume the same diff and neither consumes the other's output — they are **independent** and may run in parallel via `Agent(run_in_background=True)`. Write a log marker immediately after each background launch; both markers must appear before either result is consumed. Stall detection applies per-spawn independently.

6. Run the full test suite (never scope to changed files — catch regressions). Report counts.

## Phase 2 — Reviewer

8. **AC self-review:** Generate `git diff $(git merge-base HEAD origin/main 2>/dev/null || git merge-base HEAD origin/master 2>/dev/null || git rev-list --max-parents=0 HEAD)...HEAD`. For each AC and any "What it must NOT do" constraint from the task/plan, confirm it is satisfied. List any BLOCKERs (unsatisfied ACs, violated constraints) and WARNINGs. Fix BLOCKERs before proceeding.

9. **External review:** Always run if `EXTERNAL_REVIEW_API_KEY` is configured (checked in env and `.env`):

```bash
GIT_ROOT=$(git rev-parse --show-toplevel)
if [[ -z "${EXTERNAL_REVIEW_API_KEY:-}" ]] && [[ -f "$GIT_ROOT/.env" ]]; then
  while IFS='=' read -r _k _v; do
    [[ "$_k" =~ ^EXTERNAL_REVIEW_[A-Za-z0-9_]+$ ]] || continue
    export "$_k"="$_v"
  done < <(grep -E '^EXTERNAL_REVIEW_[A-Za-z0-9_]+=' "$GIT_ROOT/.env")
fi
git fetch origin main --quiet 2>/dev/null || true
if MERGE_BASE=$(git merge-base HEAD origin/main 2>/dev/null); then
  :
elif MERGE_BASE=$(git merge-base HEAD origin/master 2>/dev/null); then
  :
else
  MERGE_BASE=$(git rev-list --max-parents=0 HEAD)
fi
_REVIEW_DIFF=$(mktemp /tmp/review-ext-diff.XXXXXX)
git diff "$MERGE_BASE"...HEAD > "$_REVIEW_DIFF"
RESULT=$(bash "$GIT_ROOT/.claude/skills/external-code-review/external-review.sh" \
  --diff-file "$_REVIEW_DIFF" \
  --suppress-config "$GIT_ROOT/.claude-agent-flow/external-review-config.yml" \
  --suppress-config "$GIT_ROOT/external-review-config.repo.yml" \
  2>/tmp/review-ext-err.txt) || true
```

If `EXTERNAL_REVIEW_API_KEY` is not configured: note `External review: Skipped — EXTERNAL_REVIEW_API_KEY not configured.` and continue. If script fails: note `External review: Skipped — script failed.` and continue. On FAIL: fix flagged items, re-run once (max 2 external review passes total).

10. On BLOCKERs from either review: fix; re-review (max 2 total). Report: critic iterations, external review verdict, issues, test result, findings.

## Phase 3 — Commit, push, and PR

13. If the current branch is NOT main/master:
   1. Commit uncommitted changes (skip if clean).
   2. `git push -u origin $(git rev-parse --abbrev-ref HEAD)`
   3. ToolSearch `"select:mcp__github__list_pull_requests,mcp__github__create_pull_request"`. Check existing PR; create if none.

## Rules

- Never change task status — review is inspection only.
- `backlog` CLI via Bash, double-quoted strings only.
- **Spawn rules:** zero subagent spawns except critic (Phase 1). No implicit spawning; if in doubt, don't spawn.
- **Parallelism rule:** `run_in_background=True` only for independent spawns. Critic and external review are independent when both consume the same diff. Dependent pairs (critic→builder-fix) must remain sequential. Default is sequential; parallelism is opt-in per invocation.
