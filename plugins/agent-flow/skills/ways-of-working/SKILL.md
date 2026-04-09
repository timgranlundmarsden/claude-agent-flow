---
name: ways-of-working
description: >
  Agent team best practices — philosophy, routing, execution model,
  adversarial loop, cost management, failure modes, and brief writing.
---

# Agent Flow — Ways of Working

## Team Philosophy

1. **Focused context beats broad context.** Narrow agent scope = better reasoning.
2. **Delegate early, not late.** Architect before builder is cheaper than rework.
3. **Clarity over speed.** Vague brief → vague code. The brief is the bottleneck.
4. **Always use the `AskUserQuestion` tool for discrete options** (multiple choice, yes/no, A/B/C) — never plain text. This includes design approvals, skill confirmations, and any question where the answer set is bounded.
5. **Orchestrator never fixes code.** When critic, reviewer, or tester finds issues, route them back to the relevant builder agent. The orchestrator passes the issue list — the builder applies the fix. No exceptions, even for "simple" fixes.

---

## Execution Model: Sequential by Default

All agents run **sequentially** — one at a time, dependency order. Standard full sequence:

```
explorer → architect → storage (if schema) → backend → frontend → tester → critic loop (if /build) → reviewer → author
```

Adjust order by dependencies. Architect dispatches researcher internally if needed.

### Foreground-only rule

Never use `run_in_background: true` in a sequential pipeline. Foreground catches stalls immediately.

**Stall detection:** Builder agents (frontend, backend, storage) stalling 5+ minutes with no file writes
or `[MILESTONE]` markers → cancel and retry with incremental writing pattern. Non-builder agents: any
tool call or text output counts as activity.

---

## Two Operational Modes

### Full Pipeline (`/build`)
Use when correctness matters more than speed: security-critical paths, public APIs,
data migrations, anything hard to roll back. Runs the complete sequence with adversarial critic loop.

### Lite Mode (default)
Use for everyday work: bug fixes, small features, single-file changes, prototypes, docs.
Runs: explorer → builder → reviewer. Builder covers basic tests and docs inline.
Ask: "Could one agent handle this cleanly?" If yes, lite mode.

---

## Agent Routing Rules

Key sequencing constraints (see agent files for full domain details):
- **Orchestrator:** Multi-domain only. Never writes code — delegates only.
- **Architect:** Before features touching 3+ files or new patterns. Dispatches researcher internally.
- **Storage → Backend:** Storage MUST complete before backend starts when schema changes. Storage owns all RLS policies.
- **Frontend / Backend:** Typically backend first (API exists), then frontend. Reverse if no dependency.
- **Researcher:** Before the build starts, not during.
- **Tester:** After all builders. Never skip on `/build`. Canonical BATS command: `.claude-agent-flow/tests/lib/bats-core/bin/bats --jobs 8 .claude-agent-flow/tests/*.bats`
- **Reviewer:** After ALL builders and tester. Once only.
- **Critic:** Only via `/build` or `/review`. Reviews diff only, not full codebase.
- **Explorer:** Before every non-trivial task. Cheap on haiku — use constantly.
- **Author:** Last, after reviewer sign-off. Never mid-feature.

---

## The Adversarial Review Loop

```
builder → critic (FAIL) → builder fixes diff only → critic (FAIL) → ... → critic (PASS) → tester → reviewer → author
```

Key rules:
- Builder fixes ONLY flagged issues — no bonus refactoring
- Critic reviews ONLY the new diff — not the whole codebase
- Hard limit: 3 iterations (default), `--loops N` to override. Persistent failure = design problem, not code.
- **Critic integrity:** The critic is NEVER told which iteration it is on or how many remain. The orchestrator tracks iterations internally. The critic's verdict must be based solely on code quality.

### Writing a good /build brief
Include: what it must do, what it must NOT do, known edge cases, acceptance criteria.

Bad: "build the login endpoint"
Good: "build the login endpoint — email + password, returns JWT, rate-limit 5/min/IP,
must not expose whether email exists, log failed attempts to audit table"

---

## Cost Management

### Model tiers (aspirational)

The `model:` field in agent frontmatter is not yet respected at runtime. All subagents
inherit the parent model. Values document intended tiers for when per-agent routing ships.

- **opus:** orchestrator, architect, ideator, critic — expensive, use rarely
- **sonnet:** frontend, backend, storage, researcher, tester, reviewer — workhorse
- **haiku:** explorer, author — cheap, use constantly

### When to use subagents
Subagents multiply tokens 4-7x. Justified when focused context beats one bloated session.
NOT justified for single-file tasks or simple bug fixes. Default to lite mode; escalate when needed.

### Token Efficiency Rules (mandatory)

1. **Output brevity:** Completion reports under 30 lines (explorer/author/tester: 20). Structured, not prose.
2. **No redundant reading:** Never include file contents in output. Downstream agents read files themselves.
3. **Minimal briefing:** Orchestrator briefs under 15 lines. Pass scope, file paths, contracts, constraints only.
4. **Diff-only reviews:** Critic/reviewer review the diff only — never re-read full codebase each pass.
5. **No preamble:** Start with structured output immediately.

### Agent Roster

| Agent | Model | Role |
|---|---|---|
| orchestrator | opus | Routes and sequences — never writes code |
| architect | opus | Design decisions — may dispatch researcher |
| ideator | opus | Lateral thinking — output to human only |
| critic | opus | Adversarial review — tries to break code |
| frontend | sonnet | UI, React, TypeScript, Tailwind |
| backend | sonnet | API, DB queries, auth, Supabase, n8n |
| storage | sonnet | All persistence — sole RLS owner |
| researcher | sonnet | Web research, docs, library investigation |
| tester | sonnet | Tests — write, verify, visual checks |
| reviewer | sonnet | Code review — read only |
| explorer | haiku | Codebase navigation — read only, cheap |
| author | haiku | Docs and changelog — last step only |

---

## Common Failure Modes

| Failure | Symptom | Fix |
|---|---|---|
| Orchestrator implements | Editing files directly | Remind: "delegate only — never edit files" |
| Orchestrator applies fixes | Fixing critic/reviewer issues directly instead of routing to builder | Always pass issue list to the relevant builder agent — even for "trivial" fixes |
| Critic loop won't converge | New issues each iteration | Stop loop → architect with FAIL report → redesign |
| Builder off-pattern | Inconsistent files/patterns | Always run explorer before builders on multi-file tasks |
| Researcher mid-build | Build pauses for research | Invoke researcher before build, not during |
| Storage/backend out of sync | Backend queries missing columns | Storage must complete before backend starts |
| Agent stalls on large output | No writes/milestones for 5+ min | Use incremental writing pattern (skeleton + Edit calls) |

### Incremental Writing Pattern

For files >200 lines, builders MUST use skeleton-first:

1. **Write skeleton** (30-80 lines) with `TODO` placeholders per section
2. **Fill via Edit** — sequential calls, each under 100 lines
3. **Never write >200 lines** in a single Write or Edit call

Placeholder styles: HTML `<!-- TODO -->`, JS/TS `// TODO`, JSX `{/* TODO */}`,
Python `# TODO`, SQL `-- TODO`, CSS `/* TODO */`

Output `[MILESTONE]` markers after each section. Mandatory for all builder agents.

### Brief Optimization

Orchestrator MUST inline reference material (CSS tokens, patterns, contracts, schemas) in builder briefs.
Include directive: "Do NOT read additional files for context. All reference material is provided below."
Target: 0-2 file reads by builder (CLAUDE.md and agent file don't count).

### Progress Reporting

Builders MUST output `[MILESTONE]` markers: `skeleton written`, `section N/M complete`, `file complete`.
Orchestrator checks every 3 min. Builder stall (5 min, no writes/markers) → cancel and retry with skeleton+edit.
Non-builder agents: any tool call or text output = activity.

---

## Visual Layout Verification

After any CSS or layout fix, agents MUST run `visual-check.sh` before marking done.
See `playwright-cli-helpers` skill for full usage, evidence capture, and troubleshooting.

Agents with visual responsibility: frontend, tester, critic, reviewer (flags missing checks).
UI skills required in agent frontmatter: `playwright-cli`, `playwright-cli-helpers`.

---

## Writing Good Agent Briefs

Every brief must answer four questions:
1. **Scope** — which files, domains, systems
2. **Constraints** — what must not change or break
3. **Done condition** — specific, testable outcome
4. **Known unknowns** — edge cases, risks, dependencies to investigate

---

## Quick Reference

```
Task type                         → Route
─────────────────────────────────────────────────────
Single-file / small fix           → lite (just ask naturally)
Multi-file feature, hard to undo  → /build <brief>
Feature planning                  → /plan <idea>
Harden existing code              → /review <files>
Codebase question                 → explorer
Design decision                   → architect
Stuck on approach                 → ideator
Library/API research              → researcher
Schema/storage only               → storage
API/server only                   → backend
UI/component only                 → frontend
Full feature (schema+API+UI)      → orchestrator
```

Decision rule: "Could this break something across multiple systems?" Yes → `/build`. Otherwise → lite.
