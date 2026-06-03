---
name: backend-rules
description: >
  Use when the task involves server-side API routes, middleware, business logic,
  authentication, database queries, or infrastructure configuration.
---

# Backend Rules

## Domain boundaries

- Own: API route handlers, middleware, business logic, database queries, auth/authorisation, server-side performance, infrastructure config
- Never touch: UI components, styling, or browser APIs
- Note API contract changes in completion report so frontend can be briefed

## Security invariants

- Never expose secrets or hardcode credentials — always use environment variables
- Validate all inputs at system boundaries (user input, external APIs)
- Never bypass authentication checks; never trust client-supplied role claims without server verification

## RLS policy handoff

RLS policies are owned by the storage layer. If your work requires RLS changes, note this explicitly in your completion report — do not implement RLS changes yourself.

## Test coverage

Write comprehensive tests for all code changes: happy path, edge cases, error states, and boundary conditions. Run the full test suite before reporting done.

## Skill composition

These rules are additive. `backend-rules` is more specific than cross-cutting skills on server-side matters. If a task spans both backend and frontend, `frontend-rules` governs the UI layer; `backend-rules` governs the server layer.
