#!/usr/bin/env bats
# Round-trip: the survey's OWN printed paths must feed straight back into --cat.
#
# This is the loop procedure-scout.md ships — survey, select, batch-read:
#   p=$(query-records.sh --keyword X | awk -F' — ' '{print $1}')
#   query-records.sh --cat $p
# and it was broken on the live corpus while 25 --cat unit tests passed. Two
# independent causes, both invisible to a fixture-sized corpus:
#
#   1. SIGPIPE. The script runs under `set -uo pipefail`. The membership check
#      was `printf '%s\n' "$ALL_FILES" | grep -qxF -- "$ref"`. `grep -q` exits
#      on first match, closing the pipe under the still-writing printf, which
#      dies of SIGPIPE — and pipefail then reports 141 for the PIPELINE, on a
#      SUCCESSFUL match. Every real path read as "not a record".
#      It is SIZE-DEPENDENT: a small corpus fits one atomic write, so printf
#      finishes before grep exits and no SIGPIPE occurs. The old fixtures were
#      ~100 bytes. The live corpus is ~1,800 paths. That gap is the bug.
#
#   2. Shell word-splitting. bash splits an unquoted `$p` on IFS (newline
#      included) into one argv word per path; zsh does not split unquoted
#      expansions at all, so the same command hands --cat ONE word containing
#      newlines. The loop worked under bash and failed under zsh.
#
# So setup() below builds a corpus LARGER THAN THE PIPE BUFFER on purpose, and
# a guard test asserts it stayed that way. Shrink the corpus and these tests
# still pass while proving nothing — the guard exists to make that loud.
#
# Run: bats hooks/tests/query-cat-roundtrip.bats

bats_require_minimum_version 1.5.0

# Comfortably over the 64KiB pipe buffer once rendered as a path list.
CORPUS_FILES=400
PIPE_BUFFER_BYTES=65536

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/query-records.sh"
  FIX="$(mktemp -d)"
  export QUERY_RECORDS_ROOT="$FIX"
  mkdir -p "$FIX/references/decisions"

  # Long names rather than deep trees: same bytes, far fewer syscalls.
  local pad i
  pad="$(printf 'padding-to-make-this-path-long-%.0s' 1 2 3 4 5)"

  for i in $(seq 1 "$CORPUS_FILES"); do
    # printf is a builtin — no fork per record, so 400 files stay fast.
    printf '%s\n' \
      '---' \
      "id: dec.roundtrip$i" \
      'kind: decision' \
      'date: 2026-08-14' \
      'keywords: [roundtripkw]' \
      'links: {}' \
      'status: active' \
      '---' \
      "# Roundtrip decision $i" \
      '' \
      "Body of roundtrip record $i." \
      > "$FIX/references/decisions/$pad-$i.md"
  done

  # What the scout actually runs to turn a survey into a path list.
  SURVEY() { bash "$SCRIPT" --keyword roundtripkw | awk -F' — ' '{print $1}'; }
}

teardown() {
  [ -n "${FIX:-}" ] && rm -rf "$FIX"
  true
}

# ---- the guard that keeps the rest of this file honest ----

@test "the round-trip corpus exceeds the pipe buffer, or these tests prove nothing" {
  # Cause 1 cannot reproduce below the pipe buffer. If someone trims the corpus
  # for speed, every test here silently becomes a small-corpus test that would
  # pass against the original bug. Fail loudly instead.
  local listing bytes
  listing="$(cd "$FIX" && find -H references -type f -name '*.md' ! -name 'INDEX.md')"
  bytes="$(printf '%s\n' "$listing" | wc -c | tr -d ' ')"
  [ "$bytes" -gt "$PIPE_BUFFER_BYTES" ] \
    || { echo "corpus path list is $bytes bytes, needs > $PIPE_BUFFER_BYTES to exercise the SIGPIPE path"; false; }
}

# ---- the round trip, from a cwd that is NOT the store root ----

@test "survey paths feed back into --cat, word-split (bash), from a foreign cwd" {
  cd "$BATS_TEST_TMPDIR"   # deliberately not $FIX
  local paths captured
  paths="$(SURVEY | head -3)"
  [ -n "$paths" ]

  # $( ) captures STDOUT ONLY — if the dump ever moves to stderr this is empty,
  # which is the T1 stderr/stdout trap asserted end-to-end rather than by flag.
  # shellcheck disable=SC2086
  captured="$(bash "$SCRIPT" --cat $paths)"

  [ -n "$captured" ] || { echo "round trip dumped NOTHING for paths the survey itself printed"; false; }
  local headers
  headers="$(printf '%s\n' "$captured" | grep -c '^==> ')"
  [ "$headers" -eq 3 ] || { echo "expected 3 records, got $headers"; false; }
  [[ "$captured" == *"Body of roundtrip record"* ]]
}

@test "survey paths feed back into --cat as ONE newline-joined word (zsh, no word-splitting)" {
  # zsh does not word-split unquoted expansions, so the identical command line
  # delivers the whole list as a single argv element containing newlines.
  # Simulated exactly by quoting the expansion under bash.
  cd "$BATS_TEST_TMPDIR"
  local paths captured
  paths="$(SURVEY | head -3)"

  captured="$(bash "$SCRIPT" --cat "$paths")"

  [ -n "$captured" ] || { echo "newline-joined path list dumped NOTHING"; false; }
  local headers
  headers="$(printf '%s\n' "$captured" | grep -c '^==> ')"
  [ "$headers" -eq 3 ] || { echo "expected 3 records, got $headers"; false; }
}

@test "the round trip exits 0 on success" {
  cd "$BATS_TEST_TMPDIR"
  local paths
  paths="$(SURVEY | head -2)"
  # shellcheck disable=SC2086
  run --separate-stderr bash "$SCRIPT" --cat $paths
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

# ---- refusal stays loud ----

@test "a non-record in the survey list aborts the batch with a NONZERO exit" {
  # The loud-bad-query rule: a refusal must never look like a successful empty
  # read. Asserted on both channels — nonzero status AND an empty stdout dump.
  cd "$BATS_TEST_TMPDIR"
  local paths
  paths="$(SURVEY | head -2)"
  run --separate-stderr bash -c \
    "bash '$SCRIPT' --cat \$(printf '%s\n' \"\$0\") references/decisions/not-a-real-record.md" "$paths"

  [ "$status" -eq 2 ] || { echo "expected exit 2 on a bad ref, got $status"; false; }
  [ -z "$output" ] || { echo "ATOMICITY BROKEN: dumped records despite a bad ref: $output"; false; }
  [[ "$stderr" == *"not a record in the scanned stores"* ]]
}

@test "a non-record smuggled INSIDE a newline-joined word still aborts the batch" {
  # The expansion in cause 2 must not become a bypass: every element it produces
  # is validated, so a smuggled non-record aborts exactly like a separate one.
  cd "$BATS_TEST_TMPDIR"
  local paths joined
  paths="$(SURVEY | head -2)"
  joined="$paths
references/decisions/not-a-real-record.md"

  run --separate-stderr bash "$SCRIPT" --cat "$joined"

  [ "$status" -eq 2 ]
  [ -z "$output" ] || { echo "smuggled non-record did not abort the batch: $output"; false; }
  [[ "$stderr" == *"not-a-real-record.md"* ]]
}
