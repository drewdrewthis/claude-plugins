#!/usr/bin/env bats
# The store list is discovered at runtime via `query-records.sh --list-stores`,
# never enumerated in prose (owner call, 2026-08-09 — supersedes the inlined
# list this file previously guarded). These tests pin the discovery contract:
# the flag exists, reports the full scan surface, and the docs point at the
# mechanism instead of freezing a copy.
#
# Run: bats hooks/tests/store-list-drift.bats

setup() {
  PLUGIN="$BATS_TEST_DIRNAME/../.."
  SCRIPT="$PLUGIN/scripts/query-records.sh"
  # shellcheck source=../../scripts/lib/stores.sh
  source "$PLUGIN/scripts/lib/stores.sh"
  AGENT="$PLUGIN/agents/procedure-scout.md"
  SKILL="$PLUGIN/skills/how-do-i/SKILL.md"
}

@test "the SSOT is non-empty (guards the assertions below from passing vacuously)" {
  [ "${#STORES[@]}" -ge 1 ]
}

@test "--list-stores prints every configured store, one per line" {
  run bash "$SCRIPT" --list-stores
  [ "$status" -eq 0 ]
  for s in "${STORES[@]}" "${VENDOR_STORES[@]}"; do
    grep -qxF "$s" <<< "$output"
  done
}

@test "the four rule stores are configured, not just the original seven" {
  # The test above iterates STORES, so it passes vacuously whatever STORES holds.
  # These four are named explicitly because the GRC frame depends on the kinds
  # being separable: invariant (absolute) vs principle (judgment) vs policy
  # (standing authority) vs standard (measurable bar). Dropping one silently
  # collapses that distinction back into "principle with a flag".
  for s in references/invariants references/principles references/policies references/standards; do
    printf '%s\n' "${STORES[@]}" | grep -qxF "$s"
  done
}

@test "--list-stores reaches the rule stores end to end" {
  run bash "$SCRIPT" --list-stores
  [ "$status" -eq 0 ]
  grep -qxF "references/invariants" <<< "$output"
  grep -qxF "references/policies" <<< "$output"
  grep -qxF "references/standards" <<< "$output"
}

@test "--list-stores includes env-configured extra stores" {
  run bash -c "QUERY_RECORDS_EXTRA_STORES='team-kb' bash '$SCRIPT' --list-stores"
  [ "$status" -eq 0 ]
  grep -qxF "team-kb" <<< "$output"
}

@test "the scout's Boundaries point at the discovery mechanism, not a frozen list" {
  grep -qF -- '--list-stores' "$AGENT"
}

@test "the skill's tooling note points at the discovery mechanism, not a frozen list" {
  grep -qF -- '--list-stores' "$SKILL"
}
