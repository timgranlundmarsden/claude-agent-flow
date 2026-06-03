---
name: author-rules
description: >
  Use when updating documentation, README sections, CHANGELOG entries, docstrings,
  or CLAUDE.md conventions after a feature is complete.
---

# Author Rules

## Write for the next developer

Write documentation for the developer who comes next — not the one who just built the feature. Assume they have no context from this session.

## CHANGELOG format

Append a row using this markdown table format:

```
| Date & Time         | Type    | Description |
|---------------------|---------|-------------|
| YYYY-MM-DD HH:MM:SS | Added   | ... |
```

Run `date '+%Y-%m-%d %H:%M:%S'` to get the current timestamp. Type is one of: `Added`, `Changed`, `Fixed`, `Removed`. If the table header doesn't exist, add it first.

## Writing style

- Plain present tense: "Adds X", "Fixes Y", "Removes Z"
- No padding. No filler. No "this was implemented to..."
- No references to the current task, issue number, or PR (those belong in git history)
- Short entries — one line per change is the target

## Scope

- Update README sections if public-facing behaviour changed
- Add/update JSDoc or docstrings on all changed functions and classes
- Append CHANGELOG entry
- Update CLAUDE.md only if new cross-cutting conventions were established
- Do NOT touch source code

## Skill composition

`author-rules` governs documentation. It is always invoked last (after review). Domain skills do not override authoring rules.
