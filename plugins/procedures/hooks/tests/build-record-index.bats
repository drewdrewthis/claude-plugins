#!/usr/bin/env bats
# build-record-index.sh builds the numbered index a Haiku fork selects
# records from by INTEGER rather than by id string (selecting by id string
# measured 2/2 fabricated ids; by integer, 0/2). These tests pin: the four
# exclusions (node_modules, EVOLUTION.md/INDEX.md, frontmatter-scoped
# user-invocable, stale references/plans/), the id+description inclusion
# rule, description normalization (no tab/newline can reach the output),
# byte-identical determinism across runs, and the zero-records hard abort.
#
# Run: bats hooks/tests/build-record-index.bats

bats_require_minimum_version 1.5.0

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/build-record-index.sh"
  FIX="$(mktemp -d)"
  OUT="$(mktemp -d)"

  mkdir -p "$FIX/references/solutions/node_modules/pkg"
  mkdir -p "$FIX/references/decisions"
  mkdir -p "$FIX/references/plans"
  mkdir -p "$FIX/plans"

  # -- valid records (6 total; this is the fixture's known-good count) ----
  cat > "$FIX/references/solutions/good-alpha.md" <<'EOF'
---
id: sol.good-alpha
kind: solution
date: 2026-08-01
keywords: [alpha]
links: {}
status: active
description: Alpha solution description for indexing.
---
# Alpha
EOF

  cat > "$FIX/references/solutions/good-beta.md" <<'EOF'
---
id: sol.good-beta
kind: solution
date: 2026-08-02
keywords: [beta]
links: {}
status: active
description: Beta solution description for indexing.
---
# Beta
EOF

  cat > "$FIX/references/decisions/good-gamma.md" <<'EOF'
---
id: dec.good-gamma
kind: decision
date: 2026-08-03
keywords: [gamma]
links: {}
status: active
description: Gamma decision description for indexing.
---
# Gamma
EOF

  cat > "$FIX/plans/good-delta.md" <<'EOF'
---
id: plan.good-delta
kind: plan
date: 2026-08-04
keywords: [delta]
links: {}
status: active
description: Delta plan description for indexing.
---
# Delta
EOF

  # -- user-invocable in FRONTMATTER: excluded (command file, not a record) -
  cat > "$FIX/references/solutions/skill-like.md" <<'EOF'
---
name: skill-like
description: "A command file, not a record."
user-invocable: true
---
# Not a record
EOF

  # -- user-invocable mentioned only in BODY: still included (regression) --
  cat > "$FIX/references/solutions/mentions-user-invocable.md" <<'EOF'
---
id: sol.mentions-user-invocable
kind: solution
date: 2026-08-05
keywords: [body-mention]
links: {}
status: active
description: Body mentions user-invocable but frontmatter does not.
---
# Body text

This solution's body happens to say user-invocable: true as an example,
which must not exclude the record.
EOF

  # -- id but no description: counted + skipped ----------------------------
  cat > "$FIX/references/solutions/id-no-desc.md" <<'EOF'
---
id: sol.id-no-desc
kind: solution
date: 2026-08-06
keywords: [missing-desc]
links: {}
status: active
---
# No description
EOF

  # -- description but no id: counted + skipped -----------------------------
  cat > "$FIX/references/solutions/desc-no-id.md" <<'EOF'
---
kind: solution
date: 2026-08-07
keywords: [missing-id]
links: {}
status: active
description: Has a description but is missing its id.
---
# No id
EOF

  # -- no opening fence at all: unparseable ----------------------------------
  cat > "$FIX/references/solutions/no-fence.md" <<'EOF'
# Not fenced at all

id: sol.no-fence
description: This file never opens a frontmatter fence.
EOF

  # -- opening fence that never closes: unparseable --------------------------
  cat > "$FIX/references/solutions/unclosed.md" <<'EOF'
---
id: sol.unclosed
kind: solution
date: 2026-08-08
keywords: [unclosed]
links: {}
status: active
description: This frontmatter fence never closes.
# no closing fence follows, deliberately
EOF

  # -- tab in the value + a wrapped continuation line: must normalize to one
  #    clean, single-line, 3-field record ------------------------------------
  {
    printf -- '---\n'
    printf 'id: sol.tab-and-wrap\n'
    printf 'kind: solution\n'
    printf 'date: 2026-08-09\n'
    printf 'keywords: [tab]\n'
    printf 'links: {}\n'
    printf 'status: active\n'
    printf 'description: Two\ttabbed\n'
    printf '  and wrapped words.\n'
    printf -- '---\n'
    printf '# Tab and wrap\n'
  } > "$FIX/references/solutions/tab-and-wrap.md"

  # -- EVOLUTION.md / INDEX.md: excluded by filename --------------------------
  cat > "$FIX/references/solutions/EVOLUTION.md" <<'EOF'
---
id: sol.should-not-appear-evolution
kind: solution
date: 2026-08-10
keywords: [x]
links: {}
status: active
description: Should never be indexed -- EVOLUTION.md is excluded by name.
---
EOF

  cat > "$FIX/references/solutions/INDEX.md" <<'EOF'
---
id: sol.should-not-appear-index
kind: solution
date: 2026-08-10
keywords: [x]
links: {}
status: active
description: Should never be indexed -- INDEX.md is excluded by name.
---
EOF

  # -- node_modules: excluded by path -------------------------------------------
  cat > "$FIX/references/solutions/node_modules/pkg/vendored.md" <<'EOF'
---
id: sol.should-not-appear-node-modules
kind: solution
date: 2026-08-10
keywords: [x]
links: {}
status: active
description: Should never be indexed -- lives under node_modules.
---
EOF

  # -- stale references/plans/: excluded wholesale, even though it would --------
  #    otherwise be discovered as its own store
  cat > "$FIX/references/plans/stale.md" <<'EOF'
---
id: plan.stale-should-not-appear
kind: plan
date: 2026-08-10
keywords: [x]
links: {}
status: active
description: Should never be indexed -- references/plans is a stale store.
---
EOF
}

teardown() {
  [ -n "${FIX:-}" ] && rm -rf "$FIX"
  [ -n "${OUT:-}" ] && rm -rf "$OUT"
}

@test "index.txt and map.tsv have the same line count, and N is contiguous 1..count in both" {
  run bash "$SCRIPT" --out "$OUT" --root "$FIX"
  [ "$status" -eq 0 ]

  idx_lines="$(wc -l < "$OUT/index.txt" | tr -d ' ')"
  map_lines="$(wc -l < "$OUT/map.tsv" | tr -d ' ')"
  [ "$idx_lines" -eq 6 ]
  [ "$map_lines" -eq 6 ]

  expected="$(seq 1 6)"
  idx_ns="$(awk '{print $1}' "$OUT/index.txt")"
  map_ns="$(cut -f1 "$OUT/map.tsv")"
  [ "$idx_ns" = "$expected" ]
  [ "$map_ns" = "$expected" ]
}

@test "a file with user-invocable: in its FRONTMATTER is excluded" {
  run bash "$SCRIPT" --out "$OUT" --root "$FIX"
  [ "$status" -eq 0 ]
  ! grep -qF "A command file, not a record." "$OUT/index.txt"
  ! grep -qF "skill-like" "$OUT/map.tsv"
}

@test "a file with user-invocable: in its BODY is still INCLUDED (the regression that matters)" {
  run bash "$SCRIPT" --out "$OUT" --root "$FIX"
  [ "$status" -eq 0 ]
  grep -qF "sol.mentions-user-invocable" "$OUT/map.tsv"
}

@test "EVOLUTION.md, INDEX.md, and node_modules files are excluded" {
  run bash "$SCRIPT" --out "$OUT" --root "$FIX"
  [ "$status" -eq 0 ]
  ! grep -qF "sol.should-not-appear-evolution" "$OUT/map.tsv"
  ! grep -qF "sol.should-not-appear-index" "$OUT/map.tsv"
  ! grep -qF "sol.should-not-appear-node-modules" "$OUT/map.tsv"
}

@test "a record with an id but no description is skipped and counted on stderr (and vice versa)" {
  run --separate-stderr bash "$SCRIPT" --out "$OUT" --root "$FIX"
  [ "$status" -eq 0 ]
  [[ "$stderr" =~ "1 file(s) have an id but no description" ]]
  [[ "$stderr" =~ "1 file(s) have a description but no id" ]]
  ! grep -qF "sol.id-no-desc" "$OUT/map.tsv"
  ! grep -qF "Has a description but is missing its id." "$OUT/index.txt"
}

@test "two consecutive runs produce byte-identical output" {
  OUT2="$(mktemp -d)"
  run bash "$SCRIPT" --out "$OUT" --root "$FIX"
  [ "$status" -eq 0 ]
  run bash "$SCRIPT" --out "$OUT2" --root "$FIX"
  [ "$status" -eq 0 ]

  diff "$OUT/index.txt" "$OUT2/index.txt"
  diff "$OUT/map.tsv" "$OUT2/map.tsv"
  rm -rf "$OUT2"
}

@test "a description containing a tab and a newline is normalized: map.tsv stays 3 fields, index.txt stays 1 line" {
  run bash "$SCRIPT" --out "$OUT" --root "$FIX"
  [ "$status" -eq 0 ]

  map_row="$(grep -F "sol.tab-and-wrap" "$OUT/map.tsv")"
  [ -n "$map_row" ]
  nf="$(printf '%s\n' "$map_row" | awk -F'\t' '{print NF}')"
  [ "$nf" -eq 3 ]

  idx_matches="$(grep -c "and wrapped words" "$OUT/index.txt")"
  [ "$idx_matches" -eq 1 ]
  grep -qF "Two tabbed and wrapped words." "$OUT/index.txt"
  ! grep -P "\t" "$OUT/index.txt" >/dev/null 2>&1 || {
    # Fallback if -P is unsupported: assert no literal tab byte via a plain
    # bracket-expression match instead of relying on PCRE.
    ! grep -q "$(printf '\t')" "$OUT/index.txt"
  }
}

@test "zero indexed records aborts non-zero" {
  EMPTY_FIX="$(mktemp -d)"
  mkdir -p "$EMPTY_FIX/references/solutions"
  cat > "$EMPTY_FIX/references/solutions/neither.md" <<'EOF'
---
kind: solution
date: 2026-08-11
keywords: [neither]
links: {}
status: active
---
# Neither id nor description present
EOF
  EMPTY_OUT="$(mktemp -d)"
  run bash "$SCRIPT" --out "$EMPTY_OUT" --root "$EMPTY_FIX"
  [ "$status" -ne 0 ]
  rm -rf "$EMPTY_FIX" "$EMPTY_OUT"
}

@test "index.txt contains no absolute paths and no id strings" {
  run bash "$SCRIPT" --out "$OUT" --root "$FIX"
  [ "$status" -eq 0 ]

  ! grep -qF "$FIX" "$OUT/index.txt"
  while IFS="$(printf '\t')" read -r _n id _path; do
    [ -n "$id" ] || continue
    ! grep -qF "$id" "$OUT/index.txt"
  done < "$OUT/map.tsv"
}

@test "the stale references/plans/ store is excluded even though it would otherwise be discovered" {
  run bash "$SCRIPT" --out "$OUT" --root "$FIX"
  [ "$status" -eq 0 ]
  ! grep -qF "plan.stale-should-not-appear" "$OUT/map.tsv"
  # the live top-level plans/ store still contributes its one real record
  grep -qF "plan.good-delta" "$OUT/map.tsv"
  plans_rows="$(awk -F'\t' '$3 ~ "/plans/"' "$OUT/map.tsv" | grep -c .)"
  [ "$plans_rows" -eq 1 ]
}

@test "--strict fails when any file was skipped; a clean-only corpus still exits 0 under --strict" {
  run bash "$SCRIPT" --out "$OUT" --root "$FIX" --strict
  [ "$status" -ne 0 ]

  CLEAN_FIX="$(mktemp -d)"
  mkdir -p "$CLEAN_FIX/references/solutions"
  cat > "$CLEAN_FIX/references/solutions/only-good.md" <<'EOF'
---
id: sol.only-good
kind: solution
date: 2026-08-12
keywords: [clean]
links: {}
status: active
description: The only record in a deliberately clean fixture.
---
# Only good
EOF
  CLEAN_OUT="$(mktemp -d)"
  run bash "$SCRIPT" --out "$CLEAN_OUT" --root "$CLEAN_FIX" --strict
  [ "$status" -eq 0 ]
  rm -rf "$CLEAN_FIX" "$CLEAN_OUT"
}

@test "missing --out is a usage error" {
  run bash "$SCRIPT" --root "$FIX"
  [ "$status" -ne 0 ]
}

@test "stdout stays clean -- all diagnostics go to stderr" {
  run --separate-stderr bash "$SCRIPT" --out "$OUT" --root "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$stdout" ]
  [[ "$stderr" =~ "indexed 6 record(s)" ]]
}
