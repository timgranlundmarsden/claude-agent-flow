# Task Creation Guide

## Required Fields

Every task must include:

### 1. Title (required)
- Short and immediately understandable
- Describes the deliverable, not the action
- Good: "User Authentication API Implementation"
- Bad: "Work on auth stuff" or "Authentication System Development Phase 1 - Initial Setup and Configuration"

### 2. Description (-d flag, required)
Structure:
```
Brief summary of what needs to be done

## Related Documents
- [doc-XXX] Document Title - Brief explanation of relevance
- [doc-YYY] Another Document - Brief explanation of relevance
```

**Tips:**
- First paragraph: What needs to be done (1-3 sentences)
- Always list related documents if they exist
- Include context that helps resume work after losing context

### 3. Plan (--plan flag, required)
Structure:
```
Implementation background and purpose: [Why this task exists]
Technical implementation approach: [How it will be done]
Required prerequisites: [What must exist before starting]
Expected deliverables: [What will exist after completion]
```

**Tips:**
- Be specific about technical approach
- List concrete prerequisites
- Define measurable deliverables

### 4. Priority (--priority flag, required)
- `high` - High urgency, blockers, security-related
- `medium` - Regular feature implementation, improvements
- `low` - Nice-to-have, refactoring, documentation

## Task Breakdown Guidelines

**1 PR = Work amount completable within 1 day:**
- Files: Changes to 10 or fewer files
- Lines: 500 or fewer line changes
- Features: One clear functional unit

**When a request is too large:**
1. Create a parent task for the overall goal
2. Break down into smaller subtasks
3. Each subtask should be independently completable

## Example: Well-Formed Task

```bash
backlog task create "User Login API Endpoint" \
  --priority high \
  -d "Implement POST /api/auth/login endpoint for user authentication

## Related Documents
- [doc-001] Authentication Architecture Design - JWT implementation policy
- [doc-002] API Design Guidelines - Endpoint design standards" \
  --plan "Implementation background and purpose: Enable users to authenticate and receive JWT tokens
Technical implementation approach: Express.js route handler with bcrypt password verification and JWT token generation
Required prerequisites: User model exists, database configured, JWT secret configured
Expected deliverables: POST /api/auth/login endpoint, input validation, error handling, JWT token response"
```

## Example: Parent Task with Subtasks

**Parent Task:**
```bash
backlog task create "Complete Authentication System" \
  --priority high \
  -d "Implement full authentication flow including registration, login, and token refresh

## Related Documents
- [doc-003] Overall System Design - Complete authentication flow overview" \
  --plan "Implementation background and purpose: Building secure application foundation
Technical implementation approach: Phased implementation with registration → login → token refresh
Required prerequisites: Requirements definition completed, database schema designed
Expected deliverables: Complete authentication system with all endpoints tested"
```

**Then create subtasks:**
- "User Registration API Endpoint"
- "User Login API Endpoint"
- "Token Refresh API Endpoint"
- "Authentication Middleware"

## Common Mistakes

❌ **Too vague:** "Fix auth"
✅ **Specific:** "Fix JWT token expiration validation in auth middleware"

❌ **No plan:** Only title and description
✅ **Complete:** Title + description + plan + priority

❌ **Too large:** "Build entire e-commerce platform"
✅ **Right-sized:** "Implement product listing API endpoint"

❌ **Missing related docs:** Description doesn't reference existing documentation
✅ **With context:** Description links to architecture decisions and design docs
