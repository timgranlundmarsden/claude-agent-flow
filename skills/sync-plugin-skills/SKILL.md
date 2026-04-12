---
name: sync-plugin-skills
description: >
  Sync installed Claude Code plugin skills into the repo so they work in web
  environments. Run this from a local CLI session where plugins are installed.
---

Sync third-party plugin skills from the local plugin cache into this repo.

## Instructions

1. Run the sync script:

```bash
bash "$CLAUDE_PROJECT_DIR/.claude/skills/sync-plugin-skills/sync.sh"
```

2. If the script reports missing plugins, install them first using the `/plugin install` command shown in the output, then re-run the script.

3. If the script succeeds, review what was synced — it prints each skill and writes a manifest to `.claude/skills/.vendored.json`.

4. Stage the new/updated skill files and the manifest, commit, and push:

```bash
git add .claude/skills/
git commit -m "Sync vendored plugin skills for web environment"
git push -u origin "$(git rev-parse --abbrev-ref HEAD)"
```

5. Report what was synced.

## Dry run

To preview without writing files:

```bash
bash "$CLAUDE_PROJECT_DIR/.claude/skills/sync-plugin-skills/sync.sh" --dry-run
```
