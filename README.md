# Claude Agent Flow

A Claude Code plugin that brings a multi-agent development pipeline to your repository — adversarial review loops, 3 agents, 28 skills, and 14 slash commands.

**[Full documentation →](https://timgranlundmarsden.github.io/claude-agent-flow/)** · **[Jump to installation ↓](#installation)**

> **Note:** Install this into your existing project using the `install.sh` script: [Jump to installation ↓](#installation)
> For a fresh start or sandbox/workspace use, you can also clone this repo directly and open it in Claude Code — run `/install` once to initialise sync state.

![claude-agent-code.jpg](docs/img/claude-agent-code.jpg)

---

## Why use this framework/Claude Code plugin and why did I build it

I started this project because if I am honest I was a bit disappointed with the current crop of AI tooling. As amazing as their results often are, when the model says "I am done", it was always far from done. Maybe you asked for a mobile friendly web page and it turned out that the result wasnt in fact mobile friendly. Or maybe you asked it to fix some code and then on running the tests, you saw that it had made introduced another bug. Either way I was spending too much time hand holding and guiding the models.

I am a big Claude Code user and it supports so many great things so I thought why don't I try and build a workflow that would help me formulate my idea, research it for me, sanity check it and then build it for me all without my intervention. Obviously I would need to discuss with the AI what I wanted but once we had a good plan, I wanted my work to be turned into a "ticket" and then have the AI build it for me and not come back to me until it was "Done Done"!

But the big part was once it thought it was done, it would need to get the approval of multiple separate AI agents that would be very thorough and check it's work. "Works on mobile?", then prove it with screenshots! "Code looks good", then lets run all the tests. If anything breaks, send it back to the agent that did the work for correction. Only when the entire flow if complete and every agent is satisfied, is the job "Ready for Review"

Today it's 3 core agents, 28 skills, and a full CI/CD integration — built entirely by running itself. What began as a simple automation became a full on factory line capable of solving multiple tickets at once. When you couple it with Claude Code for Web you can literally have AI build your ideas whilst you are out and about. It gets rather addictive :-)

---

## The Philosophy

Two ideas drive everything in this project:

**Quality emerges from adversarial loops.** A dedicated adversary that actively tries to break the code finds what a reviewer never sees. The critic's job is not to approve — it is to fail the work. The loop runs unattended until nothing breaks, compressing days of real-team code review into minutes. This is how you catch race conditions, silent failures, and injection vectors that slip past conventional review.

**Specialisation beats generalism.** A single agent that must design, implement, test, and review the same work carries compounding bias. Separation of roles removes the tension between building and verifying. Specialised agents and skill-backed roles each own exactly one part of the problem — clean context, no role confusion. The Critic's sole mandate is to break the work; the Explorer maps without building; the Researcher validates without implementing.

The full reasoning behind these choices is on the [Why Agent Flow](https://timgranlundmarsden.github.io/claude-agent-flow/why-agent-flow.html) page.

---

## How It Works

You describe what you want. The pipeline handles the rest.

**`/plan`** — Socratic conversation that asks questions, explores approaches, produces a structured brief with acceptance criteria saved as a plan file in your repo.

**`/build`** — Takes a plan file and runs the full pipeline: Explorer maps codebase, the architect skill designs the approach, builders implement, then the adversarial Critic loop kicks in (Critic tries to break it, builder fixes, repeat until PASS), then the test suite runs, the review skill does a final pass, and the author skill updates docs. Runs unattended.

**`/review`** — For code you wrote yourself without using /build. Runs the adversarial critic loop to stress-test your diff before merging.

```
┌─────────────────────────────────┐
│           Explorer              │  ← real agent (Haiku)
│     Maps the codebase           │
└────────────────┬────────────────┘
                 ▼
┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─┐
│      Architect  [skill]         │  ← skill-backed role
│    Designs the approach         │
└ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─┘
                 ▼
┌─────────────────────────────────┐
│           Builders              │
│   Frontend / Backend / Storage  │
└────────────────┬────────────────┘
                 ▼
┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─┐
  Critic ←→ Builders (loop)         ← real agent (Opus)
  FAIL? Fix and resubmit.
  PASS? Move on.
└ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─┘
                 ▼
┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─┐
│       Tester  [skill]           │  ← skill-backed role
│    Runs full test suite         │
└ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─┘
                 ▼
┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─┐
│      Reviewer  [skill]          │  ← skill-backed role
│   Structured code review        │
└ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─┘
                 ▼
┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─┐
│       Author  [skill]           │  ← skill-backed role
│    Updates docs & changelog     │
└ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─┘

Solid border = real agent · Dashed border = skill-backed pipeline role
```

The whole thing runs unattended. You come back to a branch that's been built, challenged, fixed, tested, reviewed, and documented.

See the full [/build pipeline reference](https://timgranlundmarsden.github.io/claude-agent-flow/build-pipeline.html) for details on each phase.

---

## Works With Any Stack

Agent Flow is technology-agnostic. The same pipeline works whether your project is React, Vue, Angular, plain HTML, Python, Go, Rust, .NET, Ruby — or anything else.

**No assumptions.** Builder agents don't assume your test runner is `npm test` or your linter is ESLint. They read `TECHSTACK.md` — a file at your project root — to learn what your project actually uses.

**TECHSTACK.md** is auto-generated on first pipeline run. The explorer agent scans your codebase (CLAUDE.md, package files, config files, code patterns) and proposes a stack profile:

- Languages, frameworks, and runtimes
- Test runner command (the exact command your project uses)
- Linter and type checker
- Database engine
- CSS/styling approach
- Conventions and principles (including future intentions)

You can hand-edit TECHSTACK.md at any time. Manual edits are authoritative — the explorer will never overwrite your changes without asking. It also works as a "desire sheet": declare a technology you intend to use before you've written a line of it, and agents will follow your direction.

**Example:** A Python/FastAPI project with pytest gets agents that run `pytest` instead of `npm test`. A Go project gets agents that check `go test ./...`. A polyglot monorepo with TypeScript frontend and Rust backend gets both.

The plugin itself uses Bash, Python, BATS, and ShellCheck — no Node, no Python web framework. TECHSTACK.md was generated automatically on first run.

---

## What the Critic Catches

These are real findings from build sessions — each would have reached production without the adversarial loop:

- **Race condition** — Two auth tokens valid for overlapping windows; the critic constructed a concurrent session that could read stale permissions. The builder had only tested single-session.

- **Silent failure path** — An external API failure was caught and logged, but the calling function returned a success response. The critic traced the return value through three call stack frames to find the silent success.

- **Mobile layout broken** — Desktop looked correct, but the critic loaded the page at 375px and found the hero grid overflowed horizontally. The builder had only tested at 1280px.

- **Insecure code** — User input interpolated directly into a shell command without sanitisation. The critic flagged the injection vector and returned FAIL before the code ever ran.

- **Diverged from the plan** — The builder implemented a caching layer that wasn't in the spec. The critic compared implementation against the plan file and flagged the scope creep before it was merged.

---

## Quick Start

After installing, try this in your project:

**Plan something:**

```
/plan I want to add a user profile page with avatar upload
```

The pipeline will ask you questions, explore approaches, and produce a structured brief with acceptance criteria — saved as a plan file in your repo.

**Build it:**

```
/build @plans/2026-04-09-1430-user-profile-page.md
```

Sit back. Explorer maps your codebase, the architect skill designs the approach, builders implement, the Critic tries to break it, the test suite runs, and the review skill signs off. You come back to a branch ready for review.

**Review your own work:**

```
/review
```

If you've made changes yourself without using `/build`, run `/review` to get the adversarial critic loop to stress-test your diff before merging.

See the [Getting Started guide](https://timgranlundmarsden.github.io/claude-agent-flow/getting-started.html) for detailed walkthroughs.

---

## Installation

Run from inside your project's git repository:

```bash
curl -fsSL https://raw.githubusercontent.com/timgranlundmarsden/claude-agent-flow/main/install.sh | bash
```

This prompts you to choose a scope. To skip the prompt, pass `--scope` directly:

```bash
# Claude Code Plugin only (lightest)
curl -fsSL https://raw.githubusercontent.com/timgranlundmarsden/claude-agent-flow/main/install.sh | bash -s -- --scope plugin

# Claude Code Plugin + GitHub Actions
curl -fsSL https://raw.githubusercontent.com/timgranlundmarsden/claude-agent-flow/main/install.sh | bash -s -- --scope plugin+github

# Sandbox (fully self-contained)
curl -fsSL https://raw.githubusercontent.com/timgranlundmarsden/claude-agent-flow/main/install.sh | bash -s -- --scope sandbox
```

### Scopes

| Scope | What's included | Best for |
|-------|-----------------|----------|
| **plugin** | CLAUDE.md patch, settings.json, .gitattributes, .mcp.json, Backlog.md init | Teams managing their own CI/CD |
| **plugin+github** | Everything in plugin, plus automated AI code review on PRs and Telegram backlog notifications | GitHub Actions users |
| **sandbox** | Everything fully vendored into your repo — agents, commands, and skills live alongside your code with no external plugin dependency at runtime, so the full pipeline works inside sandboxed environments including Claude Code web (claude.ai/code) | Claude Code web or air-gapped environments |

### Prerequisites

**Platform support:**

| Platform | Support | Notes |
|----------|---------|-------|
| macOS (Intel & Apple Silicon) | ✓ Supported | |
| Linux — Ubuntu / Debian | ✓ Supported | |
| Linux — other distros | ⚠ Untested | Requires apt-get; dnf / yum / pacman not supported |
| Windows WSL2 — Ubuntu | ✓ Supported | Run as Ubuntu inside WSL2 |

> Windows users: Install [WSL2](https://learn.microsoft.com/en-us/windows/wsl/install) with Ubuntu, then run the installer from the Ubuntu terminal.

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI installed
- Git repository initialised in your project
- Node.js 18+ (for MCP servers and Backlog.md)

---

## Permissions & Unattended Use

agent-flow runs multi-agent pipelines that make many tool calls — reading files, running git commands, writing code, executing tests. By default, Claude Code asks for confirmation before each category of action. For interactive use that's fine; for unattended pipelines it becomes a wall of interruptions.

| Mode | When to use | Tradeoff |
|------|-------------|----------|
| Default + install overrides | Day-to-day local development | Pre-approves common operations; credential files and mass-delete always blocked |
| Bypass mode | Unattended local pipelines | No prompts at all; model acts without confirmation but respects denied permissions |
| Claude for web | Unattended use, any environment | Sandboxed — no filesystem or credential access but still respects denied permissions; safest option |

### Install-time overrides

When you run the installer, you're offered the option to install permission overrides. Accepting sets up two things:

- **Allow list** — pre-approves git commands, file editing, code search, and other operations the framework uses routinely, so they run without prompting
- **Deny list** (always applied, regardless of your choice) — blocks recursive deletes (`rm -rf`) and prevents reading credential files (`.env`, `~/.ssh`, `~/.aws`)

If you accepted overrides during install, most pipeline operations will run without interruption.

### Bypass mode

To run the pipeline completely unattended with no confirmation prompts, add `"defaultMode": "bypassPermissions"` to the `permissions` block in your project's `.claude/settings.json`:

```json
{
  "permissions": {
    "defaultMode": "bypassPermissions"
  }
}
```

If you already have a `permissions` block (from install-time overrides), add the `defaultMode` line inside the existing block alongside your allow and deny lists.

> **Caution:** Bypass mode removes all permission guardrails on your local machine. The deny rules installed at setup time are no longer enforced. Only enable this if you trust the pipeline, or if you're running in a sandbox where the blast radius is limited. Note: IDE extensions (VS Code, JetBrains) may not honour this setting — it is only reliably supported by the Claude Code CLI.

### Claude for web

The safest way to run agent-flow unattended is [Claude Code for web](https://claude.ai/code). Web sessions run in a sandboxed environment — the model cannot access your local filesystem, credentials, or system tools, so there's no meaningful blast radius.

Install with the `sandbox` scope to get the full pipeline working in this environment:

```bash
curl -fsSL https://raw.githubusercontent.com/timgranlundmarsden/claude-agent-flow/main/install.sh | bash -s -- --scope sandbox
```

---

## What You Get

### 3 Agents

| Agent | Role |
|-------|------|
| explorer | Read-only codebase navigator — maps files, dependencies, and patterns |
| critic | Adversarial code review — actively tries to break code; integrity-protected verdict |
| researcher | External research — live documentation lookup and library comparison |

### Domain Skills (auto-loaded by builders)

| Skill | Covers |
|-------|--------|
| `frontend-rules` | UI components, CSS, client-side state |
| `backend-rules` | API routes, business logic, auth |
| `storage-rules` | Database schema and RLS policies |
| `testing-rules` | Test creation and full suite execution |
| `review-rules` | Standards checking — BLOCKER / WARNING / SUGGESTION |
| `author-rules` | Documentation and changelog authoring |
| `critic-rules` | Adversarial evaluation standards |

### 14 Commands

| Command | Purpose |
|---------|---------|
| `/build <brief>` | Full multi-agent pipeline with adversarial critic loop |
| `/plan <feature>` | Collaborative planning session (Socratic dialogue) |
| `/review` | Adversarial code review on current changes |
| `/explore` | Codebase exploration and context gathering |
| `/help` | List all available commands and agents |
| `/install` | Plugin installation and setup |
| `/rebase` | Guided git rebase workflow |
| `/check-pr` | Check PR status and review comments |
| `/external-review` | Trigger external LLM code review |
| `/backlog-list` | List backlog tasks |
| `/backlog-status` | Backlog snapshot with PR state and QA guide |
| `/token-analyser` | Analyse token usage and costs |
| `/sync-plugin-skills` | Sync skills from vendor plugins |
| `/plugin-repo-sync` | Sync to public plugin repository |

### 28 Skills

`agent-development`, `agent-flow-init-check`, `ascii-box-tables`, `author-rules`, `backend-rules`, `backlog-md`, `backlog-tpm`, `brainstorming`, `command-development`, `critic-rules`, `external-code-review`, `frontend-design`, `frontend-rules`, `hook-development`, `log-visualiser-converter`, `mcp-integration`, `playwright-cli`, `playwright-cli-helpers`, `plugin-settings`, `plugin-structure`, `review-rules`, `skill-development`, `storage-rules`, `sync-plugin-skills`, `testing-rules`, `token-analyser`, `ways-of-working`, `web-search`

---

## See It In Action

The showcase has recorded build sessions you can replay step by step — bug fixes, feature builds, and SEO improvements all run through the full agent sequence. Watch real builds happen in real time, from `/plan` through final documentation.

**[Browse the showcase →](https://timgranlundmarsden.github.io/claude-agent-flow/showcase.html)**

---

## Configuration

After install, two files are available for customisation:

- **`CLAUDE.md`** — project-level conventions. Add your project description and team rules below the managed sections.
- **`.env`** — local environment variables (API keys, feature flags). Never committed.

---

## License

Apache-2.0. See [LICENSE](LICENSE) for details.

Third-party attributions: [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)
