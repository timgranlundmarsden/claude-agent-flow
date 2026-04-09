# Agent Flow Repo Setup Guide 

How to deploy the agent-flow distribution system from scratch.

## Step 1: Create the `agent-flow` repo

Create `<your-org>/<your-source-repo>` on GitHub. Mark it as a **template repository** (Settings > General > Template repository checkbox). It can be **private**.

## Step 2: Populate it

Push the contents of `_agent-flow-staging/` as the initial content of agent-flow:

```bash
# From idea-factory (or wherever the staging dir lives)
cd _agent-flow-staging
git init
git remote add origin git@github.com:<your-org>/<your-source-repo>.git
git add -A
git commit -m "feat: initial agent-flow distribution system"
git push -u origin main
```

Then delete the `_agent-flow-staging/` directory from the source repo (or close the branch without merging).

## Step 3: Create a Fine-Grained PAT

GitHub > Settings > Developer settings > Fine-grained personal access tokens > Generate new token

- **Repository access**: Select `agent-flow` + every child repo (idea-factory, etc.)
- **Permissions needed**:
  - Contents: Read and write (clone, push branches)
  - Pull requests: Read and write (create PRs, add labels)
  - Metadata: Read (required)

## Step 4: Add secrets to the agent-flow repo

Go to **Settings > Secrets and variables > Actions > Secrets** in the `agent-flow` repo and add:

| Secret | Required | Purpose |
|--------|----------|---------|
| `AGENT_FLOW_SYNC_TOKEN` | Yes | PAT for cloning repos and creating PRs |
| `N8N_SYNC_WEBHOOK_URL` | No | n8n webhook for sync notifications |
| `BACKLOG_NOTIFY_FROM` | No | Sender identifier for notifications |
| `N8N_BACKLOG_WEBHOOK_URL` | No | n8n webhook for backlog task notifications and PR review verdicts (Telegram) |

Child repos get their secrets configured separately in Step 7 after installation.

## Step 5: Register child repos

In `agent-flow/.claude-agent-flow/repo-sync-manifest.yml`, add each child to the targets section:

```yaml
targets:
  - repo: "<your-org>/<your-target-repo-1>"
    enabled: true      # set false to stop downstream sync to this repo
  - repo: "<your-org>/<your-target-repo-2>"
    enabled: true
```

## Step 6: Install into a child repo

Run these three commands from within the target repo (requires [gh CLI](https://cli.github.com)):

```bash
rm -rf /tmp/agent-flow
gh repo clone <your-org>/<your-source-repo> /tmp/agent-flow -- --depth 1
/tmp/agent-flow/.claude-agent-flow/scripts/agent-flow-install.sh
rm -rf /tmp/agent-flow
```

This is the primary way to install the agent team into any existing repo. The script auto-detects the project name from the repo folder. Pass `--project-name "Custom Name"` to override.

Safe to run multiple times — it will update existing files without duplicating anything.

Once installed, you can also run `/agent-flow-install` from within Claude Code to re-sync from source.

## Step 7: Configure child repo secrets and settings

After installing into a child repo, complete the following setup in the child repo's GitHub settings.

### Required: Add secrets

Go to **Settings > Secrets and variables > Actions > Secrets** and add:

| Secret | Required | Purpose |
|--------|----------|---------|
| `AGENT_FLOW_SYNC_TOKEN` | Yes | PAT for cloning repos and creating PRs (same token as Step 3) |
| `EXTERNAL_REVIEW_API_KEY` | No | API key for LLM-powered PR review (workflow skips gracefully if absent) |
| `N8N_SYNC_WEBHOOK_URL` | No | n8n webhook for sync notifications |
| `BACKLOG_NOTIFY_FROM` | No | Sender identifier for notifications |
| `N8N_BACKLOG_WEBHOOK_URL` | No | n8n webhook for backlog task notifications and PR review verdicts (Telegram) |

Without `AGENT_FLOW_SYNC_TOKEN`, the upstream sync workflow will fail silently.

### Optional: Set repo variables

Go to **Settings > Secrets and variables > Actions > Variables** and add:

| Variable | Default | Purpose |
|----------|---------|---------|
| `AGENT_FLOW_UPSTREAM_SYNC_ENABLED` | `true` | Set to `false` to stop this repo sending changes upstream |
| `EXTERNAL_REVIEW_MODEL` | _(none)_ | Model ID for PR reviews (e.g., `google/gemini-2.5-flash-lite`). Required alongside `EXTERNAL_REVIEW_API_KEY`. |
| `EXTERNAL_REVIEW_API_BASE_URL` | _(none)_ | Base URL for the external review API (e.g., `https://openrouter.ai/api/v1`). Required alongside `EXTERNAL_REVIEW_API_KEY`. |

To enable automated PR reviews, set `EXTERNAL_REVIEW_API_KEY` (secret), `EXTERNAL_REVIEW_MODEL` (variable), and `EXTERNAL_REVIEW_API_BASE_URL` (variable). The review workflow runs on every PR and posts inline review comments. If any are missing, the workflow skips gracefully with a warning annotation.

### Recommended: Restrict merge strategy

Go to **Settings > General > Pull Requests** and:

1. Uncheck **Allow merge commits**
2. Uncheck **Allow rebase merging**
3. Keep only **Allow squash merging** checked
4. Set default commit message to **Pull request title and description**

This ensures sync PRs produce clean single-commit entries on main, making the sync commit trailers (used for loop prevention) reliable and the git history readable.

## How sync works after setup

All sync happens via pull requests — nothing is ever pushed directly to main.

### Downstream (master → children)

When you push changes to managed files in agent-flow, GitHub Actions automatically:
1. Clones each enabled child repo
2. Runs the sync engine (copies managed files, merges settings, patches CLAUDE.md)
3. Creates or updates a single PR per child (`agent-flow/downstream-sync` branch)
4. Sends an n8n notification (if configured)

If an open sync PR already exists for a child, it is updated in-place. No duplicate PRs pile up.

### Upstream (children → master)

When a child repo pushes changes to content files (agents, commands, skills) on main:
1. The upstream workflow creates or updates a single PR to agent-flow
2. You review and merge (or reject) the PR
3. If merged, the improvement flows downstream to all other children automatically

Only content files sync upstream. Infrastructure files (manifest, scripts, hooks, binaries, `.mcp.json`, `.gitattributes`) are master-controlled.

### Loop prevention

Commit trailers (`Agent-Flow-Sync-Origin: <repo>`) prevent infinite loops. The originating repo is always skipped in the return sync.

### Controlling sync

| What | How | Who controls |
|------|-----|-------------|
| Stop syncing **to** a child | Set `enabled: false` in manifest targets | Master repo |
| Stop syncing **from** a child | Set `AGENT_FLOW_UPSTREAM_SYNC_ENABLED=false` as repo variable | Child repo |

## Private repo note

The agent-flow repo can be private. The install script uses `gh repo clone` (which inherits the user's GitHub auth) as the primary clone method, with `git clone` as a fallback for public repos. The `/agent-flow-install` Claude command handles this automatically.

## What gets installed in child repos

After running `/agent-flow-install`, the child repo will have:

| Path | Type | Notes |
|------|------|-------|
| `.claude/agents/` | Overwritten on sync | 12 agent definitions |
| `.claude/commands/` | Overwritten on sync | Slash commands |
| `.claude/skills/` | Overwritten on sync | Skills (backlog, brainstorming, etc.) |
| `.claude/hooks/` | Overwritten on sync | Session-start bootstrap |
| `.claude-agent-flow/bin/` | Overwritten on sync | Helper binaries (mergiraf) |
| `.claude/settings.json` | Deep-merged | Permissions and hooks merged, custom keys preserved |
| `.mcp.json` | Overwritten on sync | MCP server config |
| `.gitattributes` | Overwritten on sync | Mergiraf merge driver |
| `.claude-agent-flow/` | Overwritten on sync | Manifest, scripts, sync state |
| `CLAUDE.md` | Section-patched | Project preamble preserved, managed sections replaced |
| `.gitignore` | Append-only | Managed lines added if missing |
| `backlog/config.yml` | Templated | Project name substituted |
| `.github/workflows/` | Overwritten on sync | Upstream sync, downstream sync, backlog notify workflows |

Custom files you add (your own agents, commands, skills) are never removed by sync.
