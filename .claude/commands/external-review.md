---
name: external-review
description: >
  Run a single external code review via an external LLM API on the full branch diff vs main.
  Standalone usage — no aggregation with internal review.
---

**Skills:** agent-flow-init-check

$ARGUMENTS

If `$ARGUMENTS` is empty/whitespace, or contains `--help` as a standalone word, output the following verbatim and STOP:

    Usage: /external-review [--help]

    Run a single external code review via an external LLM API on the full branch diff vs main.

    Flags:
      --help                  Show this help text and exit

    Environment variables (required):
      EXTERNAL_REVIEW_API_KEY      External review API key
      EXTERNAL_REVIEW_MODEL        Model ID (e.g. openai/gpt-4o-mini)
      EXTERNAL_REVIEW_API_BASE_URL Base URL for the external review API

    Output: JSON with verdict, summary, and concerns list.

If you output the help text above, stop here — do not read or execute anything below this line.

## Instructions

Run a single external code review on the current branch diff vs main.

### Step 1 — Generate diff

```bash
MERGE_BASE=$(git merge-base HEAD main 2>&1 || git merge-base HEAD master 2>&1)
git diff "$MERGE_BASE"...HEAD > /tmp/external-review-diff.txt
```

If MERGE_BASE is empty, starts with `fatal:`, or contains multi-line error output, report "Could not determine merge base — ensure branch has diverged from main or master" and stop.

If the diff is empty, report "No changes found on this branch vs main" and stop.

### Step 2 — Call the review script

```bash
GIT_ROOT=$(git rev-parse --show-toplevel)
RESULT=$(bash "$GIT_ROOT/.claude/skills/external-code-review/external-review.sh" \
  --diff-file /tmp/external-review-diff.txt \
  --suppress-config "$GIT_ROOT/.claude-agent-flow/external-review-config.yml" \
  --suppress-config "$GIT_ROOT/external-review-config.repo.yml" \
  2>/tmp/external-review-err.txt) || true
```

### Step 3 — Handle result

If the script failed (empty RESULT or non-zero exit):
- Read `/tmp/external-review-err.txt` for error details
- Report the error to the user: "External review failed: <error details>"
- Stop

If the script succeeded:
- Parse the JSON result
- Display in this format:

```
EXTERNAL REVIEW COMPLETE
------------------------
Verdict: PASS/WARN/FAIL
Summary: <summary text>

Concerns (N unsuppressed):
  [severity] file:line — message
  [severity] file:line — message
  ...
```

- Only unsuppressed concerns are shown — suppressed concerns are completely hidden
- The verdict reflects only unsuppressed concerns (already recalculated by the script)
