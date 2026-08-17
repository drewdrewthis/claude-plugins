#!/usr/bin/env bats
# Tests for scripts/grc-coverage.sh — the control-coverage report.
#
# The report answers two questions and must not confuse their failure modes:
#   OBLIGATIONS (principles, policies) -> the control each one names
#     NO FIELD     — never declared a control
#     ASPIRATIONAL — declared `none-aspirational` (honest, not a defect)
#     MISSING      — names a control that is not on disk (the only --strict fail)
#     SHELFWARE    — control exists, nothing anywhere calls it
#     PROSE        — called only from agent/skill/procedure text (discretionary)
#     AUTOMATED    — called by config the machine executes (a real gate)
#   RISKS (failure-modes) -> whether any record points back at them
#
# The distinction that matters: MISSING is a broken reference, SHELFWARE is an
# intact reference to a control nothing invokes. Collapsing the two would let a
# never-firing control read as enforced.
#
# Each test builds a tiny fixture corpus under GRC_COVERAGE_ROOT so results are
# deterministic and the live corpus is never touched.
#
# Run: bats hooks/tests/grc-coverage.bats

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/grc-coverage.sh"
  FIX="$(mktemp -d)"
  export GRC_COVERAGE_ROOT="$FIX"

  mkdir -p "$FIX/references/principles" \
           "$FIX/references/policies" \
           "$FIX/references/failure-modes" \
           "$FIX/references/procedures" \
           "$FIX/agents" "$FIX/scripts" "$FIX/skills"
}

teardown() {
  [ -n "${FIX:-}" ] && rm -rf "$FIX"
}

# Write an obligation record. $1=slug, $2=enforced_by line (may be empty).
mk_principle() {
  local slug="$1" enf="${2:-}"
  {
    echo "---"
    echo "id: prin.$slug"
    echo "kind: principle"
    echo "date: 2026-08-17"
    echo "keywords: [quokka]"
    echo "links: {}"
    [ -n "$enf" ] && echo "enforced_by: $enf"
    echo "status: active"
    echo "---"
    echo
    echo "# $slug"
  } > "$FIX/references/principles/$slug.md"
}

mk_failure_mode() {
  local slug="$1"
  {
    echo "---"
    echo "id: fm.$slug"
    echo "kind: failure-mode"
    echo "date: 2026-08-17"
    echo "keywords: [quokka]"
    echo "links: {}"
    echo "status: active"
    echo "---"
  } > "$FIX/references/failure-modes/$slug.md"
}

# --- obligations without a usable control ------------------------------------

@test "obligation with no enforced_by is reported as NO FIELD" {
  mk_principle "undeclared"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"NO FIELD"* ]]
  [[ "$output" == *"prin.undeclared"* ]]
}

@test "none-aspirational is ASPIRATIONAL, never MISSING" {
  mk_principle "honest" "none-aspirational"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ASPIRATIONAL"* ]]
  [[ "$output" == *"prin.honest"* ]]
  # An honest declaration must not be counted as a broken reference.
  [[ "$output" != *"MISSING — obligation"* ]]
}

@test "enforced_by pointing at a nonexistent control is MISSING" {
  mk_principle "dangling" "scripts/does-not-exist-quokka.sh"
  run bash "$SCRIPT"
  [[ "$output" == *"MISSING"* ]]
  [[ "$output" == *"prin.dangling -> scripts/does-not-exist-quokka.sh"* ]]
}

# --- the gate can actually fail ----------------------------------------------

@test "--strict exits 1 when a control is MISSING" {
  mk_principle "dangling" "scripts/does-not-exist-quokka.sh"
  run bash "$SCRIPT" --strict
  [ "$status" -eq 1 ]
}

@test "default mode exits 0 even when a control is MISSING" {
  mk_principle "dangling" "scripts/does-not-exist-quokka.sh"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "--strict exits 0 when every named control resolves" {
  touch "$FIX/scripts/quokka-check.sh"
  mk_principle "wired" "scripts/quokka-check.sh"
  run bash "$SCRIPT" --strict
  [ "$status" -eq 0 ]
}

# --- invocation classification -----------------------------------------------

@test "control on disk that nothing references is SHELFWARE, not MISSING" {
  touch "$FIX/scripts/quokka-check.sh"
  mk_principle "unused" "scripts/quokka-check.sh"
  run bash "$SCRIPT"
  [[ "$output" == *"SHELFWARE"* ]]
  [[ "$output" == *"prin.unused -> scripts/quokka-check.sh"* ]]
}

@test "control named only in agent prose is PROSE, not AUTOMATED" {
  touch "$FIX/scripts/quokka-check.sh"
  echo "Run scripts/quokka-check.sh when reviewing." > "$FIX/agents/reviewer.md"
  mk_principle "discretionary" "scripts/quokka-check.sh"
  run bash "$SCRIPT"
  [[ "$output" == *"PROSE-DISPATCHED"* ]]
  [[ "$output" == *"prin.discretionary -> scripts/quokka-check.sh"* ]]
}

@test "control named by settings.json is AUTOMATED" {
  touch "$FIX/scripts/quokka-check.sh"
  echo '{"hooks":{"PreToolUse":[{"command":"scripts/quokka-check.sh"}]}}' > "$FIX/settings.json"
  mk_principle "gated" "scripts/quokka-check.sh"
  run bash "$SCRIPT"
  # AUTOMATED entries are counted, not listed — nothing is wrong with them.
  [[ "$output" == *"AUTOMATED  (machine runs it)     1"* ]]
  [[ "$output" != *"prin.gated ->"* ]]
}

@test "a bare control name resolves to a reviewer agent" {
  echo "reviewer body" > "$FIX/agents/quokka-reviewer.md"
  mk_principle "byname" "quokka-reviewer"
  run bash "$SCRIPT" --strict
  # Resolves, so it is not MISSING; --strict passes.
  [ "$status" -eq 0 ]
  [[ "$output" != *"prin.byname -> quokka-reviewer"*"MISSING"* ]]
}

# --- risks -------------------------------------------------------------------

@test "failure-mode nothing points at is UNTREATED" {
  mk_failure_mode "lonely"
  run bash "$SCRIPT"
  [[ "$output" == *"UNTREATED RISKS"* ]]
  [[ "$output" == *"fm.lonely"* ]]
}

@test "failure-mode named by a procedure counts as treated" {
  mk_failure_mode "handled"
  mkdir -p "$FIX/references/procedures/cat/proc"
  echo "Treats fm.handled by checking first." \
    > "$FIX/references/procedures/cat/proc/PROCEDURE.md"
  run bash "$SCRIPT"
  [[ "$output" == *"risks with a treatment         1"* ]]
  [[ "$output" != *"fm.handled"* ]]
}

# --- modes -------------------------------------------------------------------

@test "--summary prints counts and no per-record lists" {
  mk_principle "dangling" "scripts/does-not-exist-quokka.sh"
  run bash "$SCRIPT" --summary
  [ "$status" -eq 0 ]
  [[ "$output" == *"CONTROL COVERAGE"* ]]
  [[ "$output" != *"prin.dangling"* ]]
}

@test "GRC_COVERAGE_ROOT reroutes the corpus root away from the default" {
  mk_principle "fixture-only" "none-aspirational"
  run bash "$SCRIPT" --summary
  [ "$status" -eq 0 ]
  # One obligation total proves it read the fixture, not the host corpus.
  [[ "$output" == *"(1 obligations, 0 risks)"* ]]
}
