# Backlog.md Workflow Guide

## Decision Framework: When to Create Tasks

Create a task when work needs to be resumed later or handed off to another agent. Skip task creation for immediate, simple work that will be completed in the current session.

**Create a task when:**
- Work will span multiple sessions
- Context needs to be preserved for later
- Another agent might need to continue the work
- The work is part of a larger planned effort
- Documentation of work history is important

**Skip task creation when:**
- Request is simple and immediate ("show me the current tasks")
- Work will be completed in this session with no handoff needed
- It's exploratory work without concrete deliverables

## Workflow: New Task Requests

When receiving a new work request:

### 1. Evaluate Task Scope
Ask:
- Can this be completed in one PR?
- Does it affect 10 or fewer files?
- Is it 500 or fewer line changes?
- Is it one clear functional unit?

If NO to any → Break down into smaller tasks

### 2. Document Required Knowledge
Before creating tasks, create supporting documents:

```bash
backlog doc create "Architecture Decision: JWT Authentication"
# Document the technical approach, why this approach was chosen
```

Documents capture:
- Architecture decisions
- Technical specifications
- Design patterns to follow
- API contracts or schemas

### 3. Create Task with Required Fields

```bash
backlog task create "Task Title" \
  --priority [high|medium|low] \
  -d "Description with related docs

## Related Documents
- [doc-XXX] Title - Relevance" \
  --plan "Implementation background and purpose: ...
Technical implementation approach: ...
Required prerequisites: ...
Expected deliverables: ..."
```

### 4. Start Work

```bash
# Always set status before starting
backlog task edit task-XXX --status "In Progress"
```

### 5. Complete Work

```bash
# IMMEDIATELY set status when done
backlog task edit task-XXX --status "Done"
```

**Critical:** Status updates must happen immediately, not batched later.

## Workflow: Existing Task Requests

When asked to "continue that task" or "work on task-005":

### 1. Check Task List
```bash
backlog task list --plain
```

### 2. View Task Details
```bash
backlog task task-XXX --plain
```

### 3. Load Related Documents
If the task mentions related documents:

```bash
# Check what docs exist
ls /backlog/docs/

# Read the relevant documents
# Use Read tool for doc-XXX.md files mentioned in task
```

**Important:** Always read related documents before continuing work. They contain essential context.

### 4. Update Status and Work
```bash
# Set to In Progress if not already
backlog task edit task-XXX --status "In Progress"

# Do the work...

# IMMEDIATELY set to Done when finished
backlog task edit task-XXX --status "Done"
```

## Status Lifecycle

```
To Do → In Progress → Done
```

**Rules:**
- Set to "In Progress" before starting implementation
- Set to "Done" immediately upon completion
- Never batch status updates

## Task Breakdown Example

**Bad - Too Large:**
```bash
backlog task create "Build E-commerce Platform"
# This affects hundreds of files, thousands of lines
```

**Good - Broken Down:**
```bash
# Parent task
backlog task create "E-commerce Platform MVP" \
  --priority high \
  -d "..." \
  --plan "..."

# Subtasks (each is one PR)
backlog task create "Product Listing API"
backlog task create "Shopping Cart API"
backlog task create "Checkout API"
backlog task create "Product List UI Component"
backlog task create "Cart UI Component"
```

Each subtask:
- Affects ≤10 files
- Changes ≤500 lines
- One clear functional unit
- Completable in ~1 day

## Search-First Approach

Before creating a new task, search for existing tasks:

```bash
# Search by keywords
backlog task list --plain | grep "authentication"

# Or use search if available
backlog task search "login"
```

Avoid duplicate tasks by finding and continuing existing work.

## Working with Documents

### Create Documents Before Tasks
Documents capture knowledge needed to execute tasks:

```bash
backlog doc create "API Design Standards"
# Write standards for how APIs should be structured

backlog doc create "Database Schema Design"
# Document tables, relationships, constraints

backlog task create "Implement User API" \
  -d "...
## Related Documents
- [doc-001] API Design Standards
- [doc-002] Database Schema Design"
```

### When to Create Documents
- Technical specifications needed for implementation
- Architecture decisions that guide multiple tasks
- Design patterns or standards to follow
- Complex business logic that needs explanation
- Schemas, contracts, or interfaces

### Linking Documents to Tasks
Always reference related documents in task descriptions:

```
## Related Documents
- [doc-XXX] Document Title - Brief explanation of how it's relevant
```

This creates a knowledge graph that helps agents understand context when resuming work.
