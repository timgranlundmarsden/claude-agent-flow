---
name: build
description: >
  Build a feature using the adversarial review loop. Default tier: parent works
  end-to-end, zero subagent spawns. --strict tier adds critic + external review.
---

**Skills:** agent-flow-init-check

$ARGUMENTS

If `$ARGUMENTS` is empty/whitespace or contains `--help`, output the following verbatim and STOP:

    Usage: /build <brief or @plans/file.md> [--loops N] [--strict] [--help]
    Flags:
      --loops N          Max critic iterations (default: 3). --loops 0 skips critic.
      --strict           Spawn critic once (max_loops=1).
      --help             Show this help text and exit
    Default: 3 critic loops + external review (if EXTERNAL_REVIEW_API_KEY set) + AC self-review.

READ THIS FILE before executing. All steps sequential.

```bash
bash .claude-agent-flow/scripts/ensure-feature-branch.sh || exit $?
```

Extract `--loops N` (default: **3**); `--loops 0` = skip critic. `--strict` → `max_loops=1`.

**External review** — always attempted in Phase 4. Checks `EXTERNAL_REVIEW_API_KEY` in env and `.env`; skips gracefully with a note if not configured.

**Execution gate** — resolve once, apply throughout:
- `max_loops=0` → critic loop skipped.
- `max_loops>0` → critic loop runs up to N times.

## Phase 0 — Resolve and track

Strip flags from args; run `bash .claude-agent-flow/scripts/resolve-task.sh "$args"`. Extract `task_id`, `plan_file_path`, `plan_context`, `task_status`.

Derive `progress_file` before any status change (from plan path, or by searching `plans/` for `task_id`). **Completion gate:** if `progress_file` exists and last non-blank entry is `end | ready-for-review`, ask via `AskUserQuestion` — "Pipeline already completed. Re-run from scratch or Stop?" Archive existing file on Re-run; halt on Stop.

**Set In Progress:** `backlog task edit <task_id> -s "In Progress"` then `git push -u origin $(git rev-parse --abbrev-ref HEAD)`.

Init `progress_file` when not set: derive path from task title and ID (`slug_body="task"` fallback), create with start entry. If exists (not ending `end | ready-for-review`): resume from last completed step.

**Phase 0 Gate — tick every item before proceeding to Phase 1:**
- [ ] `task_id` extracted (or noted as empty — skip tracking silently)
- [ ] Completion gate checked (existing progress file handled — archived or halted)
- [ ] Status set to In Progress and pushed
- [ ] `progress_file` initialized (or resumed from last completed step)

## Phase 1 — Implement

**TECHSTACK context:** If `TECHSTACK.md` exists at the project root, read it in full and use it as reference throughout implementation to stay consistent with the declared stack.

Read affected files (Glob before Read; ≤12 files). Implement the feature. For files expected to exceed 200 lines, write a skeleton with section placeholders first, then fill each section with sequential edits (each under 100 lines). Write tests for behavior worth proving — happy path plus the riskiest edge cases. Skip tests that only grep doc strings or assert bare file existence. See testing-rules skill. Run the full test suite.

Check satisfied ACs: `backlog task edit <task_id> --check-ac <N>` per AC, then push. Append: `$(date '+%Y-%m-%d %H:%M:%S') | build | done`.

**TECHSTACK update:** If any new technology, library, or framework was introduced that is not already in `TECHSTACK.md`, add it now and commit: `git add TECHSTACK.md && git commit -m "Update TECHSTACK.md: add <technology>" && git push -u origin $(git rev-parse --abbrev-ref HEAD)`.

**Phase 1 Gate — tick every item before proceeding to Phase 2:**
- [ ] All affected files read (Glob before Read; ≤12 files)
- [ ] Feature implemented
- [ ] Tests written (happy path + riskiest edge cases)
- [ ] Full test suite run and passing
- [ ] ACs checked (`--check-ac`) and pushed
- [ ] TECHSTACK.md updated if new technology introduced

## Phase 2 — Critic loop

**If `max_loops=0`:** Skip. Append `critic-loop | SKIPPED`. Go to Phase 3.

**If `max_loops>0`:** Spawn critic subagent (fresh context, `run_in_background=False` — critic is dependent on builder output). Pass diff only — never expose iteration count or loop position. On FAIL: fix flagged items only. Repeat until PASS or `max_loops` reached. Append: `$(date '+%Y-%m-%d %H:%M:%S') | critic-<N> | PASS/FAIL`.

**Phase 2 Gate — tick every item before proceeding to Phase 3:**
- [ ] `max_loops=0`: critic skipped, noted in progress file
- [ ] `max_loops>0`: critic ran until PASS or `max_loops` reached; each iteration logged in progress file

## Phase 3 — Verify

Run the full test suite. Report pass/fail/skipped counts. Append result.

**Phase 3 Gate — tick every item before proceeding to Phase 4:**
- [ ] Full test suite run
- [ ] Pass/fail/skipped counts reported and appended to progress file

## Phase 4 — Review and ship

**AC self-review:** Generate `git diff $(git merge-base HEAD origin/main 2>/dev/null || git merge-base HEAD origin/master 2>/dev/null || git rev-list --max-parents=0 HEAD)...HEAD`. For each AC and any "What it must NOT do" constraint from the plan/task, confirm it is satisfied. List any BLOCKERs (unsatisfied ACs, violated constraints) and WARNINGs (quality concerns). Fix BLOCKERs before proceeding.

**External review:** Always run if `EXTERNAL_REVIEW_API_KEY` is configured (checked in env and `.env`):

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
_BUILD_DIFF=$(mktemp /tmp/build-review-diff.XXXXXX)
git diff "$MERGE_BASE"...HEAD > "$_BUILD_DIFF"
RESULT=$(bash "$GIT_ROOT/.claude/skills/external-code-review/external-review.sh" \
  --diff-file "$_BUILD_DIFF" \
  --suppress-config "$GIT_ROOT/.claude-agent-flow/external-review-config.yml" \
  --suppress-config "$GIT_ROOT/external-review-config.repo.yml" \
  2>/tmp/build-review-err.txt) || true
```

If `EXTERNAL_REVIEW_API_KEY` is not configured: note `External review: Skipped — EXTERNAL_REVIEW_API_KEY not configured.` and continue. If script fails: note `External review: Skipped — script failed.` and continue. On FAIL: fix flagged items and run exactly one more pass (pass 2 of 2). After pass 2, append the verdict and proceed to commit regardless of outcome — do NOT loop again.

Update docs and CHANGELOG. Stage all files (NOT `.claude/settings.local.json*`). Commit. Stage `.scratch/evidence/`. Append: `$(date '+%Y-%m-%d %H:%M:%S') | commit | <sha>`.

If `task_id` set and NOT main/master: ToolSearch `"select:mcp__github__list_pull_requests,mcp__github__create_pull_request"`, `backlog task edit <task_id> -s "Ready for Review"` + push, append `end | ready-for-review`, create PR if none with title `TASK-ID - Task Title`.

Report: what was built, critic iterations, external review verdict, unresolved WARNINGs, test summary. Run `python3 .claude/skills/token-analyser/token-analyser` and paste the complete output verbatim into the report text as **rendered markdown** (tables, bold, headings — NOT wrapped in a fenced code block; the analyser already emits markdown and ``` would defeat the formatting). Do not summarise it as a single figure.

## Rules

- `backlog` CLI via Bash, double-quoted strings only. Push after every status change. Never auto-set tasks to Done. `task_id` empty → skip tracking silently.
- On block: `backlog task edit <task_id> -s "Blocked" --append-notes "Blocked: <reason>"`. Append `blocked | <reason>`.
- **Spawn rules:** zero subagent spawns except critic (Phase 2). No implicit spawning anywhere. If in doubt, don't spawn.
- **Parallelism rule:** `run_in_background=True` is allowed **only** when spawns are dependency-independent. A spawn is independent iff its inputs do not depend on another spawn's outputs from the same pipeline stage. Worked examples — dependent (must remain sequential): builder→critic, critic→builder-fix; independent (may parallelise): critic + external-review (same diff input, neither consumes the other). Default is sequential; parallelism is opt-in per invocation. No global auto-parallelise heuristic.
- **Mixed pipeline pattern:** launch independent spawns via `Agent(run_in_background=True)`; write a log marker to progress file immediately after each launch; both markers must appear before either result is consumed; dependent spawns follow sequentially after the wait point. Stall detection applies per-spawn — one stalling does not cancel siblings; partial completion is noted in the report.
- **Builder-edit order vs runtime parallelism:** the builder edits files sequentially (a build-time property). Runtime parallelism (spawning subagents via `run_in_background=True`) is orthogonal — do not conflate the two.
- `**Skills:**` directive in plan → invoke each skill before starting work.
