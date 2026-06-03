---
name: ways-of-working
description: >
  Agent team best practices — philosophy, routing, execution model,
  adversarial loop, cost management, failure modes, and brief writing.
---

# Agent Flow — Ways of Working

## Team Philosophy

1. **Parent implements directly.** Default tier: zero subagent spawns. The parent (Claude) reads, plans, codes, tests, and documents end-to-end without routing to builder agents.
2. **Focused context beats broad context.** Narrow agent scope = better reasoning.
3. **Clarity over speed.** Vague brief → vague code. The brief is the bottleneck.
4. **Always use `AskUserQuestion` for discrete options** (multiple choice, yes/no, A/B/C) — never plain text.

---

## Execution Model: Parent-Direct (Default)

The parent runs end-to-end. Subagents are used sparingly for specific roles only:

| When | Spawn | Mode |
|---|---|---|
| `/plan`: repo >100 files AND entry points not read | `explorer` (read-only, ≤20 tool calls) | parallel if researcher also spawns |
| `/plan`: domain-specific facts needed | `researcher` (web search) | parallel if explorer also spawns |
| `/plan`: new external dep flagged | `researcher` (dependency validation) | parallel if explorer also spawns |
| `/build --strict` or `--loops N>0` | `critic` (adversarial review, once per loop) | sequential (depends on builder output) |
| `/review --strict` or `--loops N>0` | `critic` (adversarial review, once per loop) | parallel with external-review if both enabled |

**Never spawn subagents outside these rules.** Default tier (`/build`, `/review`) = zero spawns. `/plan` default tier may spawn explorer and/or researcher per the rules above.

### Parallelism Rule

`run_in_background=True` is allowed **only** for independent spawns. **A spawn is independent iff its inputs do not depend on another spawn's outputs from the same pipeline stage.**

- **Independent pairs (may parallelise):** `explorer` + `researcher` in `/plan`; `critic` + `external-review` in `/build --strict` or `/review --strict` (both consume the same diff).
- **Dependent pairs (must remain sequential):** builder → critic (critic consumes builder's diff); critic → builder-fix (builder-fix consumes critic's FAIL list); tester → builder-fix.
- Default is sequential. Parallelism is opt-in per invocation. No global auto-parallelise heuristic. If in doubt, run sequentially.

### Mixed Pipeline Pattern

When combining independent and dependent spawns in one pipeline:

```
# 1. Launch independent spawns in background
Agent(subagent_type="A", run_in_background=True, ...)  # write log marker immediately
Agent(subagent_type="B", run_in_background=True, ...)  # write log marker immediately
# Both markers must appear in progress before either result is consumed.

# 2. Wait point — parent blocks until both report complete
# Stall detection applies per-spawn: A stalling does not cancel B. Partial completion allowed.

# 3. Dependent spawn runs sequentially, consuming A and B outputs
Agent(subagent_type="C", run_in_background=False, ...)
```

### Stall Detection

A subagent producing no output for its configured stall threshold triggers a cancel-and-retry. This applies identically to foreground (`run_in_background=False`) and background (`run_in_background=True`) spawns — same threshold, cancelled the same way, parent notified the same way. Parallel fan-out does not disable stall checks.

### Agent Roster

| Agent | Model | Role |
|---|---|---|
| critic | opus | Adversarial review — tries to break code |
| researcher | sonnet | Web research, docs, library investigation |
| explorer | haiku | Codebase navigation — read only, cheap |

---

## Two Operational Modes

### Full Pipeline (`/build`)
Use when correctness matters more than speed: security-critical paths, public APIs, data migrations. Full sequence: implement → critic loop → test → review → commit.

### Lite Mode (default)
Use for everyday work: bug fixes, small features, single-file changes. Parent handles everything inline. No subagents unless using `--strict`.

---

## The Adversarial Review Loop

```
parent builds → critic (FAIL) → parent fixes diff only → critic → ... → critic (PASS) → commit
```

Key rules:
- Parent fixes ONLY flagged issues — no bonus refactoring
- Critic reviews ONLY the new diff — not the whole codebase
- Hard limit: 3 iterations (default), `--loops N` to override
- **Critic integrity:** The critic is NEVER told which iteration it is on or how many remain. Verdict based solely on code quality.

---

## Cost Management

### When to spawn subagents
Subagents multiply tokens 4-7x. Justified when focused context beats one bloated session. NOT justified for single-file tasks or simple bug fixes. Default to lite mode; escalate with `--strict`.

### Token Efficiency Rules

1. **Output brevity:** Completion reports under 30 lines. Structured, not prose.
2. **No redundant reading:** Never include file contents in output. Downstream agents read files themselves.
3. **Diff-only reviews:** Critic reviews the diff only — never re-reads the full codebase.
4. **No preamble:** Start with structured output immediately.

---

## Agent Routing Rules

- **Explorer:** Invoke before every non-trivial task. Cheap — use constantly. Read-only; never edits.
- **Researcher:** Before the build starts, not during. Use for external library docs, current best practices.
- **Critic:** Only via `/build` or `/review`. Reviews diff only. Passes ONLY when no failure scenario found.

---

## Common Failure Modes

| Failure | Symptom | Fix |
|---|---|---|
| Parent applies fixes mid-critic-loop | Bonus refactoring beyond flagged items | Fix only what critic flagged — nothing more |
| Critic loop won't converge | New issues each iteration | Stop → redesign approach |
| Explorer over-reads | Context bloat | Cap explorer at 20 tool calls; output paths only |
| Researcher mid-build | Build pauses for research | Invoke researcher before build, not during |

---

## Writing Good Briefs

Every brief must answer:
1. **Scope** — which files, domains, systems
2. **Constraints** — what must not change or break
3. **Done condition** — specific, testable outcome
4. **Known unknowns** — edge cases, risks, dependencies

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
Library/API research              → researcher
```

Decision rule: "Could this break something across multiple systems?" Yes → `/build`. Otherwise → lite.
