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
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"
  true
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

# ---------------------------------------------------------------------------
# BLOCKING fix regression: a broken scan must be LOUD (exit 3), never mistaken
# for the silent "no matches" case above — "awk couldn't run" is not "no
# matches". Sandbox a copy of the script + lib dir with record-scan.awk
# removed, so the structural-scan command substitution fails.
# ---------------------------------------------------------------------------
@test "record scan failure (missing awk lib) exits 3 with a loud stderr message" {
  SANDBOX="$(mktemp -d)"
  mkdir -p "$SANDBOX/scripts"
  cp "$BATS_TEST_DIRNAME/../../scripts/query-records.sh" "$SANDBOX/scripts/query-records.sh"
  cp -r "$BATS_TEST_DIRNAME/../../scripts/lib" "$SANDBOX/scripts/lib"
  rm -f "$SANDBOX/scripts/lib/record-scan.awk"
  run bash -c "bash '$SANDBOX/scripts/query-records.sh' --kind decision"
  [ "$status" -eq 3 ]
  [[ "$output" == *"query-records: record scan failed (awk unusable or lib missing) — NOT 'no matches'"* ]]
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

# Seeds a store the base fixture never touches (references/research), so a
# structural --kind query against it has zero pre-existing pollution and the
# match count is exactly the number of files seeded here.
_seed_structural25_fixture() {
  mkdir -p "$FIX/references/research"
  for i in $(seq 1 25); do
    cat > "$FIX/references/research/structural25-$i.md" <<EOF
---
id: res.structural25-$i
kind: research
date: 2026-06-25
keywords: [structural25kw]
links: {}
status: active
---
# structural-only fixture $i

body
EOF
  done
}

@test "structural-only --kind query with no --limit returns all 25 records uncapped" {
  _seed_structural25_fixture
  run bash -c "bash '$SCRIPT' --kind research"
  [ "$status" -eq 0 ]
  local lines
  lines="$(printf '%s\n' "$output" | grep -c .)"
  [ "$lines" -eq 25 ]
}

@test "--limit also caps structural-only (no-keyword) queries" {
  _seed_many_matches_fixture
  run bash -c "bash '$SCRIPT' --kind solution --limit 4"
  [ "$status" -eq 0 ]
  local count
  count=$(printf '%s\n' "$output" | grep -c 'manyresult[0-9]*\.md')
  [ "$count" -eq 4 ]
}

@test "--limit rejects a non-integer value with exit 2 and the contract message" {
  run bash -c "bash '$SCRIPT' --keyword quokkadec --limit abc"
  [ "$status" -eq 2 ]
  [[ "$output" == *"query-records: --limit needs a non-negative integer (0 = uncapped)"* ]]
}

@test "QUERY_RECORDS_LIMIT=abc with no --limit flag rejects with exit 2 and the contract message" {
  run bash -c "QUERY_RECORDS_LIMIT=abc bash '$SCRIPT' --keyword quokkadec"
  [ "$status" -eq 2 ]
  [[ "$output" == *"query-records: --limit needs a non-negative integer (0 = uncapped)"* ]]
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

# ---- --full ----

@test "--full on a structural query dumps full content with a path header" {
  run bash -c "bash '$SCRIPT' --kind decision --full"
  [ "$status" -eq 0 ]
  # the plain match-list line is still present
  [[ "$output" == *"references/decisions/sample-decision.md — Sample decision record"* ]]
  # the full-dump header is present
  [[ "$output" == *"==> references/decisions/sample-decision.md <=="* ]]
  # a known body line from the record is present
  [[ "$output" == *"Body about a quokkadec decision."* ]]
}

@test "--full on a --keyword query dumps full content with a path header" {
  run bash -c "bash '$SCRIPT' --keyword quokkadec --full"
  [ "$status" -eq 0 ]
  [[ "$output" == *"references/decisions/sample-decision.md — Sample decision record"* ]]
  [[ "$output" == *"==> references/decisions/sample-decision.md <=="* ]]
  [[ "$output" == *"Body about a quokkadec decision."* ]]
}

@test "--full with no matches prints nothing and exits 0" {
  run bash -c "bash '$SCRIPT' --keyword florblezzqqnonsense --full"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "--full caps the dump at 10 records and prints a truncation notice" {
  # add 11 more decision records so --kind decision has 12 candidates total.
  for i in $(seq 1 11); do
    cat > "$FIX/references/decisions/full-extra-$i.md" <<EOF
---
id: dec.full-extra-$i
kind: decision
date: 2026-06-12
keywords: [fullextrakw$i]
links: {}
status: active
---
# Full extra decision $i

Body of full extra decision $i.
EOF
  done
  run bash -c "bash '$SCRIPT' --kind decision --full --limit 20"
  [ "$status" -eq 0 ]
  headers="$(printf '%s\n' "$output" | grep -c '^==> ')"
  [ "$headers" -eq 10 ]
  # notice line present with the correct dumped/total counts
  [[ "$output" == *"(--full: dumped 10 of 12 matched records"* ]]
}

@test "--full under the cap prints no truncation notice" {
  run bash -c "bash '$SCRIPT' --kind decision --full"
  [ "$status" -eq 0 ]
  [[ "$output" != *"--full: dumped"* ]]
}

# PLUGIN ADAPTATION: --limit defaults to uncapped here, so FULL_CAP is the ONLY
# bound on a default --full query — upstream's default --limit 20 would cap the
# match list first. Guards that pairing on the keyword path.
@test "--full caps the dump at 10 under the plugin's uncapped default --limit" {
  _seed_many_matches_fixture
  run bash -c "bash '$SCRIPT' --keyword manyresultkw --full"
  [ "$status" -eq 0 ]
  local headers
  headers="$(printf '%s\n' "$output" | grep -c '^==> ')"
  [ "$headers" -eq 10 ]
  [[ "$output" == *"(--full: dumped 10 of 25 matched records"* ]]
}

# Regression guard: a small explicit --limit (below FULL_CAP) must dump
# exactly that many records and print NO truncation notice — the notice must
# compare against the LIMITED match set, not the pre-limit total.
@test "--limit 3 --full dumps exactly 3 records and prints no truncation notice" {
  _seed_many_matches_fixture
  run bash -c "bash '$SCRIPT' --keyword manyresultkw --limit 3 --full"
  [ "$status" -eq 0 ]
  local headers
  headers="$(printf '%s\n' "$output" | grep -c '^==> ')"
  [ "$headers" -eq 3 ]
  [[ "$output" != *"--full: dumped"* ]]
}

# ---- record-scan.awk direct edge cases ----

@test "record-scan.awk glosses a file with no frontmatter from its first line" {
  AWK_LIB="$BATS_TEST_DIRNAME/../../scripts/lib/record-scan.awk"
  NOFM="$FIX/no-frontmatter.md"
  cat > "$NOFM" <<'EOF'
Just a plain first line as gloss.

More content below, should not appear in the gloss.
EOF
  run bash -c "awk -v qkind='' -v qid='' -v qlinks='' -f '$AWK_LIB' '$NOFM'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Just a plain first line as gloss."* ]]
}

@test "record-scan.awk --links-to matches an id written with quotes in the links map" {
  AWK_LIB="$BATS_TEST_DIRNAME/../../scripts/lib/record-scan.awk"
  QUOTED="$FIX/quoted-links.md"
  cat > "$QUOTED" <<'EOF'
---
id: sol.quoted-linker
kind: solution
date: 2026-06-12
keywords: [quotedlink]
links: { decisions: ["dec.quoted-target"] }
status: active
---
# Quoted links record

Body of the quoted links record.
EOF
  run bash -c "awk -v qkind='' -v qid='' -v qlinks='dec.quoted-target' -f '$AWK_LIB' '$QUOTED'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$QUOTED"* ]]
}

@test "record-scan.awk --links-to does not match a record whose links map is empty" {
  AWK_LIB="$BATS_TEST_DIRNAME/../../scripts/lib/record-scan.awk"
  # the fixture decision record carries links: {} — must not match any --links-to query.
  run bash -c "awk -v qkind='' -v qid='' -v qlinks='dec.quoted-target' -f '$AWK_LIB' '$FIX/references/decisions/sample-decision.md'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---- regression guard: --kind parity across a multi-kind fixture ----

@test "--kind over a fixture of >=3 kinds returns exactly the matching files" {
  # fixture has 4 kinds: decision, solution, procedure, principle.
  run bash -c "bash '$SCRIPT' --kind solution"
  [ "$status" -eq 0 ]
  lines="$(printf '%s\n' "$output" | grep -c .)"
  [ "$lines" -eq 1 ]
  [[ "$output" == *"references/solutions/sample-solution.md"* ]]
  [[ "$output" != *"sample-decision.md"* ]]
  [[ "$output" != *"PROCEDURE.md"* ]]
  [[ "$output" != *"sample-principle.md"* ]]
}

# ---- regression guard: 0-byte record files are silently skipped, not errors ----

@test "a 0-byte .md file inside a store is silently skipped by a structural query" {
  : > "$FIX/references/decisions/empty-record.md"
  run bash -c "bash '$SCRIPT' --kind decision"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sample-decision.md"* ]]
  [[ "$output" != *"empty-record.md"* ]]
}

# ---------------------------------------------------------------------------
# PLUGIN ADAPTATION: quoted-scalar fix ahead of upstream (CodeRabbit PR #5);
# upstream orchard-codex#268-phase-2 inherits. record-scan.awk used to keep
# the surrounding quote characters on `id`/`kind` scalar values, so a quoted
# YAML value never equaled an unquoted query token.
# ---------------------------------------------------------------------------

@test "--id matches a record whose frontmatter id is double-quoted" {
  cat > "$FIX/references/decisions/quoted-id-probe.md" <<'EOF'
---
id: "dec.quoted-probe"
kind: decision
date: 2026-06-12
keywords: [quotedidkw]
links: {}
status: active
---
# Quoted id record

Body of the quoted id record.
EOF
  run bash -c "bash '$SCRIPT' --id dec.quoted-probe"
  [ "$status" -eq 0 ]
  [[ "$output" == *"references/decisions/quoted-id-probe.md"* ]]
}

@test "--kind matches a record whose frontmatter kind is single-quoted" {
  cat > "$FIX/references/decisions/quoted-kind-probe.md" <<'EOF'
---
id: dec.quoted-kind-probe
kind: 'decision'
date: 2026-06-12
keywords: [quotedkindkw]
links: {}
status: active
---
# Quoted kind record

Body of the quoted kind record.
EOF
  run bash -c "bash '$SCRIPT' --kind decision"
  [ "$status" -eq 0 ]
  [[ "$output" == *"references/decisions/quoted-kind-probe.md"* ]]
}

# ---------------------------------------------------------------------------
# Silent-wrong-answer guards (#21).
#
# Both shapes below used to exit 0 with plausible output, so a caller could not
# distinguish a bad query from a genuine miss. These tests fail on the parent
# commit: pre-fix, the repeat case exited 0 with gitflow results and the
# short-token case exited 0 with empty stdout.
# ---------------------------------------------------------------------------

@test "repeating --keyword is refused instead of silently keeping the last" {
  run bash -c "bash '$SCRIPT' --keyword quokkadec --keyword fixpattern"
  [ "$status" -eq 2 ]
  [[ "$output" == *"more than once"* ]]
  # The pre-fix bug: last flag won and the first vanished. Assert the dropped
  # term's record is absent from output, so this fails if last-wins returns.
  [[ "$output" != *"references/solutions/sample-solution.md"* ]]
}

@test "repeating a non-keyword flag is also refused" {
  run bash -c "bash '$SCRIPT' --kind decision --kind solution"
  [ "$status" -eq 2 ]
  [[ "$output" == *"more than once"* ]]
}

@test "repeating --full is allowed (idempotent, takes no value)" {
  run bash -c "bash '$SCRIPT' --keyword quokkadec --full --full"
  [ "$status" -eq 0 ]
  [[ "$output" == *"references/decisions/sample-decision.md"* ]]
}

@test "a keyword with no token above the floor exits non-zero, not a silent miss" {
  run bash -c "bash '$SCRIPT' --keyword 'a b'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"nothing to search"* ]]
  [[ "$output" == *"NOT 'no matches'"* ]]
}

# PLUGIN ADAPTATION: the PULL path indexes 2-char tokens; upstream's 3-char
# floor made `pr` (135 keyword slots in the live corpus), `ci` and `gh`
# permanently unmatchable. These fail on the parent commit.

@test "a 2-char keyword matches records carrying it (pr, ci, gh are searchable)" {
  cat > "$FIX/references/decisions/short-token-probe.md" <<'EOF'
---
id: dec.short-token-probe
kind: decision
date: 2026-08-07
keywords: [pr, review, gitflow]
links: {}
status: active
---
# Short token record

Body of the short token record.
EOF
  run bash -c "bash '$SCRIPT' --keyword pr"
  [ "$status" -eq 0 ]
  [[ "$output" == *"references/decisions/short-token-probe.md"* ]]
}

@test "a 2-char token inside a hyphenated keyword is reachable" {
  # `pr-review` tokenizes to {pr, review}; at the old 3-char floor the `pr`
  # half was dropped from the record side, so --keyword pr could never hit it.
  cat > "$FIX/references/procedures/sample/hyphen-probe.md" <<'EOF'
---
id: proc.sample.hyphen-probe
kind: procedure
date: 2026-08-07
keywords: [pr-review, checklist]
links: {}
status: active
---
# Hyphenated keyword record

Body of the hyphenated keyword record.
EOF
  run bash -c "bash '$SCRIPT' --keyword pr"
  [ "$status" -eq 0 ]
  [[ "$output" == *"references/procedures/sample/hyphen-probe.md"* ]]
}

@test "single-char tokens are still dropped (the floor is 2, not 0)" {
  run bash -c "bash '$SCRIPT' --keyword 'a'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"2+ characters"* ]]
}

@test "a genuine miss still exits 0 with empty stdout" {
  # The other half of the pair — the fix must not turn real misses into errors.
  run bash -c "bash '$SCRIPT' --keyword zzzznonexistentquux 2>/dev/null"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "multiple terms in ONE --keyword string still union" {
  run bash -c "bash '$SCRIPT' --keyword 'quokkadec fixpattern'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"references/decisions/sample-decision.md"* ]]
  [[ "$output" == *"references/solutions/sample-solution.md"* ]]
}

@test "records in the titw vendor store are found by keyword, kind, and id" {
  mkdir -p "$FIX/titw/somepkg/knowledge/principles"
  cat > "$FIX/titw/somepkg/knowledge/principles/vendored.md" <<'REC'
---
id: prin.vendored-sample
kind: principle
date: 2026-08-09
keywords: [vendoredkw, sample]
links: {}
status: active
---
# Vendored principle

Body of a titw-installed record.
REC
  run bash -c "bash '$SCRIPT' --keyword vendoredkw"
  [ "$status" -eq 0 ]
  [[ "$output" == *"titw/somepkg/knowledge/principles/vendored.md"* ]]
  run bash -c "bash '$SCRIPT' --kind principle"
  [ "$status" -eq 0 ]
  [[ "$output" == *"vendored.md"* ]]
  run bash -c "bash '$SCRIPT' --id prin.vendored-sample"
  [ "$status" -eq 0 ]
  [[ "$output" == *"vendored.md"* ]]
}

@test "a non-UTF-8 byte in one record does not abort the scan (LC_ALL=C)" {
  # BSD cut/grep under a UTF-8 locale die with "Illegal byte sequence" on a
  # single invalid byte; the script must stay byte-safe regardless of the
  # caller's locale.
  printf -- '---\nid: dec.bytes\nkind: decision\ndate: 2026-08-09\nkeywords: [bytesafekw]\nlinks: {}\nstatus: active\n---\n# Byte \xe9 record\n' \
    > "$FIX/references/decisions/bytes.md"
  run bash -c "LC_ALL=en_US.UTF-8 bash '$SCRIPT' --keyword bytesafekw"
  [ "$status" -eq 0 ]
  [[ "$output" == *"references/decisions/bytes.md"* ]]
  [[ "$output" != *"Illegal byte sequence"* ]]
}

@test "QUERY_RECORDS_EXTRA_STORES adds a store to the scan without a plugin change" {
  mkdir -p "$FIX/team-kb"
  cat > "$FIX/team-kb/extra.md" <<'REC'
---
id: dec.extra-store-sample
kind: decision
date: 2026-08-09
keywords: [extrastorekw]
links: {}
status: active
---
# Extra-store record
REC
  # Not scanned by default...
  run bash -c "bash '$SCRIPT' --keyword extrastorekw"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # ...scanned once the env var names it.
  run bash -c "QUERY_RECORDS_EXTRA_STORES='team-kb' bash '$SCRIPT' --keyword extrastorekw"
  [ "$status" -eq 0 ]
  [[ "$output" == *"team-kb/extra.md"* ]]
}
