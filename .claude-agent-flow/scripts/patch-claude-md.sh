#!/usr/bin/env bash
# patch-claude-md.sh — Patch managed sections in a target CLAUDE.md
#
# Usage: patch-claude-md.sh <source-claude-md> <target-claude-md> <managed-section-1> [managed-section-2] ...
#
# Algorithm:
#   1. Parse both files into sections (split on `## ` headings)
#   2. Keep target's preamble (everything before first ## heading)
#   3. For each section in target:
#      - If heading matches a managed section → replace with source version
#      - Otherwise → keep target version verbatim
#   4. Append any managed sections from source not found in target
#   5. Write result to stdout (caller redirects to file)
#
# Section boundaries: `## ` at start of line. Section includes everything
# from the heading line up to (but not including) the next `## ` heading or EOF.

set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <source-claude-md> <target-claude-md> <managed-section-1> [managed-section-2] ..." >&2
  exit 1
fi

SOURCE_FILE="$1"
TARGET_FILE="$2"
shift 2
MANAGED_SECTIONS=("$@")

# If target doesn't exist, copy source with a blank project header prepended
if [[ ! -f "$TARGET_FILE" ]]; then
  echo "## Project: CHANGEME"
  echo ""
  echo "Add your project description here."
  echo ""
  echo "---"
  echo ""
  cat "$SOURCE_FILE"
  exit 0
fi

# Set up temp directory for section files
TMPDIR_SECTIONS=$(mktemp -d)
trap 'rm -rf "$TMPDIR_SECTIONS"' EXIT

# Parse a CLAUDE.md file into per-section temp files.
# Creates: $TMPDIR_SECTIONS/<prefix>_N.heading and $TMPDIR_SECTIONS/<prefix>_N.content
# Returns number of sections via stdout.
parse_sections() {
  local file="$1"
  local prefix="$2"
  local idx=0
  local content_file="$TMPDIR_SECTIONS/${prefix}_${idx}.content"
  printf '%s' "__PREAMBLE__" > "$TMPDIR_SECTIONS/${prefix}_${idx}.heading"
  : > "$content_file"

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^##[[:space:]](.+)$ ]]; then
      # Start new section
      idx=$(( idx + 1 ))
      printf '%s' "${BASH_REMATCH[1]}" > "$TMPDIR_SECTIONS/${prefix}_${idx}.heading"
      content_file="$TMPDIR_SECTIONS/${prefix}_${idx}.content"
      printf '%s\n' "$line" > "$content_file"
    else
      printf '%s\n' "$line" >> "$content_file"
    fi
  done < "$file"

  echo "$idx"
}

# Check if a section heading is managed
is_managed() {
  local heading="$1"
  for managed in "${MANAGED_SECTIONS[@]}"; do
    if [[ "$heading" == "$managed" ]]; then
      return 0
    fi
  done
  return 1
}

# Parse both files
SOURCE_COUNT=$(parse_sections "$SOURCE_FILE" "source")
TARGET_COUNT=$(parse_sections "$TARGET_FILE" "target")

# Track which managed sections we've output (file-based for bash 3.x compat)
MANAGED_OUTPUT_DIR="$TMPDIR_SECTIONS/_output_tracker"
mkdir -p "$MANAGED_OUTPUT_DIR"

mark_output() {
  touch "$MANAGED_OUTPUT_DIR/$(printf '%s' "$1" | tr '/ ' '__')"
}

was_output() {
  [[ -f "$MANAGED_OUTPUT_DIR/$(printf '%s' "$1" | tr '/ ' '__')" ]]
}

# Process target sections in order
for i in $(seq 0 "$TARGET_COUNT"); do
  heading_file="$TMPDIR_SECTIONS/target_${i}.heading"
  content_file="$TMPDIR_SECTIONS/target_${i}.content"
  [[ -f "$heading_file" ]] || continue

  heading=$(cat "$heading_file")

  if [[ "$heading" == "__PREAMBLE__" ]]; then
    # Always keep target's preamble
    cat "$content_file"
  elif is_managed "$heading"; then
    # Replace with source version
    mark_output "$heading"
    # Find matching section in source
    for j in $(seq 1 "$SOURCE_COUNT"); do
      src_heading_file="$TMPDIR_SECTIONS/source_${j}.heading"
      [[ -f "$src_heading_file" ]] || continue
      src_heading=$(cat "$src_heading_file")
      if [[ "$src_heading" == "$heading" ]]; then
        cat "$TMPDIR_SECTIONS/source_${j}.content"
        break
      fi
    done
  else
    # Keep target's version
    cat "$content_file"
  fi
done

# Append any managed sections from source that weren't in the target
for j in $(seq 1 "$SOURCE_COUNT"); do
  src_heading_file="$TMPDIR_SECTIONS/source_${j}.heading"
  [[ -f "$src_heading_file" ]] || continue
  src_heading=$(cat "$src_heading_file")
  if [[ "$src_heading" == "__PREAMBLE__" ]]; then
    continue
  fi
  if is_managed "$src_heading" && ! was_output "$src_heading"; then
    cat "$TMPDIR_SECTIONS/source_${j}.content"
  fi
done
