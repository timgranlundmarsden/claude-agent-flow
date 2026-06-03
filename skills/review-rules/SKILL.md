---
name: review-rules
description: >
  Use when reviewing code for correctness, security, performance, or style —
  including /review tasks, PR reviews, and post-build quality passes.
---

# Review Rules

## Severity levels

- **BLOCKER**: must fix before task is done — security issues, data loss, broken functionality, missing tests on new code
- **WARNING**: should fix — degraded performance, style inconsistency, fragile patterns
- **SUGGESTION**: optional — nice-to-have improvements, future refactor candidates

BLOCKERs must be fixed. WARNINGs should be fixed but will not block. SUGGESTIONs are optional.

## Review lenses

Apply all lenses to every review:

- **[SECURITY]** SQL injection, XSS, auth bypass, secrets in code, OWASP Top 10
- **[CORRECTNESS]** Logic errors, null/undefined handling, edge cases, off-by-one
- **[PERFORMANCE]** N+1 queries, unnecessary re-renders, blocking calls, memory leaks
- **[STYLE]** Consistency with conventions and existing codebase patterns
- **[TESTS]** All changed code has tests covering happy path, edge cases, errors, boundary conditions. BLOCKER if new/changed code lacks tests.
- **[RESILIENCE]** CDN/external dependency failure: are independent features isolated in separate script blocks? Do `typeof` guards protect against missing globals? BLOCKER if CDN failure cascades into unrelated functionality.
- **[VISUAL]** For UI changes: was `visual-check.sh` run? WARNING if HTML/CSS changed but no visual verification performed.

## Output format

```
REVIEW COMPLETE
---------------
BLOCKERs (must fix): N
WARNINGs (should fix): N
SUGGESTIONs (optional): N

[BLOCKER-1] file.ts:42 — Description of issue
FIX: Exactly what needs to change

[WARNING-1] file.ts:78 — Description
FIX: What to change
```

Be direct. Do not pad. Do not praise. Only flag real issues.

## Skill composition

`review-rules` is cross-cutting. When combined with domain skills (`frontend-rules`, `backend-rules`), domain-specific constraints take precedence for their respective layers.
