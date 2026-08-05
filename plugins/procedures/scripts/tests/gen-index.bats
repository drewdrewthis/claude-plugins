#!/usr/bin/env bats
# Tests for scripts/lib/gen-index-lib.sh via scripts/gen-decisions-index.sh /
# scripts/gen-solutions-index.sh — the title-resolution fix for codex #60.
#
# All tests use a temp directory via DECISIONS_DIR/SOLUTIONS_DIR env-var
# overrides. The real references/decisions and references/solutions trees are
# NEVER touched here.
#
# Coverage map (each case run against BOTH wrapper scripts, per PR60 review
# r3544871108 — the solutions wrapper was previously untested):
#   frontmatter title: preferred over a generic H1 when both are present
#   H1 fallback when no frontmatter title exists
#   idempotency: two runs on an unchanged input dir produce byte-identical output
#   banner + header: each wrapper emits its own DO-NOT-EDIT banner and title line
#
# Run: bats scripts/tests/gen-index.bats

setup() {
  GEN_DECISIONS="$BATS_TEST_DIRNAME/../gen-decisions-index.sh"
  GEN_SOLUTIONS="$BATS_TEST_DIRNAME/../gen-solutions-index.sh"
  TMPDIR_REC="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMPDIR_REC"
}

# run_gen <decisions|solutions> --stdout — invoke the named wrapper with the
# matching env-var override pointed at TMPDIR_REC, leaving the real
# references/decisions and references/solutions trees untouched.
run_gen() {
  local which="$1"; shift
  if [ "$which" = "decisions" ]; then
    DECISIONS_DIR="$TMPDIR_REC" run bash "$GEN_DECISIONS" "$@"
  else
    SOLUTIONS_DIR="$TMPDIR_REC" run bash "$GEN_SOLUTIONS" "$@"
  fi
}

@test "decisions: frontmatter title: is preferred over a generic H1 when both are present" {
  cat > "$TMPDIR_REC/2026-01-01-example.md" <<'EOF'
---
id: dec.2026-01-01-example
title: Descriptive frontmatter title
---

# Problem

body text.
EOF

  run_gen decisions --stdout
  [ "$status" -eq 0 ]
  [[ "$output" == *"Descriptive frontmatter title"* ]]
  [[ "$output" != *"| Problem |"* ]]
}

@test "solutions: frontmatter title: is preferred over a generic H1 when both are present" {
  cat > "$TMPDIR_REC/2026-01-01-example.md" <<'EOF'
---
id: sol.2026-01-01-example
title: Descriptive frontmatter title
---

# Problem

body text.
EOF

  run_gen solutions --stdout
  [ "$status" -eq 0 ]
  [[ "$output" == *"Descriptive frontmatter title"* ]]
  [[ "$output" != *"| Problem |"* ]]
}

@test "decisions: H1 fallback works when no frontmatter title exists" {
  cat > "$TMPDIR_REC/2026-01-02-example.md" <<'EOF'
# A Plain Heading

body text, no frontmatter at all.
EOF

  run_gen decisions --stdout
  [ "$status" -eq 0 ]
  [[ "$output" == *"A Plain Heading"* ]]
}

@test "solutions: H1 fallback works when no frontmatter title exists" {
  cat > "$TMPDIR_REC/2026-01-02-example.md" <<'EOF'
# A Plain Heading

body text, no frontmatter at all.
EOF

  run_gen solutions --stdout
  [ "$status" -eq 0 ]
  [[ "$output" == *"A Plain Heading"* ]]
}

@test "decisions: frontmatter title: is not matched from body prose after frontmatter ends" {
  cat > "$TMPDIR_REC/2026-01-03-example.md" <<'EOF'
---
id: dec.2026-01-03-example
---

# Real Heading

Some prose that mentions title: this should not be used as the title.
EOF

  run_gen decisions --stdout
  [ "$status" -eq 0 ]
  [[ "$output" == *"Real Heading"* ]]
  [[ "$output" != *"this should not be used as the title"* ]]
}

@test "solutions: frontmatter title: is not matched from body prose after frontmatter ends" {
  cat > "$TMPDIR_REC/2026-01-03-example.md" <<'EOF'
---
id: sol.2026-01-03-example
---

# Real Heading

Some prose that mentions title: this should not be used as the title.
EOF

  run_gen solutions --stdout
  [ "$status" -eq 0 ]
  [[ "$output" == *"Real Heading"* ]]
  [[ "$output" != *"this should not be used as the title"* ]]
}

@test "decisions: idempotency: running the generator twice on an unchanged dir produces byte-identical output" {
  cat > "$TMPDIR_REC/2026-01-04-example.md" <<'EOF'
---
title: Stable Title
---

# Problem
EOF
  cat > "$TMPDIR_REC/2026-01-05-other.md" <<'EOF'
# Another Heading
EOF

  out1="$(mktemp)"
  out2="$(mktemp)"
  DECISIONS_DIR="$TMPDIR_REC" bash "$GEN_DECISIONS" --stdout > "$out1"
  DECISIONS_DIR="$TMPDIR_REC" bash "$GEN_DECISIONS" --stdout > "$out2"

  run diff "$out1" "$out2"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  rm -f "$out1" "$out2"
}

@test "solutions: idempotency: running the generator twice on an unchanged dir produces byte-identical output" {
  cat > "$TMPDIR_REC/2026-01-04-example.md" <<'EOF'
---
title: Stable Title
---

# Problem
EOF
  cat > "$TMPDIR_REC/2026-01-05-other.md" <<'EOF'
# Another Heading
EOF

  out1="$(mktemp)"
  out2="$(mktemp)"
  SOLUTIONS_DIR="$TMPDIR_REC" bash "$GEN_SOLUTIONS" --stdout > "$out1"
  SOLUTIONS_DIR="$TMPDIR_REC" bash "$GEN_SOLUTIONS" --stdout > "$out2"

  run diff "$out1" "$out2"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  rm -f "$out1" "$out2"
}

@test "solutions: emits its own DO-NOT-EDIT banner and Solutions index header" {
  cat > "$TMPDIR_REC/2026-01-06-example.md" <<'EOF'
# Some Title
EOF

  run_gen solutions --stdout
  [ "$status" -eq 0 ]
  [[ "$output" == *"DO NOT EDIT — regenerate with scripts/gen-solutions-index.sh"* ]]
  [[ "$output" == *"Solutions index"* ]]
}

@test "decisions: emits its own DO-NOT-EDIT banner and Decisions index header" {
  cat > "$TMPDIR_REC/2026-01-06-example.md" <<'EOF'
# Some Title
EOF

  run_gen decisions --stdout
  [ "$status" -eq 0 ]
  [[ "$output" == *"DO NOT EDIT — regenerate with scripts/gen-decisions-index.sh"* ]]
  [[ "$output" == *"Decisions index"* ]]
}
