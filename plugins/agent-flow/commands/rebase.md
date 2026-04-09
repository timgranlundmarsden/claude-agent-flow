---
name: rebase
description: >
  Guided rebase workflow. Stashes uncommitted changes, fetches latest from
  origin, rebases onto the remote branch (or a specified branch), resolves
  conflicts if possible, and pops the stash on success.
---

**Skills:** agent-flow-init-check

Rebase the current branch onto the latest remote changes.

If `$ARGUMENTS` is non-empty, use it as the target branch (e.g., `/rebase main` rebases onto `origin/main`).
If `$ARGUMENTS` is empty, rebase onto `origin/<current-branch>`.

Follow these steps exactly:

1. **Check for uncommitted changes:**
   ```bash
   git status --porcelain
   ```
   If there are uncommitted changes, stash them:
   ```bash
   git stash push -m "rebase-auto-stash"
   ```

2. **Fetch latest from origin:**
   ```bash
   git fetch origin
   ```

3. **Determine rebase target:**
   - If `$ARGUMENTS` is provided: `origin/$ARGUMENTS`
   - Otherwise: `origin/$(git rev-parse --abbrev-ref HEAD)`

4. **Rebase:**
   ```bash
   git rebase <target>
   ```

5. **On success:**
   - If changes were stashed in step 1, pop the stash:
     ```bash
     git stash pop
     ```
   - Report: "Rebase complete. Branch is up to date with `<target>`."

6. **On conflict:**
   - List conflicted files: `git diff --name-only --diff-filter=U`
   - Attempt to resolve each file (mergiraf handles syntax-aware resolution automatically during rebase)
   - If all conflicts resolved: `git add -u` (stages only tracked files) then `git rebase --continue`
   - If unresolvable conflicts remain: abort the rebase and report clearly:
     ```bash
     git rebase --abort
     ```
     If changes were stashed, pop the stash after abort.
   - Report which files conflicted and how they were resolved (or that the rebase was aborted)

7. **No-op case:** If `git rebase` reports "Current branch is up to date" or exits with no changes, report that no rebase was needed.
