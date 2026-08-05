#!/usr/bin/env bats
# record-ranking.bats — ranking-property tests for the BM25-lite matcher
# (scripts/lib/record-rarity.awk + scripts/lib/record-match.awk).
#
# hooks/procedure-router.sh (the PUSH/injection consumer) was retired in
# orchard-codex#197, along with its test suites (record-ranking.bats,
# procedure-frequency-prior.bats — see `git log --diff-filter=D` for the
# originals). The matcher itself is NOT retired: it is still driven by
# scripts/query-records.sh, the PULL consumer used directly and via the
# `procedure-scout` agent (Skill(how-do-i)). This file re-establishes ranking
# coverage against that surviving surface instead of the deleted hook.
#
# Design doc: references/research/2038-discovery-matcher-bm25-ranking.md
#
# Each test builds an isolated fixture corpus under QUERY_RECORDS_ROOT (fresh
# per test via setup()/teardown()) and drives it through
# scripts/query-records.sh --keyword "<tokens>", which tokenizes its argument
# the same way the old router tokenized a prompt (lowercase, split on
# non-alphanumerics, length>=3) — so a multi-word --keyword value reproduces a
# multi-token query.
#
# Properties covered (the four requested at minimum):
#   1. a rarer (higher-IDF) match outranks a more common one
#   2. per-kind buckets are preserved — records from different kinds both surface
#   3. a weak/common multi-token match is suppressed when a strong match exists
#      (the relative floor, rel_ratio in record-match.awk)
#   4. a focused record (few keywords) outranks a keyword-stuffed one
#      (BM25 length normalization, the `b` parameter)
#
# Deliberately NOT ported (see report to the dispatcher for the full reasoning):
#   - Linguistic-stopword stripping and the old codex-token denylist: both were
#     PROMPT-PARSING done in procedure-router.sh itself (grep -vxE '...') before
#     tokens ever reached the shared matcher. query-records.sh's tokenizer has
#     no stopword/denylist step, so a query of "the and for with" is not
#     representative of any live caller's behavior.
#   - The absolute df<=K_floor gate (`gate=1`: a lone common-token match does
#     NOT fire). query-records.sh always calls the matcher with `-v gate=0`
#     (deliberately permissive — see its own comments), so gate=1 is not
#     exercised by any surviving caller. Testing it would mean invoking
#     record-match.awk directly with a mode nothing live uses.
#   - The usage-count frequency prior (`usagefile`/`alpha`). Wiring a usagefile
#     into the matcher call was done ONLY in procedure-router.sh; query-records.sh
#     never passes `-v usagefile=`. The multiplier code still exists in
#     record-match.awk but is presently unreachable from any live caller.
#   - Per-kind cap "best survives, not filesystem order" at the `limit`
#     boundary (old RR8). query-records.sh hardcodes limit=20; reproducing the
#     cap boundary needs 21+ same-kind fixture records for a property already
#     exercised (same sort/less()) by the ordering tests below.
#
# Run: bats hooks/tests/record-ranking.bats

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/query-records.sh"
  FIX="$(mktemp -d)"
  export QUERY_RECORDS_ROOT="$FIX"
  mkdir -p "$FIX/references/decisions"
  mkdir -p "$FIX/references/solutions"
}

teardown() {
  [ -n "${FIX:-}" ] && rm -rf "$FIX"
}

# ---------------------------------------------------------------------------
# Helper: line_position <path-fragment> <output-string>
# 1-based line number of the fragment's first appearance, or 999 if absent.
# ---------------------------------------------------------------------------
line_position() {
  local fragment="$1" output="$2" n=0
  while IFS= read -r line; do
    n=$((n + 1))
    if [[ "$line" == *"$fragment"* ]]; then
      echo "$n"
      return
    fi
  done <<< "$output"
  echo 999
}

# ---------------------------------------------------------------------------
# Property 1 — a rarer (higher-IDF) match outranks a more common one.
#
# zzz-high.md sorts LAST alphabetically but matches a df=1 token (raretoken)
# in addition to the shared df=2 token; aaa-low.md sorts FIRST alphabetically
# but matches only the shared df=2 token plus another df=2 token. If ranking
# were still filesystem/alphabetical order, aaa-low would print first; under
# IDF-weighted scoring, zzz-high's higher-IDF match must put it first instead.
# bbb-third exists only to make df(anothercommon)=2.
# ---------------------------------------------------------------------------
@test "a rarer (higher-IDF) match outranks a more common match, regardless of alphabetical order" {
  cat > "$FIX/references/decisions/zzz-high.md" <<'EOF'
---
id: dec.rank-high
kind: decision
date: 2026-06-25
keywords: [matchtoken, raretoken]
links: {}
status: active
---
# high IDF record
body text
EOF

  cat > "$FIX/references/decisions/aaa-low.md" <<'EOF'
---
id: dec.rank-low
kind: decision
date: 2026-06-25
keywords: [matchtoken, anothercommon]
links: {}
status: active
---
# lower IDF record
body text
EOF

  cat > "$FIX/references/decisions/bbb-third.md" <<'EOF'
---
id: dec.rank-third
kind: decision
date: 2026-06-25
keywords: [anothercommon, gammatoken]
links: {}
status: active
---
# third record
body text
EOF

  run bash -c "bash '$SCRIPT' --keyword 'matchtoken raretoken anothercommon'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"zzz-high.md"* ]]
  [[ "$output" == *"aaa-low.md"* ]]

  local pos_high pos_low
  pos_high=$(line_position "zzz-high.md" "$output")
  pos_low=$(line_position "aaa-low.md" "$output")
  [ "$pos_high" -lt "$pos_low" ]
}

# ---------------------------------------------------------------------------
# Property 2 — per-kind buckets are preserved: a query that matches one
# decision AND one solution record must surface both, not let one kind crowd
# out the other.
# ---------------------------------------------------------------------------
@test "per-kind buckets are preserved — records from different kinds both surface" {
  cat > "$FIX/references/decisions/kindtest-dec.md" <<'EOF'
---
id: dec.kindtest
kind: decision
date: 2026-06-25
keywords: [kindtokendec, seconddec]
links: {}
status: active
---
# decision kind record
body
EOF

  cat > "$FIX/references/solutions/kindtest-sol.md" <<'EOF'
---
id: sol.kindtest
kind: solution
date: 2026-06-25
keywords: [kindtokensol, secondsol]
links: {}
status: active
---
# solution kind record
body
EOF

  run bash -c "bash '$SCRIPT' --keyword 'kindtokendec seconddec kindtokensol secondsol'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"kindtest-dec.md"* ]]
  [[ "$output" == *"kindtest-sol.md"* ]]
}

# ---------------------------------------------------------------------------
# Property 3 — relative floor: a weak/common multi-token match is suppressed
# when a strong match exists in the same kind bucket.
#
# relstrong.md matches one ultra-rare token (relstrongA, df=1). relfill1/2.md
# each match two very-common tokens (commonrela/commonrelb). Ten solution-kind
# decoys carry commonrela+commonrelb too, so those tokens' df climbs to 12 in
# a 13-record corpus while relstrongA stays df=1 — a wide IDF gap. Decoys are
# solution-kind so they compete in their OWN bucket, not the decision bucket
# under test.
#
# score(relstrong) = idf(relstrongA)            · lengthnorm(dl=1)
# score(relfill)    = (idf(commonrela)+idf(commonrelb)) · lengthnorm(dl=2)
# At N=13 this ratio is well under the default rel_ratio=0.3, so relfill1/2
# must be dropped from the decision bucket's output while relstrong survives.
# ---------------------------------------------------------------------------
_seed_relative_floor_fixture() {
  for i in 1 2; do
    cat > "$FIX/references/decisions/relfill$i.md" <<EOF
---
id: dec.relfill$i
kind: decision
date: 2026-06-25
keywords: [commonrela, commonrelb]
links: {}
status: active
---
# relative floor filler $i
body
EOF
  done

  cat > "$FIX/references/decisions/relstrong.md" <<'EOF'
---
id: dec.relstrong
kind: decision
date: 2026-06-25
keywords: [relstrongA]
links: {}
status: active
---
# strong match record
body
EOF

  for i in $(seq 1 10); do
    cat > "$FIX/references/solutions/reldecoy$i.md" <<EOF
---
id: sol.reldecoy$i
kind: solution
date: 2026-06-25
keywords: [commonrela, commonrelb]
links: {}
status: active
---
# decoy to inflate df of commonrela/commonrelb
body
EOF
  done
}

@test "a strong rare-token match surfaces on its own" {
  _seed_relative_floor_fixture
  run bash -c "bash '$SCRIPT' --keyword relstrongA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"relstrong.md"* ]]
}

@test "a weak common multi-token match is suppressed by the relative floor when a strong match exists" {
  _seed_relative_floor_fixture
  run bash -c "bash '$SCRIPT' --keyword 'relstrongA commonrela commonrelb'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"relstrong.md"* ]]
  [[ "$output" != *"relfill1.md"* ]]
  [[ "$output" != *"relfill2.md"* ]]
}

# ---------------------------------------------------------------------------
# Property 4 — length normalization: a focused record outranks a
# keyword-stuffed record on an identical rare-token match.
#
# Both records match the same df=2 token (lenunique) — identical IDF
# contribution — so only BM25 length normalization (dl vs avgdl) can
# differentiate them. aaa-stuffed.md (15 keywords, sorts FIRST alphabetically)
# is penalized; zzz-focused.md (3 keywords, sorts LAST alphabetically) is
# rewarded. zzz-focused must rank first despite alphabetical order.
# ---------------------------------------------------------------------------
@test "a focused record outranks a keyword-stuffed record via length normalization" {
  cat > "$FIX/references/decisions/aaa-stuffed.md" <<'EOF'
---
id: dec.len-stuffed
kind: decision
date: 2026-06-25
keywords: [lenunique, stuffkw01, stuffkw02, stuffkw03, stuffkw04, stuffkw05, stuffkw06, stuffkw07, stuffkw08, stuffkw09, stuffkw10, stuffkw11, stuffkw12, stuffkw13, stuffkw14]
links: {}
status: active
---
# keyword stuffed record
body
EOF

  cat > "$FIX/references/decisions/zzz-focused.md" <<'EOF'
---
id: dec.len-focused
kind: decision
date: 2026-06-25
keywords: [lenunique, focusedkw1, focusedkw2]
links: {}
status: active
---
# focused record
body
EOF

  run bash -c "bash '$SCRIPT' --keyword lenunique"
  [ "$status" -eq 0 ]
  [[ "$output" == *"aaa-stuffed.md"* ]]
  [[ "$output" == *"zzz-focused.md"* ]]

  local pos_focused pos_stuffed
  pos_focused=$(line_position "zzz-focused.md" "$output")
  pos_stuffed=$(line_position "aaa-stuffed.md" "$output")
  [ "$pos_focused" -lt "$pos_stuffed" ]
}
