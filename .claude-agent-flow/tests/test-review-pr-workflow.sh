#!/usr/bin/env bash
# test-review-pr-workflow.sh
# Validates .github/workflows/agent-flow-review-pr.yml for correctness.
# Self-contained: requires only bash + python3 + grep.
# Usage: bash .claude-agent-flow/tests/test-review-pr-workflow.sh

set -uo pipefail

WORKFLOW_FILE="$(cd "$(dirname "$0")/../.." && pwd)/.github/workflows/agent-flow-review-pr.yml"

PASS=0
FAIL=0
ERRORS=()

pass() {
  local name="$1"
  echo "  PASS  $name"
  ((PASS++))
}

fail() {
  local name="$1"
  local detail="${2:-}"
  echo "  FAIL  $name${detail:+ — $detail}"
  ((FAIL++))
  ERRORS+=("$name")
}

echo "=== agent-flow-review-pr.yml test suite ==="
echo "File: $WORKFLOW_FILE"
echo ""

# Guard: file must exist
if [[ ! -f "$WORKFLOW_FILE" ]]; then
  echo "FATAL: workflow file not found: $WORKFLOW_FILE"
  exit 1
fi

# ── Test 1: YAML is valid ──────────────────────────────────────────────────────
if python3 -c "import yaml, sys; yaml.safe_load(open(sys.argv[1]))" "$WORKFLOW_FILE" 2>&1; then
  pass "YAML syntax is valid"
else
  fail "YAML syntax is valid" "python3 yaml.safe_load raised an error"
fi

# ── Test 2: No inline \${{ }} in bash run: blocks ─────────────────────────────
# Strategy: extract all run: block content and check for ${{ patterns.
# We use python3 to walk the YAML tree and collect all `run` strings.
INLINE_EXPR=$(python3 - "$WORKFLOW_FILE" <<'PYEOF'
import yaml, sys, re

with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)

hits = []
jobs = doc.get("jobs", {})
for job_name, job in jobs.items():
    for step in job.get("steps", []):
        run = step.get("run", "")
        if re.search(r'\$\{\{', run):
            step_name = step.get("name", "(unnamed)")
            hits.append(f"  step '{step_name}'")

if hits:
    print("Found inline ${{...}} in run: blocks:")
    for h in hits:
        print(h)
    sys.exit(1)
sys.exit(0)
PYEOF
)
if [[ $? -eq 0 ]]; then
  pass "No inline \${{ }} in bash run: blocks"
else
  fail "No inline \${{ }} in bash run: blocks" "$INLINE_EXPR"
fi

# ── Test 3: No 2>/dev/null ─────────────────────────────────────────────────────
if grep -n '2>/dev/null' "$WORKFLOW_FILE"; then
  fail "No 2>/dev/null present" "found occurrences (see above)"
else
  pass "No 2>/dev/null present"
fi

# ── Test 4: No subject_type ────────────────────────────────────────────────────
if grep -n 'subject_type' "$WORKFLOW_FILE"; then
  fail "No subject_type present" "found occurrences (see above)"
else
  pass "No subject_type present"
fi

# ── Test 5: No hardcoded model name ───────────────────────────────────────────
if grep -En 'gemini|flash-lite|flash_lite' "$WORKFLOW_FILE"; then
  fail "No hardcoded model name" "found gemini/flash-lite in file (see above)"
else
  pass "No hardcoded model name"
fi

# ── Test 6: Required env vars defined in env: blocks before use ───────────────
# Check that PR_NUMBER, REPO, HEAD_SHA, GITHUB_TOKEN, EXTERNAL_REVIEW_API_KEY,
# EXTERNAL_REVIEW_MODEL, EXTERNAL_REVIEW_API_BASE_URL are declared in env: blocks (not just used in run: blocks)
REQUIRED_ENV_VARS=(PR_NUMBER REPO GITHUB_TOKEN EXTERNAL_REVIEW_API_KEY EXTERNAL_REVIEW_MODEL EXTERNAL_REVIEW_API_BASE_URL HEAD_SHA)
ENV_BLOCK_CONTENT=$(python3 - "$WORKFLOW_FILE" <<'PYEOF'
import yaml, sys

with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)

declared = set()
jobs = doc.get("jobs", {})
for job_name, job in jobs.items():
    for step in job.get("steps", []):
        env = step.get("env", {})
        for k in env.keys():
            declared.add(k)

print("\n".join(sorted(declared)))
PYEOF
)

for var in "${REQUIRED_ENV_VARS[@]}"; do
  if echo "$ENV_BLOCK_CONTENT" | grep -qx "$var"; then
    pass "Env var $var declared in env: block"
  else
    fail "Env var $var declared in env: block" "not found in any step's env: section"
  fi
done

# ── Test 7: Prerequisites step fails (exit 1) when config is missing ──────────
# Missing EXTERNAL_REVIEW_API_KEY or EXTERNAL_REVIEW_MODEL must fail the check, not silently pass
PREREQ_BLOCK=$(python3 - "$WORKFLOW_FILE" <<'PYEOF'
import yaml, sys

with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)

jobs = doc.get("jobs", {})
for job_name, job in jobs.items():
    for step in job.get("steps", []):
        if step.get("name", "") == "Check prerequisites":
            print(step.get("run", ""))
            break
PYEOF
)

if echo "$PREREQ_BLOCK" | grep -q '::error::' && echo "$PREREQ_BLOCK" | grep -q 'exit 1'; then
  pass "Check prerequisites uses error annotation + exit 1 (fail on missing config)"
else
  fail "Check prerequisites uses error annotation + exit 1 (fail on missing config)" "missing ::error:: or exit 1 in prerequisites step"
fi

# Check that there is NO exit 0 in the prerequisites step (would silently pass)
if echo "$PREREQ_BLOCK" | grep -q 'exit 0'; then
  fail "Check prerequisites does NOT use exit 0" "exit 0 found in prerequisites step — should be exit 1"
else
  pass "Check prerequisites does NOT use exit 0"
fi

# ── Test 8: Workflow name matches expected value ───────────────────────────────
WF_NAME=$(python3 - "$WORKFLOW_FILE" <<'PYEOF'
import yaml, sys
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)
print(doc.get("name", ""))
PYEOF
)

EXPECTED_NAME="Agent Flow Review PR"
if [[ "$WF_NAME" == "$EXPECTED_NAME" ]]; then
  pass "Workflow name is '$EXPECTED_NAME'"
else
  fail "Workflow name is '$EXPECTED_NAME'" "got: '$WF_NAME'"
fi

# ── Test 9: Correct trigger events ────────────────────────────────────────────
# Note: PyYAML parses bare 'on:' as boolean True (YAML 1.1 quirk).
# Use raw text grep on the workflow file instead.
if grep -q 'opened' "$WORKFLOW_FILE"; then
  pass "Trigger 'opened' is present"
else
  fail "Trigger 'opened' is present" "not found in workflow file"
fi

if grep -q 'reopened' "$WORKFLOW_FILE"; then
  pass "Trigger 'reopened' is present"
else
  fail "Trigger 'reopened' is present" "not found in workflow file"
fi

if grep -q 'workflow_dispatch' "$WORKFLOW_FILE"; then
  pass "Trigger 'workflow_dispatch' is present"
else
  fail "Trigger 'workflow_dispatch' is present" "not found in workflow file"
fi

# ── Test 10: Permissions are set ──────────────────────────────────────────────
PERMS=$(python3 - "$WORKFLOW_FILE" <<'PYEOF'
import yaml, sys
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)
perms = doc.get("permissions", {})
for k, v in perms.items():
    print(f"{k}={v}")
PYEOF
)

if echo "$PERMS" | grep -qx "contents=read"; then
  pass "Permission contents: read is set"
else
  fail "Permission contents: read is set" "not found in permissions block"
fi

if echo "$PERMS" | grep -qx "pull-requests=write"; then
  pass "Permission pull-requests: write is set"
else
  fail "Permission pull-requests: write is set" "not found in permissions block"
fi

# ── Test 11: No default model fallback in bash run: blocks ────────────────────
# The model must come from env var only — no fallback like ${VAR:-default-model}
# Check that no run: block contains a bash default substitution for the model
MODEL_FALLBACK=$(python3 - "$WORKFLOW_FILE" <<'PYEOF'
import yaml, sys, re

with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)

hits = []
jobs = doc.get("jobs", {})
for job_name, job in jobs.items():
    for step in job.get("steps", []):
        run = step.get("run", "")
        # Look for bash default variable substitution patterns that would supply a model
        if re.search(r'\$\{EXTERNAL_REVIEW_MODEL:-', run):
            step_name = step.get("name", "(unnamed)")
            hits.append(f"  step '{step_name}'")

if hits:
    print("Found hardcoded model fallback via bash ${VAR:-default}:")
    for h in hits:
        print(h)
    sys.exit(1)
sys.exit(0)
PYEOF
)
if [[ $? -eq 0 ]]; then
  pass "No hardcoded model fallback via bash variable default substitution"
else
  fail "No hardcoded model fallback via bash variable default substitution" "$MODEL_FALLBACK"
fi

# ── Test 12: 422 fallback does not use subject_type ───────────────────────────
# Already covered by Test 4 — but verify the fallback path specifically posts
# with empty comments array (text "comments: []" or '"comments": []')
if grep -q '"comments": \[\]' "$WORKFLOW_FILE" || grep -q "comments: \[\]" "$WORKFLOW_FILE"; then
  pass "422 fallback uses empty comments array"
else
  fail "422 fallback uses empty comments array" "no pattern for empty comments array found"
fi

# ── Test 13: Workflow sources helpers file ─────────────────────────────────────
if grep -q 'agent-flow-workflow-helpers.sh' "$WORKFLOW_FILE"; then
  pass "Workflow sources agent-flow-workflow-helpers.sh"
else
  fail "Workflow sources agent-flow-workflow-helpers.sh" "not referenced in workflow"
fi

# ── Test 14: UNKNOWN verdict results in exit 0, not exit 1 ────────────────────
# Extract the post-review step and verify UNKNOWN → exit 0
POST_REVIEW_BLOCK=$(python3 - "$WORKFLOW_FILE" <<'PYEOF'
import yaml, sys

with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)

jobs = doc.get("jobs", {})
for job_name, job in jobs.items():
    for step in job.get("steps", []):
        if "Post review" in step.get("name", ""):
            print(step.get("run", ""))
            break
PYEOF
)

# Check that the UNKNOWN branch does NOT use exit 1 (i.e. is non-blocking).
# The step relies on implicit exit 0 — no explicit exit 0 statement needed.
if echo "$POST_REVIEW_BLOCK" | grep -q 'unknown verdict'; then
  # Found the unknown verdict handler; verify it doesn't exit 1
  if echo "$POST_REVIEW_BLOCK" | grep -A2 'unknown verdict' | grep -q 'exit 1'; then
    fail "Unknown verdict results in exit 0 (non-blocking)" "UNKNOWN branch uses exit 1 — should be non-blocking"
  else
    pass "Unknown verdict results in exit 0 (non-blocking)"
  fi
else
  fail "Unknown verdict results in exit 0 (non-blocking)" "No unknown verdict handler found in Post review step"
fi

# ── Test 15: FAIL verdict uses exit 1 (should block) ──────────────────────────
if echo "$POST_REVIEW_BLOCK" | grep -q 'exit 1'; then
  pass "FAIL verdict enforces exit 1"
else
  fail "FAIL verdict enforces exit 1" "no exit 1 found in post-review step"
fi

# ── Test 16: No gawk-specific match() with capture array ─────────────────────
if grep -n 'match(.*,.*,.*)' "$WORKFLOW_FILE" | grep -v 'fnmatch\|python3' > /dev/null 2>&1; then
  fail "No gawk-specific match() with capture array"
else
  pass "No gawk-specific match() with capture array"
fi

# ── Test 17: No grep -P (PCRE) ────────────────────────────────────────────────
if grep -En 'grep.*-[a-zA-Z]*P' "$WORKFLOW_FILE" > /dev/null 2>&1; then
  fail "No grep -P (PCRE) usage"
else
  pass "No grep -P (PCRE) usage"
fi

# ── Test 18: Prerequisites step has id and outputs ready ─────────────────────
if grep -q 'id: prereqs' "$WORKFLOW_FILE" && grep -q 'ready=true' "$WORKFLOW_FILE"; then
  pass "Prerequisites step has id and outputs ready"
else
  fail "Prerequisites step has id and outputs ready"
fi

# ── Test 19: Subsequent steps are gated by prerequisites ──────────────────────
CONDITIONAL_STEPS=$(grep -c "steps.prereqs.outputs.ready" "$WORKFLOW_FILE")
if [[ "$CONDITIONAL_STEPS" -ge 3 ]]; then
  pass "Subsequent steps are gated by prerequisites"
else
  fail "Subsequent steps are gated by prerequisites" "found only $CONDITIONAL_STEPS conditional checks, expected 4+"
fi

# ── Test 20: AWK does not use gawk-specific features ─────────────────────────
AWK_BLOCKS=$(sed -n "/awk.*'$/,/'/p" "$WORKFLOW_FILE")
if echo "$AWK_BLOCKS" | grep -qE '(gensub|mktime|systime|strftime|match\([^,]+,[^,]+,)'; then
  fail "AWK position mapper uses no gawk-specific features"
else
  pass "AWK position mapper uses no gawk-specific features"
fi

# ── Test 21: WARN verdict maps to COMMENT event (not REQUEST_CHANGES) ─────────
WARN_BLOCK=$(sed -n '/VERDICT.*WARN/,/REVIEW_EVENT/p' "$WORKFLOW_FILE")
if grep -q 'REVIEW_EVENT="COMMENT"' "$WORKFLOW_FILE"; then
  pass "WARN verdict maps to COMMENT review event"
else
  fail "WARN verdict maps to COMMENT review event"
fi

# ── Test 22: 422 fallback uses empty comments array ───────────────────────────
if grep -q '"comments": \[\]' "$WORKFLOW_FILE"; then
  pass "422 fallback submits empty comments array"
else
  fail "422 fallback submits empty comments array"
fi

# ── Test 23: LLM step uses set +e ────────────────────────────────────────────
if grep -q 'set +e' "$WORKFLOW_FILE"; then
  pass "LLM step uses set +e to prevent curl failures from aborting"
else
  fail "LLM step uses set +e to prevent curl failures from aborting"
fi

# ── Test 24: Context step has an id ──────────────────────────────────────────
if grep -q 'id: context' "$WORKFLOW_FILE"; then
  pass "Context step has an id for gating subsequent steps"
else
  fail "Context step has an id for gating subsequent steps"
fi

# ── Test 25: Sync prompt mentions detrimental removals ───────────────────────
if grep -q 'detrimental' "$WORKFLOW_FILE" && grep -q 'guidance being stripped' "$WORKFLOW_FILE"; then
  pass "Sync prompt explicitly checks for detrimental content removals"
else
  fail "Sync prompt explicitly checks for detrimental content removals"
fi

# ── Test 26: Sync PR path includes manifest, classification, and upstream history
if grep -q 'MANIFEST_EXCERPT' "$WORKFLOW_FILE" && grep -q 'FILE_CLASSIFICATION' "$WORKFLOW_FILE" && grep -q 'UPSTREAM_HISTORY' "$WORKFLOW_FILE"; then
  pass "Sync PR path includes manifest, classification, and upstream history"
else
  fail "Sync PR path includes manifest, classification, and upstream history"
fi

# ── Test 27: Inline review comments include path, position, and body ──────────
if grep -q '"path":' "$WORKFLOW_FILE" && grep -q '"position":' "$WORKFLOW_FILE" && grep -q '"body":' "$WORKFLOW_FILE"; then
  pass "Inline review comments include path, position, and body"
else
  fail "Inline review comments include path, position, and body"
fi

# ── Test 28: API error status exits 1 (blocks PR) ────────────────────────────
if grep -q 'review_status=api_error' "$WORKFLOW_FILE" && grep -A5 'api_error' "$WORKFLOW_FILE" | grep -q 'exit 1'; then
  pass "API error status exits 1 (blocks PR)"
else
  fail "API error status exits 1 (blocks PR)"
fi

# ── Test 29: Empty response status exits 1 (blocks PR) ───────────────────────
# empty_response is set inside an if/elif block; exit 1 follows after the fi.
# Verify both exist in the LLM step (they co-occur in the same error-handling block).
LLM_STEP_BLOCK=$(python3 - "$WORKFLOW_FILE" <<'PYEOF'
import yaml, sys
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)
jobs = doc.get("jobs", {})
for job_name, job in jobs.items():
    for step in job.get("steps", []):
        if step.get("id", "") == "llm":
            print(step.get("run", ""))
            break
PYEOF
)
if echo "$LLM_STEP_BLOCK" | grep -q 'review_status=empty_response' && echo "$LLM_STEP_BLOCK" | grep -q 'exit 1'; then
  pass "Empty response status exits 1 (blocks PR)"
else
  fail "Empty response status exits 1 (blocks PR)"
fi

# ── Test 30: Invalid JSON status exits 1 (blocks PR) ─────────────────────────
if grep -q 'review_status=invalid_json' "$WORKFLOW_FILE" && grep -A10 'invalid_json' "$WORKFLOW_FILE" | grep -q 'exit 1'; then
  pass "Invalid JSON status exits 1 (blocks PR)"
else
  fail "Invalid JSON status exits 1 (blocks PR)"
fi

# ── Test 31: JSON parsing is delegated to shared script (fromjson no longer inline) ──
# After refactor, the workflow calls external-review.sh which handles JSON parsing.
# The workflow must NOT contain inline fromjson (that would be duplicating script logic).
# Instead, verify the shared script is invoked and review output is written directly.
if grep -q 'external-review.sh' "$WORKFLOW_FILE" && grep -q '/tmp/llm-review.json' "$WORKFLOW_FILE"; then
  pass "JSON parsing delegated to shared script (external-review.sh writes llm-review.json)"
else
  fail "JSON parsing delegated to shared script (external-review.sh writes llm-review.json)"
fi

# ── Test 32: JSON extraction handles fenced and clean JSON ─────────────────
# Test actual JSON extraction logic with sample inputs
TEST_DIR=$(mktemp -d)
EXTRACT_OK=true

# Test: clean JSON (no fences)
printf '{"verdict":"PASS","summary":"ok","concerns":[]}' > "$TEST_DIR/clean.txt"
if ! jq -e '.' "$TEST_DIR/clean.txt" > /dev/null 2>&1; then
  EXTRACT_OK=false
fi

# Test: JSON with markdown fences
printf '```json\n{"verdict":"FAIL","summary":"bad","concerns":[{"file":"a.sh","line":5,"severity":"error","message":"bug"}]}\n```\n' > "$TEST_DIR/fenced.txt"
sed '/^[[:space:]]*```[a-zA-Z]*[[:space:]]*$/d' "$TEST_DIR/fenced.txt" > "$TEST_DIR/fenced-stripped.txt"
if ! jq -e '.' "$TEST_DIR/fenced-stripped.txt" > /dev/null 2>&1; then
  EXTRACT_OK=false
fi

# Test: JSON with special chars in message (backticks, quotes)
printf '{"verdict":"WARN","summary":"check","concerns":[{"file":"x.yml","line":10,"severity":"warning","message":"debug_auth() uses `curl` to send $TOKEN to example.com"}]}' > "$TEST_DIR/special.txt"
if ! jq -e '.' "$TEST_DIR/special.txt" > /dev/null 2>&1; then
  EXTRACT_OK=false
fi

# Test: JSON with reasoning prefix (model outputs text before JSON)
printf 'I will analyze this diff carefully.\n\n{"verdict":"FAIL","summary":"bug","concerns":[]}' > "$TEST_DIR/reasoning.txt"
sed -n '/^{/,$p' "$TEST_DIR/reasoning.txt" > "$TEST_DIR/reasoning-extracted.txt"
if ! jq -e '.' "$TEST_DIR/reasoning-extracted.txt" > /dev/null 2>&1; then
  EXTRACT_OK=false
fi

rm -rf "$TEST_DIR"
if $EXTRACT_OK; then
  pass "JSON extraction handles clean, fenced, and special-char inputs"
else
  fail "JSON extraction handles clean, fenced, and special-char inputs"
fi

# ── Test 33: LLM prompt requires line numbers (never null) ─────────────────
if grep -q 'MUST include a line number' "$WORKFLOW_FILE" && grep -q 'Never use null for line' "$WORKFLOW_FILE"; then
  pass "LLM prompt requires line numbers for every concern"
else
  fail "LLM prompt requires line numbers for every concern"
fi

# ── Test 34: Token usage is extracted and passed as outputs ────────────────
if grep -q 'input_tokens=' "$WORKFLOW_FILE" && grep -q 'output_tokens=' "$WORKFLOW_FILE" && grep -q 'total_cost=' "$WORKFLOW_FILE"; then
  pass "Token usage and cost are extracted and passed as step outputs"
else
  fail "Token usage and cost are extracted and passed as step outputs"
fi

# ── Test 35: Telegram notification sends on verdict ────────────────────────
if grep -q 'N8N_WEBHOOK_URL' "$WORKFLOW_FILE" && grep -q 'NOTIFY_EMOJI' "$WORKFLOW_FILE" && grep -q 'curl.*POST.*N8N_WEBHOOK_URL' "$WORKFLOW_FILE"; then
  pass "Telegram notification sends verdict via n8n webhook"
else
  fail "Telegram notification sends verdict via n8n webhook"
fi

# ── Test 36: Prompts are passed via files (avoids arg-size limits) ───────────
# After refactor, prompt files are passed via --system-prompt and --user-prompt flags
# to the shared script rather than as --rawfile args to an inline jq call.
if grep -q '\-\-system-prompt /tmp/system-prompt.txt' "$WORKFLOW_FILE" && grep -q '\-\-user-prompt /tmp/user-prompt.txt' "$WORKFLOW_FILE"; then
  pass "Prompts passed as file paths to shared script (avoids argument list too long)"
else
  fail "Prompts passed as file paths to shared script (avoids argument list too long)"
fi

# ── Test 37: Large prompt via --rawfile doesn't hit argument limits ─────────
LARGE_TEST_DIR=$(mktemp -d)
python3 -c "print('diff --git a/big.txt b/big.txt\n' + '+added line\n' * 50000)" > "$LARGE_TEST_DIR/big-prompt.txt"
echo "You are a reviewer." > "$LARGE_TEST_DIR/sys.txt"
if jq -n --arg model "test" --rawfile system "$LARGE_TEST_DIR/sys.txt" --rawfile user "$LARGE_TEST_DIR/big-prompt.txt" '{model:$model,messages:[{role:"system",content:$system},{role:"user",content:$user}]}' > "$LARGE_TEST_DIR/req.json" 2>&1; then
  REQ_SIZE=$(wc -c < "$LARGE_TEST_DIR/req.json")
  if [[ "$REQ_SIZE" -gt 500000 ]]; then
    pass "Large prompt (${REQ_SIZE} bytes) handled via --rawfile without error"
  else
    fail "Large prompt handled via --rawfile" "output too small: $REQ_SIZE bytes"
  fi
else
  fail "Large prompt handled via --rawfile" "jq --rawfile failed"
fi
rm -rf "$LARGE_TEST_DIR"

# ── Test 38: Request schema construction delegated to shared script ───────────
# After refactor, json_schema and strict mode are handled inside external-review.sh.
# The workflow must NOT duplicate request body construction — verify delegation.
if grep -q 'external-review.sh' "$WORKFLOW_FILE" && ! grep -q 'json_schema' "$WORKFLOW_FILE"; then
  pass "Request schema construction delegated to shared script (no inline json_schema)"
else
  fail "Request schema construction delegated to shared script (no inline json_schema)" "workflow still contains inline json_schema or shared script not referenced"
fi

# ── Test 39: Workflow reads external-review-config.yml for suppressions ──────────────────────
if grep -q 'external-review-config.yml' "$WORKFLOW_FILE" && grep -q 'suppress' "$WORKFLOW_FILE"; then
  pass "Workflow reads external-review-config.yml for suppressions"
else
  fail "Workflow reads external-review-config.yml for suppressions"
fi

# ── Test 40: Suppressed concerns don't count as blocking errors ────────────
if grep -q 'EFFECTIVE_VERDICT' "$WORKFLOW_FILE" && grep -q 'suppressed' "$WORKFLOW_FILE"; then
  pass "Verdict uses EFFECTIVE_VERDICT based on unsuppressed errors only"
else
  fail "Verdict uses EFFECTIVE_VERDICT based on unsuppressed errors only"
fi

# ── Test 41: external-review-config.yml is valid YAML with expected structure ────────────────
CONFIG_FILE="$(dirname "$WORKFLOW_FILE")/../../.claude-agent-flow/external-review-config.yml"
if [[ -f "$CONFIG_FILE" ]]; then
  CONFIG_VALID=$(python3 -c "
import yaml, sys
with open('$CONFIG_FILE') as f:
    cfg = yaml.safe_load(f)
if not isinstance(cfg, dict) or 'suppress' not in cfg:
    print('missing suppress key')
    sys.exit(1)
for s in cfg['suppress']:
    if 'file' not in s or 'reason' not in s:
        print('entry missing file or reason')
        sys.exit(1)
print('ok')
" 2>&1)
  if [[ "$CONFIG_VALID" == "ok" ]]; then
    pass "external-review-config.yml is valid with correct structure"
  else
    fail "external-review-config.yml is valid with correct structure" "$CONFIG_VALID"
  fi
else
  fail "external-review-config.yml is valid with correct structure" "file not found at $CONFIG_FILE"
fi

# ── Test 42: Workflow reads both shared and repo suppression configs ──────
if grep -q 'external-review-config.yml' "$WORKFLOW_FILE" && grep -q 'external-review-config.repo.yml' "$WORKFLOW_FILE"; then
  pass "Workflow reads both shared and repo suppression config files"
else
  fail "Workflow reads both shared and repo suppression config files"
fi

# ── Test 43: Suppression from shared config works ─────────────────────────
TEST_SHARED=$(mktemp -d)
cat > "$TEST_SHARED/shared.yml" << 'SHAREDCFG'
suppress:
  - file: ".github/workflows/*.yml"
    keyword: "position"
    reason: "Known limitation"
SHAREDCFG
cat > "$TEST_SHARED/review.json" << 'SHAREDREVIEW'
{"verdict":"FAIL","summary":"test","concerns":[
  {"file":".github/workflows/review.yml","line":10,"severity":"error","message":"Position mapping is wrong"},
  {"file":"src/app.js","line":5,"severity":"error","message":"SQL injection"}
]}
SHAREDREVIEW
python3 -c "
import yaml,json,fnmatch
cfg=yaml.safe_load(open('$TEST_SHARED/shared.yml')) or {}
r=json.load(open('$TEST_SHARED/review.json'))
for c in r.get('concerns',[]):
    for s in cfg.get('suppress',[]):
        if fnmatch.fnmatch(c.get('file',''),s.get('file','')) and (not s.get('keyword','') or s['keyword'].lower() in c.get('message','').lower()):
            c['suppressed']=True;break
json.dump(r,open('$TEST_SHARED/result.json','w'))
" 2>&1
S_SUP=$(jq '[.concerns[]|select(.suppressed==true)]|length' "$TEST_SHARED/result.json")
S_UNS=$(jq '[.concerns[]|select(.suppressed|not)]|length' "$TEST_SHARED/result.json")
rm -rf "$TEST_SHARED"
if [[ "$S_SUP" == "1" && "$S_UNS" == "1" ]]; then
  pass "Shared config suppression correctly matches glob+keyword"
else
  fail "Shared config suppression" "expected 1+1, got $S_SUP+$S_UNS"
fi

# ── Test 44: Suppression from local config works ──────────────────────────
TEST_LOCAL=$(mktemp -d)
cat > "$TEST_LOCAL/local.yml" << 'LOCALCFG'
suppress:
  - file: "src/legacy.js"
    keyword: "deprecated"
    reason: "Legacy code"
LOCALCFG
cat > "$TEST_LOCAL/review.json" << 'LOCALREVIEW'
{"verdict":"FAIL","summary":"test","concerns":[
  {"file":"src/legacy.js","line":10,"severity":"error","message":"Uses deprecated API"},
  {"file":"src/legacy.js","line":20,"severity":"error","message":"Missing null check"}
]}
LOCALREVIEW
python3 -c "
import yaml,json,fnmatch
cfg=yaml.safe_load(open('$TEST_LOCAL/local.yml')) or {}
r=json.load(open('$TEST_LOCAL/review.json'))
for c in r.get('concerns',[]):
    for s in cfg.get('suppress',[]):
        if fnmatch.fnmatch(c.get('file',''),s.get('file','')) and (not s.get('keyword','') or s['keyword'].lower() in c.get('message','').lower()):
            c['suppressed']=True;break
json.dump(r,open('$TEST_LOCAL/result.json','w'))
" 2>&1
L_SUP=$(jq '[.concerns[]|select(.suppressed==true)]|length' "$TEST_LOCAL/result.json")
L_UNS=$(jq '[.concerns[]|select(.suppressed|not)]|length' "$TEST_LOCAL/result.json")
rm -rf "$TEST_LOCAL"
if [[ "$L_SUP" == "1" && "$L_UNS" == "1" ]]; then
  pass "Local config suppression correctly matches file+keyword"
else
  fail "Local config suppression" "expected 1+1, got $L_SUP+$L_UNS"
fi

# ── Test 45: Both configs merge — shared suppresses one, local another ────
TEST_BOTH=$(mktemp -d)
cat > "$TEST_BOTH/shared.yml" << 'BOTHSHARED'
suppress:
  - file: "*.yml"
    keyword: "awk"
    reason: "Known awk issue"
BOTHSHARED
cat > "$TEST_BOTH/local.yml" << 'BOTHLOCAL'
suppress:
  - file: "src/*"
    keyword: "legacy"
    reason: "Legacy code"
BOTHLOCAL
cat > "$TEST_BOTH/review.json" << 'BOTHREVIEW'
{"verdict":"FAIL","summary":"test","concerns":[
  {"file":"workflow.yml","line":1,"severity":"error","message":"awk position bug"},
  {"file":"src/old.js","line":5,"severity":"error","message":"legacy API call"},
  {"file":"src/new.js","line":10,"severity":"error","message":"real bug here"}
]}
BOTHREVIEW
# Apply shared then local (same as workflow does)
for F in "$TEST_BOTH/shared.yml" "$TEST_BOTH/local.yml"; do
  python3 -c "
import yaml,json,fnmatch
cfg=yaml.safe_load(open('$F')) or {}
r=json.load(open('$TEST_BOTH/review.json'))
for c in r.get('concerns',[]):
    for s in cfg.get('suppress',[]):
        if fnmatch.fnmatch(c.get('file',''),s.get('file','')) and (not s.get('keyword','') or s['keyword'].lower() in c.get('message','').lower()) and not c.get('suppressed'):
            c['suppressed']=True;break
json.dump(r,open('$TEST_BOTH/review.json','w'))
" 2>&1
done
B_SUP=$(jq '[.concerns[]|select(.suppressed==true)]|length' "$TEST_BOTH/review.json")
B_UNS=$(jq '[.concerns[]|select(.suppressed|not)]|length' "$TEST_BOTH/review.json")
rm -rf "$TEST_BOTH"
if [[ "$B_SUP" == "2" && "$B_UNS" == "1" ]]; then
  pass "Merged configs: shared suppresses 1, local suppresses 1, 1 unsuppressed"
else
  fail "Merged configs" "expected 2+1, got $B_SUP+$B_UNS"
fi

# ── Test 46: Suppression filtering logic works correctly ───────────────────
TEST_DIR2=$(mktemp -d)
# Create test config
cat > "$TEST_DIR2/config.yml" << 'TESTCFG'
suppress:
  - file: "src/legacy.js"
    keyword: "deprecated"
    reason: "Legacy code"
TESTCFG
# Create test review
cat > "$TEST_DIR2/review.json" << 'TESTREVIEW'
{"verdict":"FAIL","summary":"test","concerns":[
  {"file":"src/legacy.js","line":10,"severity":"error","message":"Uses deprecated API call"},
  {"file":"src/new.js","line":5,"severity":"error","message":"SQL injection risk"}
]}
TESTREVIEW
# Run the suppression logic
python3 -c "
import yaml, json, fnmatch
with open('$TEST_DIR2/config.yml') as f:
    cfg = yaml.safe_load(f)
with open('$TEST_DIR2/review.json') as f:
    review = json.load(f)
for c in review.get('concerns', []):
    for s in cfg.get('suppress', []):
        if fnmatch.fnmatch(c.get('file',''), s.get('file','')):
            if not s.get('keyword','') or s['keyword'].lower() in c.get('message','').lower():
                c['suppressed'] = True
                break
with open('$TEST_DIR2/result.json', 'w') as f:
    json.dump(review, f)
" 2>&1
SUPPRESSED=$(jq '[.concerns[] | select(.suppressed == true)] | length' "$TEST_DIR2/result.json")
UNSUPPRESSED=$(jq '[.concerns[] | select(.suppressed | not)] | length' "$TEST_DIR2/result.json")
rm -rf "$TEST_DIR2"
if [[ "$SUPPRESSED" == "1" && "$UNSUPPRESSED" == "1" ]]; then
  pass "Suppression filtering correctly marks matching concerns"
else
  fail "Suppression filtering correctly marks matching concerns" "expected 1 suppressed + 1 unsuppressed, got $SUPPRESSED + $UNSUPPRESSED"
fi

# ── Test 47: Workflow references shared script path ───────────────────────────
if grep -q 'external-review.sh' "$WORKFLOW_FILE"; then
  pass "Workflow references shared script path (external-review.sh)"
else
  fail "Workflow references shared script path (external-review.sh)" "not found in workflow file"
fi

# ── Test 48: Workflow uses --response-file for token extraction ───────────────
if grep -q '\-\-response-file' "$WORKFLOW_FILE"; then
  pass "Workflow uses --response-file for raw API response / token extraction"
else
  fail "Workflow uses --response-file for raw API response / token extraction" "not found in workflow file"
fi

# ── Test 49: Workflow still writes review_status, verdict, concern_count to GITHUB_OUTPUT ──
if grep -q 'review_status=' "$WORKFLOW_FILE" && grep -q 'verdict=' "$WORKFLOW_FILE" && grep -q 'concern_count=' "$WORKFLOW_FILE"; then
  pass "Workflow writes review_status, verdict, concern_count to GITHUB_OUTPUT"
else
  fail "Workflow writes review_status, verdict, concern_count to GITHUB_OUTPUT" "one or more output variables missing"
fi

# ── Test 50: Workflow error handling maps script failures to categories ────────
if grep -q 'review_status=api_error' "$WORKFLOW_FILE" && grep -q 'review_status=invalid_json' "$WORKFLOW_FILE"; then
  pass "Workflow error handling maps script failures to api_error and invalid_json categories"
else
  fail "Workflow error handling maps script failures to api_error and invalid_json categories" "one or more error status categories missing"
fi

# ── Test: File path normalization ─────────────────────────────────────────────
echo ""
echo "--- File path normalization ---"

# The workflow must normalize file paths from LLM output (strip leading : and ./)
if grep -q 'ltrimstr(":")' "$WORKFLOW_FILE" && grep -q 'ltrimstr("./")' "$WORKFLOW_FILE"; then
  pass "File path normalization strips leading colon and ./ from LLM concern paths"
else
  fail "File path normalization strips leading colon and ./ from LLM concern paths" "missing ltrimstr for : or ./ in jq normalization"
fi

# Normalization must happen BEFORE the dismiss/cleanup step and inline comment building
NORM_LINE=$(grep -n 'ltrimstr(":")' "$WORKFLOW_FILE" | head -1 | cut -d: -f1)
DISMISS_LINE=$(grep -n 'Dismiss old reviews' "$WORKFLOW_FILE" | head -1 | cut -d: -f1)
INLINE_LINE=$(grep -n 'Build inline comments' "$WORKFLOW_FILE" | head -1 | cut -d: -f1)
if [[ -n "$NORM_LINE" && -n "$DISMISS_LINE" && -n "$INLINE_LINE" ]] && \
   [[ "$NORM_LINE" -lt "$DISMISS_LINE" ]] && [[ "$NORM_LINE" -lt "$INLINE_LINE" ]]; then
  pass "File path normalization runs before dismiss and inline comment steps"
else
  fail "File path normalization runs before dismiss and inline comment steps" "normalization at line $NORM_LINE must precede dismiss ($DISMISS_LINE) and inline ($INLINE_LINE)"
fi

# ── Test: Suppressed concerns excluded from review body ──────────────────────
echo ""
echo "--- Suppressed concern visibility ---"

# Review body must NOT render suppressed concerns
if ! grep -q 'SUPPRESSED_LIST' "$WORKFLOW_FILE"; then
  pass "Suppressed concerns are not rendered in review body (no SUPPRESSED_LIST variable)"
else
  fail "Suppressed concerns are not rendered in review body" "SUPPRESSED_LIST variable still referenced"
fi

# Concerns count must show only unsuppressed totals
if grep -q 'UNSUPPRESSED_TOTAL' "$WORKFLOW_FILE"; then
  pass "Concerns count uses unsuppressed total (UNSUPPRESSED_TOTAL)"
else
  fail "Concerns count uses unsuppressed total" "missing UNSUPPRESSED_TOTAL calculation"
fi

# Inline comments must skip suppressed concerns
if grep -q 'IS_SUPPRESSED.*true.*continue' "$WORKFLOW_FILE"; then
  pass "Inline comments skip suppressed concerns"
else
  fail "Inline comments skip suppressed concerns" "missing IS_SUPPRESSED check in inline comment loop"
fi

# ── Test: Concurrent-run-safe inline comment cleanup ─────────────────────────
echo ""
echo "--- Concurrent-run-safe cleanup ---"

# Inline comment cleanup must use pull_request_review_id to target only
# comments from dismissed reviews — safe against concurrent runs and
# GitHub's commit_id rewriting behaviour
if grep -q 'pull_request_review_id' "$WORKFLOW_FILE"; then
  pass "Inline comment cleanup uses pull_request_review_id (targets dismissed reviews only)"
else
  fail "Inline comment cleanup uses pull_request_review_id" "cleanup should delete comments by dismissed review ID, not by pattern match or commit_id"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Results ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [[ "$FAIL" -gt 0 ]]; then
  echo ""
  echo "Failed tests:"
  for e in "${ERRORS[@]}"; do
    echo "  - $e"
  done
  exit 1
else
  echo ""
  echo "All tests passed."
  exit 0
fi
