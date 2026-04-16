---
name: backlog-status
description: "Display a live backlog status dashboard — active tasks table with PR state and branch-to-test. Optional flag: --qa also generates a QA test guide for all Ready-for-Review tasks."
---

**Skills:** agent-flow-init-check

# /backlog-status

Run the backlog status script. Follow the steps below in order.

---

## Step 1 — Run the script (first pass)

```bash
bash .claude-agent-flow/scripts/backlog-status.sh 2>/dev/null > /tmp/backlog-status-output.txt; head -1 /tmp/backlog-status-output.txt
```

If the output is NOT `__MCP_NEEDED__`, skip to Step 3.

If the output IS `__MCP_NEEDED__`, read the full metadata:

```bash
cat /tmp/backlog-status-output.txt
```

---

## Step 2 — Fetch GitHub PR data (only if Step 1 output starts with `__MCP_NEEDED__`)

Parse the lines from the script output:
- `PR_NUMS:<n,m,...>` — comma-separated PR numbers to look up
- `OPEN_PR_LIST:true` — also need open PR list for branch-name matching
- `TASKS_NO_PR:<n,m,...>` — task numbers with no known PR; search by title
- `OWNER:<owner>` / `REPO:<repo>` — repository coordinates

### 2a — Load MCP tools

```
ToolSearch query: "select:mcp__github__pull_request_read,mcp__github__list_pull_requests,mcp__github__search_pull_requests"
```

**If ToolSearch returns no tools**, write an empty JSON object and skip to Step 2d:
```bash
echo '{}' > /tmp/backlog-status-pr-data.json
bash .claude-agent-flow/scripts/backlog-status.sh --pr-data-file /tmp/backlog-status-pr-data.json 2>/dev/null > /tmp/backlog-status-output.txt
```
Then skip to Step 3. The table will show `—` for all PR columns.

### 2b — Fetch known PR numbers (single parallel batch)

**Issue ALL `mcp__github__pull_request_read` calls at the same time in one message — never one at a time.**

For every PR number in `PR_NUMS`, include one `mcp__github__pull_request_read` call in the same message:
```
owner:  <OWNER>
repo:   <REPO>
pullNumber: <N>
```

All calls resolve in parallel (one network round-trip). From each result extract:
```
{
  "state":      <"open"|"closed">,
  "merged_at":  <merged_at or null>,
  "closed_at":  <closed_at or null>,
  "updated_at": <updated_at>,
  "head_ref":   <head.ref>,
  "html_url":   <html_url>
}
```

If a call fails for a specific PR, omit it (the script shows `—` for that row).

### 2c — Fetch open PR list + search unlinked tasks (single parallel batch)

**Issue all of the following calls at the same time in one message:**

- If `OPEN_PR_LIST:true`: one `mcp__github__list_pull_requests` call:
  ```
  owner: <OWNER>, repo: <REPO>, state: "open", perPage: 30, sort: "updated"
  ```
  From each result extract the same fields as 2b plus `"number"` and `"title"`. Collect as `open_prs` array.

- For each task number N in `TASKS_NO_PR`: one `mcp__github__search_pull_requests` call:
  ```
  owner: <OWNER>, repo: <REPO>, query: "TASK-N in:title"
  ```
  Skip results whose title starts with `"Create "`. Take the first remaining result and extract the same fields as 2b plus `"number"` and `"title"`. Append to `open_prs`.

If neither `OPEN_PR_LIST:true` nor `TASKS_NO_PR` is present, skip this step entirely.

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

Then run the second pass, saving to the output file:
```bash
bash .claude-agent-flow/scripts/backlog-status.sh --pr-data-file /tmp/backlog-status-pr-data.json 2>/dev/null > /tmp/backlog-status-output.txt
```

---

## Step 3 — Emit table, then optionally emit QA section

Do not output any commentary, reasoning, or preamble. The first character of your response text must be the start of the table content.

### 3a — Emit the table

```bash
awk '/^## Still Pending Review/{exit} {print}' /tmp/backlog-status-output.txt
```

Copy the bash output above verbatim as your response text. Do not add, remove, or change anything.

### 3b — Emit the QA section (only if `--qa` was passed)

If the invocation did **not** include `--qa`, stop here.

If `--qa` was passed, read the QA section:

```bash
awk '/^## Still Pending Review/,0' /tmp/backlog-status-output.txt
```

If this produces no output, stop here.

Otherwise, scan for lines matching:
```
__QA_PARAPHRASE__:<task-id>:<wmd-lines-tilde-separated>:<title>:<unchecked-ac>
```
For each such line, write 2 short sentences (under 30 words total) summarising what a tester should do. Base it on the `<wmd-lines>` (tilde `~` is a newline separator) and `<title>`. Be terse: one sentence on what to do, one on what passing looks like. No bullet points, no sub-clauses. Replace the entire `__QA_PARAPHRASE__:...` line with your written paraphrase.

Output the modified QA section as text with no preamble or commentary. If there are no `__QA_PARAPHRASE__` lines, output it unchanged.
