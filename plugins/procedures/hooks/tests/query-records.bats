#!/usr/bin/env bats
# Tests for scripts/query-records.sh — the PULL query interface over the codex
# record stores. Shares scripts/lib/record-match.awk with the router.
#
# Each test builds a tiny fixture corpus under QUERY_RECORDS_ROOT so results
# are deterministic. The fixture records carry proper frontmatter, including
# links between records (for --links-to).
#
# Run: bats hooks/tests/query-records.bats

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/query-records.sh"
  FIX="$(mktemp -d)"
  export QUERY_RECORDS_ROOT="$FIX"
  mkdir -p "$FIX/references/decisions"
  mkdir -p "$FIX/references/solutions"
  mkdir -p "$FIX/references/procedures/sample"
  mkdir -p "$FIX/references/principles"

  # A decision record with a distinctive rare keyword (quokkadec).
  cat > "$FIX/references/decisions/sample-decision.md" <<'EOF'
---
id: dec.sample-quokka
kind: decision
date: 2026-06-12
keywords: [quokkadec, autonomy, delegation]
links: {}
status: active
---
# Sample decision record

Body about a quokkadec decision.
EOF

  # A solution record that LINKS to the decision above.
  cat > "$FIX/references/solutions/sample-solution.md" <<'EOF'
---
id: sol.sample-fix
kind: solution
date: 2026-06-12
keywords: [autonomy, recipe, fixpattern]
links: { decisions: [dec.sample-quokka] }
status: resolved
---
# Sample solution record

Body about a recipe that links the decision.
EOF

  # A procedure record (distinct kind, distinct keyword).
  cat > "$FIX/references/procedures/sample/PROCEDURE.md" <<'EOF'
---
id: proc.sample.thing
kind: procedure
date: 2026-06-12
keywords: [procedurekw, workflow, steps]
links: {}
status: active
---
# Sample procedure

Body of the sample procedure.
EOF

  # A principle record (seventh store, distinct kind).
  cat > "$FIX/references/principles/sample-principle.md" <<'EOF'
---
id: prin.sample
kind: principle
date: 2026-06-12
keywords: [principlekw, design]
links: {}
status: active
enforced_by: hooks/sample-guard.sh
---
# Sample principle

Body of the sample principle.
EOF
}

teardown() {
  [ -n "${FIX:-}" ] && rm -rf "$FIX"
}

# ---- --keyword returns a known fixture record ----

@test "--keyword returns the record whose keywords contain the token" {
  run bash -c "bash '$SCRIPT' --keyword quokkadec"
  [ "$status" -eq 0 ]
  [[ "$output" == *"references/decisions/sample-decision.md"* ]]
}

# ---- --kind filters correctly ----

@test "--kind procedure returns only procedure records" {
  run bash -c "bash '$SCRIPT' --kind procedure"
  [ "$status" -eq 0 ]
  [[ "$output" == *"references/procedures/sample/PROCEDURE.md"* ]]
  [[ "$output" != *"sample-decision.md"* ]]
  [[ "$output" != *"sample-solution.md"* ]]
}

@test "--kind principle reaches the seventh store" {
  run bash -c "bash '$SCRIPT' --kind principle"
  [ "$status" -eq 0 ]
  [[ "$output" == *"references/principles/sample-principle.md"* ]]
}

# ---- --id returns exact match ----

@test "--id returns the exact record" {
  run bash -c "bash '$SCRIPT' --id sol.sample-fix"
  [ "$status" -eq 0 ]
  [[ "$output" == *"references/solutions/sample-solution.md"* ]]
  [[ "$output" != *"sample-decision.md"* ]]
}

# ---- --links-to finds records with that id in their links ----

@test "--links-to finds the record linking the given id" {
  run bash -c "bash '$SCRIPT' --links-to dec.sample-quokka"
  [ "$status" -eq 0 ]
  [[ "$output" == *"references/solutions/sample-solution.md"* ]]
  # the decision itself does not link to its own id
  [[ "$output" != *"sample-decision.md"* ]]
}

# ---- no-match is silent (empty stdout, exit 0) ----

@test "a no-match query prints nothing and exits 0" {
  run bash -c "bash '$SCRIPT' --keyword florblezzqqnonsense"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a no-match --id is silent, exit 0" {
  run bash -c "bash '$SCRIPT' --id no.such.id.exists"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---- multiple flags combine (AND logic) ----

@test "--kind + --keyword AND-combine: solution AND autonomy" {
  run bash -c "bash '$SCRIPT' --kind solution --keyword autonomy"
  [ "$status" -eq 0 ]
  # solution record has autonomy keyword -> matches
  [[ "$output" == *"references/solutions/sample-solution.md"* ]]
  # decision also has autonomy but is kind=decision -> excluded by AND
  [[ "$output" != *"sample-decision.md"* ]]
}

@test "AND with a contradictory pair yields nothing" {
  # procedure kind but a keyword only the decision carries -> empty
  run bash -c "bash '$SCRIPT' --kind procedure --keyword quokkadec"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---- output shape ----

@test "output lines have the path — gloss shape" {
  run bash -c "bash '$SCRIPT' --kind decision"
  [ "$status" -eq 0 ]
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    [[ "$line" == *" — "* ]]
  done <<< "$output"
}

# ---------------------------------------------------------------------------
# PLUGIN ADAPTATION: owner call — a query returns ALL matches by default;
# truncation and ranking floors are opt-in knobs, because the scout needs the
# full match set.
#
# Fixture: 25 tiny solution records sharing a rare keyword (manyresultkw),
# one per file, so a query for it produces >20 matches — enough to exceed
# the old hardcoded LIMIT=20 and prove the new default is uncapped.
# ---------------------------------------------------------------------------
_seed_many_matches_fixture() {
  for i in $(seq 1 25); do
    cat > "$FIX/references/solutions/manyresult$i.md" <<EOF
---
id: sol.manyresult$i
kind: solution
date: 2026-06-25
keywords: [manyresultkw]
links: {}
status: resolved
---
# many-result fixture $i

body
EOF
  done
}

@test "more than 20 matches in a kind all come back by default (no cap)" {
  _seed_many_matches_fixture
  run bash -c "bash '$SCRIPT' --keyword manyresultkw"
  [ "$status" -eq 0 ]
  local count
  count=$(printf '%s\n' "$output" | grep -c 'manyresult[0-9]*\.md')
  [ "$count" -eq 25 ]
}

@test "--limit 3 caps the total result count to exactly 3" {
  _seed_many_matches_fixture
  run bash -c "bash '$SCRIPT' --keyword manyresultkw --limit 3"
  [ "$status" -eq 0 ]
  local count
  count=$(printf '%s\n' "$output" | grep -c 'manyresult[0-9]*\.md')
  [ "$count" -eq 3 ]
}

@test "QUERY_RECORDS_LIMIT env var caps the total result count" {
  _seed_many_matches_fixture
  run bash -c "QUERY_RECORDS_LIMIT=5 bash '$SCRIPT' --keyword manyresultkw"
  [ "$status" -eq 0 ]
  local count
  count=$(printf '%s\n' "$output" | grep -c 'manyresult[0-9]*\.md')
  [ "$count" -eq 5 ]
}

@test "--limit also caps structural-only (no-keyword) queries" {
  _seed_many_matches_fixture
  run bash -c "bash '$SCRIPT' --kind solution --limit 4"
  [ "$status" -eq 0 ]
  local count
  count=$(printf '%s\n' "$output" | grep -c 'manyresult[0-9]*\.md')
  [ "$count" -eq 4 ]
}

# ---------------------------------------------------------------------------
# --rel-ratio 0 disables the relative-floor suppression: mirrors the
# suppression fixture in record-ranking.bats (relstrong vs relfill1/2), but
# here asserts that rel-ratio=0 lets the otherwise-suppressed weak matches
# through.
# ---------------------------------------------------------------------------
_seed_relfloor_fixture() {
  for i in 1 2; do
    cat > "$FIX/references/decisions/qrrelfill$i.md" <<EOF
---
id: dec.qrrelfill$i
kind: decision
date: 2026-06-25
keywords: [qrcommonrela, qrcommonrelb]
links: {}
status: active
---
# relative floor filler $i

body
EOF
  done

  cat > "$FIX/references/decisions/qrrelstrong.md" <<'EOF'
---
id: dec.qrrelstrong
kind: decision
date: 2026-06-25
keywords: [qrrelstrongA]
links: {}
status: active
---
# strong match record

body
EOF

  for i in $(seq 1 10); do
    cat > "$FIX/references/solutions/qrreldecoy$i.md" <<EOF
---
id: sol.qrreldecoy$i
kind: solution
date: 2026-06-25
keywords: [qrcommonrela, qrcommonrelb]
links: {}
status: resolved
---
# decoy to inflate df of qrcommonrela/qrcommonrelb

body
EOF
  done
}

@test "default rel_ratio suppresses the weak match (baseline for the next test)" {
  _seed_relfloor_fixture
  run bash -c "bash '$SCRIPT' --keyword 'qrrelstrongA qrcommonrela qrcommonrelb'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"qrrelstrong.md"* ]]
  [[ "$output" != *"qrrelfill1.md"* ]]
  [[ "$output" != *"qrrelfill2.md"* ]]
}

@test "--rel-ratio 0 disables relative-floor suppression, weak match now surfaces" {
  _seed_relfloor_fixture
  run bash -c "bash '$SCRIPT' --keyword 'qrrelstrongA qrcommonrela qrcommonrelb' --rel-ratio 0"
  [ "$status" -eq 0 ]
  [[ "$output" == *"qrrelstrong.md"* ]]
  [[ "$output" == *"qrrelfill1.md"* ]]
  [[ "$output" == *"qrrelfill2.md"* ]]
}
