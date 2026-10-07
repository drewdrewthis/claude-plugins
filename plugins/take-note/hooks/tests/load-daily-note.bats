#!/usr/bin/env bats
# Behavioural tests for hooks/load-daily-note.sh — the SessionStart loader.
#
# WHY THIS SHAPE. The note file is shared by every agent on the machine and
# grows all day, so the dangerous failure is the loader dumping the WHOLE file
# into every session's context. The assertions therefore pin the cap: total
# output stays small, only the tail (never the top of a long file) is emitted,
# and exactly one file is ever loaded. The open-item index is asserted to
# INCLUDE open headings and EXCLUDE both closed (" — done") ones and the
# "### Scratch" bucket — the three states that decide what an agent sees first.
# The missing-file path asserts exit 0 with no notes header, because the hook
# must fail open and never block a session over an absent note.
#
# Every fixture is synthetic and written under $BATS_TEST_TMPDIR; NOTES_DIR and
# ABOUT_MY_PERSON_FILE are pointed into the sandbox so no real note or person
# file is read. The previous-day fixture uses a fixed past date (2000-01-01) so
# notes_prev_file picks it regardless of the real calendar date.
#
# Requires bats >= 1.4 for $BATS_TEST_TMPDIR (guarded in setup). Deliberately
# avoids bats >= 1.5 features. Portable to the ubuntu-latest apt bats.
#
# Run: cd plugins/take-note && bats hooks/tests

setup() {
  # Every test writes into $BATS_TEST_TMPDIR. On bats < 1.4 it is unset, which
  # would scatter fixtures through the checkout — fail loudly instead.
  if [ -z "$BATS_TEST_TMPDIR" ]; then
    printf 'BATS_TEST_TMPDIR is unset: this suite needs bats >= 1.4.\n' >&2
    return 1
  fi

  HOOK="$BATS_TEST_DIRNAME/../load-daily-note.sh"
  export NOTES_DIR="$BATS_TEST_TMPDIR/notes"
  mkdir -p "$NOTES_DIR"
  # Point the ABOUT file at a non-existent path so the person block never fires
  # and the note output is all that appears.
  export ABOUT_MY_PERSON_FILE="$BATS_TEST_TMPDIR/no-such-about.md"
  TODAY="$NOTES_DIR/$(date +%F).md"
  PREV="$NOTES_DIR/2000-01-01.md"
}

# (1) A long today file is capped: small total output, the tail is present, the
# top of the file is not.
@test "long today file is capped to a small output with only the tail" {
  {
    echo "### open item one"
    echo "- TOP_LINE_BODY_UNIQUE"
    i=0
    while [ "$i" -lt 497 ]; do
      echo "filler line $i"
      i=$((i + 1))
    done
    echo "LAST_LINE_BODY_UNIQUE"
  } > "$TODAY"
  # Sanity: the fixture is 500 lines.
  [ "$(wc -l < "$TODAY" | tr -d ' ')" -eq 500 ]

  run "$HOOK"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -le 40 ]
  [[ "$output" == *"$TODAY"* ]]
  [[ "$output" == *"LAST_LINE_BODY_UNIQUE"* ]]
  [[ "$output" != *"TOP_LINE_BODY_UNIQUE"* ]]
  [[ "$output" == *"Last 20 lines (of 500):"* ]]
}

# (2) Open items are listed; closed (" — done") items and Scratch are excluded.
@test "open items listed, done items and Scratch excluded" {
  {
    echo "# 2026-10-07 — work notes"
    echo
    echo "### https://example.com/issues/1"
    echo "- 02:40 note"
    echo "### closed thread — done"
    echo "- 03:10 merged"
    echo "### Scratch"
    echo "- 04:00 scratch text"
    echo "### another open item"
    echo "- 05:00 note"
  } > "$TODAY"

  run "$HOOK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"- https://example.com/issues/1"* ]]
  [[ "$output" == *"- another open item"* ]]
  # The tail legitimately echoes the raw "### Scratch" / "### closed thread —
  # done" lines, so assert only that neither appears as a listed open item
  # (open items are emitted with a "- " prefix and the "### " stripped).
  [[ "$output" != *"- closed thread"* ]]
  [[ "$output" != *"- Scratch"* ]]
}

# (3) No today file → the previous day's file is loaded with the previous-day
# label, and it is the ONLY file loaded (one header line).
@test "no today file falls back to previous day with its label" {
  {
    echo "### yesterday open item"
    echo "- 09:00 note"
  } > "$PREV"
  [ ! -e "$TODAY" ]

  run "$HOOK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$PREV"* ]]
  [[ "$output" == *"(previous day — no note yet today)"* ]]
  [[ "$output" == *"- yesterday open item"* ]]
  # Exactly one file loaded → exactly one "## Work notes" header line.
  [ "$(printf '%s\n' "$output" | grep -c '^## Work notes')" -eq 1 ]
}

# (4) No files at all → exit 0, and no notes header is emitted (fail open).
@test "no note files emits no notes header and exits 0" {
  run "$HOOK"
  [ "$status" -eq 0 ]
  [[ "$output" != *"## Work notes"* ]]
}

# (5) The pointer line steering agents to the full file and /take-note is shown.
@test "pointer line is present" {
  {
    echo "### an open item"
    echo "- 01:00 note"
  } > "$TODAY"

  run "$HOOK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Read the full file when your task touches other work. Write via /take-note."* ]]
}
