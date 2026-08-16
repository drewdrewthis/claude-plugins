#!/usr/bin/env bats
# Tests for `query-records.sh --cat` — batch full-record retrieval over an
# EXPLICIT path list, as opposed to `--full`, which dumps whatever the current
# query happened to match.
#
# The two dump paths differ on purpose and the difference is asserted here:
#   --full  match count is NOT caller-controlled -> capped at FULL_CAP (10)
#   --cat   the list IS the caller's own -> uncapped, but every path must be a
#           record the same corpus scan could have returned
#
# `--cat` exists so the scout never needs a raw `awk`/`cat` outside the record
# stores to read a selection gathered across several surveys — query-records.sh
# is its sole retrieval surface.
#
# Run: bats hooks/tests/query-cat.bats

# `run --separate-stderr` needs 1.5.0+. The refusal tests below depend on it:
# bats merges the two streams by default, which is how a suite can assert a
# failure message on the wrong stream and still pass.
bats_require_minimum_version 1.5.0

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/query-records.sh"
  FIX="$(mktemp -d)"
  export QUERY_RECORDS_ROOT="$FIX"
  mkdir -p "$FIX/references/decisions" "$FIX/references/solutions"

  cat > "$FIX/references/decisions/alpha.md" <<'EOF'
---
id: dec.alpha
kind: decision
date: 2026-08-14
keywords: [alphakw]
links: {}
status: active
---
# Alpha decision

Body of the alpha decision.
EOF

  cat > "$FIX/references/solutions/beta.md" <<'EOF'
---
id: sol.beta
kind: solution
date: 2026-08-14
keywords: [betakw]
links: {}
status: resolved
---
# Beta solution

Body of the beta solution.
EOF
}

teardown() {
  [ -n "${FIX:-}" ] && rm -rf "$FIX"
  true
}

# ---- the happy path ----

@test "--cat dumps one record in full behind a path header, on STDOUT" {
  # --separate-stderr is load-bearing, not decoration. Under a plain `run`,
  # bats merges the streams, so this test stayed green with print_full's whole
  # pipeline redirected to stderr (proven by mutation) — while the scout's own
  # `--cat` step, which captures via command substitution, would have received
  # nothing. The dump landing on stdout IS the contract.
  run --separate-stderr bash -c "bash '$SCRIPT' --cat references/decisions/alpha.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"==> references/decisions/alpha.md <=="* ]]
  [[ "$output" == *"Body of the alpha decision."* ]]
  # frontmatter comes too — status/enforced_by are part of what a reader needs
  [[ "$output" == *"status: active"* ]]
  # nothing on the error stream on a clean dump
  [ -z "$stderr" ]
}

@test "--cat output survives command substitution (the scout's actual call shape)" {
  # The end-to-end form of the stream contract above: procedure-scout.md reads
  # records as "$(query-records.sh --cat ...)". Command substitution captures
  # stdout ONLY, so this fails outright if the dump ever moves to stderr.
  local captured
  captured="$(bash "$SCRIPT" --cat references/decisions/alpha.md references/solutions/beta.md)"
  [[ "$captured" == *"Body of the alpha decision."* ]]
  [[ "$captured" == *"Body of the beta solution."* ]]
}

@test "--cat dumps N records in one call, each behind its own header" {
  run bash -c "bash '$SCRIPT' --cat references/decisions/alpha.md references/solutions/beta.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"==> references/decisions/alpha.md <=="* ]]
  [[ "$output" == *"==> references/solutions/beta.md <=="* ]]
  [[ "$output" == *"Body of the alpha decision."* ]]
  [[ "$output" == *"Body of the beta solution."* ]]
  local headers
  headers="$(printf '%s\n' "$output" | grep -c '^==> ')"
  [ "$headers" -eq 2 ]
}

@test "--cat preserves the caller's order" {
  run bash -c "bash '$SCRIPT' --cat references/solutions/beta.md references/decisions/alpha.md"
  [ "$status" -eq 0 ]
  local first
  first="$(printf '%s\n' "$output" | grep -m1 '^==> ')"
  [[ "$first" == *"beta.md"* ]]
}

@test "--cat accepts an absolute path inside the corpus root" {
  run bash -c "bash '$SCRIPT' --cat '$FIX/references/decisions/alpha.md'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Body of the alpha decision."* ]]
}

@test "--cat accepts a ./-prefixed path" {
  run bash -c "bash '$SCRIPT' --cat ./references/decisions/alpha.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Body of the alpha decision."* ]]
}

@test "--cat dedupes a repeated path so a record selected twice is dumped once" {
  # The scout unions selections from several surveys; the same record turning up
  # in two of them must not be paid for twice.
  run bash -c "bash '$SCRIPT' --cat references/decisions/alpha.md references/decisions/alpha.md"
  [ "$status" -eq 0 ]
  local headers
  headers="$(printf '%s\n' "$output" | grep -c '^==> ')"
  [ "$headers" -eq 1 ]
}

@test "--cat is NOT capped at FULL_CAP — an explicit 12-path list dumps all 12" {
  # The point of the flag: --full's cap guards against a query the caller did
  # not size, but a --cat list is the caller's own selection. Capping it would
  # push the scout back to a raw awk batch-read outside the record stores,
  # which is exactly what this flag removes.
  for i in $(seq 1 12); do
    cat > "$FIX/references/decisions/many-$i.md" <<EOF
---
id: dec.many-$i
kind: decision
date: 2026-08-14
keywords: [manycatkw]
links: {}
status: active
---
# Many $i

Body of many $i.
EOF
  done
  local paths=""
  for i in $(seq 1 12); do paths="$paths references/decisions/many-$i.md"; done
  run bash -c "bash '$SCRIPT' --cat $paths"
  [ "$status" -eq 0 ]
  local headers
  headers="$(printf '%s\n' "$output" | grep -c '^==> ')"
  [ "$headers" -eq 12 ]
  [[ "$output" != *"dumped"* ]]
}

@test "--cat output is consumable as the same shape --full emits" {
  # One parse for both dump paths: `==> path <==` then the file verbatim.
  run bash -c "bash '$SCRIPT' --cat references/decisions/alpha.md"
  local cat_body
  cat_body="$(printf '%s\n' "$output" | sed -n '/^==> /,$p')"
  run bash -c "bash '$SCRIPT' --id dec.alpha --full"
  local full_body
  full_body="$(printf '%s\n' "$output" | sed -n '/^==> /,$p')"
  [ "$cat_body" = "$full_body" ]
}

# ---- refusals: loud, atomic, and on the right stream ----
#
# Every case below asserts stdout is EMPTY and the message is on STDERR.
# A prior incident in this suite asserted a failure message on the wrong
# stream and passed while the script wrote it to the other one, so these use
# `run --separate-stderr` rather than the merged default.

@test "--cat with a path that does not exist exits 2, names it on stderr, dumps nothing" {
  run --separate-stderr bash -c "bash '$SCRIPT' --cat references/decisions/nope.md"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"references/decisions/nope.md"* ]]
}

@test "--cat is atomic: one bad path suppresses the dump of the good ones" {
  # Half a batch is the dangerous shape — the scout would believe it had read
  # everything it selected. Refuse the whole call instead.
  run --separate-stderr bash -c "bash '$SCRIPT' --cat references/decisions/alpha.md references/decisions/nope.md"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"nope.md"* ]]
}

@test "--cat refuses a real file outside the record stores" {
  # --cat is a RECORD retrieval surface, not `cat`. A path the corpus scan
  # would never return is out of bounds even though it exists and is readable.
  printf 'secrets\n' > "$FIX/not-a-record.md"
  run --separate-stderr bash -c "bash '$SCRIPT' --cat not-a-record.md"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"not a record"* ]]
}

@test "--cat refuses a traversal path escaping the corpus root" {
  run --separate-stderr bash -c "bash '$SCRIPT' --cat ../../../../etc/passwd"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"not a record"* ]]
}

@test "--cat refuses an absolute path outside the corpus root" {
  run --separate-stderr bash -c "bash '$SCRIPT' --cat /etc/passwd"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"not a record"* ]]
}

@test "--cat with no paths at all is a usage error, not an empty success" {
  run --separate-stderr bash -c "bash '$SCRIPT' --cat"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"--cat needs at least one record path"* ]]
}

@test "--cat names the id flag when handed something that looks like a record id" {
  # `--cat dec.alpha` is the obvious wrong guess; the error has to point at the
  # flag that does work rather than just refusing.
  run --separate-stderr bash -c "bash '$SCRIPT' --cat dec.alpha"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"--id"* ]]
}

@test "--cat cannot be combined with a query mode" {
  run --separate-stderr bash -c "bash '$SCRIPT' --keyword alphakw --cat references/decisions/alpha.md"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"its own mode"* ]]
}

@test "--cat cannot be combined with --recall" {
  run --separate-stderr bash -c "bash '$SCRIPT' --recall something --cat references/decisions/alpha.md"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"its own mode"* ]]
}

@test "--cat does not silently swallow a trailing flag as if it were a path" {
  # --cat consumes the rest of argv, so a flag typed after it would otherwise
  # become a path and be reported as a missing record — a confusing error for
  # the real mistake, which is that the flags cannot combine.
  run --separate-stderr bash -c "bash '$SCRIPT' --cat references/decisions/alpha.md --kind decision"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"its own mode"* ]]
}

# ---- store-boundary parity with the query path ----

@test "--cat reaches a vendor-store record (same surface a query scans)" {
  mkdir -p "$FIX/titw/pkg/knowledge/principles"
  cat > "$FIX/titw/pkg/knowledge/principles/vend.md" <<'REC'
---
id: prin.vend
kind: principle
date: 2026-08-14
keywords: [vendcatkw]
links: {}
status: active
---
# Vendored principle

Body of the vendored principle.
REC
  run bash -c "bash '$SCRIPT' --cat titw/pkg/knowledge/principles/vend.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Body of the vendored principle."* ]]
}

@test "--cat reaches an env-configured extra store" {
  mkdir -p "$FIX/team-kb"
  cat > "$FIX/team-kb/extra.md" <<'REC'
---
id: dec.extra-cat
kind: decision
date: 2026-08-14
keywords: [extracatkw]
links: {}
status: active
---
# Extra-store record

Body of the extra-store record.
REC
  # Out of bounds by default...
  run --separate-stderr bash -c "bash '$SCRIPT' --cat team-kb/extra.md"
  [ "$status" -eq 2 ]
  # ...in bounds once the env var names the store, with no plugin change.
  run bash -c "QUERY_RECORDS_EXTRA_STORES='team-kb' bash '$SCRIPT' --cat team-kb/extra.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Body of the extra-store record."* ]]
}

@test "--cat refuses a newline-smuggled second path" {
  # grep -F reads a multi-line pattern as SEVERAL patterns, so a ref whose
  # first line is a real record would match the boundary check, and the dump
  # would then split the same string back into two filenames — the second one
  # never checked. Escapes the record stores if unguarded.
  printf 'secret\n' > "$FIX/not-a-record.md"
  run --separate-stderr bash -c "bash '$SCRIPT' --cat \"\$(printf 'references/decisions/alpha.md\\nnot-a-record.md')\""
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$output" != *"secret"* ]]
}

@test "--cat refuses an empty path argument" {
  run --separate-stderr bash -c "bash '$SCRIPT' --cat ''"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "--cat refuses an archived record, matching what a query would return" {
  mkdir -p "$FIX/plans/_archived"
  cat > "$FIX/plans/_archived/old.md" <<'REC'
---
id: plan.old
kind: plan
date: 2026-01-01
keywords: [oldkw]
links: {}
status: done
---
# Archived plan
REC
  run --separate-stderr bash -c "bash '$SCRIPT' --cat plans/_archived/old.md"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"not a record"* ]]
}
