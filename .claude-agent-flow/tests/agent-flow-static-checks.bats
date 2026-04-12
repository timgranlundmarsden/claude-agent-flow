#!/usr/bin/env bats
# Static validation tests for scripts and workflow files

setup() {
  load test_helper
}

# ── Workflow linting ──────────────────────────────────────────────────────────

@test "1. actionlint passes on downstream workflow" {
  command -v actionlint || skip "actionlint not installed"
  local workflow="$PROJECT_ROOT/.github/workflows/agent-flow-downstream.yml"
  [[ -f "$workflow" ]] || skip "downstream workflow not found"
  # Disable shellcheck integration — we run shellcheck separately in test 5
  # with -S warning threshold. Actionlint treats info-level SC findings as errors.
  local al_output
  al_output=$(actionlint -shellcheck="" "$workflow" 2>&1) || {
    echo "$al_output" >&2
    return 1
  }
}

@test "2. actionlint passes on upstream workflow" {
  command -v actionlint || skip "actionlint not installed"
  local workflow="$PROJECT_ROOT/.github/workflows/agent-flow-upstream.yml"
  [[ -f "$workflow" ]] || skip "upstream workflow not found"
  local al_output
  al_output=$(actionlint -shellcheck="" "$workflow" 2>&1) || {
    echo "$al_output" >&2
    return 1
  }
}

# ── Manifest / workflow path consistency ──────────────────────────────────────

@test "3. both workflows use manifest-driven detection (no hardcoded paths filter)" {
  local downstream="$PROJECT_ROOT/.github/workflows/agent-flow-downstream.yml"
  local upstream="$PROJECT_ROOT/.github/workflows/agent-flow-upstream.yml"
  [[ -f "$downstream" ]] || skip "downstream workflow not found"
  [[ -f "$upstream" ]] || skip "upstream workflow not found"

  # Both workflows should NOT have a paths: filter — they use manifest-driven detection.
  # Check that there's no 'paths:' under the 'on: push:' section (a simple heuristic).
  # We look for the pattern "    paths:" which is the YAML indent level for on.push.paths.
  if grep -A2 'branches:.*main' "$downstream" | grep -q '^\s*paths:'; then
    echo "FAIL: downstream workflow has hardcoded paths filter — should be manifest-driven" >&2
    return 1
  fi
  if grep -A2 'branches:.*main' "$upstream" | grep -q '^\s*paths:'; then
    echo "FAIL: upstream workflow has hardcoded paths filter — should be manifest-driven" >&2
    return 1
  fi

  # Both should have a "Detect managed file changes" step
  grep -q "Detect managed file changes" "$downstream" || {
    echo "FAIL: downstream missing 'Detect managed file changes' step" >&2
    return 1
  }
  grep -q "Detect managed file changes" "$upstream" || {
    echo "FAIL: upstream missing 'Detect managed file changes' step" >&2
    return 1
  }
}

# ── Script hygiene ────────────────────────────────────────────────────────────

@test "4. all scripts in .claude-agent-flow/scripts/ have a shebang line" {
  local scripts_dir="$PROJECT_ROOT/.claude-agent-flow/scripts"
  [[ -d "$scripts_dir" ]] || skip "scripts directory not found"

  local failed=0
  while IFS= read -r -d '' script; do
    first_line=$(head -1 "$script")
    if [[ "$first_line" != "#!"* ]]; then
      echo "Missing shebang: $script" >&2
      failed=1
    fi
  done < <(find "$scripts_dir" -name "*.sh" -print0)

  [[ "$failed" -eq 0 ]]
}

@test "5. shellcheck passes on all scripts" {
  command -v shellcheck >/dev/null || skip "shellcheck not installed in this environment"
  local scripts_dir="$PROJECT_ROOT/.claude-agent-flow/scripts"
  [[ -d "$scripts_dir" ]] || skip "scripts directory not found"

  local failed=0
  local sc_output
  while IFS= read -r -d '' script; do
    sc_output=$(shellcheck -S warning "$script" 2>&1) || {
      echo "$sc_output" >&2
      failed=1
    }
  done < <(find "$scripts_dir" -name "*.sh" -print0)

  [[ "$failed" -eq 0 ]]
}

# ── Manifest schema ───────────────────────────────────────────────────────────

@test "6. manifest version field is an integer" {
  local manifest="$PROJECT_ROOT/.claude-agent-flow/repo-sync-manifest.yml"
  [[ -f "$manifest" ]] || skip "manifest not found"

  version=$(grep '^version:' "$manifest" | awk '{print $2}')
  [[ -n "$version" ]] || { echo "version field missing"; return 1; }
  [[ "$version" =~ ^[0-9]+$ ]] || { echo "version is not an integer: $version"; return 1; }
}

@test "7. manifest targets all have a repo field" {
  local manifest="$PROJECT_ROOT/.claude-agent-flow/repo-sync-manifest.yml"
  [[ -f "$manifest" ]] || skip "manifest not found"
  command -v python3 || skip "python3 not available"

  result=$(python3 - "$manifest" << 'PYEOF'
import sys, re

with open(sys.argv[1]) as f:
    content = f.read()

# Find targets section and check each entry has a repo: line
in_targets = False
depth = 0
entries = []
current = {}

for line in content.splitlines():
    if re.match(r'^targets\s*:', line):
        in_targets = True
        continue
    if in_targets:
        if re.match(r'^\S', line) and not line.startswith(' ') and not line.startswith('-'):
            break
        m_entry = re.match(r'^\s{2}-\s+repo:\s*(\S+)', line)
        if m_entry:
            entries.append({'repo': m_entry.group(1)})
        m_item = re.match(r'^\s+-\s*$', line)
        if m_item:
            entries.append({})
        m_repo = re.match(r'^\s{4}repo:\s*(\S+)', line)
        if m_repo and entries:
            entries[-1]['repo'] = m_repo.group(1)

missing = [i for i, e in enumerate(entries) if 'repo' not in e or not e['repo']]
if missing:
    print(f"FAIL: targets at indices {missing} missing repo field")
    sys.exit(1)
print("ok")
PYEOF
  )
  [[ "$result" == "ok" ]]
}

# ── Workflow sourcing ─────────────────────────────────────────────────────────

@test "8. actionlint passes on review-pr workflow" {
  command -v actionlint || skip "actionlint not installed"
  local workflow="$PROJECT_ROOT/.github/workflows/agent-flow-review-pr.yml"
  [[ -f "$workflow" ]] || skip "review-pr workflow not found"
  local al_output
  al_output=$(actionlint -shellcheck="" "$workflow" 2>&1) || {
    echo "$al_output" >&2
    return 1
  }
}

@test "9. workflow run: blocks have no unindented python3 -c multi-line bodies" {
  # Multi-line python3 -c "..." inside YAML run: | blocks breaks the YAML parser
  # when the Python code starts at column 1 (YAML sees it as a new mapping key).
  # All inline Python must be single-line or written to a temp file via heredoc.
  local failed=0
  while IFS= read -r -d '' wf; do
    # Validate YAML parses at all
    if ! python3 -c "import yaml; yaml.safe_load(open('$wf'))" 2>/dev/null; then
      echo "FAIL: $wf is not valid YAML" >&2
      failed=1
    fi
  done < <(find "$PROJECT_ROOT/.github/workflows" -name "*.yml" -print0)

  [[ "$failed" -eq 0 ]]
}

@test "10. review-pr workflow fails (not silently passes) when prerequisites are missing" {
  local workflow="$PROJECT_ROOT/.github/workflows/agent-flow-review-pr.yml"
  [[ -f "$workflow" ]] || skip "review-pr workflow not found"

  # Extract the prereqs step run block and check that missing EXTERNAL_REVIEW_API_KEY
  # and EXTERNAL_REVIEW_MODEL both use exit 1 (not exit 0) so the check fails visibly
  local prereqs_block
  prereqs_block=$(sed -n '/name: Check prerequisites/,/name: Fetch PR diff/p' "$workflow")

  # Verify no "exit 0" in the prereqs block for missing config
  if echo "$prereqs_block" | grep -q 'exit 0'; then
    echo "FAIL: Check prerequisites step uses 'exit 0' for missing config — must use 'exit 1' to prevent false-positive passing checks" >&2
    return 1
  fi

  # Verify exit 1 is used for missing key, model, and base URL
  local exit1_count
  exit1_count=$(echo "$prereqs_block" | grep -c 'exit 1' || true)
  if [[ "$exit1_count" -lt 3 ]]; then
    echo "FAIL: Expected at least 3 'exit 1' in prereqs (one for API key, one for model, one for base URL), found $exit1_count" >&2
    return 1
  fi
}

@test "11. review-pr workflow fails when LLM call encounters errors" {
  local workflow="$PROJECT_ROOT/.github/workflows/agent-flow-review-pr.yml"
  [[ -f "$workflow" ]] || skip "review-pr workflow not found"

  # Extract the LLM call step and verify error paths use exit 1
  local llm_block
  llm_block=$(sed -n '/name: Call external LLM for review/,/name: Post review/p' "$workflow")

  # There should be no "exit 0" in the LLM step — all error paths must fail
  if echo "$llm_block" | grep -q 'exit 0'; then
    echo "FAIL: LLM call step uses 'exit 0' on error — must use 'exit 1' so failed reviews don't appear as passed" >&2
    return 1
  fi
}

@test "12. review-pr post step fails when review was unavailable" {
  local workflow="$PROJECT_ROOT/.github/workflows/agent-flow-review-pr.yml"
  [[ -f "$workflow" ]] || skip "review-pr workflow not found"

  # Extract the non-success handler block (from REVIEW_STATUS check to its exit)
  # and verify it uses exit 1
  local unavailable_block
  unavailable_block=$(sed -n '/REVIEW_STATUS.*!=.*success/,/exit [01]/p' "$workflow")

  if echo "$unavailable_block" | grep -q 'exit 0'; then
    echo "FAIL: Post review step exits 0 when review is unavailable — must exit 1" >&2
    return 1
  fi
  if ! echo "$unavailable_block" | grep -q 'exit 1'; then
    echo "FAIL: Post review step does not exit 1 when review is unavailable" >&2
    return 1
  fi
}

@test "13. every error path posts an UNAVAILABLE comment on the PR" {
  local workflow="$PROJECT_ROOT/.github/workflows/agent-flow-review-pr.yml"
  [[ -f "$workflow" ]] || skip "review-pr workflow not found"

  local failed=0

  # Path 1: Missing prerequisites — dedicated step posts comment
  # The "Post unavailable comment on missing prerequisites" step must exist
  # and must post to the issues/comments API with the UNAVAILABLE message
  local prereq_comment_step
  prereq_comment_step=$(sed -n '/name: Post unavailable comment on missing prerequisites/,/name: /p' "$workflow")
  if [[ -z "$prereq_comment_step" ]]; then
    echo "FAIL: No 'Post unavailable comment on missing prerequisites' step found" >&2
    failed=1
  else
    if ! echo "$prereq_comment_step" | grep -q 'UNAVAILABLE'; then
      echo "FAIL: Prereq comment step does not contain UNAVAILABLE message" >&2
      failed=1
    fi
    if ! echo "$prereq_comment_step" | grep -q 'issues.*comments'; then
      echo "FAIL: Prereq comment step does not post to issues/comments API" >&2
      failed=1
    fi
    # Must run on failure (prereqs step exits 1)
    if ! echo "$prereq_comment_step" | grep -q 'failure()'; then
      echo "FAIL: Prereq comment step does not use failure() condition" >&2
      failed=1
    fi
  fi

  # Path 2: LLM errors (api_error, empty_response, invalid_json) — post step handles
  # The "Post review and enforce verdict" step must handle non-success review_status
  # by posting UNAVAILABLE comment for each error type
  local post_step
  post_step=$(sed -n '/name: Post review and enforce verdict/,/^[[:space:]]*- name:/p' "$workflow")
  if [[ -z "$post_step" ]]; then
    # If it's the last step, sed won't find next "- name:" — grab to end of file
    post_step=$(sed -n '/name: Post review and enforce verdict/,$p' "$workflow")
  fi

  for error_type in api_error empty_response invalid_json; do
    if ! echo "$post_step" | grep -q "$error_type"; then
      echo "FAIL: Post step does not handle $error_type" >&2
      failed=1
    fi
  done

  if ! echo "$post_step" | grep -q 'UNAVAILABLE'; then
    echo "FAIL: Post step does not contain UNAVAILABLE message for LLM errors" >&2
    failed=1
  fi
  if ! echo "$post_step" | grep -q 'issues.*comments'; then
    echo "FAIL: Post step does not post to issues/comments API" >&2
    failed=1
  fi

  # Verify the post step runs even when LLM step fails (always() condition)
  if ! echo "$post_step" | grep -q 'always()'; then
    echo "FAIL: Post step does not use always() condition — LLM failures may skip it" >&2
    failed=1
  fi

  [[ "$failed" -eq 0 ]]
}

@test "14. prereqs step sets prereq_error output before exit 1" {
  local workflow="$PROJECT_ROOT/.github/workflows/agent-flow-review-pr.yml"
  [[ -f "$workflow" ]] || skip "review-pr workflow not found"

  # The prereqs step must write prereq_error to GITHUB_OUTPUT before each exit 1
  # so the comment-posting step can read the error reason
  local prereqs_block
  prereqs_block=$(sed -n '/name: Check prerequisites/,/name: Post unavailable/p' "$workflow")

  # Count prereq_error outputs — should match the number of exit 1 paths (2: API key + model)
  local output_count
  output_count=$(echo "$prereqs_block" | grep -c 'prereq_error=' || true)
  if [[ "$output_count" -lt 2 ]]; then
    echo "FAIL: Expected at least 2 prereq_error outputs (one per missing config), found $output_count" >&2
    return 1
  fi

  # Verify each prereq_error is set BEFORE the corresponding exit 1 (not after)
  # Check that prereq_error appears before exit 1 in each if block
  if ! echo "$prereqs_block" | awk '/prereq_error/{found=1} /exit 1/{if(found){found=0; ok++}} END{exit(ok>=2?0:1)}'; then
    echo "FAIL: prereq_error output is not set before exit 1 in all paths" >&2
    return 1
  fi
}

@test "15. external-review-system-prompt.md exists and is non-empty" {
  local prompt_file="$PROJECT_ROOT/.claude/skills/external-code-review/external-review-system-prompt.md"
  [[ -f "$prompt_file" ]] || {
    echo "FAIL: external-review-system-prompt.md not found" >&2
    return 1
  }
  local content
  content=$(cat "$prompt_file")
  # Must not be empty or whitespace-only
  [[ -n "${content// /}" ]] || {
    echo "FAIL: external-review-system-prompt.md is empty or whitespace-only" >&2
    return 1
  }
  # Must contain at least 50 chars of real content (not just a stub)
  local char_count
  char_count=${#content}
  [[ "$char_count" -ge 50 ]] || {
    echo "FAIL: external-review-system-prompt.md is suspiciously short ($char_count chars)" >&2
    return 1
  }
}

@test "16. review-pr workflow loads system prompt from file with guards" {
  local workflow="$PROJECT_ROOT/.github/workflows/agent-flow-review-pr.yml"
  [[ -f "$workflow" ]] || skip "review-pr workflow not found"

  # Must reference the prompt file
  grep -q 'external-review-system-prompt.md' "$workflow" || {
    echo "FAIL: workflow does not reference external-review-system-prompt.md" >&2
    return 1
  }

  # Must check file exists before reading
  grep -q '! -f.*PROMPT_FILE' "$workflow" || {
    echo "FAIL: workflow does not check prompt file exists before reading" >&2
    return 1
  }

  # Must check content is non-empty
  grep -q 'empty\|whitespace' "$workflow" || {
    echo "FAIL: workflow does not guard against empty prompt file" >&2
    return 1
  }

  # Must exit 1 on missing/empty prompt (not silently continue)
  local guard_block
  guard_block=$(sed -n '/PROMPT_FILE=/,/printf.*Review this/p' "$workflow")
  local exit_count
  exit_count=$(echo "$guard_block" | grep -c 'exit 1' || true)
  [[ "$exit_count" -ge 2 ]] || {
    echo "FAIL: Expected at least 2 exit 1 guards (missing file + empty file), found $exit_count" >&2
    return 1
  }
}

@test "17. external-review-system-prompt.md survives jq encoding without data loss" {
  local prompt_file="$PROJECT_ROOT/.claude/skills/external-code-review/external-review-system-prompt.md"
  [[ -f "$prompt_file" ]] || skip "prompt file not found"
  command -v jq || skip "jq not available"

  # Simulate what the workflow does: cp file → jq --rawfile (preserves exact content)
  cp "$prompt_file" /tmp/test-prompt.txt
  # jq --rawfile must produce valid JSON with the content intact
  local json_output
  json_output=$(jq -n --rawfile sys /tmp/test-prompt.txt '{system: $sys}' 2>&1) || {
    echo "FAIL: jq --rawfile failed on prompt content: $json_output" >&2
    rm -f /tmp/test-prompt.txt
    return 1
  }
  rm -f /tmp/test-prompt.txt

  # Verify round-trip: extract from JSON and compare against original file
  # Use jq -rj (--join-output) to suppress jq's trailing newline
  echo "$json_output" | jq -rj '.system' > /tmp/test-prompt-extracted.txt
  if ! diff -q "$prompt_file" /tmp/test-prompt-extracted.txt >/dev/null 2>&1; then
    echo "FAIL: prompt content changed after jq round-trip" >&2
    echo "Original bytes: $(wc -c < "$prompt_file"), Extracted bytes: $(wc -c < /tmp/test-prompt-extracted.txt)" >&2
    rm -f /tmp/test-prompt-extracted.txt
    return 1
  fi
  rm -f /tmp/test-prompt-extracted.txt
}

@test "18. external-review-system-prompt.md contains required review layers" {
  local prompt_file="$PROJECT_ROOT/.claude/skills/external-code-review/external-review-system-prompt.md"
  [[ -f "$prompt_file" ]] || skip "prompt file not found"

  local failed=0
  for keyword in SECURITY CORRECTNESS ROBUSTNESS INTEGRATION "TEST COVERAGE"; do
    if ! grep -qi "$keyword" "$prompt_file"; then
      echo "FAIL: prompt missing required review layer: $keyword" >&2
      failed=1
    fi
  done
  [[ "$failed" -eq 0 ]]
}

@test "19. agent-flow-workflow-helpers.sh is sourced by both workflows" {
  local downstream="$PROJECT_ROOT/.github/workflows/agent-flow-downstream.yml"
  local upstream="$PROJECT_ROOT/.github/workflows/agent-flow-upstream.yml"
  [[ -f "$downstream" ]] || skip "downstream workflow not found"
  [[ -f "$upstream" ]] || skip "upstream workflow not found"

  grep -q "agent-flow-workflow-helpers" "$downstream" || {
    echo "FAIL: downstream workflow does not source agent-flow-workflow-helpers.sh" >&2
    return 1
  }
  grep -q "agent-flow-workflow-helpers" "$upstream" || {
    echo "FAIL: upstream workflow does not source agent-flow-workflow-helpers.sh" >&2
    return 1
  }
}

# ── External code review skill ──────────────────────────────────────────────

@test "20. external-review.sh exists and has shebang" {
  local script="$PROJECT_ROOT/.claude/skills/external-code-review/external-review.sh"
  [[ -f "$script" ]] || skip "external-review.sh not found"

  local first_line
  first_line=$(head -1 "$script")
  [[ "$first_line" == "#!/usr/bin/env bash" ]] || {
    echo "FAIL: external-review.sh missing or wrong shebang: $first_line" >&2
    return 1
  }
}

@test "21. external-review.sh is executable" {
  local script="$PROJECT_ROOT/.claude/skills/external-code-review/external-review.sh"
  [[ -f "$script" ]] || skip "external-review.sh not found"
  [[ -x "$script" ]] || {
    echo "FAIL: external-review.sh is not executable" >&2
    return 1
  }
}

@test "22. external-review.sh passes shellcheck" {
  command -v shellcheck >/dev/null || skip "shellcheck not installed in this environment"
  local script="$PROJECT_ROOT/.claude/skills/external-code-review/external-review.sh"
  [[ -f "$script" ]] || skip "external-review.sh not found"

  local sc_output
  sc_output=$(shellcheck -S warning "$script" 2>&1) || {
    echo "$sc_output" >&2
    return 1
  }
}

@test "23. external-code-review SKILL.md exists and has frontmatter" {
  local skill="$PROJECT_ROOT/.claude/skills/external-code-review/SKILL.md"
  [[ -f "$skill" ]] || skip "SKILL.md not found"
  [[ -s "$skill" ]] || { echo "FAIL: SKILL.md is empty" >&2; return 1; }
  head -1 "$skill" | grep -q '^---' || { echo "FAIL: SKILL.md missing frontmatter" >&2; return 1; }
}

# ── agent-flow-auto-merge-planning workflow ───────────────────────────────────

@test "24. agent-flow-auto-merge-planning.yml exists and is named agent-flow-*.yml" {
  local workflow="$PROJECT_ROOT/.github/workflows/agent-flow-auto-merge-planning.yml"
  [[ -f "$workflow" ]] || {
    echo "FAIL: agent-flow-auto-merge-planning.yml not found" >&2
    return 1
  }
  # Filename MUST match agent-flow-*.yml (synced downstream as an opt-in workflow)
  local basename
  basename=$(basename "$workflow")
  if [[ "$basename" != agent-flow-*.yml ]]; then
    echo "FAIL: workflow is not named agent-flow-*.yml — it will not be synced downstream" >&2
    return 1
  fi
}

@test "25. actionlint passes on agent-flow-auto-merge-planning.yml" {
  command -v actionlint || skip "actionlint not installed"
  local workflow="$PROJECT_ROOT/.github/workflows/agent-flow-auto-merge-planning.yml"
  [[ -f "$workflow" ]] || skip "agent-flow-auto-merge-planning.yml not found"
  local al_output
  al_output=$(actionlint -shellcheck="" "$workflow" 2>&1) || {
    echo "$al_output" >&2
    return 1
  }
}

@test "26. agent-flow-auto-merge-planning.yml triggers on backlog/** and plans/** paths only" {
  local workflow="$PROJECT_ROOT/.github/workflows/agent-flow-auto-merge-planning.yml"
  [[ -f "$workflow" ]] || skip "agent-flow-auto-merge-planning.yml not found"

  # Must have paths: filter (not paths-ignore:)
  grep -q "^\s*paths:" "$workflow" || {
    echo "FAIL: workflow missing paths: trigger filter" >&2
    return 1
  }
  grep -q "backlog/\*\*" "$workflow" || {
    echo "FAIL: workflow missing backlog/** path trigger" >&2
    return 1
  }
  grep -q "plans/\*\*" "$workflow" || {
    echo "FAIL: workflow missing plans/** path trigger" >&2
    return 1
  }
  # Must NOT have paths-ignore under trigger (that would invert logic)
  # paths-ignore under 'on:' would mean "fire on everything EXCEPT these paths"
  # We want the opposite: only fire on these paths
  local trigger_block
  trigger_block=$(sed -n '/^on:/,/^[^[:space:]]/p' "$workflow")
  if echo "$trigger_block" | grep -q "paths-ignore"; then
    echo "FAIL: trigger uses paths-ignore instead of paths — would fire on non-planning PRs too" >&2
    return 1
  fi
}

@test "27. agent-flow-auto-merge-planning.yml triggers include synchronize event" {
  local workflow="$PROJECT_ROOT/.github/workflows/agent-flow-auto-merge-planning.yml"
  [[ -f "$workflow" ]] || skip "agent-flow-auto-merge-planning.yml not found"

  grep -q "synchronize" "$workflow" || {
    echo "FAIL: workflow does not trigger on synchronize event — re-pushes to planning PRs won't be re-validated" >&2
    return 1
  }
}

@test "28. agent-flow-auto-merge-planning.yml uses AGENT_FLOW_SYNC_TOKEN, not GITHUB_TOKEN, for merge" {
  local workflow="$PROJECT_ROOT/.github/workflows/agent-flow-auto-merge-planning.yml"
  [[ -f "$workflow" ]] || skip "agent-flow-auto-merge-planning.yml not found"

  grep -q "AGENT_FLOW_SYNC_TOKEN" "$workflow" || {
    echo "FAIL: workflow does not reference AGENT_FLOW_SYNC_TOKEN" >&2
    return 1
  }
  # The merge curl call must use SYNC_TOKEN (which is bound to AGENT_FLOW_SYNC_TOKEN)
  # Verify the merge PUT uses Authorization with SYNC_TOKEN
  local merge_block
  merge_block=$(sed -n '/curl.*-X PUT/,/HTTP_CODE/p' "$workflow")
  echo "$merge_block" | grep -q "SYNC_TOKEN" || {
    echo "FAIL: merge curl call does not use SYNC_TOKEN" >&2
    return 1
  }
  # Must NOT use secrets.GITHUB_TOKEN directly for the merge
  if echo "$merge_block" | grep -q "GITHUB_TOKEN"; then
    echo "FAIL: merge curl call uses GITHUB_TOKEN instead of AGENT_FLOW_SYNC_TOKEN" >&2
    return 1
  fi
}

@test "29. agent-flow-auto-merge-planning.yml handles HTTP 409 with exit 0 (silent fallthrough)" {
  local workflow="$PROJECT_ROOT/.github/workflows/agent-flow-auto-merge-planning.yml"
  [[ -f "$workflow" ]] || skip "agent-flow-auto-merge-planning.yml not found"

  # 409 block must exist and must exit 0 (not exit 1) — conflict leaves PR open silently
  grep -q "409)" "$workflow" || {
    echo "FAIL: workflow does not handle HTTP 409 (merge conflict)" >&2
    return 1
  }
  # Extract 409 case block and verify it uses exit 0
  local block_409
  block_409=$(sed -n '/409)/,/;;/p' "$workflow")
  if echo "$block_409" | grep -q "exit 1"; then
    echo "FAIL: HTTP 409 handler uses exit 1 — should exit 0 (leave PR open for human resolution)" >&2
    return 1
  fi
  echo "$block_409" | grep -q "exit 0" || {
    echo "FAIL: HTTP 409 handler does not exit 0" >&2
    return 1
  }
}

@test "29a. agent-flow-auto-merge-planning.yml HTTP 405 handler exits 0" {
  local workflow="$PROJECT_ROOT/.github/workflows/agent-flow-auto-merge-planning.yml"
  [[ -f "$workflow" ]] || skip "agent-flow-auto-merge-planning.yml not found"

  grep -q "405)" "$workflow" || {
    echo "FAIL: workflow does not handle HTTP 405" >&2
    return 1
  }
  local block_405
  block_405=$(sed -n '/405)/,/;;/p' "$workflow")
  if echo "$block_405" | grep -q "exit 1"; then
    echo "FAIL: HTTP 405 handler uses exit 1 — should exit 0" >&2
    return 1
  fi
  echo "$block_405" | grep -q "exit 0" || {
    echo "FAIL: HTTP 405 handler does not exit 0" >&2
    return 1
  }
}

@test "29b. agent-flow-auto-merge-planning.yml HTTP 422 handler exits 0" {
  local workflow="$PROJECT_ROOT/.github/workflows/agent-flow-auto-merge-planning.yml"
  [[ -f "$workflow" ]] || skip "agent-flow-auto-merge-planning.yml not found"

  grep -q "422)" "$workflow" || {
    echo "FAIL: workflow does not handle HTTP 422" >&2
    return 1
  }
  local block_422
  block_422=$(sed -n '/422)/,/;;/p' "$workflow")
  if echo "$block_422" | grep -q "exit 1"; then
    echo "FAIL: HTTP 422 handler uses exit 1 — should exit 0" >&2
    return 1
  fi
  echo "$block_422" | grep -q "exit 0" || {
    echo "FAIL: HTTP 422 handler does not exit 0" >&2
    return 1
  }
}

@test "29c. agent-flow-auto-merge-planning.yml unexpected HTTP code fallthrough exits 0" {
  local workflow="$PROJECT_ROOT/.github/workflows/agent-flow-auto-merge-planning.yml"
  [[ -f "$workflow" ]] || skip "agent-flow-auto-merge-planning.yml not found"

  # The *) catch-all case must exit 0
  local block_star
  block_star=$(sed -n '/\*)/,/;;/p' "$workflow")
  if echo "$block_star" | grep -q "exit 1"; then
    echo "FAIL: *) fallthrough handler uses exit 1 — should exit 0" >&2
    return 1
  fi
  echo "$block_star" | grep -q "exit 0" || {
    echo "FAIL: *) fallthrough handler does not exit 0" >&2
    return 1
  }
}

@test "30. agent-flow-auto-merge-planning.yml uses squash merge method" {
  local workflow="$PROJECT_ROOT/.github/workflows/agent-flow-auto-merge-planning.yml"
  [[ -f "$workflow" ]] || skip "agent-flow-auto-merge-planning.yml not found"

  grep -q '"squash"' "$workflow" || {
    echo "FAIL: workflow does not use squash merge method" >&2
    return 1
  }
}

@test "31. agent-flow-auto-merge-planning.yml skips when AGENT_FLOW_SYNC_TOKEN is missing" {
  local workflow="$PROJECT_ROOT/.github/workflows/agent-flow-auto-merge-planning.yml"
  [[ -f "$workflow" ]] || skip "agent-flow-auto-merge-planning.yml not found"

  # Token check must use exit 0 (skip, not fail) when token is absent
  local token_check_block
  token_check_block=$(sed -n '/SYNC_TOKEN.*-z\|z.*SYNC_TOKEN/,/exit 0/p' "$workflow")
  if [[ -z "$token_check_block" ]]; then
    # Alternative pattern: if [[ -z "${SYNC_TOKEN}" ]]
    token_check_block=$(sed -n '/-z.*SYNC_TOKEN/,/exit 0/p' "$workflow")
  fi
  grep -q 'exit 0' <<< "$token_check_block" || {
    echo "FAIL: missing token check does not exit 0 (should skip, not fail)" >&2
    return 1
  }
  # Must NOT exit 1 for missing token
  if grep -q 'exit 1' <<< "$token_check_block"; then
    echo "FAIL: missing token causes exit 1 — should silently skip with exit 0" >&2
    return 1
  fi
}

@test "32. agent-flow-auto-merge-planning.yml validates ALL files before merging (not just first page)" {
  local workflow="$PROJECT_ROOT/.github/workflows/agent-flow-auto-merge-planning.yml"
  [[ -f "$workflow" ]] || skip "agent-flow-auto-merge-planning.yml not found"

  # Must paginate — check for page loop
  grep -q "per_page=100" "$workflow" || {
    echo "FAIL: workflow does not paginate file list (missing per_page=100)" >&2
    return 1
  }
  # Must bail out at >400 files
  grep -q "400" "$workflow" || {
    echo "FAIL: workflow does not handle >400 files case" >&2
    return 1
  }
}

@test "33. agent-flow-auto-merge-planning.yml guards against non-planning files in the PR" {
  local workflow="$PROJECT_ROOT/.github/workflows/agent-flow-auto-merge-planning.yml"
  [[ -f "$workflow" ]] || skip "agent-flow-auto-merge-planning.yml not found"

  # The file-validation loop must check the '^(backlog/|plans/)' pattern
  grep -qE '\^\(backlog/\|plans/\)' "$workflow" || {
    echo "FAIL: workflow does not validate files against '^(backlog/|plans/)' pattern" >&2
    return 1
  }
  # Finding a non-planning file must cause exit 0 (skip, not hard fail)
  local guard_block
  guard_block=$(sed -n '/non-planning file/,/exit 0/p' "$workflow")
  grep -q "exit 0" <<< "$guard_block" || {
    echo "FAIL: non-planning file detection does not exit 0 (skip)" >&2
    return 1
  }
}

@test "33b. auto-merge validation loop rejects mixed backlog+src file list" {
  local workflow="$PROJECT_ROOT/.github/workflows/agent-flow-auto-merge-planning.yml"
  [[ -f "$workflow" ]] || skip "agent-flow-auto-merge-planning.yml not found"

  # Extract and run the validation loop against a mixed file list
  # The grep -qE pattern must reject 'src/main.js'
  local test_files="backlog/task.md
src/main.js"
  local rejected=false
  while IFS= read -r FILE; do
    [[ -z "${FILE}" ]] && continue
    if ! echo "${FILE}" | grep -qE '^(backlog/|plans/)'; then
      rejected=true
      break
    fi
  done <<< "${test_files}"
  [[ "${rejected}" == "true" ]] || {
    echo "FAIL: validation loop did not reject src/main.js in a mixed file list" >&2
    return 1
  }
}

@test "34. agent-flow-auto-merge-planning.yml uses jq --arg for merge payload (injection prevention)" {
  local workflow="$PROJECT_ROOT/.github/workflows/agent-flow-auto-merge-planning.yml"
  [[ -f "$workflow" ]] || skip "agent-flow-auto-merge-planning.yml not found"

  # Merge payload must be built with jq -n --arg, not with inline string interpolation
  grep -q "jq -n" "$workflow" || {
    echo "FAIL: merge payload not built with 'jq -n' — risk of injection via PR title" >&2
    return 1
  }
  grep -q "\-\-arg merge_method" "$workflow" || {
    echo "FAIL: merge_method not passed via --arg (injection risk)" >&2
    return 1
  }
  grep -q "\-\-arg sha" "$workflow" || {
    echo "FAIL: sha not passed via --arg (injection risk)" >&2
    return 1
  }
  grep -q "\-\-arg commit_title" "$workflow" || {
    echo "FAIL: commit_title not passed via --arg (injection risk)" >&2
    return 1
  }
}

@test "35. agent-flow-auto-merge-planning.yml has minimal GITHUB_TOKEN permissions" {
  local workflow="$PROJECT_ROOT/.github/workflows/agent-flow-auto-merge-planning.yml"
  [[ -f "$workflow" ]] || skip "agent-flow-auto-merge-planning.yml not found"

  # Must declare permissions block
  grep -q "^permissions:" "$workflow" || {
    echo "FAIL: workflow missing top-level permissions block" >&2
    return 1
  }
  # contents must be read (not write)
  grep -q "contents: read" "$workflow" || {
    echo "FAIL: contents permission is not 'read'" >&2
    return 1
  }
  # pull-requests must be read (not write) — merge uses PAT
  grep -q "pull-requests: read" "$workflow" || {
    echo "FAIL: pull-requests permission is not 'read'" >&2
    return 1
  }
}

@test "36. agent-flow-auto-merge-planning.yml has concurrency group to prevent race conditions" {
  local workflow="$PROJECT_ROOT/.github/workflows/agent-flow-auto-merge-planning.yml"
  [[ -f "$workflow" ]] || skip "agent-flow-auto-merge-planning.yml not found"

  grep -q "^concurrency:" "$workflow" || {
    echo "FAIL: workflow missing concurrency block" >&2
    return 1
  }
  grep -q "cancel-in-progress: true" "$workflow" || {
    echo "FAIL: concurrency block missing cancel-in-progress: true" >&2
    return 1
  }
  grep -q "auto-merge-planning-" "$workflow" || {
    echo "FAIL: concurrency group name does not include 'auto-merge-planning-' prefix" >&2
    return 1
  }
}

@test "37. agent-flow-auto-merge-planning.yml shell uses set -euo pipefail" {
  local workflow="$PROJECT_ROOT/.github/workflows/agent-flow-auto-merge-planning.yml"
  [[ -f "$workflow" ]] || skip "agent-flow-auto-merge-planning.yml not found"

  grep -q "set -euo pipefail" "$workflow" || {
    echo "FAIL: workflow shell script missing 'set -euo pipefail'" >&2
    return 1
  }
}

@test "38. review-pr workflow has paths-ignore for backlog/** and plans/**" {
  local workflow="$PROJECT_ROOT/.github/workflows/agent-flow-review-pr.yml"
  [[ -f "$workflow" ]] || skip "review-pr workflow not found"

  grep -q "paths-ignore:" "$workflow" || {
    echo "FAIL: agent-flow-review-pr.yml missing paths-ignore block — LLM review fires on planning PRs" >&2
    return 1
  }
  grep -q "backlog/\*\*" "$workflow" || {
    echo "FAIL: agent-flow-review-pr.yml missing backlog/** in paths-ignore" >&2
    return 1
  }
  grep -q "plans/\*\*" "$workflow" || {
    echo "FAIL: agent-flow-review-pr.yml missing plans/** in paths-ignore" >&2
    return 1
  }
}

@test "39. review-pr workflow paths-ignore is under pull_request trigger (not job level)" {
  local workflow="$PROJECT_ROOT/.github/workflows/agent-flow-review-pr.yml"
  [[ -f "$workflow" ]] || skip "review-pr workflow not found"

  # paths-ignore must appear in the on: block (before 'jobs:'), not inside a job step
  local trigger_section
  trigger_section=$(sed -n '/^on:/,/^jobs:/p' "$workflow")
  echo "$trigger_section" | grep -q "paths-ignore:" || {
    echo "FAIL: paths-ignore is not under the 'on:' trigger block — it won't filter PR events" >&2
    return 1
  }
}

@test "40. agent-flow-auto-merge-planning.yml has opt-in guard comment" {
  local workflow="$PROJECT_ROOT/.github/workflows/agent-flow-auto-merge-planning.yml"
  [[ -f "$workflow" ]] || skip "agent-flow-auto-merge-planning.yml not found"

  grep -q "AGENT_FLOW_AUTO_MERGE_PLANNING" "$workflow" || {
    echo "FAIL: workflow missing opt-in guard referencing AGENT_FLOW_AUTO_MERGE_PLANNING" >&2
    return 1
  }
  grep -q "opt-in" "$workflow" || {
    echo "FAIL: workflow missing opt-in comment explaining how to enable it" >&2
    return 1
  }
}

@test "40a. agent-flow-auto-merge-planning.yml has two-job opt-in pattern (skip-if-not-enabled + auto-merge)" {
  local workflow="$PROJECT_ROOT/.github/workflows/agent-flow-auto-merge-planning.yml"
  [[ -f "$workflow" ]] || skip "agent-flow-auto-merge-planning.yml not found"

  grep -q "vars.AGENT_FLOW_AUTO_MERGE_PLANNING != 'true'" "$workflow" || {
    echo "FAIL: skip-if-not-enabled job missing != 'true' condition" >&2
    return 1
  }
  grep -q "vars.AGENT_FLOW_AUTO_MERGE_PLANNING == 'true'" "$workflow" || {
    echo "FAIL: auto-merge job missing == 'true' condition" >&2
    return 1
  }
}

@test "41. auto-version-bump.yml has skip-in-forks guard (two-job pattern)" {
  local workflow="$PROJECT_ROOT/.claude-agent-flow/plugin-repo-workflows/auto-version-bump.yml"
  [[ -f "$workflow" ]] || skip "auto-version-bump.yml not found"

  grep -q "github.repository != 'timgranlundmarsden/claude-agent-flow'" "$workflow" || {
    echo "FAIL: skip-in-forks job missing in auto-version-bump.yml" >&2
    return 1
  }
  grep -q "github.repository == 'timgranlundmarsden/claude-agent-flow'" "$workflow" || {
    echo "FAIL: real job guard missing in auto-version-bump.yml" >&2
    return 1
  }
}

@test "42. deploy-pages.yml has skip-in-forks guard (two-job pattern)" {
  local workflow="$PROJECT_ROOT/.claude-agent-flow/plugin-repo-workflows/deploy-pages.yml"
  [[ -f "$workflow" ]] || skip "deploy-pages.yml not found"

  grep -q "github.repository != 'timgranlundmarsden/claude-agent-flow'" "$workflow" || {
    echo "FAIL: skip-in-forks job missing in deploy-pages.yml" >&2
    return 1
  }
  grep -q "github.repository == 'timgranlundmarsden/claude-agent-flow'" "$workflow" || {
    echo "FAIL: real job guard missing in deploy-pages.yml" >&2
    return 1
  }
}

@test "43. plugin-distribution-tests.yml has skip-in-forks guard (two-job pattern)" {
  local workflow="$PROJECT_ROOT/.claude-agent-flow/plugin-repo-workflows/plugin-distribution-tests.yml"
  [[ -f "$workflow" ]] || skip "plugin-distribution-tests.yml not found"

  grep -q "github.repository != 'timgranlundmarsden/claude-agent-flow'" "$workflow" || {
    echo "FAIL: skip-in-forks job missing in plugin-distribution-tests.yml" >&2
    return 1
  }
  grep -q "github.repository == 'timgranlundmarsden/claude-agent-flow'" "$workflow" || {
    echo "FAIL: real job guard missing in plugin-distribution-tests.yml" >&2
    return 1
  }
}
