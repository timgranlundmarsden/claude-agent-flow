---
name: log-visualiser-converter
description: >
  Convert a Claude Code session JSONL log into an enriched visualiser JSON file
  for docs/public/logs/. Runs log_converter.py for the base structure, then enriches
  with correct agent models, brainstorming Q&A (question events), adversarial loop
  transitions, parallel timing, and a story-focused title/subtitle.
---

# Log Visualiser Converter

Convert a Claude Code session log into an enriched `docs/public/logs/<logid>.json` file
for the visualiser page. The user invokes this as a one-liner:

> `/log-visualiser-converter logid="bug-fixes" title="..." subtitle="..."`

Or just `/log-visualiser-converter` and ask the two required questions below.

---

## PII and Anonymization (Mandatory — Step 9a)

Log files are committed to `docs/public/` and served publicly. Session logs contain real
usernames, repo names, file paths, and branch names that MUST be sanitized before saving.

**This is not optional.** Run the sanitization and verification below as part of Step 9,
BEFORE writing the final JSON to `docs/public/logs/`.

### What to sanitize

| Pattern | Replacement | Example |
|---|---|---|
| GitHub org/username | `example-org` | `timuser` → `example-org` |
| Repo name (everywhere — paths, API args, prose) | `my-project` | `secret-app` → `my-project` |
| Branch names with username | `claude/improve-feature` | `claude/improve-github-pages-seo-Y5Tk2` → `claude/improve-feature` |
| GitHub Pages domain | `example-org.github.io/my-project` | `realuser.github.io/real-repo` |
| PR/issue URLs | `example-org/my-project/pull/1` | Real PR URLs |
| Claude session URLs | `claude.ai/code/session_REDACTED` | `claude.ai/code/session_014BtCCUrhk1Auqw...` |
| UUIDs in temp/task paths | `00000000-0000-0000-0000-000000000000` | `d723488b-5d8e-44ce-...` in `/tmp/claude-0/` |
| Subagent task/result hex IDs | `0000000000000000` | `/tasks/aac024b42a82b8d00` |
| Absolute file paths containing `/docs/` | `/site/` | `/docs/public/index.html` → `/site/index.html` |
| Home directory paths (`/Users/...` or `/home/...`) | `/home/user/my-project` | `/Users/tglm/secret-project` |
| Commit hashes (full 40-char) | Truncate to 7 chars or replace | `abc123def456...` |
| Real backlog task IDs | `TASK-1`, `TASK-2`, etc. | `TASK-30` → `TASK-1` |

### How to sanitize

Extract the real org and repo from the git remote, then do a global find-and-replace:

```python
import json, subprocess, re, os

# Auto-detect real values from git remote
remote = subprocess.check_output(['git', 'remote', 'get-url', 'origin'], text=True).strip()
match = re.search(r'[:/]([^/]+)/([^/.]+?)(?:\.git)?$', remote)
real_owner, real_repo = match.group(1), match.group(2) if match else ('', '')

with open(output_path) as f:
    content = f.read()

# ── Phase 1: Targeted patterns (longest/most-specific first) ──
content = content.replace(f'{real_owner}.github.io/{real_repo}', 'example-org.github.io/my-project')
content = content.replace(f'{real_owner}/{real_repo}', 'example-org/my-project')
content = content.replace(real_owner, 'example-org')

# ── Phase 2: Repo name (raw replace catches paths, API args, prose) ──
content = content.replace(real_repo, 'my-project')

# ── Phase 3: Paths ──
content = content.replace('/docs/public/', '/site/')
content = content.replace('/docs/', '/site-root/')
home = os.path.expanduser('~')
content = content.replace(home, '/home/user')

# ── Phase 4: Session URLs, UUIDs, hex IDs ──
content = re.sub(r'claude\.ai/code/session_[A-Za-z0-9]+', 'claude.ai/code/session_REDACTED', content)
content = re.sub(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',
                 '00000000-0000-0000-0000-000000000000', content)
content = re.sub(r'/tasks/[0-9a-f]{15,}', '/tasks/0000000000000000', content)
content = re.sub(r'tool-results/[a-z0-9]{8,}', 'tool-results/redacted', content)

# ── Phase 5: Task IDs (renumber sequentially) ──
task_ids = sorted(set(re.findall(r'TASK-(\d+)', content)), key=int)
for idx, tid in enumerate(task_ids, 1):
    content = content.replace(f'TASK-{tid}', f'TASK-{idx}')

data = json.loads(content)  # Validate JSON survived
with open(output_path, 'w') as f:
    json.dump(data, f, indent=2)
```

### Verification gate (MUST pass before committing)

After sanitization, run these checks. **Do not commit the file if any check fails.**

```bash
LOG_FILE="docs/public/logs/<logid>.json"
REAL_OWNER=$(git remote get-url origin | sed -E 's|.*[:/]([^/]+)/[^/]+$|\1|; s|\.git$||')
REAL_REPO=$(git remote get-url origin | sed -E 's|.*/||; s|\.git$||')
FAIL=0

# 1. No real org/repo names
grep -qi "$REAL_OWNER" "$LOG_FILE" && { echo "FAIL: Real owner '$REAL_OWNER' still present"; FAIL=1; }
grep -q "$REAL_REPO" "$LOG_FILE"   && { echo "FAIL: Real repo '$REAL_REPO' still present"; FAIL=1; }

# 2. No /docs/ absolute paths
grep -q '/docs/' "$LOG_FILE" && { echo "FAIL: /docs/ paths still present"; FAIL=1; }

# 3. No home directory paths (/Users/... or real $HOME)
grep -q '/Users/' "$LOG_FILE" && { echo "FAIL: /Users/ paths still present"; FAIL=1; }
grep -q "$HOME" "$LOG_FILE"   && { echo "FAIL: \$HOME paths still present"; FAIL=1; }

# 4. No Claude session URLs (real session IDs)
grep -qE 'claude\.ai/code/session_[A-Za-z0-9]{10,}' "$LOG_FILE" && { echo "FAIL: Real Claude session URL found"; FAIL=1; }

# 5. Valid JSON
python3 -c "import json; json.load(open('$LOG_FILE'))" || { echo "FAIL: Invalid JSON"; FAIL=1; }

[[ "$FAIL" -eq 0 ]] && echo "PASS: All PII checks clear" || exit 1
```

If any check fails, re-run sanitization with broader patterns until all pass.

> **Tip:** The BATS test suite (tests 70-75) runs the same checks automatically. You can also
> validate by running: `.claude-agent-flow/tests/lib/bats-core/bin/bats --jobs 8 --filter "7[0-5]\." .claude-agent-flow/tests/github-pages.bats`

---

## Configuration

```
COST_MULTIPLIER = 1.5
```

Adjust `COST_MULTIPLIER` to scale the final `estimated_cost` written to the log JSON.
Set to `1.0` for no adjustment. Useful when running through a LiteLLM proxy where token-based
estimates may undercount actual billed cost.

---

## Required inputs

Ask the user if not provided in the invocation:

1. **`logid`** — slug for the output filename (e.g. `bug-fixes`, `auth-refactor`)
2. **`title`** — headline shown in the visualiser (e.g. "Bug Fix: Github Pages Tests")
3. **`subtitle`** — one-line story framing shown below the title (e.g. "Even bug fixes benefit from planning, brainstorming, and adversarial review")

Optional:
- **`session`** — which session to use: `latest` (default), or a specific session ID or `.jsonl` path
- **`parallel-speedup`** — if tests ran with `--jobs N` or similar parallelism, provide the factor (e.g. `8`) to compress the depicted timing

---

## Step 1 — Locate the session log

Find the JSONL log for the current project:

```bash
PROJECT_KEY=$(pwd | sed 's|/|-|g')
SESSION_LOG=$(ls -t ~/.claude/projects/${PROJECT_KEY}/*.jsonl 2>/dev/null | head -1)
echo "Using session log: $SESSION_LOG"
```

If `--session <id>` was specified, use:
```bash
SESSION_LOG="$HOME/.claude/projects/${PROJECT_KEY}/${SESSION_ID}.jsonl"
```

If `--session <path>` is an absolute path, use it directly.

Confirm the file exists before proceeding.

---

## Step 2 — Run log_converter.py

```bash
python3 .claude-agent-flow/scripts/log_converter.py "$SESSION_LOG" > /tmp/log-base.json
```

This produces a base JSON with `title`, `subtitle`, `agents[]`, `transitions[]`, and `events[]`.
The converter uses heuristics — the output will need enrichment (Steps 3–6).

---

## Step 3 — Set title, subtitle, result link, and cost

Edit the root-level fields in the JSON:

```json
{
  "title": "<user-provided title>",
  "subtitle": "<user-provided subtitle>",
  "resultLink": null,
  "estimated_cost": 0.00,
  "duration_minutes": 0
}
```

If there is a PR, commit, or GitHub page URL related to the session work, set `resultLink` to it.
Otherwise leave it `null`.

### Getting the actual cost and duration

**Option 1 — From JSONL `costUSD` (direct Anthropic API only):**

```bash
python3 -c "
import json
total_cost = 0
for line in open('$SESSION_LOG'):
    r = json.loads(line.strip())
    if r.get('costUSD'): total_cost += r['costUSD']
print(f'estimated_cost: {total_cost:.2f}')
"
```

> ⚠️ If the result is `$0.00`, you are likely running through a LiteLLM proxy — `costUSD` is not populated in that case. Use Option 2 instead.

**Option 2 — From token counts via token-analyser (works with LiteLLM proxy):**

```bash
python3 ~/.claude/skills/token-analyser/token-analyser \
  --project-path "$(pwd)" \
  --session <session-id>
```

Read `est_cost_usd` from the output and apply `COST_MULTIPLIER` from the Configuration section above:

```
estimated_cost = est_cost_usd × COST_MULTIPLIER
```

For `duration_minutes`, use the wall-clock elapsed time of the session (start to end timestamp in the JSONL):
```bash
python3 -c "
import json
lines = [json.loads(l) for l in open('$SESSION_LOG') if l.strip()]
ts = [r.get('timestamp') for r in lines if r.get('timestamp')]
if ts:
    from datetime import datetime
    fmt = '%Y-%m-%dT%H:%M:%S.%fZ'
    start = datetime.strptime(min(ts), fmt)
    end = datetime.strptime(max(ts), fmt)
    print(f'duration_minutes: {(end - start).total_seconds() / 60:.1f}')
"
```

Set both fields in the JSON before proceeding.

---

## Step 4 — Fix agent models

The converter defaults all agents to `"model": "opus"`. Set the correct model for each agent
based on what actually ran in the session. Use the agent definitions in `.claude/agents/` to
verify, and cross-reference any model mentions in the session log.

Standard agent-flow model assignments:
| Agent | Typical model |
|---|---|
| orchestrator | sonnet |
| explorer / plan-explorer | haiku |
| ideator | opus |
| architect | opus |
| builder | sonnet |
| critic | opus |
| tester | sonnet |
| reviewer | sonnet |
| author | haiku |
| researcher | sonnet |

Override if the session log or `.claude/agents/<name>.md` shows a different model.

Valid values: `"haiku"`, `"sonnet"`, `"opus"`

---

## Step 5 — Convert AskUserQuestion to `question` events

Every `AskUserQuestion` interaction in the log MUST be converted from raw tool-call/tool-result
pairs into a single structured `question` event. **Raw AskUserQuestion tool-calls must never
appear in the final log** — the visualiser renders them as ugly JSON dumps instead of the
orange Q&A panel.

### 5a. Find AskUserQuestion tool-calls in the base JSON

Look for events with `"kind": "tool-call"` and `"tool": "AskUserQuestion"`. Each will be
followed by a `"kind": "tool-result"` containing the user's answer.

### 5b. Replace each pair with a `question` event

For each `tool-call`/`tool-result` pair:
1. Parse the `args` JSON to extract `questions[0].question`, `questions[0].options`, and `questions[0].multiSelect`
2. Extract the selected answer from the `tool-result` text (format: `"question"="answer"`)
3. **Replace** the `tool-call` event with the `question` event
4. **Delete** the `tool-result` event

The resulting `question` event:

```json
{
  "agent": "<agent-id-who-asked>",
  "kind": "question",
  "question": "What should happen to test 36?",
  "options": [
    { "label": "Invert it", "description": "Assert the workflow DOES exist" },
    { "label": "Remove it", "description": "Delete the test entirely" },
    { "label": "Leave it", "description": "Keep the existing assertion" }
  ],
  "answer": "Invert it"
}
```

For multi-select answers, `"answer"` is an array: `["option-a", "option-b"]`.

### 5c. Verify no raw AskUserQuestion tool-calls remain

After conversion, confirm zero `tool-call` events with `"tool": "AskUserQuestion"` remain in the
events array. The Step 9d validation script checks this automatically.

---

## Step 6 — Fix adversarial loop transitions

The converter may not correctly identify FAIL/PASS transitions between critic and builder.
Look at the session log to determine how many critic loops ran and what the verdicts were.

For each critic FAIL → builder retry transition, set `"type": "fail"`:
```json
{ "id": "t5", "from": "critic", "to": "builder", "type": "fail" }
```

For the final critic PASS → next agent transition, set `"type": "pass"`:
```json
{ "id": "t7", "from": "critic", "to": "tester", "type": "pass" }
```

Normal agent-to-agent transitions use `"type": "normal"` (or omit the field).

---

## Step 7 — Adjust timing for parallel test execution (optional)

If tests ran with parallelism (e.g. `bats --jobs 8`, `pytest -n 8`, `jest --runInBand=false`),
the depicted duration in tester events should reflect the actual wall-clock time, not the
sum of individual test times.

In the tester's `message` events, update the timing text to show the actual parallel runtime.
For example if 52 tests took 11s sequentially but ran `--jobs 8`, show ~1.4s.

Also update the tester command shown in the events to include the parallel flag:
```
bats --jobs 8 .claude-agent-flow/tests/github-pages.bats
```

---

## Step 8 — Add phase events (optional)

If the session had distinct phases (plan, build, review), add `phase` events to give
the log a narrative structure:

```json
{ "agent": "orchestrator", "kind": "phase", "phase": "plan",  "result": "start", "text": "PLAN PHASE" }
{ "agent": "orchestrator", "kind": "phase", "phase": "plan",  "result": "end",   "text": "PLAN COMPLETE" }
{ "agent": "orchestrator", "kind": "phase", "phase": "build", "result": "start", "text": "BUILD PHASE" }
{ "agent": "orchestrator", "kind": "phase", "phase": "build", "result": "end",   "text": "BUILD COMPLETE" }
```

### Phase event conventions (mandatory)

- Phase-end events **must** use `"result": "end"` — never `"complete"` or any other value
- Phase-end text **must** match the phase:
  - `"phase": "plan"` end → `"text": "PLAN COMPLETE"`
  - `"phase": "build"` end → `"text": "BUILD COMPLETE"`
  - `"phase": "review"` end → `"text": "REVIEW COMPLETE"`
- **Never** use `"PIPELINE COMPLETE"` as phase text — it is not a valid phase name and the visualiser will show it verbatim on the done banner

---

## Step 9 — Sanitize, save, and verify

**9a. Sanitize PII** — Run the anonymization script from the "PII and Anonymization" section above.
This is mandatory, not optional. The log file will be publicly served from GitHub Pages.

**9b. Verify PII removal** — Run the verification gate checks. All must pass before saving.

**9c. Save the enriched JSON:**
```bash
cp /tmp/log-enriched.json docs/public/logs/<logid>.json
```

Or write it directly from your edits.

**9d. Validate log schema** — Run this validation script. **Do not commit the file if any check fails.**

```bash
python3 -c "
import json, sys

with open('docs/public/logs/<logid>.json') as f:
    data = json.load(f)

errors = []

# Validate transitions array
tid_set = set()
for i, t in enumerate(data.get('transitions', [])):
    if not t.get('id'):   errors.append(f'transitions[{i}] missing id')
    if not t.get('from'): errors.append(f'transitions[{i}] missing from')
    if not t.get('to'):   errors.append(f'transitions[{i}] missing to')
    if t.get('id'): tid_set.add(t['id'])

# Validate events
for i, ev in enumerate(data.get('events', [])):
    kind = ev.get('kind')
    if not kind or not isinstance(kind, str):
        errors.append(f'events[{i}]: missing or invalid kind')
        continue
    if kind == 'transition':
        tr = ev.get('transition')
        if not tr or not isinstance(tr, str):
            errors.append(f'events[{i}]: transition event must have \"transition\" field (a transition ID like \"t1\"), not \"to\"')
        elif tr not in tid_set:
            errors.append(f'events[{i}]: transition references unknown ID \"{tr}\" (valid: {sorted(tid_set)})')
    elif kind == 'tool-call' and ev.get('tool') == 'AskUserQuestion':
        errors.append(f'events[{i}]: raw AskUserQuestion tool-call found — must be converted to a question event (Step 5)')
    elif kind == 'question':
        if not ev.get('question'): errors.append(f'events[{i}]: question event missing \"question\" text')
        if not ev.get('options'): errors.append(f'events[{i}]: question event missing \"options\" array')
        if not ev.get('answer'): errors.append(f'events[{i}]: question event missing \"answer\"')
    elif kind == 'phase':
        if ev.get('result') == 'end' and ev.get('text') == 'PIPELINE COMPLETE':
            errors.append(f'events[{i}]: phase end must not use \"PIPELINE COMPLETE\" — use e.g. \"BUILD COMPLETE\"')
        if ev.get('result') not in ('start', 'end'):
            errors.append(f'events[{i}]: phase result must be \"start\" or \"end\", got \"{ev.get(\"result\")}\"')

if errors:
    print('FAIL: Log validation errors:')
    for e in errors: print(f'  - {e}')
    sys.exit(1)
else:
    print(f'PASS: Log validated ({len(data[\"events\"])} events, {len(data[\"transitions\"])} transitions)')
"
```

Then verify it loads in the visualiser:
```
docs/public/visualiser.html?logid=<logid>
```

Check that:
- [ ] **PII verification gate passes** (no real usernames, no /docs/ paths, no home dirs)
- [ ] Title and subtitle appear in the hero
- [ ] All agents appear in the flow diagram with correct model badge colours
- [ ] Brainstorming questions render as orange Q&A panels with selected answer highlighted
- [ ] Adversarial loop shows dashed red border with FAIL/PASS arrows
- [ ] Phase-complete banner appears at the end with the correct text (e.g. "BUILD COMPLETE")
- [ ] PASS/FAIL verdict events are green/red with ✅/❌ icons

---

## JSON format reference

Full schema for a visualiser log file:

```json
{
  "title": "string",
  "subtitle": "string",
  "resultLink": "url | null",
  "agents": [
    { "id": "orchestrator", "label": "Orchestrator", "model": "sonnet", "x": 60, "y": 80 }
  ],
  "transitions": [
    { "id": "t1", "from": "orchestrator", "to": "explorer", "type": "normal" },
    { "id": "t5", "from": "critic", "to": "builder",  "type": "fail" },
    { "id": "t7", "from": "critic", "to": "tester",   "type": "pass" }
  ],
  "events": [
    { "agent": "orchestrator", "kind": "activate",    "label": "Orchestrator" },
    { "agent": "orchestrator", "kind": "message",     "text": "Starting pipeline..." },
    { "agent": "orchestrator", "kind": "thinking",    "text": "internal reasoning..." },
    { "agent": "orchestrator", "kind": "tool-call",   "tool": "Bash", "args": "git status" },
    { "agent": "orchestrator", "kind": "tool-result", "text": "..." },
    { "agent": "orchestrator", "kind": "phase",       "phase": "plan",  "result": "start", "text": "PLAN PHASE" },
    { "agent": "orchestrator", "kind": "phase",       "phase": "plan",  "result": "end",   "text": "PLAN COMPLETE" },
    { "agent": "orchestrator", "kind": "transition",  "transition": "t1" },
    { "agent": "critic",       "kind": "verdict",     "verdict": "FAIL", "text": "Two issues found" },
    { "agent": "critic",       "kind": "verdict",     "verdict": "PASS", "text": "All issues resolved" },
    { "agent": "orchestrator", "kind": "pause",       "text": "Awaiting user input" },
    { "agent": "orchestrator", "kind": "user",        "text": "> Yes, go ahead." },
    {
      "agent": "orchestrator",
      "kind": "question",
      "question": "What should happen to test 36?",
      "options": [
        { "label": "Invert it",  "description": "Assert the workflow DOES exist" },
        { "label": "Remove it",  "description": "Delete the test entirely" }
      ],
      "answer": "Invert it"
    }
  ]
}
```

### Event kind reference

| `kind` | Required fields | Notes |
|---|---|---|
| `activate` | `label` | First event for an agent, shows "AGENT ACTIVE" banner |
| `message` | `text` | Plain console output from agent |
| `thinking` | `text` | Shown dimmed/italic, prefixed with `···` |
| `tool-call` | `tool`, `args` | Blue bordered box |
| `tool-result` | `text` | Collapsible result block |
| `verdict` | `verdict` ("PASS"\|"FAIL"\|"UNKNOWN"), `text` | Coloured verdict banner |
| `phase` | `phase` (name, e.g. "plan"\|"build"), `result` ("start"\|"end"), `text` | Orange (start) or green (end) phase banner. End text must be "PLAN COMPLETE" / "BUILD COMPLETE" — never "PIPELINE COMPLETE" |
| `transition` | `transition` | Agent handoff — value is a transition ID (e.g. `"t1"`) from the `transitions[]` array. Advances flow diagram. |
| `pause` | `text` | Pause indicator |
| `user` | `text` | User response in dark yellow, left-bordered |
| `question` | `question`, `options[]`, `answer` | Orange Q&A panel; `answer` is string or array |
