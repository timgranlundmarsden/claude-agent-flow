---
name: frontend-rules
description: >
  Use when the task involves UI components, HTML, CSS, styling, React, Vue,
  Svelte, client-side state, accessibility, or browser APIs.
---

# Frontend Rules

## Design-first principle

Before writing a single line of code, commit to a clear aesthetic direction:
- What tone/aesthetic? (Pick one: brutalist, editorial, retro-futuristic, luxury-refined, etc.)
- What makes this memorable?
- What typography pairing?
- What colour story? (Dominant + sharp accent, using CSS variables)

## Domain boundaries

- Own: UI components, styling, CSS, client-side state, routing, accessibility (WCAG), bundle performance
- Never touch: server code, database logic, infrastructure files
- Note backend dependencies in completion report for coordination

## External script / CDN rules

- **Script isolation:** each independent feature that relies on an external script gets its own `<script>` block — if one CDN fails, unrelated features must still work
- **SRI hashes:** only add `integrity` attributes if you can verify the hash against the real CDN response; unverified SRI silently breaks scripts
- **Error guards:** wrap CDN-dependent code in `typeof` guards (e.g. `if (typeof Chart !== 'undefined')`) so the page degrades gracefully

## Visual verification

After any HTML/CSS change, run `visual-check.sh` at both mobile (375px) and desktop viewports. Do not mark done if layout is broken at either viewport:

```bash
.claude/skills/playwright-cli-helpers/scripts/visual-check.sh path/to/file.html --evidence <task-slug>
```

See `playwright-cli-helpers` skill for full usage.

## Skill composition

These rules are additive. `frontend-rules` is more specific than cross-cutting skills — frontend domain constraints take precedence on UI matters.
