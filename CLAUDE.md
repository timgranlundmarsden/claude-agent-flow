## Project: agent-flow

Add your project description here.

---
## Backlog Management

This project uses Backlog.md MCP for task and project management.

- Read `backlog://workflow/overview` before creating tasks — it has the full workflow.
- Use the `backlog-md` skill for detailed commands and reference.
- Search before creating. Plan before code. **After every `backlog task edit -s "..."` status change, immediately run `git push -u origin $(git rev-parse --abbrev-ref HEAD)`** — the auto-push hook commits reliably but does not reliably push in this environment; explicit push is required for status changes to be visible on GitHub.
- Status lifecycle: To Do → In Progress → Blocked → Ready for Review → Done.
  - Set In Progress before work; if revisiting a Ready for Review task, set back to In Progress first.
  - Log progress with `notesAppend` and tick acceptance criteria as you go.

---

## Git Workflow — Required Before Every Push

1. **Rebase before push** when diverged: `git fetch origin && git rebase origin/$(git rev-parse --abbrev-ref HEAD)`
2. **Run external code review** before pushing — see `external-code-review` skill for the command. Fix any FAIL verdicts before pushing. Skip silently if review env vars are not set.
3. Use **`/rebase`** for a guided workflow
4. **No force-push** unless explicitly instructed
5. **mergiraf** is the merge driver — installed via session-start hook

### After-merge workflow

If the branch's PR has been merged or closed: rebase onto main, force-push with lease, create a new PR.

### Main Branch Protection

Never commit directly to main. Before ANY work, verify the branch:

```bash
current_branch=$(git branch --show-current)
[[ "$current_branch" == "main" || "$current_branch" == "master" ]] && git checkout -b claude/<topic-slug>
```

This applies to all pipelines and any operation that produces commits.

<!-- master-only -->

---

## Plan Mode Override

When plan mode is active and the user provides a feature description, **skip default phases**:
1. Write a plan file: `# Redirect to /plan\n\n<user's input verbatim>`
2. Call `ExitPlanMode`, then run `/plan <input>` after approval

---

## Agent Flow

This project uses a multi-agent team. Agents are defined in `.claude/agents/`.

**Default: Lite mode** — explorer → builder → reviewer. For everyday tasks.
**Full pipeline: `/build <brief>`** — full sequence with adversarial critic loop.

See `ways-of-working` skill for routing rules, agent roster, execution model, and cost guidance.

Key rules:
- Orchestrator never writes code — delegates all work including fixes. When critic or reviewer finds issues, route them back to the relevant builder agent; never apply fixes directly.
- Storage agent is sole owner of RLS policies
- All agents run sequentially, one at a time
- Completion reports: structured, under 30 lines (exception: architect, researcher, explorer, ideator — output IS the deliverable)
- `**Skills:**` directives in briefs: invoke each listed skill before starting work
- Always use `AskUserQuestion` for discrete-option questions (yes/no, A/B/C, design approvals, confirm/deny gates) — never plain text
- Reference skills by short name only (e.g. `brainstorming`)
- Before executing any slash command, verify `.claude-agent-flow/sync-state.json` exists. If absent, stop and tell the user to run `/install` first.
- Any new command added to `.claude/commands/` MUST include `**Skills:** agent-flow-init-check` as its first skill directive (except `install.md` and `help.md`, which are bootstrapping/discovery commands).

### Pipeline Execution Rule

**Read the command file first.** When running `/build` or `/plan`, read the full command file before starting. It is the authoritative source — follow every step sequentially. Do not run from memory.

### Lite Mode Auto-Plan

When the user describes new feature work without invoking `/build` or `/plan`, treat it as a `/plan` invocation automatically. Does NOT apply to direct actions (bug fixes, renames, config updates).

### Brainstorming Routing Rule

**Never invoke the `brainstorming` skill directly.** Always route through `/plan` instead — it uses brainstorming internally for the Socratic dialogue phase. This applies to all scenarios where you would otherwise call the brainstorming skill: new features, design exploration, creative work, component creation, and behaviour changes. The brainstorming skill's own trigger description ("MUST use before any creative work") is superseded by this rule when agent-flow is installed. If the user explicitly asks to brainstorm without planning overhead, use the `ideator` agent (read-only, lateral thinking) instead.

### Auto-Review After Significant Work

After significant non-`/build` implementation (multi-file, new features), run `/review` before reporting. Scale: 1-3 loops by change size. Does NOT apply to: planning sessions, config/docs changes, backlog management, or exploration.

### Critic Integrity Rule

The critic must NEVER be told which loop iteration it is on or how many remain. Verdict based solely on code quality. See critic agent definition for enforcement.

---

## Honouring User Intent

- **Respect specific wording.** If the user names a specific product, technology, version, or scope, do NOT silently broaden or reinterpret it. If there is any ambiguity, ask first.
- **Research the subject matter.** Use WebSearch to verify facts about the topic itself — training data may be outdated.

## Vendor Skills — Read-Only

Vendor-installed skills (e.g. `brainstorming`, `playwright-cli`, `frontend-design`) **cannot be edited**. Their files are managed by the plugin system. Add guidance to CLAUDE.md, command files, or agent definitions instead.

## Mandatory Test Coverage

All code changes require tests (happy path, edge cases, error states, boundary conditions). Enforced by builders, critic, tester, and reviewer at every stage. No exceptions. Tester must always run the **full** test suite — never scoped to changed files only — to catch regressions.

## Visual Layout Verification

After any CSS or layout fix, run `visual-check.sh` before marking done. Load `playwright-cli-helpers` alongside `playwright-cli` for project-specific setup.

## Document Folder Auto-Suggest

When calling `save_document`: call `list_folders` first, then use `AskUserQuestion` to offer the user existing folders, no folder, or a new name. Pass the choice as the `folder` parameter. Skip if no folders exist. Does not apply to `edit_document`.

## Backlog Workflow

Read `backlog://workflow/overview` before creating any tasks (mandatory, every session). Use CLI for mutations; MCP guide tools for reading workflow docs.

---

When the user says "suppress this in the review", read `.claude-agent-flow/docs/external-review-suppression-guide.md` first. Fix the code before adding a suppression.
See `.claude-agent-flow/docs/sync-workflow-conventions.md` before editing sync workflows.
