---
name: install
description: Initialize or update the agent-flow system in this repository
---

# /install

Interactive setup for the agent-flow multi-agent development system.

## Instructions

You are running the agent-flow installation command. Follow these steps:

### Step 1: Detect Context

Check if this is a fresh install or an update:
- If `.claude-agent-flow/sync-state.json` exists → this is an **update** (re-sync from source)
- If it doesn't exist → this is a **fresh install**

### Step 1.5: Select Scope

Present the scope options to the user using `AskUserQuestion`. For **updates**, first read the current scope from `.claude-agent-flow/sync-state.json` (field: `scope`, default: `"plugin"` if absent) and offer to keep or change it.

Use the following wording verbatim for the options:

**A) Plugin** — Claude Code components only
- Patches CLAUDE.md, merges settings.json, sets up .gitattributes, inits backlog
- Best for teams that manage their own CI/CD and just want the Claude Code agent team experience
- Stays lightweight; your repo owns its own workflows

**B) Plugin + GitHub Actions** — Plugin + GitHub Actions
- Everything in Plugin
- Automated AI code review on every PR — when a PR is opened, an agent reviews the diff and posts structured feedback directly on the PR, catching issues before human review
- Telegram notifications for backlog task state changes and PR code quality review completions, so you never miss a status update
- Best for teams wanting complete GitHub integration and the safety net of automated review on every code change

**C) Sandbox mode** — Everything in A and B, plus fully self-contained
- All of Plugin + GitHub Actions, including GitHub Actions and Telegram notifications
- All agent-flow files copied directly into your repo (agents, commands, skills, scripts) — no plugin dependency at runtime
- Best choice if you're using Claude Code on the web (claude.ai/code) — the web UI cannot load marketplace plugins, so vendoring files directly into the repo is how you get the full agent team experience there
- Also ideal for air-gapped environments or teams that want to fork and customise the system
- The repo becomes the source of truth; re-running install pulls the latest files from upstream

Store the chosen scope as a variable (one of: `plugin`, `plugin+github`, `sandbox`) for use in Step 2.

### Step 2: Run the Install Script

Run the appropriate command, passing the chosen scope:

**Fresh install:**
```bash
bash .claude-agent-flow/scripts/agent-flow-install.sh --scope <chosen_scope>
```

**Update:**
```bash
bash .claude-agent-flow/scripts/agent-flow-install.sh --update --scope <chosen_scope>
```

The script auto-detects the project name from the repo folder. No `--project-name` flag needed.

If `.claude-agent-flow/scripts/agent-flow-install.sh` doesn't exist locally (running in a repo that hasn't been bootstrapped yet), use the dynamic install script:

**Method 1: Auto-detect scope from existing installation (if available)**
```bash
SCOPE=$(jq -r '.scope // empty' .claude-agent-flow/sync-state.json 2>/dev/null)
if [ -n "$SCOPE" ]; then
  curl -fsSL https://raw.githubusercontent.com/timgranlundmarsden/claude-agent-flow/main/install.sh | bash -s -- --scope "$SCOPE"
else
  # If no scope found or file missing, prompt user to choose and run with their choice
  echo "No existing scope found. Choose a scope (plugin/plugin+github/sandbox) and run:"
  echo "curl -fsSL https://raw.githubusercontent.com/timgranlundmarsden/claude-agent-flow/main/install.sh | bash -s -- --scope <chosen_scope>"
fi
```

**Method 2: Direct install with chosen scope**
```bash
curl -fsSL https://raw.githubusercontent.com/timgranlundmarsden/claude-agent-flow/main/install.sh | bash -s -- --scope <chosen_scope>
```

### Step 3: Review and Commit

After the script completes:
1. Show the user a summary of what was installed/updated using `git diff --stat`
2. Ask if they want to commit the changes
3. If yes, commit with message: `feat: install agent-flow system` (fresh) or `feat: update agent-flow system` (update)

### Step 4: Registration Reminder

For fresh installs, remind the user:
> "To enable automatic sync, add this repo to the `targets` list in `.claude-agent-flow/repo-sync-manifest.yml` in the agent-flow source repo, and add the `AGENT_FLOW_SYNC_TOKEN` secret to this repo's GitHub settings."

### Step 5: Installation Summary and Getting Started Guide

After everything is done (commit included), output the following verbatim:

```
## What was installed

The agent team system has been installed into hidden directories in your repo.
If you don't see them in your file explorer, enable "Show hidden files".

### Agents (.claude/agents/)

| Agent | Purpose |
|-------|---------|
| orchestrator | Breaks work into subtasks and delegates to specialist agents |
| architect | Designs feature architecture — read-only, produces build plans |
| explorer | Maps codebases quickly — finds files, patterns, and dependencies |
| frontend | Builds UI components, styling, and client-side state |
| backend | Builds API routes, business logic, DB queries, and server code |
| storage | Owns all data persistence — databases, RLS policies, migrations |
| tester | Writes and runs tests for both frontend and backend |
| reviewer | Reviews code for security, correctness, performance, and style |
| critic | Adversarial reviewer — tries to break code with edge cases |
| author | Updates documentation — README, CHANGELOG, docstrings |
| researcher | Searches the web for current docs, best practices, and comparisons |
| ideator | Lateral thinking — explores solution spaces and creative approaches |

### Skills (.claude/skills/)

| Skill | Purpose |
|-------|---------|
| ways-of-working | Routing rules, execution model, and best practices for the agent team |
| brainstorming | Interactive visual brainstorming — explores intent before implementation |
| backlog-md | Task management via Backlog.md — create, track, and search tasks |
| backlog-tpm | Coordinated multi-task project management with sub-agents |
| playwright-cli | Browser automation — testing, screenshots, form filling |
| playwright-cli-helpers | Project-specific visual verification with visual-check.sh |
| frontend-design | High-quality UI design — avoids generic AI aesthetics |
| ascii-box-tables | Pretty tables and diagrams for terminal/monospace display |
| token-analyser | Analyse Claude Code token usage and costs |
| sync-plugin-skills | Sync plugin skills into the repo for web environments |

### Commands (.claude/commands/)

| Command | Purpose |
|---------|---------|
| /plan | Guided planning — brainstorm, architect, and save a structured plan |
| /build | Full quality pipeline — architect, build, critic loop, test, review |
| /review | Adversarial code review without rebuilding |
| /explore | Quick read-only codebase exploration |
| /rebase | Guided git rebase workflow |
| /backlog-list | View all tracked backlog tasks |
| /install | This command — install or update the agent team |
| /help | Comprehensive help guide — run any time |

### Other installed files

| File | Purpose |
|------|---------|
| .claude/settings.json | Permissions, hooks, and plugin configuration |
| .claude/hooks/session-start.sh | Auto-installs backlog CLI, playwright, and mergiraf on session start |
| .claude-agent-flow/bin/ | Helper binaries (mergiraf for syntax-aware git merges) |
| .mcp.json | MCP server configuration (Backlog.md) |
| .gitattributes | Mergiraf merge driver registration |
| .claude-agent-flow/ | Manifest, sync scripts, and sync state (hidden directory) |
| .github/workflows/ | Upstream sync and backlog notification workflows |
| CLAUDE.md | Updated with managed sections (your project content preserved) |
| backlog/config.yml | Backlog project configuration |

---

## Getting Started

You're all set! Here's what you can do now:

| Command | What it does |
|---------|--------------|
| `/plan <idea>` | Guided planning — brainstorm, architect, and save a structured plan |
| `/build <plan>` | Full quality pipeline — architect, build, critic loop, test, review |
| `/build @plans/file.md` | Build from a saved plan file |
| `/build TASK-54` | Build from a backlog task |
| `/build <plan> --loops 5` | Build with up to 5 adversarial critic iterations (default: 3) |
| `/review` | Review all changes on the current branch vs main |
| `/review --loops 3` | Run up to 3 adversarial critic iterations (default: 1, max: 5) |
| `/review TASK-42` | Review changes linked to a specific backlog task |
| `/explore <topic>` | Quick read-only codebase exploration |
| `/rebase` | Guided rebase onto latest remote changes |
| `/rebase main` | Rebase onto a specific branch |
| `/backlog-list` | View all tracked backlog tasks |
| `/install` | Install or update the agent team system |
| `/help` | Full help guide — commands, agents, ways of working |

Or just ask naturally — "Add a dark mode toggle to the settings page" works too.

### How it works
- **Lite mode (default):** Just ask naturally. An explorer maps the code,
  a builder implements, and a reviewer checks the work.
- **Full pipeline (`/build`):** Adds an architect, adversarial critic loop,
  and tester for quality-critical features.
- **Planning (`/plan`):** Interactive brainstorming session that produces
  a structured plan and backlog task before any code is written.

Tasks are tracked automatically via Backlog.md. Use `/backlog-list` to see them.
Run `/help` any time for the full guide on commands, agents, and ways of working.

---

## Next Steps — Enable Sync

The agent team files are installed locally. To enable automatic sync between
this repo and the agent-flow source, complete these steps:

### 1. Commit and push
Commit the changes from this install and push to your main branch.

### 2. Add the sync token secret
Go to **GitHub > Settings > Secrets and variables > Actions** and add:

| Secret | Value |
|--------|-------|
| `AGENT_FLOW_SYNC_TOKEN` | A fine-grained PAT with Contents (read/write) and Pull Requests (read/write) access to both this repo and the agent-flow source repo |

### 3. Request registration in the source repo
Ask the agent-flow source repo owner to add this repo to `.claude-agent-flow/repo-sync-manifest.yml` so it receives future updates:
```yaml
targets:
  - repo: "owner/this-repo"
    enabled: true
```

### 4. Optional — notifications
Add these secrets if you want n8n webhook notifications for sync PRs:

| Secret | Purpose |
|--------|---------|
| `N8N_SYNC_WEBHOOK_URL` | n8n webhook endpoint for sync notifications |
| `BACKLOG_NOTIFY_FROM` | Sender identifier for notifications |
| `N8N_BACKLOG_WEBHOOK_URL` | n8n webhook for backlog task notifications |

### How sync works after setup

All sync happens via pull requests — nothing is ever pushed directly to main.

- **Downstream (source → this repo):** When managed files change in the
  agent-flow source, a PR is automatically created here with the updates.
  If an open sync PR already exists, it is updated in-place — no duplicates.

- **Upstream (this repo → source):** When you improve agents, commands, or
  skills and push to main, a PR is created in the source repo proposing your
  changes. Once merged there, improvements flow to all other child repos.

- **No ping-pong:** Commit trailers prevent infinite loops. A change synced
  down from source won't trigger an upstream PR back, and vice versa.

- **Opt out:** Set the repo variable `AGENT_FLOW_UPSTREAM_SYNC_ENABLED=false`
  to stop this repo from sending changes upstream.
```
