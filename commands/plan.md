---
name: plan
description: >
  Guide a collaborative planning session to refine an idea into a structured build
  brief. Conducts Socratic dialogue with the user via the brainstorming skill,
  leverages architect and researcher for design and technical validation, and
  saves the result as a plan file and backlog task that /build can consume.
---

**Skills:** agent-flow-init-check

$ARGUMENTS

If `$ARGUMENTS` is empty/whitespace, or contains `--help` as a standalone word, output the following verbatim and STOP:

    Usage: /plan <feature description> [--help]

    Plan a feature through collaborative refinement.

    Arguments:
      <feature description>   Free-text description of the feature to plan

    Flags:
      --help                  Show this help text and exit

    Pipeline: explorers + ideator (parallel) -> brainstorming -> architect -> save plan file -> create backlog task
    Output:   plans/YYYY-MM-DD-HHMM-<slug>.md + backlog task

If you output the help text above, stop here — do not read or execute anything below this line.

Plan the following feature through collaborative refinement:

## Instructions

This command runs an interactive planning process. All steps are sequential.

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

### Phase 1 — Context
1. Invoke **Explorer** (subagent_type="explorer") first, alone. Include the following in the explorer brief:
   - The feature being planned (for file/pattern mapping)
   - **Always** check whether `TECHSTACK.md` exists at the project root (via Glob) before invoking the explorer. If it exists and is **stale** (`last_scanned` >= 24 hours ago): read it and include its full content in the explorer brief so the explorer can perform an accurate staleness comparison (Case C). If it exists and is **fresh** (`last_scanned` < 24 hours ago): tell the explorer "TECHSTACK.md exists and is fresh" so it knows to run Case B (trust it, no discovery needed). If it does not exist: tell the explorer "TECHSTACK.md does not exist" so it knows to run Case A.
   - The explorer maps files, modules, reusable patterns, and conventions relevant to the feature, and runs the Technology Discovery Protocol, returning a `TECHSTACK DISCOVERY:` section if TECHSTACK.md is missing or stale.
1a. **TECHSTACK.md lifecycle** — Resolve this before launching the ideator. Use the Glob result from step 1 as the authoritative check.

    **If TECHSTACK.md is missing** (file does not exist):
    - The explorer MUST have returned a `TECHSTACK DISCOVERY:` section (Case A). Check which outcome:
      - **A2 — Greenfield:** The section contains the note `Greenfield: no stack detected`. Note this to the user: "No existing tech stack detected — the technology choices will emerge from brainstorming and design." Set `techstack_context` to empty and continue to step 1b. TECHSTACK.md will be created later when `/build` runs (its step 2a handles post-builder stack declaration) or via `/techstack-refresh`.
      - **A1 — Stack detected:** The section contains a full proposed TECHSTACK.md. Proceed to confirmation below.
    - If the explorer did NOT return a `TECHSTACK DISCOVERY:` section at all: this is an explorer protocol failure. Ask the user via `AskUserQuestion`: "Explorer did not return TECHSTACK data as required. Retry?" (options: Retry / Continue without stack context). If retry: re-invoke explorer with the same brief. If the second run also returns nothing, warn the user: "Explorer failed to return TECHSTACK data after two attempts. Continuing without stack context — run `/techstack-refresh` later to create it." Set `techstack_context` to empty and continue to step 1b.
    - **Confirmation:** Ask via `AskUserQuestion`: "TECHSTACK.md is missing. Confirm creating it with the proposed content?" (options: Confirm as-is / Review first / Skip for now).
    - If confirmed: invoke the author agent: "Write the following content verbatim to `TECHSTACK.md` at the project root: <paste full proposed content>". Commit: `git add TECHSTACK.md && git commit -m "Add TECHSTACK.md" && git push`.

    **If TECHSTACK.md is stale** (explorer returned a `TECHSTACK DISCOVERY:` section with changes):
    - Read the existing `TECHSTACK.md` in full. Apply these rules to each entry in the explorer's diff:
      - **Net-new entry** (DETECTED section/key has no exact match anywhere in the current file): before auto-adding, scan the full file for any semantically equivalent entry (same concept expressed differently, e.g. "Python 3" vs "Python"). If a semantic match is found, treat it as a **conflicting entry** instead. Only auto-add if no exact or semantic match exists anywhere in the file.
      - **Conflicting entry** (DETECTED value for a key that already exists — exactly or semantically — with a different value): ask via `AskUserQuestion` — show CURRENT vs DETECTED, let the user keep current, accept detected, or skip.
      - **Entry only in CURRENT** (exists in file but not mentioned in DETECTED): leave untouched, always. Never propose removal. It may be user-added or simply undetected — either way it is preserved.
    - If any changes were accepted: invoke the author agent to apply only the accepted changes. Commit: `git add TECHSTACK.md && git commit -m "Update TECHSTACK.md" && git push`.

    **If TECHSTACK.md is fresh** (exists and `last_scanned` < 24 hours ago — the orchestrator determines freshness from frontmatter, not from explorer output):
    - No action needed. Continue.

1b. **TECHSTACK context load** — Read `TECHSTACK.md` (the confirmed, up-to-date version from step 1a) in full and store its content as `techstack_context`. Include this content verbatim in the brief for **every agent invoked for the remainder of this pipeline** — ideator, architect, and researcher. Prefix it with the heading `## Project Tech Stack (from TECHSTACK.md)` so agents can find it immediately. If TECHSTACK.md does not exist (user skipped creation in step 1a), set `techstack_context` to empty and omit the section from briefs.
1c. Invoke **Ideator** (subagent_type="ideator"): generate 3-5 meaningfully different approaches to the feature.
2. Present a 2-3 line summary of what exists and what will be affected
3. Present the ideator's approaches as starting material for brainstorming

### Phase 2 — Refinement
4. Call `Skill` with the name `brainstorming`. Conduct an interactive Socratic
   refinement session, seeded with the ideator's approaches as starting material.
   The brainstorming skill handles: one question at a time, multiple-choice where possible,
   exploring 2-3 approaches, and incremental validation.
   **NOTE: Use the brainstorming skill for dialogue only.** Skip steps 6-9 of
   the brainstorming checklist (write design doc, spec self-review, user reviews spec,
   invoke writing-plans). Do NOT create a spec document in docs/superpowers/specs/.
   The /plan command owns all output: Phase 3 sends the design to the architect,
   Phase 4 saves the plan file to `plans/`. Exit the brainstorming skill after
   step 5 (present design sections, get user approval on the design).
   Continue until the brainstorming skill reaches a fully-formed design with clear answers to:
   - What must it do?
   - What must it NOT do or break?
   - What does "done" look like (specific, testable)?
5. After brainstorming reaches a fully-formed design, ask the user for task priority:
   "What priority should this task have? (high / medium / low)"
   Store the answer as `task_priority` for use in Phase 4.
6. Scan the available skills list and infer any skills relevant to the deliverable type.
   Present your suggestions with a one-line rationale each, for example:
   > "Based on what we're building, I'd suggest:
   > - `frontend-design` — polished HTML/CSS output
   > - `brand-guidelines` — Anthropic brand styling
   > Confirm all, drop any, or add others?"
   Collect the confirmed set as `confirmed_skills` (may be empty).

### Phase 2a — Subject Matter Research
6a. If the feature involves domain-specific content (product analysis, market data, industry
    topics, real-world facts), invoke a **Researcher** agent (subagent_type="researcher")
    to verify the subject matter via WebSearch BEFORE invoking the architect. The researcher must:
    - Confirm key facts: launch dates, current status, pricing, clinical data, market share
    - Verify the user's specific framing (e.g. "Wegovy pill" = oral formulation, not the injection)
    - Return a structured summary of verified facts to feed into the architect's brief
    Training data may be months or years out of date. Never build a content page on assumptions
    when a web search can confirm the facts in seconds.

### Phase 3 — Design
7. Invoke architect with the full refined requirements, `confirmed_skills`, AND any subject
   matter research from Phase 2a.
   If `confirmed_skills` is non-empty, instruct architect to include a `**Skills:**`
   directive verbatim in its design brief output.
   **IMPORTANT:** Explicitly instruct the architect to run its mandatory research validation
   (step 2 in its agent definition) — verify all external libraries, frameworks, GitHub Actions,
   and tools are still current, actively maintained, and the recommended approach. The architect
   must include a "Research Validation" section in its output listing each tool checked.
   Libraries can be deprecated, migrated, or superseded — never assume training data is current.
8. Wait for architect's design brief. Verify it contains a "Research Validation" section.
   If missing, send the architect a follow-up message requesting it validate all external
   dependencies against current web sources before proceeding.
8a. **TECHSTACK.md awareness** — If architect's design introduces new technologies not listed in `TECHSTACK.md`, note them in a `NEW TECHNOLOGIES:` subsection of the architect's completion notes. These will be added to TECHSTACK.md after the build completes (handled by `/build` step 2a).

### Phase 4 — Save
9. Create the plans/ directory at the project root if it does not exist
10. Save the plan as plans/YYYY-MM-DD-HHMM-<slug>.md where:
   - YYYY-MM-DD is today's date
   - HHMM is the current 24-hour time in the Europe/Berlin timezone (CET/CEST) — obtain via `TZ=Europe/Berlin date +%H%M` in Bash
   - slug is a 3-4 word kebab-case summary (e.g. chat-message-history)
11. Plan file format:

   # Feature: [Title]

   ## What it must do
   [Functional requirements from the refinement session]

   ## What it must NOT do
   [Constraints and non-goals]

   ## Acceptance criteria
   [Specific, testable outcomes — what "done" looks like]

   ## Technical approach
   [From architect — chosen approach, files to change, dependencies, risks,
    execution order for builder agents]
   **Skills:** [comma-separated list of confirmed skills, or omit this line if none]

   ## Edge cases
   [Known edge cases to handle]

12. Completeness audit: Re-read the plan file and audit it against the full conversation.
    Check for: decisions made but not captured, field-level detail missing (DoD items, label
    rules, standalone readability), constraints discussed but not written down.
    Patch any gaps into the plan file before proceeding. The task created next must be a
    complete dehydration of the plan — a builder reading only the task has identical
    information to one reading the plan file.

    Commit and push the plan file:
    ```
    git add plans/<filename>.md && git commit -m "Add plan: <title>" && git push -u origin $(git rev-parse --abbrev-ref HEAD)
    ```

13. Search for duplicate tasks before creating: run `backlog search "<title keywords>"` via Bash.
    If a matching task exists, extract its task ID from the search output and store as `task_id`, then skip to step 16 (bidirectional link update). Do not create a new task. A task matches only if its title closely matches the plan title AND it references the same plan file path (or is clearly the same feature). If uncertain, create a new task rather than reusing an unrelated one.

14. Create the backlog task. **Verbatim, not summarised** — copy each plan section as-is
    into the corresponding field. Use regular double-quoted strings only — no ANSI-C quoting.
    If content exceeds 2000 chars, you may truncate — but only after including: exact wording,
    before/after examples, execution order, and all named constraints. Append "See plan file: <path>" after any truncation.

    | Plan section | Task field | Rule |
    |---|---|---|
    | `# Feature: <title>` | title | Extracted heading |
    | `## What it must do` + `## What it must NOT do` | `-d` | Both sections verbatim, each with its heading (e.g. `## What it must do\n...\n## What it must NOT do\n...`). Never omit either section. |
    | Each `- [ ] item` in `## Acceptance criteria` | `--ac` (one flag per item) | Never combine into one string |

    > Note: use one `--ac` flag per acceptance criterion — never comma-separate multiple items into a single flag.

    | N/A (standard set) | `--dod` | Standard DoD items: tests pass, critic PASS, reviewer approved, docs updated. Always include these. |
    | `## Technical approach` | `--plan` | Full section verbatim |
    | `## Edge cases` | `--notes` | Full section verbatim, prefix with "Edge Cases:" |
    | `**Skills:**` line | append to `--notes` | If present, append after edge cases |
    | `task_priority` from Phase 2 | `--priority` | high / medium / low |
    | Inferred labels | `-l` | UI/styling/components → frontend, API/server → backend, schema/DB → storage, docs → docs; always add feature unless clearly refactor/bugfix; max 3 |
    | Plan file path | `--ref` | Bidirectional link |

    Example command shape (adapt content from plan):
    ```
    backlog task create "Title" -d "Description" --ac "AC item 1" --ac "AC item 2" --dod "Tests pass" --dod "Critic PASS" --dod "Reviewer approved" --dod "Docs updated" --plan "Technical approach text" --notes "Edge Cases: ..." --priority medium -l feature,backend --ref "plans/YYYY-MM-DD-HHMM-chat-message-history.md"
    ```
    Push: `git push -u origin $(git rev-parse --abbrev-ref HEAD)` (This push covers the task creation. The next push in step 16 covers the plan file bidirectional link update — two pushes for two operations.)

15. Parse the task ID from the `backlog task create` stdout (e.g. "Created task TASK-37"). Store as `task_id`.
    If parsing fails, warn the user ("Could not parse task ID from output — add manually") and
    continue without the bidirectional link.

15a. **Task fidelity audit** — Run `backlog task view <task_id>` and compare each field against the plan file:
    - Description contains both `## What it must do` and `## What it must NOT do` sections
    - Each acceptance criterion is present as a separate item
    - Implementation plan (`--plan`) matches the `## Technical approach` section verbatim (no paraphrasing, no missing sub-sections)
    - Notes contain the full `## Edge cases` content

    If any field is missing content or was paraphrased, patch it immediately with `backlog task edit <task_id> --<field> "..."` and push before continuing.

16. If `task_id` is non-empty: Update the plan file to add `## Backlog Task: <task_id>` (substituting the actual task ID, e.g. `## Backlog Task: TASK-37`) as a header immediately after the `# Feature:` heading line.
    Then commit and push:
    ```
    git add plans/<filename>.md && git commit -m "Link plan to <task_id>" && git push -u origin $(git rev-parse --abbrev-ref HEAD)
    ```

### Phase 5 — Hand off
17. **Token cost summary:** Run the token analyser CLI (basic mode, no `--breakdown` or `--models`) and display the summary table:
    ```bash
    python3 .claude/skills/token-analyser/token-analyser
    ```
    Display only the first output block (summary table with model, health, calls, duration, tokens, cost). Do not include the call breakdown, model breakdown, or savings sections — keep the report concise.

18. Use the `AskUserQuestion` tool to present exactly three options:

   Question: If `task_id` is non-empty: "Plan saved: `plans/<filename>.md` (Task: <task_id>) — What would you like to do next?" Otherwise: "Plan saved: `plans/<filename>.md` — What would you like to do next?"
   - Option 1 label: "Build it now" — description: "Run /build @plans/<filename>.md immediately"
   - Option 2 label: "Stop and build in new session" — description: "Stop here; run /build @plans/<filename>.md in a fresh session for clean context"
   - Option 3 label: "Save and stop" — description: "Keep the plan for later"

19. On option 1: immediately invoke the build pipeline using the saved plan as the brief,
    proceeding without pausing for individual confirmations (treat as auto-accepted).
    When invoking the build pipeline, include this instruction in the brief: "Treat the plan file as the sole source of truth. Disregard any prior session context — the plan contains everything you need."
    On option 2: stop. Display: "Run `/build @plans/<filename>.md` in a fresh session for clean context." If `task_id` is non-empty, also show the task ID.
    On option 3: stop. Show the plan file path and task ID (if available) for reference.

## Rules
- One question at a time during refinement
- Always use the `AskUserQuestion` tool for discrete-option questions (multiple choice, yes/no, A/B/C) — never plain text. This applies throughout all phases including design approvals and skill confirmations during brainstorming.
- The plan file IS the /build brief — write it so /build has everything
- Verbatim field mapping (step 14) — never summarise plan sections
- `backlog` CLI via Bash, double-quoted strings only. Hooks auto-push after backlog ops.
- Never auto-set tasks to Done

### Skill collision rules
- `brainstorming`: dialogue only — skip its spec save and writing-plans steps; /plan owns those
- `backlog-md`: reference only — /plan owns control flow
- `backlog-tpm`: never invoked
