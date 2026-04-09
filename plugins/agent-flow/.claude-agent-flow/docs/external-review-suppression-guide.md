# External Review Bot Suppression

The automated external review uses two config files for suppressing known concerns. When the user says **"suppress this in the review"**, determine which file to use:

| File | Synced | Purpose |
|------|--------|---------|
| `.claude-agent-flow/external-review-config.yml` | Yes (downstream) | Agent-flow infrastructure concerns — shared across all repos |
| `external-review-config.repo.yml` | No | Repo-specific concerns — unique to this project |

**Which file to use:**
- Concerns about agent-flow managed files (workflows, agents, commands, scripts, tests in `.claude-agent-flow/`) → **`external-review-config.yml`** (shared)
- Concerns about repo-specific code (project source, local configs, custom workflows) → **`external-review-config.repo.yml`** (repo)

**IMPORTANT: This repo IS the agent-flow source repo.** All code here is agent-flow infrastructure that flows downstream to client repos. Therefore, ALL suppressions in this repo should go in the shared file (`external-review-config.yml`), never in `external-review-config.repo.yml`. The repo-level file should remain `suppress: []` in this repo. Only client repos should use the repo-level file for their own project-specific suppressions.

**Format** (same for both files):
```yaml
suppress:
  - file: "path/to/file.ext"       # Exact path or glob (e.g. "src/*.js")
    keyword: "word from message"    # Case-insensitive match on the concern message
    reason: "Why this is accepted"  # Shown in review body as [suppressed]
```

**How it works:**
- Both files are read and merged at runtime — suppressions from either file apply
- Suppressed concerns are **completely hidden** — they do not appear in the review body or as inline comments
- They do NOT count toward the error threshold — only unsuppressed `error` severity concerns block the PR
- `warning` and `info` severity concerns never block regardless of suppression

**IMPORTANT: Fix first, suppress last.** Before adding a suppression, always check if the concern can be resolved by fixing code or updating docs. Suppression is only for concerns that are **genuinely not errors** — the reviewer misunderstood the code, missed a guard, or flagged an intentional design decision. If a concern points to a real bug, fix the bug. If it points to a docs mismatch, update the docs.

**Suppression is NOT a way to move on.** Never suppress a valid concern just because it's inconvenient, time-consuming to fix, or exists in code you didn't write. If the file is in the diff, the concern is fair game. "Pre-existing" or "belongs to a separate task" is not a valid suppression reason if the concern describes a real defect.

**When to suppress:**
- **False positives**: The reviewer misread the code — a guard/check already exists, the pattern is safe, or the scenario can't happen
- **Intentional design**: An acknowledged tradeoff with documented reasoning (e.g. AWK parser heuristic matching a controlled format)
- **Bot artifacts**: Malformed file paths or line-mapping failures that aren't real code concerns

**When NOT to suppress:**
- Actual bugs or security issues (fix them)
- Docs mismatches (update the docs)
- Valid concerns in code you didn't originally write but that appears in this PR's diff (fix them)
- Things you plan to fix later (create a task instead, but don't suppress)
- Anything where the right answer is to change the code
