---
name: testing-rules
description: >
  Use when writing, reviewing, or validating tests — including unit tests,
  integration tests, BATS tests, and visual verification tasks.
---

# Testing Rules

## Tests for behaviour, not phrasing

**This is the canonical home of the "tests for behaviour, not phrasing" rule.**

Do not assert that a markdown file contains a specific word. Do not test that a file exists when the next operation would fail loudly if missing. Do not write 20 tests for a README section. Match test depth to change risk: new modules need real coverage; trivial edits need none.

Every test must exercise one of:
- Real observable behaviour
- A known regression (proven by a bug that actually occurred)
- A silent-failure invariant (something that fails quietly without a test)

## Proportional coverage

| Change type | Required coverage |
|---|---|
| New file or module | happy path + edge cases + error states — FAIL if missing |
| Bug fix | regression test that proves the bug is fixed — WARN if absent, do NOT REJECT |
| Small edit / refactor | coverage gaps are WARNINGs, not blockers |
| Trivial one-liner | no test required |

## Full suite always

Always run the full test suite — never scope to changed files only. The goal is to catch regressions across the entire codebase.

BATS command: `.claude-agent-flow/tests/lib/bats-core/bin/bats --jobs 8 .claude-agent-flow/tests/*.bats`

## Diagnose before fixing

When a test fails, diagnose the root cause first:
- **Genuine code bug** → fix the code, not the test
- **Incorrect or incomplete test** → fix the test

Never blindly update a test to make it pass — a green suite built on weakened assertions is worse than a red one.

## Visual verification (UI tasks)

After any HTML/CSS change, run `visual-check.sh` at mobile (375px) and desktop viewports. Report pass/fail as part of test results. See `playwright-cli-helpers` skill.

## Skill composition

`testing-rules` is cross-cutting. It applies to all test writing and review regardless of domain. Domain skills (`frontend-rules`, `backend-rules`) do not override testing rules.

## Test-suite bloat rubric (DELETE / CONSOLIDATE / KEEP)

Use this explicit rubric when editing or reviewing tests:

1. **DELETE**
   - Delete tests that only grep literal phrases in markdown/docs.
   - Delete tests that only assert `[[ -f path ]]` with no behavioral follow-up.
   - Delete tests that lock in headings, section names, or exact prose.

2. **CONSOLIDATE**
   - Collapse repeated test shapes into list-driven loops (e.g. `N` near-identical file checks).
   - Consolidated tests must print failing entry context (which term/file/item failed).
   - Prefer one helper in `test_helper.bash` over duplicate loop logic across files.

3. **KEEP**
   - Keep tests that run scripts/commands and assert status, output, side effects.
   - Keep known regression tests tied to real bugs.
   - Keep silent-failure invariants where breakage would otherwise go unnoticed.

### Worked examples

- **DELETE example:** 12 tests each doing `grep -q 'literal phrase' README.md`.
- **CONSOLIDATE example:** 9 separate "X.html exists" tests become one loop over an array of required files that prints the missing file.
- **KEEP example:** A test that runs `resolve-task.sh`, verifies exit code, and checks parsed output fields.
