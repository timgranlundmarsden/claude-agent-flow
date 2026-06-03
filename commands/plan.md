---
name: plan
description: >
  Guide a collaborative planning session. Conducts Socratic dialogue, spawns
  explorer on large repos and researcher on new deps; saves plan + backlog task.
---

**Skills:** agent-flow-init-check

$ARGUMENTS

If `$ARGUMENTS` is empty/whitespace or contains `--help`, output the following verbatim and STOP:

    Usage: /plan <feature description> [--help]
    Pipeline: [explorer on large repos] → brainstorming → [researcher on new deps] → save plan → backlog task
    Output:   plans/YYYY-MM-DD-HHMM-<slug>.md + backlog task

READ THIS FILE before executing. All steps sequential.

Derive a 3–4 word kebab-case slug from the feature description (e.g. "warp-finder-context-menu"). Then run — substituting `<slug>` with the derived slug:

```bash
CLAUDE_BRANCH_SLUG=<slug> bash .claude-agent-flow/scripts/ensure-feature-branch.sh || exit $?
```

## Phase 1 — Context

Check repo size: `git ls-files | wc -l`. **Spawn `explorer` subagent** iff repo has >100 files AND you have not already read the plan's target entry points; pass feature slug, TECHSTACK.md status, and instruction to map relevant files (≤10 files). Otherwise read relevant files directly (≤10 files).

If explorer will spawn here AND researcher will spawn in Phase 3, the two spawns are **independent** (neither consumes the other's output). Launch both in parallel via `Agent(run_in_background=True)`. Write a log marker immediately after each launch; both markers must appear before either result is consumed. Stall detection applies per-spawn independently — one stalling does not cancel the other.

Present a 2-3 line summary of what exists and what will be affected.

## Phase 2 — Refinement

Call `Skill` with `brainstorming`. Conduct interactive Socratic refinement. Use `AskUserQuestion` for every question asked — never plain text.

**NOTE: Use the brainstorming skill for dialogue only.** Skip steps 6–9 of the brainstorming checklist (write design doc, spec self-review, user reviews spec, invoke writing-plans). Do NOT create a spec document in `docs/superpowers/specs/`. Exit the brainstorming skill after step 5 (present design sections, get user approval on the design). `/plan` owns all output: Phase 4 saves the plan file to `plans/`.

Capture: What must it do? / What must it NOT do? / Done condition.

Ask: "What priority? (high / medium / low)" → `task_priority`. Scan skills; suggest relevant ones → `confirmed_skills`. If the feature involves domain-specific facts (market data, product status), invoke `researcher` subagent for verification before Phase 3.

**Phase 2 Gate — tick every item before proceeding to Phase 3:**
- [ ] Priority asked via `AskUserQuestion` → `task_priority` captured
- [ ] Skills scanned (`ls .claude/skills/`), relevant ones suggested, confirmed via `AskUserQuestion` → `confirmed_skills` captured
- [ ] Researcher invoked if domain-specific facts flagged (or explicitly noted as not applicable)

## Phase 3 — Design

**Spawn `researcher` subagent** iff the plan introduces a new external dependency — detected when the refined requirements contain the phrase "new external dep" or user/notes explicitly flag a new library/tool. Pass: dependency name + validation request. If explorer was already launched in Phase 1, researcher may run in parallel with it (see Phase 1 note).

Produce design inline: approach, alternatives, per-file analysis, ACs, edge cases. Include `**Skills:**` directive if `confirmed_skills` non-empty.

**Phase 3 Gate — tick every item before proceeding to Phase 3a:**
- [ ] Researcher spawned if new external dep flagged (or explicitly noted as not applicable)
- [ ] Design produced inline with approach, alternatives, per-file analysis, ACs, edge cases
- [ ] `**Skills:**` directive included if `confirmed_skills` non-empty

## Phase 3a — Plan External Review

Check whether external review is configured:

```bash
GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [[ -z "${EXTERNAL_REVIEW_API_KEY:-}" ]] && [[ -f "$GIT_ROOT/.env" ]]; then
  while IFS='=' read -r _k _v; do
    [[ "$_k" =~ ^EXTERNAL_REVIEW_[A-Za-z0-9_]+$ ]] || continue
    export "$_k"="$_v"
  done < <(grep -E '^EXTERNAL_REVIEW_[A-Za-z0-9_]+=' "$GIT_ROOT/.env")
fi
```

**If `EXTERNAL_REVIEW_API_KEY` is still unset:** note `Plan External Review: Skipped — EXTERNAL_REVIEW_API_KEY not configured.` in the design and proceed to Phase 4. Do not execute the steps below.

If the key is available:

1. Write the Phase 3 design to a temp file:
   ```bash
   PLAN_TMPDIR=$(mktemp -d)
   PLAN_TMP="$PLAN_TMPDIR/plan.md"
   # write design content into $PLAN_TMP via Bash heredoc
   ```
   If `mktemp` fails: note `Plan External Review: Skipped — mktemp failed.` and proceed to Phase 4.
2. Run the review:
   ```bash
   REVIEW_OUTPUT=$(bash "$GIT_ROOT/.claude/skills/external-code-review/external-review.sh" \
     --plan-mode \
     --diff-file "$PLAN_TMP" \
     --repo-name "$(basename "$GIT_ROOT")" 2>&1) || REVIEW_EXIT=$?
   REVIEW_EXIT="${REVIEW_EXIT:-0}"
   ```
   If `REVIEW_EXIT` is non-zero or `REVIEW_OUTPUT` is empty/not valid JSON: `rm -rf "$PLAN_TMPDIR"`, note `Plan External Review: Skipped — external-review.sh failed (<first 200 chars of output>).` and proceed to Phase 4. Otherwise `rm -rf "$PLAN_TMPDIR"` after confirming valid JSON.
3. Parse the JSON. Map severity: `error → CONCERN`, `warning → SUGGESTION`, `info → QUESTION`.
4. For each **CONCERN**: revise the design to address it, or explicitly reject with one-sentence rationale.
5. For each **SUGGESTION**: apply if it improves the design; otherwise note `Skipped: <reason>`.
6. For each **QUESTION**: resolve by adding an assumption or clarification; if unresolvable, note as an open question.
7. Update the Phase 3 design with accepted changes.
8. **Loop cap — at most two runs total.** If at least one CONCERN was accepted and substantially changed the design, re-run steps 1–7 once with the updated design. Do not run a third time.
9. Append a `## Plan External Review` section to the design. Format: one line per item — `[PASS N] [LABEL] <section> — <message ≤100 chars> → <disposition>`. Max 25 lines total. If PASS (no concerns), state that explicitly.

**Phase 3a Gate — tick every item before proceeding to Phase 4:**
- [ ] API key check bash snippet executed
- [ ] Either: review ran and `## Plan External Review` section appended to design, OR: "Plan External Review: Skipped — ..." note written in design

## Phase 4 — Save

Save as `plans/YYYY-MM-DD-HHMM-<slug>.md` (HHMM via `TZ=Europe/Berlin date +%H%M`; slug = 3-4 word kebab-case). Plan file format:

```
# Feature: [Title]
## What it must do
## What it must NOT do
## Acceptance criteria
## Technical approach
**Skills:** [confirmed_skills or omit]
## Edge cases
```

Completeness audit: re-read; patch missing decisions. Commit and push.

Search for duplicate task: `backlog task search "<title keywords>"` via Bash. If match: store `task_id`, skip to backlog-link step.

Otherwise create the backlog task — verbatim, not summarised — mapping each plan section as-is into its field:

| Plan section | Task field | Rule |
|---|---|---|
| `# Feature: <title>` | title | Extracted heading |
| `## What it must do` + `## What it must NOT do` | `-d` | Both sections verbatim with headings |
| Each `- [ ] item` in `## Acceptance criteria` | `--ac` | One `--ac` flag per item — never combined |
| N/A | `--dod` | Tests pass / Critic PASS / Reviewer approved / Docs updated |
| `## Technical approach` | `--plan` | Full section verbatim |
| `## Edge cases` | `--notes` | Prefix with "Edge Cases:" |
| `**Skills:**` line | append to `--notes` | After edge cases, if present |
| `task_priority` | `--priority` | high / medium / low |
| Labels | `-l` | UI/styling/components → frontend, API/server → backend, schema/DB → storage, docs → docs; always add `feature` unless clearly refactor/bugfix; max 3 |
| Plan file path | `--ref` | Bidirectional link |

Example command shape (adapt content from plan):

    backlog task create "Title" \
      -d "## What it must do\n...\n## What it must NOT do\n..." \
      --ac "AC item 1" --ac "AC item 2" \
      --dod "Tests pass" --dod "Critic PASS" --dod "Reviewer approved" --dod "Docs updated" \
      --plan "Technical approach text" \
      --notes "Edge Cases: ..." \
      --priority medium -l feature,backend \
      --ref "plans/YYYY-MM-DD-HHMM-<slug>.md"

Parse task ID from stdout (e.g. "Created task TASK-37"). Store as `task_id`. If parsing fails, warn the user ("Could not parse task ID — add manually") and continue without the bidirectional link.

Fidelity audit: run `backlog task view <task_id>`. Verify each field against the plan file:
- Description contains both `## What it must do` and `## What it must NOT do`
- Each AC is present as a separate item
- Plan field matches `## Technical approach` verbatim
- Notes contain full `## Edge cases` content

Patch any missing fields with `backlog task edit <task_id> --<field> "..."` before continuing.

Add `## Backlog Task: <task_id>` to plan file immediately after the `# Feature:` heading line. Commit and push (single push after task creation, fidelity audit, and bidirectional link are all complete).

**Phase 4 Gate — tick every item before proceeding to Phase 5:**
- [ ] Plan file saved with all required sections (`## What it must do`, `## What it must NOT do`, `## Acceptance criteria`, `## Technical approach`, `**Skills:**` line if applicable, `## Edge cases`)
- [ ] Completeness audit done (re-read and patched)
- [ ] Backlog task created with all fields mapped per the table above
- [ ] Fidelity audit passed (`backlog task view`) — all fields verified or patched
- [ ] `## Backlog Task: <task_id>` added to plan file
- [ ] Single commit + push done (plan file + task file together, after bidirectional link complete)

## Phase 5 — Hand off

Run `python3 .claude/skills/token-analyser/token-analyser` and output the first block verbatim to the user as **rendered markdown** (tables, bold, headings — NOT wrapped in a fenced code block). The analyser already emits markdown; pasting it inside ``` would defeat the formatting. Do not skip or summarise it.

`AskUserQuestion`: "Plan saved: `plans/<filename>.md` (Task: <task_id>) — What next?" Options: Build it now / Stop and build in new session / Save and stop.

## Rules

- One question at a time during refinement. Always use `AskUserQuestion` for ALL questions — not just discrete options. Never ask via plain text.
- The plan file IS the /build brief — write it so /build has everything.
- `backlog` CLI via Bash, double-quoted strings only. Never auto-set tasks to Done.
- `brainstorming`: dialogue only — /plan owns saving and task creation.
- **Parallelism rule:** `run_in_background=True` only for independent spawns. A spawn is independent iff its inputs do not depend on another spawn's outputs from the same pipeline stage. Explorer and researcher are the canonical independent pair in `/plan`. Default is sequential; parallelism is opt-in per invocation. No global auto-parallelise heuristic.
