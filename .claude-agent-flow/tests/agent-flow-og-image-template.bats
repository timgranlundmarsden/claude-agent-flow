#!/usr/bin/env bats
# Tests for .claude-agent-flow/templates/og-image-template.html

setup() {
  load test_helper
  TEMPLATE="$PROJECT_ROOT/.claude-agent-flow/templates/og-image-template.html"
  # In the source repo the file lives under docs/public/; in the plugin repo
  # the sync manifest strips the "public/" prefix so it lands under docs/.
  if is_source_repo; then
    PNG_OUTPUT="$PROJECT_ROOT/docs/public/img/og-image.png"
  else
    PNG_OUTPUT="$PROJECT_ROOT/docs/img/og-image.png"
  fi
}

# ── File existence ────────────────────────────────────────────────────────────

@test "1. og-image-template.html exists at expected path" {
  [[ -f "$TEMPLATE" ]]
}

@test "2. og-image.png exists at expected path" {
  [[ -f "$PNG_OUTPUT" ]]
}

# ── HTML structure: DOCTYPE and charset ──────────────────────────────────────

@test "3. template has valid HTML5 doctype" {
  grep -qi '<!DOCTYPE html>' "$TEMPLATE"
}

@test "4. template has UTF-8 charset meta tag" {
  grep -q 'charset="UTF-8"' "$TEMPLATE"
}

@test "5. template has a title element" {
  grep -q '<title>' "$TEMPLATE"
}

# ── Body dimensions: exactly 1200x630 ────────────────────────────────────────

@test "6. template has width: 1200px" {
  grep -q 'width: 1200px' "$TEMPLATE"
}

@test "7. template has height: 630px" {
  grep -q 'height: 630px' "$TEMPLATE"
}

@test "8. template has overflow: hidden" {
  grep -q 'overflow: hidden' "$TEMPLATE"
}

@test "9. template has margin: 0" {
  grep -q 'margin: 0' "$TEMPLATE"
}

@test "10. template has padding: 0 (initial reset in universal selector or body)" {
  grep -q 'padding: 0' "$TEMPLATE"
}

# ── No external resources ─────────────────────────────────────────────────────

@test "11. no external stylesheet links (link rel=stylesheet)" {
  ! grep -qi '<link[^>]*rel=["\x27]stylesheet' "$TEMPLATE"
}

@test "12. no Google Fonts imports" {
  ! grep -qi 'fonts.googleapis.com' "$TEMPLATE"
}

@test "13. no external @import in style block" {
  ! grep -q '@import url' "$TEMPLATE"
}

@test "14. CSS is inline in a <style> tag" {
  grep -q '<style>' "$TEMPLATE"
}

# ── Font stack ────────────────────────────────────────────────────────────────

@test "15. font stack includes a monospace variant (SF Mono, ui-monospace, or Cascadia Code)" {
  grep -qE "(ui-monospace|'SF Mono'|SF Mono|'Cascadia Code'|Cascadia Code)" "$TEMPLATE"
}

@test "16. font stack includes Consolas" {
  grep -q 'Consolas' "$TEMPLATE"
}

@test "17. generic monospace is included in font stack" {
  grep -q 'monospace' "$TEMPLATE"
}

# ── Colour tokens ─────────────────────────────────────────────────────────────

@test "18. blue colour (#0071e3) is defined in CSS" {
  grep -q '#0071e3' "$TEMPLATE"
}

@test "19. cyan colour (#06b6d4) is defined in CSS" {
  grep -q '#06b6d4' "$TEMPLATE"
}

@test "20. purple colour (#7c3aed) is defined in CSS" {
  grep -q '#7c3aed' "$TEMPLATE"
}

@test "21. green colour (#28a745) is defined in CSS" {
  grep -q '#28a745' "$TEMPLATE"
}

# ── Wordmark content ──────────────────────────────────────────────────────────

@test "22. wordmark contains 'Claude Agent Flow'" {
  grep -q 'Claude Agent Flow' "$TEMPLATE"
}

# ── Pipeline agents present (case-insensitive) ────────────────────────────────

@test "23. Orchestrator agent is present" {
  grep -qi 'Orchestrator' "$TEMPLATE"
}

@test "24. Explorer agent is present" {
  grep -qi 'Explorer' "$TEMPLATE"
}

@test "25. Architect agent is present" {
  grep -qi 'Architect' "$TEMPLATE"
}

@test "26. Builder agent is present" {
  grep -qi 'Builder' "$TEMPLATE"
}

@test "27. Critic Pass agent is present" {
  grep -qi 'Critic' "$TEMPLATE"
}

# ── Flow arrows ───────────────────────────────────────────────────────────────

@test "28. template contains arrow between badges (→ unicode or HTML entity or CSS arrow class)" {
  grep -qE '(→|&#x2192;|&#8594;|&rarr;|arrow)' "$TEMPLATE"
}

@test "29. at least 4 arrows present (connecting 5+ agents)" {
  # Count both unicode arrows and HTML entities
  local unicode_count entity_count total
  unicode_count=$(grep -o '→' "$TEMPLATE" | wc -l)
  entity_count=$(grep -oE '(&#x2192;|&#8594;|&rarr;)' "$TEMPLATE" | wc -l)
  # Also count elements with class "arrow" as a proxy
  arrow_class_count=$(grep -c 'class="arrow"' "$TEMPLATE" 2>/dev/null || echo 0)
  total=$((unicode_count + entity_count + arrow_class_count))
  [[ "$total" -ge 4 ]]
}

# ── Tagline ───────────────────────────────────────────────────────────────────

@test "30. tagline 'Plan. Build. Review.' is present" {
  grep -q 'Plan\.' "$TEMPLATE"
  grep -q 'Build\.' "$TEMPLATE"
  grep -q 'Review\.' "$TEMPLATE"
}

@test "31. tagline words appear in correct order (Plan before Build before Review)" {
  local plan_line build_line review_line
  plan_line=$(grep -n 'Plan\.' "$TEMPLATE" | head -1 | cut -d: -f1)
  build_line=$(grep -n 'Build\.' "$TEMPLATE" | head -1 | cut -d: -f1)
  review_line=$(grep -n 'Review\.' "$TEMPLATE" | head -1 | cut -d: -f1)
  [[ -n "$plan_line" && -n "$build_line" && -n "$review_line" ]]
  [[ "$plan_line" -le "$build_line" ]]
  [[ "$build_line" -le "$review_line" ]]
}

# ── No scrollbars / no overflow content ──────────────────────────────────────

@test "32. html or body element has overflow: hidden" {
  grep -q 'overflow: hidden' "$TEMPLATE"
}

# ── Pipeline semantic structure ───────────────────────────────────────────────

@test "33. pipeline container element is present" {
  grep -qE '(class="pipeline|id="pipeline|class=.pipeline)' "$TEMPLATE"
}

@test "34. agents are in correct order (Orchestrator before Explorer)" {
  local orch_line exp_line
  orch_line=$(grep -in 'Orchestrator' "$TEMPLATE" | grep -v '^\s*//' | head -1 | cut -d: -f1)
  exp_line=$(grep -in 'Explorer' "$TEMPLATE" | grep -v '^\s*//' | head -1 | cut -d: -f1)
  [[ -n "$orch_line" && -n "$exp_line" ]]
  [[ "$orch_line" -lt "$exp_line" ]]
}

@test "35. agents are in correct order (Explorer before Architect)" {
  local exp_line arch_line
  exp_line=$(grep -in 'Explorer' "$TEMPLATE" | head -1 | cut -d: -f1)
  arch_line=$(grep -in 'Architect' "$TEMPLATE" | head -1 | cut -d: -f1)
  [[ "$exp_line" -lt "$arch_line" ]]
}

@test "36. agents are in correct order (Architect before Builder)" {
  local arch_line build_line
  arch_line=$(grep -in 'Architect' "$TEMPLATE" | head -1 | cut -d: -f1)
  build_line=$(grep -in 'Builder' "$TEMPLATE" | head -1 | cut -d: -f1)
  [[ -n "$arch_line" && -n "$build_line" ]]
  [[ "$arch_line" -lt "$build_line" ]]
}

@test "37. agents are in correct order (Builder before Critic)" {
  local build_line crit_line
  build_line=$(grep -in '>Builder<\|Builder</\|Builder</' "$TEMPLATE" | head -1 | cut -d: -f1)
  crit_line=$(grep -in 'Critic' "$TEMPLATE" | head -1 | cut -d: -f1)
  [[ -n "$build_line" && -n "$crit_line" ]]
  [[ "$build_line" -lt "$crit_line" ]]
}

# ── PNG output dimensions ─────────────────────────────────────────────────────

@test "38. og-image.png is exactly 1200 pixels wide (PNG IHDR chunk)" {
  command -v python3 || skip "python3 not available"
  local width
  width=$(python3 -c "
import struct
with open('$PNG_OUTPUT', 'rb') as f:
    f.read(8)   # PNG signature
    f.read(4)   # IHDR length
    f.read(4)   # IHDR type
    w = struct.unpack('>I', f.read(4))[0]
    print(w)
")
  [[ "$width" == "1200" ]]
}

@test "39. og-image.png is exactly 630 pixels tall (PNG IHDR chunk)" {
  command -v python3 || skip "python3 not available"
  local height
  height=$(python3 -c "
import struct
with open('$PNG_OUTPUT', 'rb') as f:
    f.read(8)   # PNG signature
    f.read(4)   # IHDR length
    f.read(4)   # IHDR type
    f.read(4)   # width
    h = struct.unpack('>I', f.read(4))[0]
    print(h)
")
  [[ "$height" == "630" ]]
}

@test "40. og-image.png has a valid PNG signature (first 8 bytes)" {
  command -v python3 || skip "python3 not available"
  local sig
  sig=$(python3 -c "
with open('$PNG_OUTPUT', 'rb') as f:
    sig = f.read(8)
    print(sig.hex())
")
  [[ "$sig" == "89504e470d0a1a0a" ]]
}

@test "41. og-image.png file size is non-trivial (at least 20KB — indicates real render)" {
  local size
  size=$(wc -c < "$PNG_OUTPUT")
  [[ "$size" -gt 20480 ]]
}

# ── Template placement (not inside docs/public) ───────────────────────────────

@test "42. template is in .claude-agent-flow/templates/ not in docs/public/" {
  [[ "$TEMPLATE" == *".claude-agent-flow/templates/"* ]]
  [[ "$TEMPLATE" != *"docs/public/"* ]]
}

@test "43. PNG output is in docs/public/img/ (source repo) or docs/img/ (plugin repo)" {
  [[ "$PNG_OUTPUT" == *"docs/public/img/"* ]] || [[ "$PNG_OUTPUT" == *"docs/img/"* ]]
}

# ── CSS variable definitions ──────────────────────────────────────────────────

@test "44. CSS custom properties (:root block) defined" {
  grep -q ':root' "$TEMPLATE"
}

@test "45. a font CSS variable is defined" {
  # Accepts either --font-mono or --font or --mono naming
  grep -qE '(--(font-mono|font|mono)[[:space:]]*:)' "$TEMPLATE"
}

@test "46. a muted/secondary text CSS variable is defined for tagline" {
  # Accepts --text-muted, --text-secondary, --muted, or similar
  grep -qE '(--(text-muted|text-secondary|muted|secondary)[[:space:]]*:)' "$TEMPLATE"
}

# ── Self-contained: no inline scripts ────────────────────────────────────────

@test "47. no inline JavaScript src from external CDN" {
  ! grep -qE '<script[^>]*src=["\x27]https?://' "$TEMPLATE"
}

# ── Template is non-empty / substantial ──────────────────────────────────────

@test "48. template is at least 80 lines long (indicates substantive content)" {
  local lines
  lines=$(wc -l < "$TEMPLATE")
  [[ "$lines" -ge 80 ]]
}

@test "49. template has a closing </html> tag" {
  grep -q '</html>' "$TEMPLATE"
}

@test "50. template has a closing </body> tag" {
  grep -q '</body>' "$TEMPLATE"
}
