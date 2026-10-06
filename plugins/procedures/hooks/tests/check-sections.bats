#!/usr/bin/env bats
# Tests for scripts/check-sections.sh — per-kind required-section presence.
# AC13: WARN + exit 0 by default; blocks under LINT_SECTIONS_REQUIRED=1; a
# record with all required sections passes in both modes.
# Run: bats hooks/tests/check-sections.bats

# setup — resolve the script under test and a fresh tmp fixture dir.
setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/check-sections.sh"
  FIX="$(mktemp -d)"
}
# teardown — remove the tmp fixture tree.
teardown() { rm -rf "$FIX"; }

# A decision missing its "Chosen path" section.
_decision_missing_section() {
  cat > "$FIX/d.md" <<'EOF'
---
id: dec.d
kind: decision
date: 2026-09-05
keywords: [k]
links: {}
status: active
description: a decision missing its Chosen path section.
---
# d
## Goal
g
## Outcome
o
EOF
}

# A decision with every required section.
_decision_complete() {
  cat > "$FIX/d.md" <<'EOF'
---
id: dec.d
kind: decision
date: 2026-09-05
keywords: [k]
links: {}
status: active
description: a complete decision record.
---
# d
## Goal
g
## Chosen path
c
## Outcome
o
EOF
}

@test "missing section: WARN and exit 0 by default" {
  _decision_missing_section
  run bash "$SCRIPT" "$FIX/d.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN"* ]]
  [[ "$output" == *"Chosen path"* ]]
}

@test "missing section: blocks (exit non-zero) under LINT_SECTIONS_REQUIRED=1" {
  _decision_missing_section
  LINT_SECTIONS_REQUIRED=1 run bash "$SCRIPT" "$FIX/d.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL"* ]]
  [[ "$output" == *"Chosen path"* ]]
}

@test "complete record: exit 0 in default mode" {
  _decision_complete
  run bash "$SCRIPT" "$FIX/d.md"
  [ "$status" -eq 0 ]
}

@test "complete record: exit 0 under LINT_SECTIONS_REQUIRED=1" {
  _decision_complete
  LINT_SECTIONS_REQUIRED=1 run bash "$SCRIPT" "$FIX/d.md"
  [ "$status" -eq 0 ]
}
