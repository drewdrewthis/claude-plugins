#!/usr/bin/env bats
# Tests for scripts/compile-records.sh — stage 2 of the two-stage retrieval
# pipeline: expands a stage-1 selection (numbers, or ids as fallback) from
# map.tsv into full record text, with optional cycle-safe link expansion and
# a byte budget. No model calls; a fixture corpus + hand-built map.tsv are
# created fresh per test in setup().
#
# Run: bats hooks/tests/compile-records.bats

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/compile-records.sh"
  TMP="$(mktemp -d)"
  CORPUS="$TMP/corpus"
  mkdir -p "$CORPUS"
  MAP="$TMP/map.tsv"

  # rec.a <-> rec.b: mutually-linking pair, used for link-expansion and
  # cycle-safety tests.
  cat > "$CORPUS/rec-a.md" <<'EOF'
---
id: rec.a
kind: solution
date: 2026-08-01
keywords: [alpha]
links: {procedures: [], solutions: [], decisions: [], research: [], plans: [], principles: [], failure-modes: [rec.b]}
status: active
---
# Record A
Fixture body content for record a.
EOF

  cat > "$CORPUS/rec-b.md" <<'EOF'
---
id: rec.b
kind: failure-mode
date: 2026-08-01
keywords: [beta]
links: {procedures: [], solutions: [rec.a], decisions: [], research: [], plans: [], principles: [], failure-modes: []}
status: active
---
# Record B
Fixture body content for record b, links back to a.
EOF

  # rec.c: no links, plain record.
  cat > "$CORPUS/rec-c.md" <<'EOF'
---
id: rec.c
kind: research
date: 2026-08-01
keywords: [gamma]
links: {}
status: active
---
# Record C
Fixture body content for record c.
EOF

  # rec.d: no links; target of the unreadable-path tests (chmod'd 000
  # inside the specific tests that need it).
  cat > "$CORPUS/rec-d.md" <<'EOF'
---
id: rec.d
kind: research
date: 2026-08-01
keywords: [delta]
links: {}
status: active
---
# Record D
Fixture body content for record d.
EOF

  # rec.e: no links; a second plain direct-selection candidate, used by the
  # budget-priority test.
  cat > "$CORPUS/rec-e.md" <<'EOF'
---
id: rec.e
kind: research
date: 2026-08-01
keywords: [epsilon]
links: {}
status: active
---
# Record E
Fixture body content for record e.
EOF

  # rec.f: links to an id that does not exist anywhere in map.tsv — the
  # unresolved-link-target case.
  cat > "$CORPUS/rec-f.md" <<'EOF'
---
id: rec.f
kind: research
date: 2026-08-01
keywords: [zeta]
links: {procedures: [], solutions: [], decisions: [], research: [rec.ghost], plans: [], principles: [], failure-modes: []}
status: active
---
# Record F
Fixture body content for record f, links to a ghost id.
EOF

  printf '1\trec.a\t%s/rec-a.md\n' "$CORPUS" > "$MAP"
  printf '2\trec.b\t%s/rec-b.md\n' "$CORPUS" >> "$MAP"
  printf '3\trec.c\t%s/rec-c.md\n' "$CORPUS" >> "$MAP"
  printf '4\trec.d\t%s/rec-d.md\n' "$CORPUS" >> "$MAP"
  printf '5\trec.e\t%s/rec-e.md\n' "$CORPUS" >> "$MAP"
  printf '6\trec.f\t%s/rec-f.md\n' "$CORPUS" >> "$MAP"
}

teardown() {
  chmod -R u+rwx "$TMP" 2>/dev/null || true
  rm -rf "$TMP"
}

# Runs the script with a single-number selection and echoes the "bytes=N"
# summary value, so budget tests can compute a threshold from a REAL
# measured block size instead of a hardcoded byte count (the header line
# embeds $CORPUS's mktemp path, whose length is not fixed across runs).
measure_bytes() {
  run bash "$SCRIPT" --map "$MAP" --nums "$1"
  printf '%s\n' "$output" | grep -oE 'bytes=[0-9]+' | cut -d= -f2
}

# ---------- required test 1 ----------

@test "a plain comma list resolves and emits records in selection order" {
  bash "$SCRIPT" --map "$MAP" --nums "3,1" >"$TMP/out.txt" 2>"$TMP/err.txt"
  ec=$?
  [ "$ec" -eq 0 ]
  first_line="$(grep -n '^===== RECORD' "$TMP/out.txt" | head -1)"
  second_line="$(grep -n '^===== RECORD' "$TMP/out.txt" | tail -1)"
  [[ "$first_line" == *"RECORD 3 rec.c"* ]]
  [[ "$second_line" == *"RECORD 1 rec.a"* ]]
}

# ---------- required tests 2 & 3 ----------

@test "a fenced json array (the real model output shape) parses and resolves correctly" {
  run bash "$SCRIPT" --map "$MAP" --nums '```json
[1, 3]
```'
  [ "$status" -eq 0 ]
  [[ "$output" == *"RECORD 1 rec.a"* ]]
  [[ "$output" == *"RECORD 3 rec.c"* ]]
}

@test "a bare json array parses and resolves correctly" {
  run bash "$SCRIPT" --map "$MAP" --nums '[1, 3]'
  [ "$status" -eq 0 ]
  [[ "$output" == *"RECORD 1 rec.a"* ]]
  [[ "$output" == *"RECORD 3 rec.c"* ]]
}

# ---------- required test 4 ----------

@test "an out-of-range number is reported unresolvable on stderr and never appears on stdout" {
  bash "$SCRIPT" --map "$MAP" --nums "1,9999" >"$TMP/out.txt" 2>"$TMP/err.txt"
  ec=$?
  [ "$ec" -eq 0 ]
  grep -q "unresolvable" "$TMP/err.txt"
  grep -q "9999" "$TMP/err.txt"
  ! grep -q "9999" "$TMP/out.txt"
}

# ---------- required test 5 ----------

@test "--strict exits non-zero when a requested number is unresolvable" {
  run bash "$SCRIPT" --map "$MAP" --nums "1,9999" --strict
  [ "$status" -ne 0 ]
}

# ---------- required test 6 ----------

@test "duplicate numbers in the selection are emitted once" {
  run bash "$SCRIPT" --map "$MAP" --nums "1,1,1"
  [ "$status" -eq 0 ]
  count="$(printf '%s\n' "$output" | grep -c '^===== RECORD')"
  [ "$count" -eq 1 ]
}

# ---------- required test 7 ----------

@test "--expand-links emits records linked from a selected record" {
  run bash "$SCRIPT" --map "$MAP" --nums "1" --expand-links
  [ "$status" -eq 0 ]
  [[ "$output" == *"RECORD 1 rec.a"* ]]
  [[ "$output" == *"RECORD 2 rec.b"* ]]
}

# ---------- required test 8 ----------

@test "an A->B->A link cycle terminates and emits each record exactly once" {
  # link-depth 5 is deliberately far beyond what a 2-node cycle needs, so
  # this proves the VISITED-set guard stops the recursion, not the depth
  # bound — depth 1 (the default) would never even look at B's own links,
  # which would pass trivially without exercising the guard at all.
  run bash "$SCRIPT" --map "$MAP" --nums "1" --expand-links --link-depth 5
  [ "$status" -eq 0 ]
  count="$(printf '%s\n' "$output" | grep -c '^===== RECORD')"
  [ "$count" -eq 2 ]
  a_count="$(printf '%s\n' "$output" | grep -c '^===== RECORD 1 rec.a')"
  b_count="$(printf '%s\n' "$output" | grep -c '^===== RECORD 2 rec.b')"
  [ "$a_count" -eq 1 ]
  [ "$b_count" -eq 1 ]
}

# ---------- required test 9 ----------

@test "--link-depth 0 suppresses expansion entirely" {
  run bash "$SCRIPT" --map "$MAP" --nums "1" --expand-links --link-depth 0
  [ "$status" -eq 0 ]
  count="$(printf '%s\n' "$output" | grep -c '^===== RECORD')"
  [ "$count" -eq 1 ]
}

# ---------- required test 10 ----------

@test "--max-bytes drops records when the budget is tight and names them loudly on stderr" {
  size1="$(measure_bytes 1)"
  [ -n "$size1" ]
  budget=$((size1 + 10))

  bash "$SCRIPT" --map "$MAP" --nums "1,2,3" --max-bytes "$budget" >"$TMP/out.txt" 2>"$TMP/err.txt"
  ec=$?
  [ "$ec" -eq 0 ]
  # record 1 alone fits (size1 <= budget); records 2 and 3 each individually
  # exceed the remaining ~10 bytes of headroom, so both are dropped.
  grep -q "RECORD 1 rec.a" "$TMP/out.txt"
  ! grep -q "RECORD 2 rec.b" "$TMP/out.txt"
  ! grep -q "RECORD 3 rec.c" "$TMP/out.txt"
  grep -q "exceeded" "$TMP/err.txt"
  grep -q "rec.b" "$TMP/err.txt"
  grep -q "rec.c" "$TMP/err.txt"
}

@test "--max-bytes so tight nothing fits leaves zero emitted and exits non-zero" {
  if bash "$SCRIPT" --map "$MAP" --nums "1,2,3" --max-bytes 1 >"$TMP/out.txt" 2>"$TMP/err.txt"; then
    ec=0
  else
    ec=$?
  fi
  [ "$ec" -ne 0 ]
  [ ! -s "$TMP/out.txt" ]
  grep -q "nothing was emitted" "$TMP/err.txt"
}

# ---------- required test 11 ----------

@test "an empty/garbage selection exits non-zero and touches no output" {
  if bash "$SCRIPT" --map "$MAP" --nums "abc,xyz,###" >"$TMP/out.txt" 2>"$TMP/err.txt"; then
    ec=0
  else
    ec=$?
  fi
  [ "$ec" -ne 0 ]
  [ ! -s "$TMP/out.txt" ]
  grep -q "empty selection" "$TMP/err.txt"
}

# ---------- required test 12 ----------

@test "stdout carries no diagnostic text, even when some requests are unresolvable" {
  bash "$SCRIPT" --map "$MAP" --nums "1,9999" >"$TMP/out.txt" 2>"$TMP/err.txt"
  ec=$?
  [ "$ec" -eq 0 ]
  ! grep -q "unresolvable" "$TMP/out.txt"
  ! grep -q "compile-records:" "$TMP/out.txt"
  ! grep -q "summary:" "$TMP/out.txt"
}

# ---------- extra: --ids fallback path + the hallucination detector ----------

@test "--ids selects by id string and reports a fabricated id as unresolvable" {
  bash "$SCRIPT" --map "$MAP" --ids "rec.a,rec.fake" >"$TMP/out.txt" 2>"$TMP/err.txt"
  ec=$?
  [ "$ec" -eq 0 ]
  grep -q "RECORD 1 rec.a" "$TMP/out.txt"
  grep -q "unresolvable" "$TMP/err.txt"
  grep -q "rec.fake" "$TMP/err.txt"
  ! grep -q "rec.fake" "$TMP/out.txt"
}

# ---------- extra: --nums-file ----------

@test "--nums-file parses the same list shapes as --nums, read from a file" {
  printf '```json\n[1, 3]\n```\n' > "$TMP/nums.txt"
  run bash "$SCRIPT" --map "$MAP" --nums-file "$TMP/nums.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RECORD 1 rec.a"* ]]
  [[ "$output" == *"RECORD 3 rec.c"* ]]
}

# ---------- extra: unreadable map.tsv path ----------

@test "an unreadable path in map.tsv is reported loudly and skipped, not fatal alongside a readable record" {
  chmod 000 "$CORPUS/rec-d.md"
  bash "$SCRIPT" --map "$MAP" --nums "1,4" >"$TMP/out.txt" 2>"$TMP/err.txt"
  ec=$?
  [ "$ec" -eq 0 ]
  grep -q "RECORD 1 rec.a" "$TMP/out.txt"
  ! grep -q "RECORD 4 rec.d" "$TMP/out.txt"
  grep -q "unreadable" "$TMP/err.txt"
  grep -q "rec.d" "$TMP/err.txt"
}

@test "an unreadable path as the sole selection leaves nothing emitted and exits non-zero" {
  chmod 000 "$CORPUS/rec-d.md"
  if bash "$SCRIPT" --map "$MAP" --nums "4" >"$TMP/out.txt" 2>"$TMP/err.txt"; then
    ec=0
  else
    ec=$?
  fi
  [ "$ec" -ne 0 ]
  [ ! -s "$TMP/out.txt" ]
  grep -q "unreadable" "$TMP/err.txt"
  grep -q "nothing was emitted" "$TMP/err.txt"
}

# ---------- extra: unresolved link target ----------

@test "a links: target absent from map.tsv is reported but not fatal" {
  bash "$SCRIPT" --map "$MAP" --nums "6" --expand-links >"$TMP/out.txt" 2>"$TMP/err.txt"
  ec=$?
  [ "$ec" -eq 0 ]
  grep -q "RECORD 6 rec.f" "$TMP/out.txt"
  grep -q "unresolvable link target" "$TMP/err.txt"
  grep -q "rec.ghost" "$TMP/err.txt"
}

# ---------- extra: budget priority (direct beats link-expanded) ----------

@test "direct selections take priority over link-expanded records when the budget is tight" {
  size1="$(measure_bytes 1)"
  size5="$(measure_bytes 5)"
  [ -n "$size1" ]
  [ -n "$size5" ]
  budget=$((size1 + size5 + 10))

  # 1 (direct) links to 2/rec.b (expansion); 5 (direct) has no links. Both
  # directs fit; adding rec.b's expansion would exceed the ~10-byte
  # headroom, so a record selected AFTER rec.a still bumps an expansion
  # discovered BEFORE it — proving priority order, not arrival order.
  bash "$SCRIPT" --map "$MAP" --nums "1,5" --expand-links --max-bytes "$budget" >"$TMP/out.txt" 2>"$TMP/err.txt"
  ec=$?
  [ "$ec" -eq 0 ]
  grep -q "RECORD 1 rec.a" "$TMP/out.txt"
  grep -q "RECORD 5 rec.e" "$TMP/out.txt"
  ! grep -q "RECORD 2 rec.b" "$TMP/out.txt"
  grep -q "rec.b" "$TMP/err.txt"
}

# ---------- extra: usage errors ----------

@test "--map is required" {
  run bash "$SCRIPT" --nums "1"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--map is required"* ]]
}

@test "choosing more than one selection source is a usage error" {
  run bash "$SCRIPT" --map "$MAP" --nums "1" --ids "rec.a"
  [ "$status" -eq 2 ]
  [[ "$output" == *"exactly one"* ]]
}

@test "a non-integer --link-depth is a usage error" {
  run bash "$SCRIPT" --map "$MAP" --nums "1" --link-depth abc
  [ "$status" -eq 2 ]
}

@test "a missing --map file is a fatal error, not a usage error" {
  run bash "$SCRIPT" --map "$TMP/does-not-exist.tsv" --nums "1"
  [ "$status" -eq 1 ]
}

# ---------- bash-4 re-exec guard (regression) ----------

@test "runs end-to-end when launched via a bash<4 interpreter (declare -A guard re-execs)" {
  # The script uses `declare -A`, so it must run under bash 4+. When invoked
  # via macOS's frozen /bin/bash 3.2, lib/require-bash4.sh must transparently
  # re-exec it under a bash 4+ and still produce records. Skip where no bash<4
  # interpreter exists (typical Linux CI: /bin/bash is already >=4, in which
  # case every other test in this file already covers the invocation).
  local low="/bin/bash" major
  major="$("$low" -c 'printf %s "${BASH_VERSINFO[0]:-0}"' 2>/dev/null || echo 0)"
  [ "$major" -lt 4 ] || skip "no bash<4 at $low on this host"
  run "$low" "$SCRIPT" --map "$MAP" --nums "1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RECORD 1 rec.a"* ]]
}
