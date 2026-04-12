---
name: install
description: Initialize or update the agent-flow system in this repository
---

# /install

Interactive setup for the agent-flow multi-agent development system.

## Instructions

You are running the agent-flow installation command. Follow these steps:

### Step 1: Detect Context

Check the following in order:

1. If `.claude-agent-flow/sync-state.json` exists → this is an **update** (re-sync from source)
2. If it doesn't exist but `.claude-agent-flow/scripts/agent-flow-install.sh` exists → this is a **fresh clone of the plugin repo** — auto-select `sandbox` scope and skip Step 1.5 entirely (do not ask the user)
3. Otherwise → this is a **fresh install** into a new repo

### Step 1.5: Select Scope

Skip this step entirely if scope was auto-selected in Step 1 (plugin repo clone case).

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

### Step 1.7: Permission Overrides Consent

Ask the user whether they want Agent Flow to install permission overrides using `AskUserQuestion`. Use this exact wording:

> Agent Flow can install permission overrides in your project settings that allow common operations (git commands, file editing, code search) to run without prompting you each time. This makes the workflow smoother but means those tools won't ask for confirmation.
>
> Permission deny rules (which protect sensitive files like .env and credentials) are always installed regardless of your choice here.
>
> Would you like to install these permission overrides?

Options:
- **Yes, install permission overrides** — common operations run without prompting
- **No, skip permission overrides** — you'll be prompted for each operation

Store the result. If the user chose "No, skip permission overrides", set a variable `skip_permissions=true` and append `--skip-permissions` to all `agent-flow-install.sh` invocations in Step 2.

**Always ask this question on every install/update** — do not remember or assume the previous answer.

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

If the user declined permission overrides in Step 1.7, append `--skip-permissions` to the command. For example:
```bash
bash .claude-agent-flow/scripts/agent-flow-install.sh --scope <chosen_scope> --skip-permissions
```

Similarly for all other invocation methods (curl-based and dynamic install). Append `--skip-permissions` to the curl/bash commands shown in Method 1 and Method 2 as well.

The script auto-detects the project name from the repo folder. No `--project-name` flag needed.

If `.claude-agent-flow/scripts/agent-flow-install.sh` doesn't exist locally (running in a repo that hasn't been bootstrapped yet), use the dynamic install script:

**Method 1: Auto-detect scope from existing installation (if available)**
```bash
SCOPE=$(jq -r '.scope // empty' .claude-agent-flow/sync-state.json 2>/dev/null)
if [ -n "$SCOPE" ]; then
  curl -fsSL https://raw.githubusercontent.com/timgranlundmarsden/claude-agent-flow/main/install.sh -o /tmp/agent-flow-install.sh && bash /tmp/agent-flow-install.sh --scope "$SCOPE"
else
  # If no scope found or file missing, prompt user to choose and run with their choice
  echo "No existing scope found. Choose a scope (plugin/plugin+github/sandbox) and run:"
  echo "curl -fsSL https://raw.githubusercontent.com/timgranlundmarsden/claude-agent-flow/main/install.sh -o /tmp/agent-flow-install.sh && bash /tmp/agent-flow-install.sh --scope <chosen_scope>"
fi
```

**Method 2: Direct install with chosen scope**
```bash
curl -fsSL https://raw.githubusercontent.com/timgranlundmarsden/claude-agent-flow/main/install.sh -o /tmp/agent-flow-install.sh && bash /tmp/agent-flow-install.sh --scope <chosen_scope>
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

---

Next step: `/plan Make me a html web page`
```
