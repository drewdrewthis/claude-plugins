#!/usr/bin/env bats
# Regression: `printf | grep -q` under `set -o pipefail` (issue #46).
#
# Same defect that broke `--cat` on the live corpus (fixed in 002f95a, pinned by
# query-cat-roundtrip.bats), still latent in three more places. `grep -q` exits
# on its FIRST match, closing the pipe under a printf that is still writing;
# printf dies of SIGPIPE and pipefail reports 141 for the pipeline — on a
# SUCCESSFUL match. Every one of these sites reads that as "no match" and takes
# the wrong branch:
#
#   lint-frontmatter.sh:188  a present required key is reported MISSING
#   lint-frontmatter.sh:204  a principle WITH enforced_by: is warned aspirational
#   enforce-frontmatter.sh:37  a non-lintable target is BLOCKED as a violation
#
# TWO conditions are needed, which is why no existing test catches it:
#   1. input larger than the pipe buffer (64KiB) — fixtures are ~100 bytes, so
#      printf's single atomic write completes before grep can exit; and
#   2. the match must be EARLY. A match on the last line forces grep to read
#      everything, so printf finishes and no SIGPIPE occurs. Required keys sit
#      at the top of a frontmatter block, so real inputs match early.
#
# Run: bats hooks/tests/frontmatter-sigpipe.bats

PIPE_BUFFER_BYTES=65536

setup() {
  LINTER="$BATS_TEST_DIRNAME/../../scripts/lint-frontmatter.sh"
  HOOK="$BATS_TEST_DIRNAME/../enforce-frontmatter.sh"
  FIX="$BATS_TEST_TMPDIR/root"
  mkdir -p "$FIX/references/failure-modes" "$FIX/references/principles"
  export LINT_FRONTMATTER_ROOT="$FIX"
}

# Emit enough frontmatter filler to push the block past the pipe buffer. Keys
# are unique and inert; only the block's SIZE matters here.
filler() {
  awk 'BEGIN { for (i = 0; i < 9000; i++) printf "x_%05d: filler\n", i }'
}

@test "a required key present in an oversized frontmatter block is not reported missing" {
  # The six required keys are written FIRST, then the block is padded past the
  # pipe buffer. Under the bug every one of them matches early, SIGPIPEs the
  # printf, and is reported as missing — the linter fails a record that is
  # perfectly valid.
  local rec="$FIX/references/failure-modes/big.md"
  {
    echo "---"
    echo "id: fm.big-block"
    echo "kind: failure-mode"
    echo "date: 2026-08-14"
    echo "keywords: [alpha, beta]"
    echo "links: []"
    echo "status: active"
    filler
    echo "---"
    echo
    echo "Body."
  } > "$rec"

  [ "$(wc -c < "$rec")" -gt "$PIPE_BUFFER_BYTES" ] \
    || { echo "fixture is not larger than the pipe buffer; the test proves nothing"; false; }

  run bash "$LINTER" "references/failure-modes/big.md"
  [[ "$output" != *"missing required key"* ]] \
    || { echo "present keys reported missing (SIGPIPE read as no-match):"; echo "$output"; false; }
}

@test "an enforced_by: present in an oversized principle block is not warned aspirational" {
  # Same mechanism at the second site. enforced_by: is present and early, so
  # the warning must not fire.
  local rec="$FIX/references/principles/big.md"
  {
    echo "---"
    echo "id: pr.big-block"
    echo "kind: principle"
    echo "date: 2026-08-14"
    echo "keywords: [alpha]"
    echo "links: []"
    echo "status: active"
    echo "enforced_by: hooks/how-do-i-gate.sh"
    filler
    echo "---"
    echo
    echo "Body."
  } > "$rec"

  [ "$(wc -c < "$rec")" -gt "$PIPE_BUFFER_BYTES" ]

  run bash "$LINTER" "references/principles/big.md"
  [[ "$output" != *"aspirational"* ]] \
    || { echo "a principle WITH enforced_by: was warned as aspirational:"; echo "$output"; false; }
}

@test "an oversized 'not a lintable record' linter output does not block the write" {
  # Third site. The hook shells out to the linter and greps its combined
  # output for the out-of-scope marker. A verbose linter run pushes that
  # output past the pipe buffer; the marker is on line 1, so grep exits
  # immediately and the pipeline reports 141 — the hook then treats an
  # out-of-scope target as a schema violation and exits 2, blocking the agent.
  local tree="$BATS_TEST_TMPDIR/plugin"
  mkdir -p "$tree/hooks" "$tree/scripts"
  cp "$HOOK" "$tree/hooks/enforce-frontmatter.sh"
  cat > "$tree/scripts/lint-frontmatter.sh" <<'STUB'
#!/usr/bin/env bash
echo "$1: not a lintable record"
awk 'BEGIN { for (i = 0; i < 9000; i++) printf "padding line %05d\n", i }'
exit 1
STUB
  chmod +x "$tree/scripts/lint-frontmatter.sh"

  [ "$(bash "$tree/scripts/lint-frontmatter.sh" x | wc -c)" -gt "$PIPE_BUFFER_BYTES" ] \
    || { echo "stub output is not larger than the pipe buffer; the test proves nothing"; false; }

  local target="$FIX/references/failure-modes/target.md"
  echo "not a record" > "$target"

  run bash -c "printf '%s' '{\"tool_input\":{\"file_path\":\"$target\"}}' \
    | KNOWLEDGE_ROOT='$FIX' bash '$tree/hooks/enforce-frontmatter.sh'"
  [ "$status" -eq 0 ] \
    || { echo "out-of-scope target BLOCKED with status $status (SIGPIPE read as no-match)"; echo "$output"; false; }
}
