# Task Examples: Good vs Bad

## Example 1: Feature Implementation

### ❌ Bad
```bash
backlog task create "Add authentication"
```

**Problems:**
- No description
- No plan
- No priority
- Too vague
- Too large (affects many files)

### ✅ Good
```bash
backlog task create "User Login API Endpoint" \
  --priority high \
  -d "Implement POST /api/auth/login endpoint that accepts email/password and returns JWT token

## Related Documents
- [doc-001] Authentication Architecture - JWT implementation approach
- [doc-002] API Standards - Error response format" \
  --plan "Implementation background and purpose: Enable user authentication for the application
Technical implementation approach: Express.js route with bcrypt password verification and jsonwebtoken library
Required prerequisites: User model exists, database connection configured, JWT_SECRET in environment
Expected deliverables: POST /api/auth/login endpoint with validation, error handling, and JWT response"
```

**Why it's good:**
- Clear, specific title
- Detailed description with context
- References relevant documentation
- Complete plan with all sections
- Right-sized (one endpoint, one PR)
- Appropriate priority

## Example 2: Bug Fix

### ❌ Bad
```bash
backlog task create "Fix bug" \
  --priority high
```

**Problems:**
- What bug?
- No description of issue
- No plan for fix
- No way to verify when done

### ✅ Good
```bash
backlog task create "Fix JWT Token Expiration Validation" \
  --priority high \
  -d "Token expiration is not being checked properly - expired tokens still validate successfully

Steps to reproduce:
1. Generate token with 1-second expiration
2. Wait 2 seconds
3. Use token - it still works

## Related Documents
- [doc-001] Authentication Architecture - Token validation flow" \
  --plan "Implementation background and purpose: Security issue allowing expired tokens to be used
Technical implementation approach: Fix jwt.verify() call to properly check exp claim
Required prerequisites: Test case that reproduces the issue
Expected deliverables: Fixed validation logic, passing test case, no expired tokens accepted"
```

**Why it's good:**
- Specific problem statement
- Reproduction steps
- Clear security priority
- Plan includes test case
- Measurable success criteria

## Example 3: Large Feature Breakdown

### ❌ Bad - Monolithic Task
```bash
backlog task create "Implement Complete Authentication System" \
  --priority high \
  -d "Add registration, login, logout, password reset, email verification, 2FA, and OAuth providers"
```

**Problems:**
- Too large (would affect 50+ files)
- Multiple features bundled together
- Would take weeks, not days
- Can't be completed in one PR
- No clear order of implementation

### ✅ Good - Broken Down

**Parent Task:**
```bash
backlog task create "Complete Authentication System" \
  --priority high \
  -d "Full authentication system implementation including registration, login, and security features

## Related Documents
- [doc-003] Authentication System Design - Overall architecture and feature breakdown" \
  --plan "Implementation background and purpose: Establish secure user authentication foundation
Technical implementation approach: Phased implementation - core auth first, then enhanced security
Required prerequisites: Database schema designed, security requirements documented
Expected deliverables: Working authentication system with all planned features implemented and tested"
```

**Subtask 1:**
```bash
backlog task create "User Registration API Endpoint" \
  --priority high \
  -d "Implement POST /api/auth/register endpoint for new user creation

## Related Documents
- [doc-003] Authentication System Design
- [doc-004] User Schema Definition" \
  --plan "Implementation background and purpose: Allow new users to create accounts
Technical implementation approach: Express.js route with input validation, password hashing with bcrypt
Required prerequisites: User model defined, database connection configured
Expected deliverables: POST /api/auth/register endpoint with validation, duplicate email check, password hashing"
```

**Subtask 2:**
```bash
backlog task create "User Login API Endpoint" \
  --priority high \
  -d "Implement POST /api/auth/login endpoint for user authentication

## Related Documents
- [doc-003] Authentication System Design
- [doc-005] JWT Token Strategy" \
  --plan "Implementation background and purpose: Enable users to authenticate and receive access tokens
Technical implementation approach: Express.js route with password verification and JWT token generation
Required prerequisites: Registration endpoint working, JWT_SECRET configured
Expected deliverables: POST /api/auth/login endpoint with credentials validation and JWT token response"
```

**Subtask 3:**
```bash
backlog task create "Authentication Middleware" \
  --priority high \
  -d "Create middleware to protect routes requiring authentication

## Related Documents
- [doc-003] Authentication System Design
- [doc-005] JWT Token Strategy" \
  --plan "Implementation background and purpose: Protect routes from unauthorized access
Technical implementation approach: Express.js middleware that validates JWT tokens from Authorization header
Required prerequisites: Login endpoint working, JWT token format defined
Expected deliverables: Middleware function that verifies tokens and attaches user to request object"
```

**Why this breakdown is good:**
- Each subtask is one PR
- Clear dependency order (registration → login → middleware)
- Each affects ≤10 files
- Each completable in ~1 day
- Parent task provides overview
- Related documents provide shared context

## Example 4: Documentation Task

### ❌ Bad
```bash
backlog task create "Write docs"
```

**Problems:**
- What docs?
- For what audience?
- What needs to be documented?

### ✅ Good
```bash
backlog task create "API Documentation for Authentication Endpoints" \
  --priority medium \
  -d "Create OpenAPI/Swagger documentation for registration and login endpoints

Endpoints to document:
- POST /api/auth/register
- POST /api/auth/login

## Related Documents
- [doc-002] API Standards - Documentation format requirements" \
  --plan "Implementation background and purpose: Provide clear API documentation for frontend developers
Technical implementation approach: OpenAPI 3.0 specification with request/response examples
Required prerequisites: Endpoints implemented and tested
Expected deliverables: OpenAPI YAML file with complete endpoint documentation, example requests/responses"
```

**Why it's good:**
- Specific scope (which docs)
- Clear deliverable format
- Identifies target audience
- Lists what needs documenting
- Right-sized for one PR

## Example 5: Refactoring Task

### ❌ Bad
```bash
backlog task create "Refactor code" \
  --priority low
```

**Problems:**
- What code?
- Why refactor?
- What's the goal?

### ✅ Good
```bash
backlog task create "Extract User Validation Logic to Separate Module" \
  --priority low \
  -d "User input validation logic is duplicated across registration, login, and profile update endpoints

Current problem: Same validation code in 3 different files
Desired state: Shared validation module used by all endpoints

## Related Documents
- [doc-006] Code Organization Standards - Module structure guidelines" \
  --plan "Implementation background and purpose: Reduce code duplication and improve maintainability
Technical implementation approach: Create validators/user.js with validation functions, update endpoints to use shared validators
Required prerequisites: All endpoints have passing tests
Expected deliverables: validators/user.js module, updated endpoints using shared validators, all tests still passing"
```

**Why it's good:**
- Specific refactoring goal
- Explains the problem being solved
- Clear before/after state
- Measurable success (tests still pass)
- Includes benefit (reduce duplication)

## Key Patterns

### Good Tasks Have:
1. **Specific titles** - Immediately understandable
2. **Context in description** - Why this task exists
3. **Related documents** - Links to relevant knowledge
4. **Complete plan** - All four sections filled out
5. **Right-sized scope** - One PR, ≤10 files, ≤500 lines
6. **Measurable completion** - Clear "done" criteria

### Bad Tasks Have:
1. **Vague titles** - "Fix stuff", "Add feature"
2. **Missing description** - No context
3. **No plan** - Missing required sections
4. **Too large** - Would take weeks
5. **No priority** - Importance unclear
6. **Unclear completion** - When is it done?

## Quick Checklist

Before creating a task, verify:
- [ ] Title is clear and specific
- [ ] Description explains what and why
- [ ] Related documents are linked
- [ ] Plan has all four sections
- [ ] Scope is one PR (≤10 files, ≤500 lines)
- [ ] Priority is set appropriately
- [ ] Success criteria are clear
