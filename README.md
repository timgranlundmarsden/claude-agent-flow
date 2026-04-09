# Claude Agent Flow

A Claude Code plugin that brings a multi-agent development pipeline to your repository — adversarial review loops, 12 specialist agents, 13 slash commands, and 18 skills.

**[Full documentation →](https://timgranlundmarsden.github.io/claude-agent-flow/)**

![claude-agent-code.jpg](docs/img/claude-agent-code.jpg)

## Why use this framework/plugin and why did I build it 

I started this project because if I am honest I was a bit disappointed with the current crop of AI tooling. As amazing as their results often are, when the model says "I am done", it was always far from done. Maybe you asked for a mobile friendly web page and it turned out that the result wasnt in fact mobile friendly. Or maybe you asked it to fix some code and then on running the tests, you saw that it had made introduced another bug. Either way I was spending too much time hand holding and guiding the models.

I am a big Claude Code user and it supports so many great things so I thought why don't I try and build a workflow that would help me formulate my idea, research it for me, sanity check it and then build it for me all without my intervention. Obviously I would need to discuss with the AI what I wanted but once we had a good plan, I wanted my work to be turned into a "ticket" and then have the AI build it for me and not come back to me until it was "Done Done"!

But the big part was once it thought it was done, it would need to get the approval of multiple separate AI agents that would be very thorough and check it's work. "Works on mobile?", then prove it with screenshots! "Code looks good", then lets run all the tests. If anything breaks, send it back to the agent that did the work for correction. Only when the entire flow if complete and every agent is satisfied, is the job "Ready for Review"

Today it's 12 specialised agents, a skill library, and a full CI/CD integration — built entirely by running itself. What began as a simple automation became a full on factory line capable of solving multiple tickets at once. When you couple it with Claude Code for Web you can literally have AI build your ideas whilst you are out and about. It gets rather addictive :-)

## Installation

Run from inside your project's git repository:

```bash
curl -fsSL https://raw.githubusercontent.com/timgranlundmarsden/claude-agent-flow/main/install.sh | bash
```

This prompts you to choose a scope. To skip the prompt, pass `--scope` directly:

```bash
# Plugin only (lightest)
curl -fsSL https://raw.githubusercontent.com/timgranlundmarsden/claude-agent-flow/main/install.sh | bash -s -- --scope plugin

# Plugin + GitHub Actions
curl -fsSL https://raw.githubusercontent.com/timgranlundmarsden/claude-agent-flow/main/install.sh | bash -s -- --scope plugin+github

# Sandbox (fully self-contained)
curl -fsSL https://raw.githubusercontent.com/timgranlundmarsden/claude-agent-flow/main/install.sh | bash -s -- --scope sandbox
```

### Scopes

| Scope | What's included | Best for |
|-------|----------------|----------|
| **plugin** | CLAUDE.md patch, settings.json, .gitattributes, .mcp.json, Backlog.md init | Teams managing their own CI/CD |
| **plugin+github** | Everything in plugin, plus automated AI code review on PRs and Telegram backlog notifications | GitHub Actions users |
| **sandbox** | Everything fully vendored into your repo — agents, commands, and skills live alongside your code with no external plugin dependency at runtime, so the full pipeline works inside sandboxed environments including Claude Code web (claude.ai/code) | Claude Code web or air-gapped environments |

### Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI installed
- Git repository initialised in your project
- Node.js 18+ (for MCP servers and Backlog.md)

## What You Get

### 12 Agents

| Agent | Role |
|-------|------|
| orchestrator | Routes work through the pipeline; never writes code |
| explorer | Codebase reconnaissance and context gathering |
| architect | Design decisions and implementation blueprints |
| ideator | Feature ideation and creative problem-solving |
| researcher | External research and technology validation |
| frontend | UI, CSS, and client-side implementation |
| backend | APIs, services, and server-side implementation |
| storage | Database schema and RLS policies (sole owner) |
| tester | Test creation and full test suite execution |
| critic | Adversarial code review (integrity-protected verdict) |
| reviewer | Final review pass before completion |
| author | Documentation and changelog authoring |

### 13 Commands

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
| `/token-analyser` | Analyse token usage and costs |
| `/sync-plugin-skills` | Sync skills from vendor plugins |
| `/plugin-repo-sync` | Sync to public plugin repository |

### 18 Skills

`agent-development`, `ascii-box-tables`, `backlog-md`, `backlog-tpm`, `brainstorming`, `command-development`, `external-code-review`, `frontend-design`, `hook-development`, `mcp-integration`, `playwright-cli`, `playwright-cli-helpers`, `plugin-settings`, `plugin-structure`, `skill-development`, `sync-plugin-skills`, `token-analyser`, `ways-of-working`

## Modes

- **Lite mode** (default): explorer → builder → reviewer. For everyday tasks.
- **Full pipeline** (`/build <brief>`): Full agent sequence with adversarial critic loop. For production features.

Describe what you want naturally — the pipeline routes automatically.

## Configuration

After install, two files are available for customisation:

- **`CLAUDE.md`** — project-level conventions. Add your project description and team rules below the managed sections.
- **`.env`** — local environment variables (API keys, feature flags). Never committed.

## License

Apache-2.0. See [LICENSE](LICENSE) for details.

Third-party attributions: [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)
