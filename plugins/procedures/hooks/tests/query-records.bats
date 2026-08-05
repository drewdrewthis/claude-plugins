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
