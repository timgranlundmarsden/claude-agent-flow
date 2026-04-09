# Third-Party Licenses

This project includes or depends on the following third-party software.

---

## mergiraf

- **Description:** Syntax-aware git merge driver
- **Version:** 0.16.3
- **Source:** https://codeberg.org/mergiraf/mergiraf
- **License:** GPL-3.0-only
- **Usage:** Vendored binary tarball at `.claude-agent-flow/bin/mergiraf-v0.16.3-x86_64-unknown-linux-musl.tar.gz`, installed as the git merge driver during session startup.

Full text: https://www.gnu.org/licenses/gpl-3.0.html

---

## Backlog.md

- **Description:** Markdown-native task manager and kanban visualiser for git repos
- **Source:** https://github.com/MrLesk/Backlog.md (original); https://github.com/timgranlundmarsden/Backlog.md (fork used by this project)
- **License:** MIT
- **Usage:** Runtime dependency installed via MCP server configuration. Not vendored; installed from the fork repository.

Full text: https://opensource.org/licenses/MIT

---

## brainstorming (skill)

- **Description:** Socratic creative brainstorming skill for agent-flow
- **Source:** https://github.com/obra/superpowers-marketplace
- **License:** MIT
- **Copyright:** Copyright (c) 2025 Jesse Vincent
- **Usage:** Vendored skill file at `.claude/skills/brainstorming/`. Synced from the superpowers plugin via `sync-plugin-skills`.

Full text: https://opensource.org/licenses/MIT

---

## playwright-cli (skill)

- **Description:** Browser automation skill for web testing and interaction
- **Source:** https://github.com/microsoft/playwright-cli
- **License:** Apache-2.0
- **Copyright:** Copyright (c) Microsoft Corporation
- **Usage:** Vendored skill file at `.claude/skills/playwright-cli/`. Synced from the playwright-cli plugin via `sync-plugin-skills`.

Full text: https://www.apache.org/licenses/LICENSE-2.0

---

## Anthropic plugin-dev skills

- **Description:** Official skill set for Claude Code plugin development, distributed via the Claude Code plugin marketplace
- **Skills included:** `agent-development`, `command-development`, `hook-development`, `mcp-integration`, `plugin-settings`, `plugin-structure`, `skill-development`
- **Source:** https://github.com/anthropics/claude-code
- **License:** Proprietary — All rights reserved, Anthropic PBC
- **Copyright:** Copyright (c) Anthropic PBC
- **Usage:** Vendored skill files at `.claude/skills/` (one subdirectory per skill). Synced from the `plugin-dev` plugin. These skills are designed for distribution via the Claude Code plugin marketplace; inclusion here is solely for web-environment compatibility. The canonical installation path is through the Claude Code plugin marketplace.
- **Terms:** Subject to Anthropic's Commercial Terms of Service. See https://www.anthropic.com/legal/commercial-terms
