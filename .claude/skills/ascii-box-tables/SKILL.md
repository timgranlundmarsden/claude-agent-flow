---
name: ascii-box-tables
description: Create visually appealing tables and diagrams for display. Use when the user asks to create tables, diagrams, status displays, dashboards, or structured text layouts that should render nicely in monospace fonts. Triggers include requests for tables, terminal-style output, box diagrams, or recreating visual layouts in text form.
---

# Two Distinct Styles — Use the Right One

## 1. Data Tables → Markdown pipe syntax

Use `|` and `-` for structured data with rows and columns. Renders cleanly everywhere.

```
| COLUMN A       | COLUMN B       | COLUMN C       |
|----------------|----------------|----------------|
| Data row 1     | Value 1        | Value 1        |
| Data row 2     | Value 2        | Value 2        |
```

For titled sections, use markdown headings above the table:

```
### Section Title

| COLUMN A       | COLUMN B       |
|----------------|----------------|
| Data row 1     | Value 1        |
```

### Data Table Design Rules

1. **Column separator**: Always `|`
2. **Header divider row**: Use `---` (three or more dashes) per cell
3. **Padding**: Add a space on each side of cell content for readability
4. **Consistent column width**: Pad with spaces so columns align visually
5. **Section titles**: Use markdown headings (`##`, `###`) above tables instead of title rows inside the table

Do NOT use heavy Unicode box-drawing characters (`╔`, `║`, `═`, etc.) for data tables — they cause alignment issues.

---

## 2. Flow Diagrams & Architecture → Unicode box-drawing characters

Use Unicode box-drawing characters for node boxes, flow arrows, and architecture diagrams. These look far better than `+`/`-`/`|` for visual layouts.

### Character Set for Diagrams

| Purpose         | Character |
|-----------------|-----------|
| Horizontal      | `─`       |
| Vertical        | `│`       |
| Top-left        | `┌`       |
| Top-right       | `┐`       |
| Bottom-left     | `└`       |
| Bottom-right    | `┘`       |
| T-left          | `├`       |
| T-right         | `┤`       |
| T-top           | `┬`       |
| T-bottom        | `┴`       |
| Cross           | `┼`       |
| Arrow down      | `▼`       |
| Arrow up        | `▲`       |
| Arrow right     | `▶`       |
| Arrow left      | `◀`       |

Do NOT use `+`, `-`, `*` for diagram boxes — always prefer the Unicode characters above.

### Diagram Structure Pattern

```
┌─────────────────┐     ┌─────────────────┐
│   Node A        │     │   Node B        │
│  - detail       │     │  - detail       │
└────────┬────────┘     └────────┬────────┘
         │                       │
         └───────────┬───────────┘
                     ▼
          ┌──────────────────────┐
          │      Next Layer      │
          └──────────────────────┘
```

## Emoji Handling

Emojis render as ~2 characters wide in most monospace fonts and can cause column misalignment.

**Include emojis** (may cause slight alignment drift):
```
| Authentication | 🟢 Operational |
| Database       | 🔴 Outage      |
```

**ASCII alternatives** (perfect alignment):
```
| Authentication | [*] Operational |
| Database       | [X] Outage      |
```

Common substitutions:
- `[~]` = pending/waiting (replaces ⏳)
- `[!]` = warning/attention (replaces ⚡ 🟡)
- `[*]` = success/OK (replaces 🟢 ✓)
- `[X]` = error/failure (replaces 🔴 ✗)
- `[x]` = checkbox checked
- `[ ]` = checkbox unchecked
- `>>` = callout/verdict

## Example Output

### API Status Dashboard

Date: 2026-02-05 | Time: 14:30 UTC

| Service        | Status          | Notes                          |
|----------------|-----------------|--------------------------------|
| Authentication | [*] Operational |                                |
| Database       | [!] Degraded    |                                |
| Storage        | [X] Outage      | Affecting file uploads, ETA 15:00 UTC |
