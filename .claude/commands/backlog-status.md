---
name: backlog-status
description: Display a live backlog status dashboard — active tasks table with PR state, branch-to-test, and a QA test guide for all Ready-for-Review tasks. No arguments accepted.
---

**Skills:** agent-flow-init-check

# /backlog-status

Run the backlog status script. Follow the steps below in order.

---

## Step 1 — Run the script (first pass)

```bash
bash .claude-agent-flow/scripts/backlog-status.sh 2>/dev/null
```

Capture the output. If the first line is NOT `__MCP_NEEDED__`, skip to Step 3.

---

## Step 2 — Fetch GitHub PR data (only if Step 1 output starts with `__MCP_NEEDED__`)

Parse the lines from the script output:
- `PR_NUMS:<n,m,...>` — comma-separated PR numbers to fetch individually
- `OPEN_PR_LIST:true` — also fetch the open PR list for branch-name matching
- `OWNER:<owner>` / `REPO:<repo>` — repository coordinates

### 2a — Load MCP tools

```
ToolSearch query: "select:mcp__github__pull_request_read,mcp__github__list_pull_requests"
```

### 2b — Fetch each PR number

For each PR number in `PR_NUMS`, call `mcp__github__pull_request_read` with `method: "get"`. Do all calls in parallel. From each result extract:

```
{
  "state":      <"open"|"closed">,
  "merged_at":  <ISO timestamp or null>,
  "closed_at":  <ISO timestamp or null>,
  "updated_at": <ISO timestamp>,
  "head_ref":   <branch name — from head.ref field>,
  "html_url":   <PR URL>
}
```

If a call fails for a specific PR, omit it from the JSON (the script will leave that task's PR columns as `—`).

### 2c — Fetch open PR list (only if `OPEN_PR_LIST:true`)

Call `mcp__github__list_pull_requests` with:
```
owner:    <OWNER>
repo:     <REPO>
state:    "open"
perPage:  30
sort:     "updated"
```

From each result in the list extract the same fields as 2b, plus `"number": <PR number>`. Collect as an array under key `"open_prs"`.

### 2d — Write PR data to temp file and run second pass

Build a single JSON object:
```json
{
  "<pr_num>": { "state": ..., "merged_at": ..., ... },
  "<pr_num>": { ... },
  "open_prs": [ { "state": ..., "head_ref": ..., "number": ..., ... }, ... ]
}
```

Write the JSON to a temp file using:
```bash
python3 -c "
import json
data = <the JSON object as a Python dict literal>
with open('/tmp/backlog-status-pr-data.json', 'w') as f:
    json.dump(data, f)
"
```

Then run the second pass:
```bash
bash .claude-agent-flow/scripts/backlog-status.sh --pr-data-file /tmp/backlog-status-pr-data.json 2>/dev/null
```

Capture this output. This is the final script output.

---

## Step 3 — Replace QA paraphrase placeholders

Scan the script output for lines matching:
```
__QA_PARAPHRASE__:<task-id>:<wmd-lines-tilde-separated>:<title>:<unchecked-ac>
```

For each such line, write 2 short sentences (under 30 words total) summarising what a tester should do. Base it on the `<wmd-lines>` (tilde `~` is a newline separator) and `<title>`. Be terse: one sentence on what to do, one on what passing looks like. No bullet points, no sub-clauses.

Replace the entire `__QA_PARAPHRASE__:...` line with your written paraphrase.

If there are no `__QA_PARAPHRASE__` lines, emit the script output unchanged.

---

## Step 4 — Emit the final output

Print the complete processed output. Do not add any commentary, preamble, or extra headings.
