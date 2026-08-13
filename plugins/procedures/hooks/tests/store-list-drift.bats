#!/usr/bin/env bats
# The scout's search boundary and the skill's tooling note both INLINE the
# store list. Inlining was chosen deliberately — the previous version pointed
# at scripts/lib/stores.sh, which the scout cannot read without breaching the
# very boundary that names it — but it trades auto-freshness for silent drift.
# This is the guard that buys the freshness back.
#
# Run: bats hooks/tests/store-list-drift.bats

setup() {
  PLUGIN="$BATS_TEST_DIRNAME/../.."
  # shellcheck source=../../scripts/lib/stores.sh
  source "$PLUGIN/scripts/lib/stores.sh"
  AGENT="$PLUGIN/agents/procedure-scout.md"
  SKILL="$PLUGIN/skills/how-do-i/SKILL.md"
}

@test "the SSOT is non-empty (guards the assertions below from passing vacuously)" {
  [ "${#STORES[@]}" -ge 1 ]
}

@test "every store in stores.sh is named in the scout's Boundaries" {
  for s in "${STORES[@]}"; do
    # references/failure-modes -> failure-modes; plans -> plans
    run grep -qF "${s#references/}" "$AGENT"
    [ "$status" -eq 0 ]
  done
}

@test "every store in stores.sh is named in the skill's tooling note" {
  for s in "${STORES[@]}"; do
    run grep -qF "${s#references/}" "$SKILL"
    [ "$status" -eq 0 ]
  done
}

@test "the docs name no store the SSOT does not have" {
  # The reverse direction: a store deleted from stores.sh must not linger in
  # prose, or the scout searches a surface the tooling no longer covers.
  # A bare `references/[a-z-]+` also matches the TAIL of unrelated plugin paths
  # like skills/create-new/references/create-procedure.procedure.md, reporting a
  # store that was never claimed. The guard is the character in front of it.
  # Deliberately NOT a `-P` negative lookbehind: PCRE is a GNU extension and BSD
  # grep (macOS, FreeBSD) rejects -P, which would empty the loop and pass this
  # test vacuously on those toolchains. Match the leading character with POSIX
  # ERE, then strip it back off.
  for d in $(grep -ohE '(^|[^/[:alnum:]_-])references/[a-z-]+' "$AGENT" "$SKILL" \
               | sed 's/.*\(references\/[a-z-]*\)/\1/' | sort -u); do
    found=0
    for s in "${STORES[@]}"; do [ "$s" = "$d" ] && found=1; done
    # mistakes.jsonl lives outside STORES by design and is not a references/ path.
    [ "$found" -eq 1 ]
  done
}
