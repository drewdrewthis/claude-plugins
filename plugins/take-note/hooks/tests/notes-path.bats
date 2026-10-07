#!/usr/bin/env bats
# Behavioural test for the default notes directory contract.
#
# WHY. The notes dir is a machine-wide convention — ~/agent-resources/notes —
# and NOTES_DIR is its ONLY override. If that default drifts, every agent on
# the box writes somewhere else and the shared note silently splits. This pins
# the default through note-file.sh (the skill's path resolver) with NOTES_DIR
# unset and HOME sandboxed, asserting both the printed path and that the dir is
# created on first resolution.
#
# Requires bats >= 1.4 for $BATS_TEST_TMPDIR (guarded in setup).
#
# Run: cd plugins/take-note && bats hooks/tests

setup() {
  if [ -z "$BATS_TEST_TMPDIR" ]; then
    printf 'BATS_TEST_TMPDIR is unset: this suite needs bats >= 1.4.\n' >&2
    return 1
  fi
  NOTE_FILE="$BATS_TEST_DIRNAME/../../skills/take-note/scripts/note-file.sh"
}

@test "default notes dir is \$HOME/agent-resources/notes and is created" {
  local home="$BATS_TEST_TMPDIR/home"
  mkdir -p "$home"
  unset NOTES_DIR
  run env -u NOTES_DIR HOME="$home" "$NOTE_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TODAY=$home/agent-resources/notes/$(date +%F).md"* ]]
  [ -d "$home/agent-resources/notes" ]
}
