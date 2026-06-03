## Project: agent-flow

Add your project description here.

---
## Backlog Management

This project uses Backlog.md MCP for task and project management.

- Read `backlog://workflow/overview` before creating tasks (mandatory, every session).
- Use the `backlog-md` skill for detailed commands. Search before creating. Plan before code.
- **After every `backlog task edit -s "..."` status change, immediately run `git push -u origin $(git rev-parse --abbrev-ref HEAD)`** — explicit push is required for status changes to be visible on GitHub.
- Status lifecycle: To Do → In Progress → Blocked → Ready for Review → Done.
  - Set In Progress before work; set back to In Progress if revisiting a Ready for Review task.
  - Log progress with `notesAppend` and tick acceptance criteria as you go.

---

## Git Workflow — Required Before Every Push

1. **Rebase before push** when diverged: `git fetch origin && git rebase origin/$(git rev-parse --abbrev-ref HEAD)`
2. **Run external code review** before pushing — see `external-code-review` skill. Fix FAIL verdicts before pushing. Skip silently if review env vars are not set.
3. **No force-push** unless explicitly instructed. **mergiraf** is the merge driver.
4. After-merge: rebase onto main, force-push with lease, create a new PR.

### Main Branch Protection

Never commit directly to main. Before ANY work, verify the branch:

```bash
current_branch=$(git branch --show-current)
[[ "$current_branch" == "main" || "$current_branch" == "master" ]] && git checkout -b claude/<topic-slug>
```

### Failure-Mode Contract

Commands are either **git-dependent** (call `ensure-feature-branch.sh` first — /build, /plan, /review, /check-pr, /rebase, /external-review, /plugin-repo-staging, /plugin-repo-release) or **git-independent** (no git interaction). No silent degradation.

<!-- master-only -->

---

## Plan Mode Override

When plan mode is active and the user provides a feature description, **skip default phases**:
1. Write a plan file: `# Redirect to /plan\n\n<user's input verbatim>`
2. Call `ExitPlanMode`, then run `/plan <input>` after approval

---

## Agent Flow

Three agents: `explorer` (read-only navigator), `critic` (adversarial reviewer), `researcher` (web search). Parent implements directly — zero default subagent spawns. See `ways-of-working` skill for routing rules.

Key rules:
- `**Skills:**` directives in briefs: invoke each listed skill before starting work.
- Always use `AskUserQuestion` for discrete-option questions — never plain text.
- Before executing any slash command, verify `.claude-agent-flow/sync-state.json` exists. If absent, tell the user to run `/install` first.
- Any new command in `.claude/commands/` MUST include `**Skills:** agent-flow-init-check` as its first directive (except `install.md` and `help.md`).
- **Read the command file first.** When running `/build` or `/plan`, read the full command file and follow every step sequentially — do not run from memory.
- **Phase gates:** Before executing each named phase, re-read that phase section of the command file. State `[Phase N — starting]` before executing it. At each gate, tick every checklist item explicitly before advancing. Never skip a phase item because it seems inapplicable — check it first, then note why it was skipped if so.
- **Lite Mode Auto-Plan:** When the user describes new feature work without invoking `/build` or `/plan`, treat it as a `/plan` invocation. Does NOT apply to direct actions (bug fixes, renames, config updates).
- **Brainstorming:** Never invoke the `brainstorming` skill directly — route through `/plan`.
- **Auto-Review:** After significant non-`/build` implementation (multi-file, new features), run `/review` before reporting.

---

## Honouring User Intent

- **Respect specific wording.** If the user names a specific product, technology, version, or scope, do NOT silently broaden or reinterpret it. Ask first if ambiguous.
- **Research the subject matter.** Use WebSearch to verify facts — training data may be outdated.

## Vendor Skills — Read-Only

Vendor-installed skills (e.g. `brainstorming`, `playwright-cli`, `frontend-design`) **cannot be edited**. Add guidance to CLAUDE.md, command files, or agent definitions instead.

## Visual Layout Verification

After any CSS or layout fix, run `visual-check.sh` before marking done. Load `playwright-cli-helpers` alongside `playwright-cli`.

---

When the user says "suppress this in the review", read `.claude-agent-flow/docs/external-review-suppression-guide.md` first. Fix the code before adding a suppression.
See `.claude-agent-flow/docs/sync-workflow-conventions.md` before editing sync workflows.

## Technology Stack

See `TECHSTACK.md` for project tooling (test runner, linter, conventions). Agents read it on demand.

