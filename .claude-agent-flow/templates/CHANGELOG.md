# Changelog

| Date & Time | Type    | Description |
|-------------|---------|-------------|
| 2026-04-11 00:00:00 | Added   | Two-layer consent fallback: optional-tools.json (per-machine, gitignored) takes precedence over consent-defaults.json (committed repo-scoped defaults); both absent falls back to TTY prompt. Supports mergiraf opt-in defaults in ephemeral sandbox sessions. |
| 2026-04-09 18:45:00 | Fixed   | marketplace.json writes to `.claude-plugin/marketplace.json` instead of repo root; cleanup removes stale root-level files. |
| 2026-04-04  | release | **1.0.0** — Initial release. 12 agents (orchestrator, explorer, architect, ideator, researcher, frontend, backend, storage, tester, critic, reviewer, author), 13 slash commands (/build, /plan, /review, /explore, /help, /install, /rebase, /check-pr, /external-review, /backlog-list, /token-analyser, /sync-plugin-skills, /plugin-repo-sync), 18 skills, adversarial critic loop with integrity protection, lite and full pipeline modes, plugin-repo-sync distribution system, section-patch CLAUDE.md management, mergiraf merge driver integration, Backlog.md task management. |
