#!/usr/bin/env bats
# Tests for query-records.sh --ask — the one-shot front door for the gate
# forks. Per dec.2026-08-07 (decompose-recall-pr-at-the-fts5-translator): these
# are table-driven WHICH-DOCUMENTS assertions over flag/token COMBINATIONS,
# never string-shape checks — every historical defect in this script produced
# well-formed output.
#
# The trimmed output shape (one-query redesign): sectioned output ONLY —
# `== records: N matched ==`, full-text dumps behind `==> path <==` headers up
# to a top-N ceiling that is DISCLOSED by count, then `== mistakes: N matched
# ==`. No gloss list is printed; vendored mirrors fold into their canonical
# twins before the ceiling applies.
#
# Run: bats hooks/tests/query-ask.bats

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/query-records.sh"
  FIX="$(mktemp -d)"
  export QUERY_RECORDS_ROOT="$FIX"
  mkdir -p "$FIX/references/decisions"
  mkdir -p "$FIX/references/solutions"
  mkdir -p "$FIX/references/procedures/sample"

  assert_line_matches() {
    printf '%s\n' "${lines[@]}" | grep -qF -- "$1" || {
      echo "expected a line naming $1; got:"; printf '%s\n' "${lines[@]}"; false; }
  }

  # Decision record: rare keyword quokkadec + shared keyword autonomy.
  cat > "$FIX/references/decisions/sample-decision.md" <<'EOF'
---
id: dec.sample-quokka
kind: decision
date: 2026-06-12
keywords: [quokkadec, autonomy]
links: {}
status: active
---
# Quokka decision

Body about a quokkadec decision.
EOF

  # Solution record: different rare keyword, links to the decision.
  cat > "$FIX/references/solutions/sample-solution.md" <<'EOF'
---
id: sol.sample-fix
kind: solution
date: 2026-06-12
keywords: [quokkasol, recipe]
links: { decisions: [dec.sample-quokka] }
status: resolved
---
# Quokka solution

Body about a recipe.
EOF

  # Procedure record: third store, third rare keyword.
  cat > "$FIX/references/procedures/sample/PROCEDURE.md" <<'EOF'
---
id: proc.sample-thing
kind: procedure
date: 2026-06-12
keywords: [quokkaproc, workflow]
links: {}
status: active
---
# Sample procedure

Steps live here.
EOF

  # mistakes.jsonl: two entries, one sharing the quokka token family via its
  # pattern VALUE, one unrelated.
  cat > "$FIX/mistakes.jsonl" <<'EOF'
{"ts":"2026-08-01T00:00:00Z","pattern":"quokkamistake shipped unreviewed","description":"d1","correction":"c1"}
{"ts":"2026-08-02T00:00:00Z","pattern":"unrelated failure","description":"d2","correction":"c2"}
EOF
}

teardown() { rm -rf "$FIX"; }

# ---------- the union reaches every store ----------

@test "--ask unions all stores from ONE term set" {
  run bash "$SCRIPT" --ask 'quokkadec quokkasol quokkaproc'
  [ "$status" -eq 0 ]
  assert_line_matches 'references/decisions/sample-decision.md'
  assert_line_matches 'references/solutions/sample-solution.md'
  assert_line_matches 'references/procedures/sample/PROCEDURE.md'
}

@test "--ask dumps full content of matched records" {
  run bash "$SCRIPT" --ask 'quokkadec'
  [ "$status" -eq 0 ]
  # The full dump carries body text a gloss line would not.
  assert_line_matches 'Body about a quokkadec decision.'
  assert_line_matches '==> references/decisions/sample-decision.md <=='
}

@test "--ask emits the trimmed sectioned shape: no gloss list, only count + dumps + mistakes" {
  # The redesign replaced the old gloss-list-plus-capped-dump shape with three
  # sections only. A gloss list growing back would mean the fork pays context
  # for every match twice — once as a line, once as a dump.
  run bash "$SCRIPT" --ask 'quokkadec'
  [ "$status" -eq 0 ]
  local glosses
  glosses="$(printf '%s\n' "${lines[@]}" | grep -c '^references/.*\.md — ' || true)"
  [ "$glosses" -eq 0 ] || { echo "--ask grew a gloss list back ($glosses lines)"; false; }
  assert_line_matches '== records: 1 matched =='
  assert_line_matches '==> references/decisions/sample-decision.md <=='
  assert_line_matches '== mistakes: 0 matched =='
}

@test "--ask discloses the top-15 full-text ceiling by count instead of capping silently" {
  # ASK_FULL_CAP=15 bounds the DUMP; the count header still carries EVERY
  # match, and anything past the ceiling must be DISCLOSED with its number and
  # a remedy — never silently dropped. Build 17 matchable records.
  local i
  for i in $(seq 1 17); do
    cat > "$FIX/references/procedures/sample/cap-$i.md" <<EOF
---
id: proc.cap-$i
kind: procedure
date: 2026-06-12
keywords: [capkw$i]
links: {}
status: active
---
Cap body $i.
EOF
  done
  run bash "$SCRIPT" --ask 'capkw1 capkw2 capkw3 capkw4 capkw5 capkw6 capkw7 capkw8 capkw9 capkw10 capkw11 capkw12 capkw13 capkw14 capkw15 capkw16 capkw17'
  [ "$status" -eq 0 ]
  local dumped
  dumped="$(printf '%s\n' "${lines[@]}" | grep -c '^==> .* <==$')"
  assert_line_matches '== records: 17 matched =='
  [ "$dumped" -eq 15 ] || { echo "dumped $dumped records, expected the 15-record ceiling"; false; }
  printf '%s\n' "${lines[@]}" | grep -qF 'full text dumped for the 15 top-ranked; 2 more matched but are not dumped' \
    || { echo "ceiling disclosure missing or miscounted"; false; }
  printf '%s\n' "${lines[@]}" | grep -qF 'narrow the terms' \
    || { echo "disclosure does not name the remedy"; false; }
}

# ---------- the fused mistakes sweep ----------

@test "--ask sweeps mistakes.jsonl with the same terms, in the SAME call" {
  run bash "$SCRIPT" --ask 'quokkamistake'
  [ "$status" -eq 0 ]
  assert_line_matches '== mistakes: 1 matched =='
  assert_line_matches 'quokkamistake shipped unreviewed'
}

@test "a records-miss never skips the mistakes sweep" {
  run bash "$SCRIPT" --ask 'zzznomatch'
  [ "$status" -eq 0 ]
  assert_line_matches '== records: 0 matched =='
  assert_line_matches '== mistakes:'
}

@test "an unrelated mistake does not ride along" {
  run bash "$SCRIPT" --ask 'quokkadec'
  [ "$status" -eq 0 ]
  assert_line_matches '== mistakes: 0 matched =='
  if printf '%s\n' "${lines[@]}" | grep -qF 'unrelated failure'; then
    echo "mistakes sweep leaked an unmatched entry"; false
  fi
}

@test "missing mistakes.jsonl degrades loudly, records answer survives" {
  rm "$FIX/mistakes.jsonl"
  run bash "$SCRIPT" --ask 'quokkadec'
  [ "$status" -eq 0 ]
  assert_line_matches 'sample-decision.md'
  # stderr said why; stdout must NOT fake an == mistakes: 0 matched == line,
  # which reads as "searched, found nothing".
  if printf '%s\n' "${lines[@]}" | grep -q '== mistakes:'; then
    echo "missing recall store printed a results header it could not produce"; false
  fi
}

# ---------- the front-door contract ----------

@test "--ask refuses query-flag combinations (exit 2)" {
  run bash "$SCRIPT" --ask 'x' --keyword y
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" --ask 'x' --recall y
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" --ask 'x' --cat "$FIX/references/decisions/sample-decision.md"
  [ "$status" -eq 2 ]
}

@test "--ask without a term set is a usage error, not an empty success" {
  run bash "$SCRIPT" --ask ''
  [ "$status" -eq 2 ]
}

@test "--ask honors --limit on the match set" {
  # --limit is one of the ranking knobs --ask may combine with; it caps before
  # the ceiling applies, so both header and dump must reflect it.
  run bash "$SCRIPT" --ask 'autonomy recipe workflow' --limit 1
  [ "$status" -eq 0 ]
  local dumped
  dumped="$(printf '%s\n' "${lines[@]}" | grep -c '^==> .* <==$')"
  assert_line_matches '== records: 1 matched =='
  [ "$dumped" -eq 1 ] || { echo "--limit ignored inside --ask: $dumped dumps"; false; }
}

# ---------- vendored mirrors fold into their canonical twins ----------

@test "--ask folds a matched vendored mirror into its canonical twin" {
  # The same record shipped twice (titw/corpus/@owner+repo/ mirror of an
  # in-corpus twin) would be paid twice — dumped twice, counted twice. The
  # fold drops the mirror when its canonical twin ALSO matched, and says so in
  # the count header.
  mkdir -p "$FIX/titw/corpus/@acme+widget/references/decisions"
  cat > "$FIX/references/decisions/twin.md" <<'EOF'
---
id: dec.twinfold
kind: decision
date: 2026-06-12
keywords: [twinfold]
links: {}
status: active
---
# Twin record

Canonical twin body.
EOF
  # Mirror: same path under the vendor prefix, IDENTICAL keywords and heading,
  # so its match line equals the twin's after the prefix is stripped.
  cat > "$FIX/titw/corpus/@acme+widget/references/decisions/twin.md" <<'EOF'
---
id: dec.twinfold
kind: decision
date: 2026-06-12
keywords: [twinfold]
links: {}
status: active
---
# Twin record

Mirror body text.
EOF
  run bash "$SCRIPT" --ask 'twinfold'
  [ "$status" -eq 0 ]
  local dumped
  dumped="$(printf '%s\n' "${lines[@]}" | grep -c '^==> .* <==$')"
  assert_line_matches '== records: 1 matched (1 vendored mirrors folded) =='
  [ "$dumped" -eq 1 ] || { echo "mirror was not folded: $dumped dumps for one logical record"; false; }
  # The CANONICAL twin is what gets dumped, never the vendored copy.
  assert_line_matches 'Canonical twin body.'
  if printf '%s\n' "${lines[@]}" | grep -qF 'Mirror body text'; then
    echo "the vendored mirror leaked into the dump"; false
  fi
}

@test "--ask keeps a vendored record whose canonical twin did not match" {
  # Folding requires BOTH sides to have matched. A vendor-only record is a
  # real answer and must survive untouched.
  mkdir -p "$FIX/titw/corpus/@acme+widget/references/solutions"
  cat > "$FIX/titw/corpus/@acme+widget/references/solutions/lonely.md" <<'EOF'
---
id: sol.lonelyfold
kind: solution
date: 2026-06-12
keywords: [lonelyfold]
links: {}
status: active
---
# Lonely vendor record

Vendor-only body.
EOF
  run bash "$SCRIPT" --ask 'lonelyfold'
  [ "$status" -eq 0 ]
  assert_line_matches '== records: 1 matched =='
  assert_line_matches '==> titw/corpus/@acme+widget/references/solutions/lonely.md <=='
  assert_line_matches 'Vendor-only body.'
}

# ---------- the mistakes section's own cap is loud ----------

@test "--ask caps the mistakes section at the 20 most recent, loudly" {
  local i
  for i in $(seq 1 22); do
    printf '{"ts":"2026-08-03T00:00:%02dZ","pattern":"flood-%d","description":"quokkaplenty miss %d","correction":"c"}\n' \
      "$((i % 60))" "$i" "$i" >> "$FIX/mistakes.jsonl"
  done
  run bash "$SCRIPT" --ask 'quokkaplenty'
  [ "$status" -eq 0 ]
  local hits
  hits="$(printf '%s\n' "${lines[@]}" | grep -c 'quokkaplenty miss')"
  assert_line_matches '== records: 0 matched =='
  assert_line_matches '== mistakes: 22 matched =='
  assert_line_matches '== mistakes: showing the 20 most recent =='
  [ "$hits" -eq 20 ] || { echo "expected exactly 20 shown entries, got $hits"; false; }
}

@test "plain --keyword output shape is unchanged by the new mode" {
  # The legacy callers (update-records, lint flows) must not see section
  # headers appear on their path.
  run bash "$SCRIPT" --keyword 'quokkadec' --full
  [ "$status" -eq 0 ]
  if printf '%s\n' "${lines[@]}" | grep -q '== '; then
    echo "legacy --keyword path grew an --ask section header"; false
  fi
}
