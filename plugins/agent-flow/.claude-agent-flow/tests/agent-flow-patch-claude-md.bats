#!/usr/bin/env bats
# Tests for patch-claude-md.sh

setup() {
  load test_helper
  setup_temp_dirs
}

# ── patch-claude-md.sh tests ─────────────────────────────────────────────────

@test "no target file creates fresh with CHANGEME header" {
  cat > "$BATS_TEST_TMPDIR/source.md" << 'EOF'
## Agent Flow

Agent team content here.
EOF
  result=$(bash "$SCRIPT_DIR/patch-claude-md.sh" \
    "$BATS_TEST_TMPDIR/source.md" \
    "$BATS_TEST_TMPDIR/nonexistent.md" \
    "Agent Flow")
  [[ "$result" == *"## Project: CHANGEME"* ]]
}

@test "managed section replaced from source" {
  cat > "$BATS_TEST_TMPDIR/source.md" << 'EOF'
## Agent Flow

New content here.
EOF
  cat > "$BATS_TEST_TMPDIR/target.md" << 'EOF'
## Agent Flow

Old content here.
EOF
  result=$(bash "$SCRIPT_DIR/patch-claude-md.sh" \
    "$BATS_TEST_TMPDIR/source.md" \
    "$BATS_TEST_TMPDIR/target.md" \
    "Agent Flow")
  [[ "$result" == *"New content here."* ]]
  [[ "$result" != *"Old content here."* ]]
}

@test "non-managed section preserved" {
  cat > "$BATS_TEST_TMPDIR/source.md" << 'EOF'
## Agent Flow

Agent team stuff.
EOF
  cat > "$BATS_TEST_TMPDIR/target.md" << 'EOF'
## Agent Flow

Old agent team stuff.

## My Custom Section

Custom content preserved.
EOF
  result=$(bash "$SCRIPT_DIR/patch-claude-md.sh" \
    "$BATS_TEST_TMPDIR/source.md" \
    "$BATS_TEST_TMPDIR/target.md" \
    "Agent Flow")
  [[ "$result" == *"## My Custom Section"* ]]
  [[ "$result" == *"Custom content preserved."* ]]
}

@test "new managed section appended when not in target" {
  cat > "$BATS_TEST_TMPDIR/source.md" << 'EOF'
## Backlog Management

Backlog content here.
EOF
  cat > "$BATS_TEST_TMPDIR/target.md" << 'EOF'
## Some Other Section

Other content.
EOF
  result=$(bash "$SCRIPT_DIR/patch-claude-md.sh" \
    "$BATS_TEST_TMPDIR/source.md" \
    "$BATS_TEST_TMPDIR/target.md" \
    "Backlog Management")
  [[ "$result" == *"## Backlog Management"* ]]
  [[ "$result" == *"Backlog content here."* ]]
}

@test "preamble always preserved from target" {
  cat > "$BATS_TEST_TMPDIR/source.md" << 'EOF'
## Agent Flow

Source agent team content.
EOF
  cat > "$BATS_TEST_TMPDIR/target.md" << 'EOF'
My preamble text here.

## Agent Flow

Old agent team content.
EOF
  result=$(bash "$SCRIPT_DIR/patch-claude-md.sh" \
    "$BATS_TEST_TMPDIR/source.md" \
    "$BATS_TEST_TMPDIR/target.md" \
    "Agent Flow")
  [[ "$result" == *"My preamble text here."* ]]
}

@test "multiple managed sections all replaced" {
  cat > "$BATS_TEST_TMPDIR/source.md" << 'EOF'
## Section A

New A content.

## Section B

New B content.

## Section C

New C content.
EOF
  cat > "$BATS_TEST_TMPDIR/target.md" << 'EOF'
## Section A

Old A content.

## Section B

Old B content.

## Section C

Old C content.
EOF
  result=$(bash "$SCRIPT_DIR/patch-claude-md.sh" \
    "$BATS_TEST_TMPDIR/source.md" \
    "$BATS_TEST_TMPDIR/target.md" \
    "Section A" "Section B" "Section C")
  [[ "$result" == *"New A content."* ]]
  [[ "$result" == *"New B content."* ]]
  [[ "$result" == *"New C content."* ]]
  [[ "$result" != *"Old A content."* ]]
  [[ "$result" != *"Old B content."* ]]
  [[ "$result" != *"Old C content."* ]]
}

@test "section ordering preserved: non-managed sections stay in place" {
  cat > "$BATS_TEST_TMPDIR/source.md" << 'EOF'
## Section B

New B content.
EOF
  cat > "$BATS_TEST_TMPDIR/target.md" << 'EOF'
## Section A

Content A.

## Section B

Old B content.

## Section C

Content C.
EOF
  result=$(bash "$SCRIPT_DIR/patch-claude-md.sh" \
    "$BATS_TEST_TMPDIR/source.md" \
    "$BATS_TEST_TMPDIR/target.md" \
    "Section B")
  # A should appear before B, B before C
  pos_a=$(echo "$result" | grep -n "## Section A" | cut -d: -f1)
  pos_b=$(echo "$result" | grep -n "## Section B" | cut -d: -f1)
  pos_c=$(echo "$result" | grep -n "## Section C" | cut -d: -f1)
  [[ "$pos_a" -lt "$pos_b" ]]
  [[ "$pos_b" -lt "$pos_c" ]]
}

@test "empty source section replaces non-empty target section" {
  cat > "$BATS_TEST_TMPDIR/source.md" << 'EOF'
## Agent Flow
EOF
  cat > "$BATS_TEST_TMPDIR/target.md" << 'EOF'
## Agent Flow

Lots of existing content that should be removed.
More content here.
EOF
  result=$(bash "$SCRIPT_DIR/patch-claude-md.sh" \
    "$BATS_TEST_TMPDIR/source.md" \
    "$BATS_TEST_TMPDIR/target.md" \
    "Agent Flow")
  [[ "$result" != *"Lots of existing content"* ]]
  [[ "$result" != *"More content here."* ]]
}
