---
name: playwright-cli-helpers
description: Default verification tool for local HTML files. Use visual-check.sh as the FIRST choice whenever you need to verify, test, or check any local HTML page — whether confirming elements render correctly, checking layout, detecting overflow, or asserting uniform widths. Prefer this over raw playwright-cli commands. Also the authoritative reference for playwright-cli setup and gotchas in this project — always load this skill before using playwright-cli directly.
---

# Playwright CLI Helpers

**This is the authoritative reference for all playwright-cli usage in this project.**
The vendored `playwright-cli` skill may be replaced by `/sync-plugin-skills` and
lacks project-specific setup knowledge. Always load this skill (`playwright-cli-helpers`)
alongside or instead of `playwright-cli` when doing browser work.

## Skill priority: playwright-cli-helpers FIRST

When both `playwright-cli` and `playwright-cli-helpers` skills are loaded, **always
start with `playwright-cli-helpers`**:

1. **Default action for any HTML/CSS verification:** Run `visual-check.sh` (this skill).
   It handles server setup, sandbox config, mobile+desktop screenshots, and overflow
   detection in one command.
2. **Only fall back to raw `playwright-cli` commands** (from the vendored skill) when
   you need interactive browser work that `visual-check.sh` can't do — e.g. clicking
   elements, filling forms, navigating between pages, or checking computed styles.
3. When using raw `playwright-cli`, follow the setup guidance in this skill (sandbox,
   no file:// URLs, correct binary name) — not just the vendored skill's examples.

Local helper scripts that wrap `playwright-cli` for common visual verification tasks.

## visual-check.sh

**Location:** `.claude/skills/playwright-cli-helpers/scripts/visual-check.sh`

Screenshots a local HTML file at mobile (375px), tablet portrait (768px), and desktop (1280px) widths, checks for horizontal overflow, and optionally asserts uniform element widths for a CSS selector.

```bash
# Basic check — screenshots + overflow detection
scripts/visual-check.sh path/to/file.html

# With uniform-width assertion on a CSS selector
scripts/visual-check.sh path/to/file.html ".card"
```

### Output

- `PASS` + paths to three screenshots (mobile, tablet, desktop) on success
- `FAIL: horizontal overflow at 375px (mobile)` with scroll/client widths on overflow
- `FAIL: non-uniform widths for '.card': [300, 298, 301]` on width mismatch
- Exit code 0 on pass, 1 on failure, 2 on bad arguments

### Saving evidence

Use the `--evidence <task-folder>` flag to save JPEG screenshots directly.
The folder name should match the backlog task filename (without `.md`), e.g.
`task-50 - Fix-mobile-grey-horizontal-line-on-breadcrumb-nav`.

```bash
# Saves mobile.jpg + tablet.jpg + desktop.jpg as JPEG (quality 80), stages with git add
.claude/skills/playwright-cli-helpers/scripts/visual-check.sh path/to/file.html --evidence "task-50 - Fix-mobile-grey-horizontal-line-on-breadcrumb-nav"

# With a prefix — produces no-grey-line_mobile.jpg, no-grey-line_tablet.jpg, no-grey-line_desktop.jpg
.claude/skills/playwright-cli-helpers/scripts/visual-check.sh path/to/file.html --evidence "task-50 - Fix-mobile-grey-horizontal-line-on-breadcrumb-nav" no-grey-line

# With selector check too
.claude/skills/playwright-cli-helpers/scripts/visual-check.sh path/to/file.html ".card" --evidence "task-50 - Title"
```

**Naming convention:** `<prefix>_<viewport>.jpg` — the prefix describes the
specific change, the suffix is the viewport. A task touching multiple things should
have evidence for each:

```
.scratch/evidence/task-42 - Update-nav-and-badges/
  new_badge_mobile.jpg
  new_badge_tablet.jpg
  new_badge_desktop.jpg
  moved_link_mobile.jpg
  moved_link_tablet.jpg
  moved_link_desktop.jpg
```

The `--evidence` flag without a prefix produces generic `mobile.jpg` + `tablet.jpg` + `desktop.jpg`.
With a prefix (`--evidence <folder> <prefix>`), filenames become `<prefix>_mobile.jpg`, etc.
Use the prefix when a task has multiple evidence captures in the same folder.
For targeted screenshots of specific changes, crop to the relevant element:

```bash
playwright-cli run-code "async page => {
  const el = await page.$('.badge-container');
  await el.screenshot({ path: '.scratch/evidence/<task-slug>/new_badge_desktop.jpg', type: 'jpeg', quality: 80 });
}"
git add .scratch/evidence/<task-slug>/
```

Evidence is saved as JPEG (not PNG) to keep repo size down.

When completing a backlog task, append a note: `Evidence: .scratch/evidence/<task-folder>/`

### When to use

- **Any time you need to verify a local HTML file** — this is the default verification tool
- After creating or modifying any HTML page, to confirm it renders correctly
- After any CSS/layout fix, before marking a task done
- When a user reports cards or elements are different widths
- When checking responsive behaviour across breakpoints
- When a user asks to "verify", "check", or "test" a local HTML page

**Fallback:** If visual-check.sh can't do what you need (e.g. clicking elements, filling forms, checking specific computed styles), fall back to raw `playwright-cli` commands. But always try visual-check.sh first.

### How it works

1. Spins up a local `python3 -m http.server` to serve the file (playwright-cli blocks `file://` URLs)
2. Opens the page in headless Chrome via `playwright-cli`
3. Resizes to 375×812, takes screenshot, checks overflow (mobile)
4. Resizes to 768×1024, takes screenshot, checks overflow (tablet portrait)
5. Resizes to 1280×900, takes screenshot, checks overflow (desktop)
6. Optionally measures `getBoundingClientRect().width` for all elements matching the selector
7. Cleans up browser and HTTP server on exit

## Using playwright-cli directly (fallback)

When visual-check.sh isn't enough and you need raw `playwright-cli` commands:

### Sandbox (root / container environments)

In CI, containers, or any environment running as root, Chromium refuses to launch
with sandboxing enabled. The visual-check.sh script handles this automatically,
but if you call `playwright-cli` directly you **must** set:

```bash
export PLAYWRIGHT_MCP_SANDBOX=false
```

before running `playwright-cli open`. This is safe on macOS too (ignored when
sandboxing works natively).

### Do NOT use npx playwright-cli or npx @anthropic-ai/playwright-cli

The globally installed `playwright-cli` (from `@playwright/cli`) is the correct
binary. Do not try to run it via `npx playwright-cli` — that resolves to a
different (non-existent) package.

### Do NOT use file:// URLs

`playwright-cli` blocks `file://` URLs. Always serve files via a local HTTP
server first:

```bash
python3 -m http.server 18765 --directory /path/to/dir &
playwright-cli open http://localhost:18765/file.html
# ... do your work ...
playwright-cli close
kill %1
```

### Browser availability

The session-start hook (`session-start.sh`) ensures Chromium is available.
If you hit "browser not found" errors, the hook likely didn't run. You can
manually fix it:

```bash
# Find Playwright's cached Chromium and symlink it (Linux only)
CHROME=$(find ~/.cache/ms-playwright -name "chrome" -path "*/chrome-linux/*" -type f | head -1)
mkdir -p /opt/google/chrome && ln -sf "$CHROME" /opt/google/chrome/chrome
```
