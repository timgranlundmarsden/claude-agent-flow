# Changelog

| Version | Date | Changes |
|---------|------|---------|
| **v1.0.7** | 2026-04-12 | **Fixed** install: `print_optional_tools_hint` no longer exits with code 1 on empty hint; permissions flags always passed explicitly (fixes non-TTY runs). **Fixed** diagnostic: reads `settings.local.json` first for `enabledPlugins`; shows actionable message when `sync-state.json` missing. **Fixed** sync: preserves existing symlink when replacement directory is absent. |
| **v1.0.6** | 2026-04-12 | **Changed** plugin repo restructured to root-level layout — `agents/`, `commands/`, `skills/`, `hooks/` now live at repo root so Claude Code auto-discovers them without `path` overrides in `plugin.json`. Compatibility symlinks (`.claude/agents → ../agents` etc.) added post-sync for existing installs. `find -L` used throughout for macOS symlink support. |
| **v1.0.5** | 2026-04-12 | **Fixed** plugin hooks format corrected to work within Claude Code. |
| **v1.0.4** | 2026-04-12 | **Changed** README revised with updated command listing and project description. |
| **v1.0.0** | 2026-04-09 | Initial release. 12 agents, 13 slash commands, 18 skills, adversarial critic loop, lite and full pipeline modes, plugin distribution system, mergiraf integration, Backlog.md task management. Post-launch fixes bundled: flat dual-use plugin layout (TASK-54); two-layer consent fallback (`optional-tools.json` → `consent-defaults.json` → TTY); `--skip-permissions` install flag; marketplace ID fix; removed `gh` CLI dependency; shell fallback for YAML parsing; `defaultMode` stripped from distributed `settings.json`; `marketplace.json` path corrected. |
