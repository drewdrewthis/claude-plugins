#!/usr/bin/env bats
# Round-trip: the `project:` field is WRITTEN by the record writers and READ
# back by the --project filter, through the real scripts, in one corpus.
#
# --project shipped as a filter over a column nothing wrote. Measured against
# the live corpus at the time: of ~1,800 scanned records, six carried a
# `project:` key at all, every one of them hand-written by a different
# procedure — `--project claude-plugins` and `--project langwatch` both
# returned empty. A filter whose column no writer populates is fail-closed by
# construction, and its emptiness is indistinguishable from a genuine miss.
#
# Unit tests on either half cannot catch that: query-records.bats hand-rolls
# fixture records carrying the key, so the filter passes while no writer emits
# it. These tests deliberately span writer -> corpus -> reader, and lint, so
# the seam is covered rather than each side's fixture.
#
# Run: bats hooks/tests/project-field-roundtrip.bats

setup() {
  PLUGIN="$BATS_TEST_DIRNAME/../.."
  WRITER="$PLUGIN/scripts/log-record.sh"
  QUERY="$PLUGIN/scripts/query-records.sh"
  LINT="$PLUGIN/scripts/lint-frontmatter.sh"
  FIX="$(mktemp -d)"
  # One root for all three scripts — the point of the round-trip is that the
  # writer's output lands where the reader and the lint actually look.
  export CODEX_ROOT="$FIX"
  export QUERY_RECORDS_ROOT="$FIX"
  export LINT_FRONTMATTER_ROOT="$FIX"
  # The failure-mode promotion gate counts occurrences in this file; point it
  # at the fixture so the live ~/.claude/mistakes.jsonl is never read.
  export MISTAKES_JSONL="$FIX/mistakes.jsonl"
  : > "$MISTAKES_JSONL"
}

teardown() {
  [ -n "${FIX:-}" ] && rm -rf "$FIX"
  true
}

# ---------------------------------------------------------------------------
# THE ACCEPTANCE CRITERION: a record written by `/log decision --project
# langwatch/scenario` comes back from BOTH the repo-name query and the full
# owner/name query. This is the end-to-end claim the flag rests on.
# ---------------------------------------------------------------------------
@test "a decision written with --project is returned by both --project scenario and --project langwatch/scenario" {
  run bash "$WRITER" decision --slug ac-roundtrip --date 2026-08-10 \
    --title "AC round-trip decision" --keywords '[acroundtripkw]' \
    --project langwatch/scenario
  [ "$status" -eq 0 ]
  [ -f "$FIX/references/decisions/2026-08-10-ac-roundtrip.md" ]

  # by the repo NAME (text after the last `/`)
  run bash "$QUERY" --project scenario
  [ "$status" -eq 0 ]
  [[ "$output" == *"references/decisions/2026-08-10-ac-roundtrip.md"* ]]

  # by the full owner/name
  run bash "$QUERY" --project langwatch/scenario
  [ "$status" -eq 0 ]
  [[ "$output" == *"references/decisions/2026-08-10-ac-roundtrip.md"* ]]
}

@test "the writer's own output passes the frontmatter shape lint" {
  # A writer that emits a value its own lint rejects makes the record
  # uncommittable — the two halves must agree on the grammar.
  run bash "$WRITER" decision --slug lint-parity --date 2026-08-10 \
    --title "Lint parity decision" --keywords '[lintparitykw]' \
    --project langwatch/scenario
  [ "$status" -eq 0 ]
  run env LINT_FRONTMATTER_ROOT="$FIX" bash "$LINT" \
      references/decisions/2026-08-10-lint-parity.md
  [ "$status" -eq 0 ]
}

@test "a solution written with --project is returned by --project" {
  run bash "$WRITER" solution --slug sol-roundtrip --date 2026-08-10 \
    --title "Solution round-trip" --keywords '[solroundtripkw]' \
    --project langwatch/scenario
  [ "$status" -eq 0 ]
  run bash "$QUERY" --project langwatch/scenario
  [ "$status" -eq 0 ]
  [[ "$output" == *"references/solutions/2026-08-10-sol-roundtrip.md"* ]]
}

@test "a failure-mode written with --project is returned by --project" {
  run bash "$WRITER" failure-mode --slug fm-roundtrip --date 2026-08-10 \
    --rule "Always round-trip the project field." --keywords '[fmroundtripkw]' \
    --skip-gate --project langwatch/scenario
  [ "$status" -eq 0 ]
  run bash "$QUERY" --project langwatch/scenario
  [ "$status" -eq 0 ]
  [[ "$output" == *"references/failure-modes/fm-roundtrip.md"* ]]
}

@test "omitting --project writes NO project key, and the record stays corpus-wide" {
  # The default must remain a record with no `project:` line at all. An empty
  # `project:` would be neither scoped nor corpus-wide: unmatchable by every
  # --project query AND rejected by the shape lint.
  run bash "$WRITER" decision --slug no-project --date 2026-08-10 \
    --title "Unscoped decision" --keywords '[noprojectkw]'
  [ "$status" -eq 0 ]
  run grep -c '^project:' "$FIX/references/decisions/2026-08-10-no-project.md"
  [ "$status" -ne 0 ]
  # still discoverable the ordinary way...
  run bash "$QUERY" --keyword noprojectkw
  [ "$status" -eq 0 ]
  [[ "$output" == *"2026-08-10-no-project.md"* ]]
  # ...and correctly invisible to a scoped query, which is why --project is a
  # refinement over the unscoped survey and never a replacement for it.
  run bash "$QUERY" --project langwatch/scenario
  [ "$status" -eq 0 ]
  [[ "$output" != *"2026-08-10-no-project.md"* ]]
}
