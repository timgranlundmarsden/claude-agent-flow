---
name: help
description: Show comprehensive help guide for the agent team system
---

# /help

Output the following verbatim:

## Agent Flow — Quick-Start Help Guide

Run `/help` any time to see this guide.

---

### Commands

| Command | What it does |
|---------|--------------|
| `/plan <idea>` | Guided planning — brainstorm, architect, and save a structured plan |
| `/plan --help` | Show usage for /plan |
| `/build <plan>` | Full quality pipeline — architect, build, critic loop, test, review |
| `/build @plans/file.md` | Build from a saved plan file |
| `/build TASK-54` | Build from a backlog task |
| `/build <plan> --loops 5` | Build with up to 5 adversarial critic iterations (default: 3) |
| `/build --help` | Show usage for /build |
| `/review` | Review all changes on the current branch vs main |
| `/review --loops 3` | Run up to 3 adversarial critic iterations (default: 1, max: 5) |
| `/review TASK-42` | Review changes linked to a specific backlog task |
| `/review @plans/file.md` | Review using a plan file for context |
| `/review --help` | Show usage for /review |
| `/explore <topic>` | Quick read-only codebase exploration — no changes made |
| `/rebase` | Guided rebase onto latest remote changes |
| `/rebase main` | Rebase onto a specific branch |
| `/backlog-list` | View all tracked backlog tasks |
| `/install` | Install or update the agent team system |
| `/token-analyser` | Analyse Claude Code session token costs |
| `/diagnostic` | Check health of agent-flow installation |
| `/help` | Show this help guide |

Or just ask naturally — "Fix the login bug" or "Add a dark mode toggle" works too.

---

### Agents

The team has 12 specialist agents. You don't invoke them directly — the system
routes work to the right agent automatically based on the command you use.

| Agent | Role | When it's used |
|-------|------|----------------|
| orchestrator | Breaks work into subtasks, delegates to specialists | Multi-domain tasks via `/build` |
| architect | Designs feature architecture (read-only) | Features touching 3+ files or new patterns |
| explorer | Maps files, patterns, and dependencies (read-only) | Before every non-trivial task |
| frontend | UI, React, TypeScript, Tailwind, a11y | UI/component work |
| backend | API routes, business logic, DB queries, auth | Server-side work |
| storage | Databases, RLS policies, migrations | Schema/persistence changes |
| tester | Writes and runs tests | After all builders complete |
| reviewer | Reviews for security, correctness, performance | Final quality check |
| critic | Adversarial — tries to break code with edge cases | `/build` and `/review` loops |
| author | README, CHANGELOG, docstrings | Last step after reviewer sign-off |
| researcher | Web search for docs, best practices, comparisons | Before builds when research needed |
| ideator | Lateral thinking, creative solution exploration | When you're stuck on approach |

---

### Two Modes of Working

**Lite mode (default)** — Just ask naturally.
Pipeline: explorer → builder → reviewer.
Use for: bug fixes, small features, single-file changes, prototypes, docs.

**Full pipeline (`/build`)** — Quality-critical work.
Pipeline: explorer → architect → builder(s) → critic loop → tester → reviewer → author.
Use for: security-critical paths, public APIs, data migrations, multi-file features.

**Decision rule:** "Could this break something across multiple systems?" Yes → `/build`. Otherwise → just ask.

---

### Quick Reference — What to Use When

```
Task type                         → What to do
─────────────────────────────────────────────────────
Single-file fix or small change   → Just ask naturally (lite mode)
Multi-file feature                → /build <plan>
Plan before building              → /plan <idea>, then /build @plans/file.md
Build from a backlog task         → /build TASK-54
Harden existing code              → /review (or /review --loops 3)
Explore unfamiliar code           → /explore <topic>
Stuck on approach                 → Ask for ideation help
Need library/API research         → Ask for research help
Rebase onto latest changes        → /rebase
View backlog tasks                → /backlog-list
```

---

### How Sync Works

If this repo is connected to an agent-flow source, changes sync via PRs:

- **Downstream (source → here):** When managed files change in the source,
  a PR arrives with updates. One PR per repo, updated in-place.

- **Upstream (here → source):** When you improve agents, commands, or skills
  and push to main, a PR is created in the source proposing your changes.

- **No ping-pong:** Commit trailers prevent infinite loops.

- **Opt out of upstream:** Set repo variable `AGENT_FLOW_UPSTREAM_SYNC_ENABLED=false`.

- **Update manually:** Run `/install` to pull the latest system files.

---

### Backlog & Task Management

Tasks are tracked via Backlog.md. Key rules:
- Tasks auto-push after every operation (hooks handle this)
- Search before creating to avoid duplicates
- Status flow: To Do → In Progress → Blocked → Ready for Review → Done
- Use `/backlog-list` to see all tasks

---

### Troubleshooting

| Problem | Solution |
|---------|----------|
| Agent seems stuck | Agents stall after 5 min with no output → cancel and retry |
| Critic loop won't converge | After 3 iterations, it's a design problem — re-architect |
| Missing tools (backlog, playwright, mergiraf) | Session-start hook installs them automatically — restart session |
| Want to update agent team files | Run `/install` |
| Changes not syncing upstream | Check `AGENT_FLOW_UPSTREAM_SYNC_ENABLED` repo variable |
| Too many sync PRs | PRs are reused per branch — only one open at a time per direction |
