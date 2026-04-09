---
name: token-analyser
description: Analyse Claude Code session token costs inline
---

# Token Analyser Skill

Analyse Claude Code session token costs inline. All formatting is done by the CLI — no LLM work required for data crunching or display.

---

## Arguments

- *(none)* — current session (auto-detects `$CLAUDE_SESSION_ID`)
- `--today` — sessions from 00:00 local time today to now
- `--24h` — sessions from exactly 24 hours ago to now (rolling window)
- `--week` — sessions from last 7 days
- `--session <uuid>` — specific session by UUID
- `--models` — add per-model usage breakdown (answers "did agents use different models?")

---

## Step 1 — Run the CLI

**Always include `--breakdown --models`** to produce the richest output by default. Only omit them if the user explicitly asks for a minimal view.

```bash
python3 .claude/skills/token-analyser/token-analyser \
  [--today | --24h | --week | --session <uuid>] \
  --breakdown --models \
  [--project-path <cwd>]
```

> ⚠️ **`--project-path` must be the actual working directory Claude Code was invoked from** (i.e. `$PWD`), not the git root. Defaults to `$PWD` automatically.

Capture and print the full stdout output verbatim — it contains the complete Markdown dashboard.

---

## Step 2 — Display Output

Print the CLI stdout verbatim. The dashboard includes:

- Summary table (model, health, calls, duration, tokens, cost)
- Cost breakdown with bar chart
- Per-call token breakdown (raw input, cache writes, cache reads, output)
- Per-model usage breakdown
- Top issues with severity indicators
- Savings comparison (what cheaper models would have cost)
- For multi-session modes: horizontal session table + worst session narrative

---

## Optional Follow-Up Actions

### Write guidelines to CLAUDE.md

If the user wants to prevent the detected issues going forward:

```bash
python3 .claude/skills/token-analyser/token-analyser \
  [--today | --24h | ...] \
  --write-guidelines
```

Appends applicable token-efficiency guidelines to `<project-path>/CLAUDE.md`. Safe to re-run — uses a marker to avoid duplicates.

### Save a full Markdown report

```bash
python3 .claude/skills/token-analyser/token-analyser \
  [--today | --24h | ...] \
  --report
```

Saves to `.claude/reports/token-analyser-YYYY-MM-DD-HH-MM.md` and opens the file on macOS.

### Per-model usage breakdown

Included by default (`--models`). Shows a **MODEL BREAKDOWN** table with calls/tokens/cost per model and warns if all calls used a single model — indicating that agent `model:` frontmatter overrides are not being applied (subagents inherit the parent session model).

### Per-call token breakdown

Included by default (`--breakdown`). Shows a **CALL BREAKDOWN** table with each API call: raw (uncached) input, cache writes (new tokens written to cache), cache reads (tokens reused from cache), total context Claude saw, and output. Annotates the call with the largest cache write spike.

### Debug / raw data

```bash
python3 .claude/skills/token-analyser/token-analyser --json
```

Outputs raw JSON from the underlying `parse-logs.py` parser.

---

## Notes

- `parse-logs.py` lives alongside this CLI in the same skill directory
- Subagent files live at `~/.claude/projects/<encoded>/subagents/*.jsonl`
- The parser itself costs <$0.01 to run (compact JSON, no file reads into LLM)
- The CLI is zero additional LLM cost — all formatting is deterministic Python
