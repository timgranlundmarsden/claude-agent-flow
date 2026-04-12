# Sync Workflow Conventions

The downstream (`.github/workflows/agent-flow-downstream.yml`) and upstream (`agent-flow-upstream.yml`) workflows sync managed files between repos. When editing these:

- **Never suppress git errors** — capture output with `2>&1`, never use `2>/dev/null` on clone/push
- **Always redact tokens** — use the shared `redact_token()` function from `.claude-agent-flow/scripts/agent-flow-workflow-helpers.sh` (pipe output through it). Both workflows source this file.
- **Handle errors per-target** — in the downstream loop, use `continue` so one failed target doesn't block others, but track failures with a counter and `exit 1` at the end
- **Use process substitution for loops** — `done < <(...)` not `... | while`, to avoid subshell/pipefail issues under GitHub Actions' `set -e -o pipefail`
- **Shallow clones only** — always `git checkout -b` for new branches, never `git fetch` + `git checkout` existing remote branches in `--depth 1` clones
- **Keep both workflows in sync** — downstream and upstream share the same patterns (clone, push, token redaction, error handling) via `.claude-agent-flow/scripts/agent-flow-workflow-helpers.sh`. A fix to one almost always needs applying to the other
- **Manifest is the single source of truth** — both workflows use manifest-driven detection (no hardcoded path filters). When adding or removing entries in the manifest, the workflows automatically pick up the changes
- **No multi-line Python in YAML `run:` blocks** — `python3 -c "..."` must be a true single-line command. Multi-line content inside the quotes starts at column 1, which the YAML parser reads as new mapping keys, silently breaking the entire workflow file. For complex Python logic, either (a) keep it as a single-line one-liner, or (b) move it to a script in `.claude-agent-flow/scripts/` and call that script. Never use heredocs (`cat << 'EOF'`) with unindented content inside `run: |` blocks either — same YAML parse failure. The "workflow run: blocks have no unindented python3 -c multi-line bodies" test in `agent-flow-static-checks.bats` validates all workflow YAML parses correctly.
