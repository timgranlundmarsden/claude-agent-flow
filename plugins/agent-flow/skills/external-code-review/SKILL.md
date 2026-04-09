---
name: external-code-review
description: Run code review via an external LLM API using external-review.sh. Outputs structured JSON with verdict, summary, and per-file concerns.
---

# External Code Review Skill

Run code review via an external LLM API using the bundled `external-review.sh` script. Outputs structured JSON with a verdict, summary, and per-file concerns.

---

## Environment Variables

All three variables must be available before calling the script. Resolution order: (1) check if already set in the environment, (2) source `.env` from the repo root if any are missing. For Claude Code web, set them in environment variables (.env format) in cloud environment settings.

| Variable | Required | Description |
|---|---|---|
| `EXTERNAL_REVIEW_API_KEY` | Yes | API key for the external review LLM provider |
| `EXTERNAL_REVIEW_MODEL` | Yes | Model ID, e.g. `openai/gpt-4o-mini` |
| `EXTERNAL_REVIEW_API_BASE_URL` | Yes | Base URL for the external review API (e.g. `https://openrouter.ai/api/v1`) |

Configure Custom network access with domain allowlist for your API provider

---

## Script Interface

```
.claude/skills/external-code-review/external-review.sh \
  --diff-file <path> \
  [--system-prompt <path>] \
  [--user-prompt <path>] \
  [--repo-name <name>] \
  [--response-file <path>]
```

| Argument | Required | Description |
|---|---|---|
| `--diff-file` | Yes | Path to the diff file to review |
| `--system-prompt` | No | Path to system prompt file. Defaults to `.claude/skills/external-code-review/external-review-system-prompt.md` |
| `--user-prompt` | No | Path to user prompt file. When omitted, constructs prompt from diff content |
| `--repo-name` | No | Repository name for HTTP-Referer header |
| `--response-file` | No | Path to save raw API response JSON (for callers that need token usage data) |
| `--suppress-config` | No | Path to YAML suppress config file (repeatable). Entries matching file glob + keyword are marked as suppressed in the output. |

All errors go to stderr. Exit 0 on success, exit 1 on failure.

---

## Output Format

JSON to stdout:

```json
{
  "verdict": "PASS|WARN|FAIL",
  "summary": "...",
  "concerns": [
    {
      "file": "path/to/file",
      "line": 42,
      "severity": "error|warning|info",
      "message": "Description of concern",
      "suppressed": true,
      "suppress_reason": "Why this is accepted"
    }
  ]
}
```

When `--suppress-config` is provided, the verdict is recalculated based on unsuppressed concerns only. Suppressed concerns remain in the output with `suppressed: true` for transparency.

---

## Suppression Config Format

YAML files with a `suppress` list. Both file AND keyword must match for a concern to be suppressed:

```yaml
suppress:
  - file: "src/legacy/*.js"       # Glob pattern (fnmatch)
    keyword: "deprecated API"      # Case-insensitive substring match
    reason: "Legacy code scheduled for removal"
```

Two standard config files:
- `.claude-agent-flow/external-review-config.yml` — shared across repos (synced downstream)
- `external-review-config.repo.yml` — repo-specific suppressions (not synced)

---

## Step 1 — Run a Standalone Review

Generate a diff and call the script:

```bash
MERGE_BASE=$(git merge-base HEAD main)
git diff "$MERGE_BASE"...HEAD > /tmp/branch.diff
bash .claude/skills/external-code-review/external-review.sh \
  --diff-file /tmp/branch.diff \
  --suppress-config .claude-agent-flow/external-review-config.yml \
  --suppress-config external-review-config.repo.yml
```

---

## Step 2 — Parse the Output

Parse results with `jq`:

```bash
RESULT=$(bash .claude/skills/external-code-review/external-review.sh \
  --diff-file /tmp/branch.diff \
  --suppress-config .claude-agent-flow/external-review-config.yml \
  --suppress-config external-review-config.repo.yml)
VERDICT=$(echo "$RESULT" | jq -r '.verdict')
CONCERNS=$(echo "$RESULT" | jq -r '.concerns | length')
```

---

## Graceful Degradation

If `EXTERNAL_REVIEW_API_KEY`, `EXTERNAL_REVIEW_MODEL`, or `EXTERNAL_REVIEW_API_BASE_URL` are missing, or if the API call fails, the script exits 1 with an error message on stderr. Callers should capture stderr and handle gracefully — skip the external review and proceed with internal review only.

---

## Claude Code Web Setup

1. Set `EXTERNAL_REVIEW_API_KEY`, `EXTERNAL_REVIEW_MODEL`, and `EXTERNAL_REVIEW_API_BASE_URL` in environment variables (.env format) in Claude Code web cloud environment settings
2. Configure Custom network access with domain allowlist for your API provider
