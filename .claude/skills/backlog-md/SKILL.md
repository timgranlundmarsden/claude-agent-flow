---
name: backlog-md
description: Task and document management with Backlog.md. Use this skill whenever working with tasks, tracking work, creating subtasks, searching or viewing existing tasks, or any time work should be preserved across sessions or handed off. Triggers include: "create a task", "track this", "add to backlog", "what tasks do I have", "mark as done", "continue on task", "break this into tasks", or any request where the outcome has a concrete deliverable worth tracking. Always use this skill when a project includes a Backlog.md setup and work needs to be logged. Prefer CLI commands unless MCP tools are confirmed working in the current environment.
---

# Backlog.md Task Management

## Tool Priority

**Default: CLI.** Use `backlog` CLI commands unless MCP tools are confirmed working in the current environment. MCP command equivalents are noted in the fallback section at the bottom.

## CRITICAL: Always Push After Operations

**After executing ANY backlog operation (task create, task edit, doc create, etc.), ALWAYS run:**
```bash
git push -u origin $(git rev-parse --abbrev-ref HEAD)
```

This ensures all backlog changes are immediately synced to the remote branch, regardless of whether hooks execute.

---

## When to Create a Task

**Create a task when:**
- Work spans multiple sessions or needs handoff
- There's a concrete deliverable
- It's part of a larger planned effort

**Skip task creation when:**
- Request is simple and immediate (e.g. "show me current tasks")
- Exploratory work with no clear deliverable
- Work will be fully completed in this session with no handoff needed

---

## Core Workflows

### New Task

1. Search first to avoid duplicates: `backlog search "keywords"`
2. Create supporting documents if needed (architecture, specs)
3. Create the task with all required fields
4. Set status to **In Progress** before starting work
5. Set status to **Done** immediately after completing

### Continue Existing Task

1. Find the task: `backlog search "keywords"` or `backlog task list`
2. View full details: `backlog task <id> --plain`
3. Check any linked documents in `/backlog/docs/`
4. Set status to **In Progress**
5. Set status to **Done** immediately after completing

### Large Feature → Subtasks

1. Create a parent task describing the overall goal
2. Create subtasks for each PR-sized piece: `backlog task create -p <parent-id> "Subtask title"`
3. Reference parent in subtask descriptions
4. Complete subtasks in dependency order

---

## Required Task Fields

Every task must have:

| Field | Purpose |
|---|---|
| **Title** | Short, specific, describes the deliverable |
| **Description** (`-d`) | What needs to be done + related doc references |
| **Plan** (`--plan`) | Background, approach, prerequisites, expected deliverables |
| **Priority** (`--priority`) | `high` / `medium` / `low` |

---

## Status Lifecycle

```
To Do → In Progress → Done
```

- Set **In Progress** before starting
- Set **Done** immediately on completion — never batch status updates

---

## Quick Command Reference

### Tasks

```bash
# Create
backlog task create "Title" -d "Description" --plan "Approach" --priority medium

# Create with all options
backlog task create "Title" \
  -d "What needs doing" \
  --plan "Approach and background" \
  --priority high \
  --ac "Must pass tests,Must be reviewed" \
  --dep task-1,task-2 \
  -l auth,backend

# Create subtask under parent
backlog task create -p <parent-id> "Subtask title"

# List
backlog task list
backlog task list -s "In Progress"
backlog task list -p <parent-id>

# View (AI-friendly plain output)
backlog task <id> --plain

# Edit / update status
backlog task edit <id> -s "In Progress"
backlog task edit <id> -s "Done"
backlog task edit <id> --priority high
backlog task edit <id> --append-notes "Completed X, working on Y"

# Acceptance criteria
backlog task edit <id> --ac "New criterion"
backlog task edit <id> --check-ac 1
backlog task edit <id> --remove-ac 2

# Dependencies
backlog task edit <id> --dep task-1 --dep task-2
```

### Search

```bash
backlog search "keywords"
backlog search "auth" --status "In Progress"
backlog search "bug" --priority high
backlog search "feature" --plain   # for scripts / AI use
```

### Documents

```bash
backlog doc create "Title"
backlog doc create "Setup Guide" -p guides/setup
backlog doc list
backlog doc view doc-<id>
```

### Board

```bash
backlog board              # interactive Kanban
backlog board export       # export to markdown
```

---

## Priority Guidelines

| Priority | When to use |
|---|---|
| **High** | Blockers, security issues, production bugs, critical features |
| **Medium** | Regular feature work, non-blocking improvements |
| **Low** | Nice-to-have, refactoring, docs, tech debt |

---

## Task Sizing

**One task = one PR:**
- ≤ 10 files changed
- ≤ 500 lines changed
- One clear functional unit
- Completable in ~1 day

If larger → break into parent task + subtasks.

---

## Linking Documents to Tasks

Always create documents before tasks when relevant:

```bash
# 1. Create the doc
backlog doc create "Auth Architecture"
# → returns doc-001

# 2. Reference it in the task description
backlog task create "Implement OAuth" \
  -d $'Implement OAuth login flow\n\n## Related Documents\n- [doc-001] Auth Architecture - Overall design' \
  --plan "Follow design in doc-001. Use existing session middleware." \
  --priority high
```

---

## Multi-line Input (bash)

Use ANSI-C quoting for real newlines:

```bash
backlog task create "Feature" \
  -d $'What needs doing\n\n## Related Documents\n- [doc-001] Title' \
  --plan $'1. Research\n2. Implement\n3. Test'
```

---

## MCP Fallback

If CLI is unavailable and MCP tools are confirmed working, use these equivalents:

| CLI | MCP |
|---|---|
| `backlog task create ...` | `mcp__backlog__task_create` |
| `backlog task edit <id> -s "Done"` | `mcp__backlog__task_edit --id <id> --status "Done"` |
| `backlog task <id> --plain` | `mcp__backlog__task_view --id <id>` |
| `backlog task list` | `mcp__backlog__task_list` |
| `backlog search "keywords"` | `mcp__backlog__task_search --query "keywords"` |
| `backlog doc create "Title"` | `mcp__backlog__document_create --title "Title"` |

MCP follows the same field requirements and status lifecycle as CLI.
