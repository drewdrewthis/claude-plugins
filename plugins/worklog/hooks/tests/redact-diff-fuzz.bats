#!/usr/bin/env bats
# Tests for hooks/tests/redact_diff_fuzz.py — the differential fuzz of hooks/lib/redact.py.
#
# WHAT THIS FILE PROVES (claude-plugins#218):
#   A candidate redact lib is compared with a pinned reference lib. A text is
#   "worse" when the candidate leaves more of the planted fake tokens in the
#   output than the reference does. Exit 0 = no worse text, 1 = one or more,
#   2 = the harness could not run. These tests pin that contract, the named
#   regressions from PR 217, and the eight exit-2 failure modes.
#
# ⚠ NO TOKEN LITERALS IN THIS FILE. Every fake token is made by the helper at
# run time (prefix + seeded random characters). This file only holds recipe
# names (F, G1, ...), seeds, and commit ids. Do not paste a token here: the
# helper's own gitleaks scan (AC7) runs over this file.
#
# ⚠ THE OUTPUT OF PASSING TESTS IS PRINTED ON PURPOSE. Bats hides stdout of a
# passing test, and the CI log is the evidence (corpus_sha256, mode, worse=).
# show() copies the helper call, exit code and output to fd 3, which bats
# always prints. Do not remove it.
#
# ⚠ NEVER skip A TEST HERE. A missing gitleaks or a missing sha must FAIL
# (AC6 rows 1-3). A skipped test would read as a pass in the log.
#
# Run: bats hooks/tests/redact-diff-fuzz.bats

bats_require_minimum_version 1.5.0

# Full ids of the PR 217 commits. They are public commit ids, not secrets.
SHA_F=cb0ab8458a40c2cbc6e8c91b80feed2b1a981231      # case F bad commit
SHA_G=3854dc277b0c72fb1f306884329ed96d2c899d78      # cases G1, G2, G2b
SHA_H=f1f1f8ad37229c5736668503841da328746ee3cc      # cases H1, H2
SHA_TEETH=05b246073138548869adc73427eed69f980c9567  # AC5 builtin teeth
# Absent from any clone. Rows 1 and 2.
SHA_ABSENT=0000000000000000000000000000000000000001

# Regenerate with
#   python3 plugins/worklog/hooks/tests/redact_diff_fuzz.py fuzz --mode builtin --seed 1 --n 200
# and read corpus_sha256. A changed value means the corpus changed; it must be
# the same on ubuntu-latest and macos-latest.
EXPECTED_CORPUS_SHA256=bdbfeb56828bcf0ff713a7d5a47e993778865188b05d1f8651cf4c483c40aa16

setup() {
  HELPER="$BATS_TEST_DIRNAME/redact_diff_fuzz.py"
  REPO="$(git -C "$BATS_TEST_DIRNAME" rev-parse --show-toplevel)"
  cd "$REPO"
  # AC2b: the batch scan of 1000 texts needs the long gitleaks timeout.
  export WORKLOG_GITLEAKS_TIMEOUT=120
  # Row 8 stub delegates to the real lib for single-text calls.
  export REAL_LIB="$REPO/plugins/worklog/hooks/lib/redact.py"
}

# --- helpers ----------------------------------------------------------------

# show — copy the helper call, exit code, stdout and stderr to fd 3 so the CI
# log of a PASSING test still holds mode=, corpus_sha256=, flagged=, worse=.
show() {
  local l
  printf '# $ redact_diff_fuzz.py %s\n' "$*" >&3
  printf '# [exit %s]\n' "$status" >&3
  while IFS= read -r l; do printf '# %s\n' "$l" >&3; done <<<"$output"
  while IFS= read -r l; do [ -n "$l" ] && printf '# stderr: %s\n' "$l" >&3; done <<<"$stderr"
  return 0
}

# fuzz <helper args...> — run the helper; sets $status, $output, $stderr.
fuzz() {
  run --separate-stderr python3 "$HELPER" "$@"
  show "$@"
}

# has_line <exact line> — stdout holds this exact line.
has_line() { [[ $'\n'"$output"$'\n' == *$'\n'"$1"$'\n'* ]]; }

# has_match <ERE> — some stdout line matches.
has_match() { grep -Eq -- "$1" <<<"$output"; }

# value_of <key> — the value after "key=" on stdout (first match, up to space).
value_of() { grep -Eo -- "(^|[ ])$1=[^ ]+" <<<"$output" | head -n 1 | sed -e 's/^ //' -e "s/^$1=//"; }

BUILTIN_MODE='mode=builtin gitleaks_present=False'
GITLEAKS_MODE='mode=gitleaks gitleaks_present=True version=8.30.1 failed=False'

# no_planted_leak <planted file> — AC7. No run of 8+ chars of any planted piece
# is in stdout or stderr. The dump file is written by the helper, one piece per
# line. Prints only counts: this function must never echo a piece itself.
no_planted_leak() {
  local out="$BATS_TEST_TMPDIR/combined.out"
  printf '%s\n%s\n' "$output" "$stderr" >"$out"
  [ -s "$1" ]
  run python3 - "$1" "$out" <<'PY'
import sys
pieces = [l.rstrip("\n") for l in open(sys.argv[1], errors="replace") if len(l.rstrip("\n")) >= 8]
out = open(sys.argv[2], errors="replace").read()
hits = sum(1 for p in pieces for i in range(len(p) - 7) if p[i:i + 8] in out)
print("planted_pieces_checked=%d planted_windows_in_output=%d" % (len(pieces), hits))
sys.exit(0 if pieces and hits == 0 else 1)
PY
  printf '# AC7 %s\n' "$output" >&3
  [ "$status" -eq 0 ]
}

# clean_case <name> <mode line> — AC3: the candidate hooks/lib is not worse.
clean_case() {
  fuzz case --name "$1"
  [ "$status" -eq 0 ]
  has_line "$2"
  has_line worse=0
}

# teeth_case <name> <sha> — AC3: the bad commit is worse, and nothing planted leaks into the log.
teeth_case() {
  local pl="$BATS_TEST_TMPDIR/planted"
  fuzz case --name "$1" --candidate-sha "$2" --dump-planted "$pl"
  [ "$status" -eq 1 ]
  has_line worse=1
  no_planted_leak "$pl"
}

# write_stub <dir> — a candidate dir whose redact.py is read from stdin.
write_stub() { mkdir -p "$1"; cat >"$1/redact.py"; }

# path_without_gitleaks — a PATH dir with the tools the helper needs and no gitleaks.
path_without_gitleaks() {
  local d="$BATS_TEST_TMPDIR/nogl" b p
  mkdir -p "$d"
  for b in bash sh env git python3 cat sed grep tr head tail wc sort mkdir ls dirname basename; do
    if p="$(command -v "$b" 2>/dev/null)" && [ -x "$p" ]; then ln -sf "$p" "$d/$b"; fi
  done
  printf '%s' "$d"
}

# --- environment ------------------------------------------------------------

@test "gitleaks 8.30.1 is installed on this runner" {
  run gitleaks version
  echo "# gitleaks version: $output" >&3
  [ "$status" -eq 0 ]
  [[ "$output" == *8.30.1* ]]
}

# --- AC1: corpus hash -------------------------------------------------------

@test "corpus hash is stable across runs" {
  fuzz fuzz --mode builtin --seed 1 --n 200
  [ "$status" -eq 0 ]
  first="$(value_of corpus_sha256)"
  [ -n "$first" ]
  fuzz fuzz --mode builtin --seed 1 --n 200
  [ "$(value_of corpus_sha256)" = "$first" ]
}

@test "corpus hash follows the seed" {
  fuzz fuzz --mode builtin --seed 1 --n 200
  a="$(value_of corpus_sha256)"
  fuzz fuzz --mode builtin --seed 2 --n 200
  [ -n "$a" ]
  [ "$(value_of corpus_sha256)" != "$a" ]
}

@test "corpus hash at seed 1 and N 200 equals the pinned value on every leg" {
  fuzz fuzz --mode builtin --seed 1 --n 200
  [ "$(value_of corpus_sha256)" = "$EXPECTED_CORPUS_SHA256" ]
}

# --- AC2a: builtin mode, seeds 1-5 -------------------------------------------

# builtin_seed <seed> — gitleaks IS on this runner's PATH; the helper hides it.
builtin_seed() {
  command -v gitleaks >/dev/null
  fuzz fuzz --mode builtin --seed "$1" --n 3000
  [ "$status" -eq 0 ]
  has_line "$BUILTIN_MODE"
  has_line worse=0
}

@test "builtin mode is clean at seed 1" { builtin_seed 1; }
@test "builtin mode is clean at seed 2" { builtin_seed 2; }
@test "builtin mode is clean at seed 3" { builtin_seed 3; }
@test "builtin mode is clean at seed 4" { builtin_seed 4; }
@test "builtin mode is clean at seed 5" { builtin_seed 5; }

# --- AC2b: gitleaks mode ----------------------------------------------------

@test "gitleaks mode is clean on the first 1000 pairs texts" {
  fuzz fuzz --mode gitleaks
  [ "$status" -eq 0 ]
  has_line "$GITLEAKS_MODE"
  has_match '^flagged=[0-9]+ confirmed=0$'
  has_line worse=0
}

# --- AC3: named cases -------------------------------------------------------

@test "named case F is clean with the candidate" { clean_case F "$BUILTIN_MODE"; }
@test "named case G1 is clean with the candidate" { clean_case G1 "$BUILTIN_MODE"; }
@test "named case G2 is clean with the candidate" { clean_case G2 "$BUILTIN_MODE"; }
@test "named case G2b is clean with the candidate" { clean_case G2b "$BUILTIN_MODE"; }
@test "named case H1 is clean with the candidate" { clean_case H1 "$GITLEAKS_MODE"; }
@test "named case H2 is clean with the candidate" { clean_case H2 "$GITLEAKS_MODE"; }

@test "named case F is worse with cb0ab84" { teeth_case F "$SHA_F"; }
@test "named case G1 is worse with 3854dc2" { teeth_case G1 "$SHA_G"; }
@test "named case G2b is worse with 3854dc2" { teeth_case G2b "$SHA_G"; }
@test "named case H1 is worse with f1f1f8a" { teeth_case H1 "$SHA_H"; }
@test "named case H2 is worse with f1f1f8a" { teeth_case H2 "$SHA_H"; }

@test "named case G2 changes only marker names" {
  fuzz case --name G2 --candidate-sha "$SHA_G"
  [ "$status" -eq 0 ]
  has_line worse=0
}

# --- AC5 / AC5b: teeth of the fuzz ------------------------------------------

@test "builtin fuzz has teeth against 05b2460" {
  local pl="$BATS_TEST_TMPDIR/planted"
  fuzz fuzz --mode builtin --seed 2 --n 3000 --candidate-sha "$SHA_TEETH" --dump-planted "$pl"
  [ "$status" -eq 1 ]
  has_match '^worse=[1-9][0-9]*$'
  no_planted_leak "$pl"
}

@test "gitleaks fuzz has teeth against f1f1f8a" {
  local pl="$BATS_TEST_TMPDIR/planted" confirmed
  fuzz fuzz --mode gitleaks --candidate-sha "$SHA_H" --dump-planted "$pl"
  [ "$status" -eq 1 ]
  has_match '^flagged=[0-9]+ confirmed=[1-9][0-9]*$'
  confirmed="$(grep -Eo 'confirmed=[0-9]+' <<<"$output" | head -n 1 | sed 's/confirmed=//')"
  has_line "worse=$confirmed"
  no_planted_leak "$pl"
}

# --- AC6: eight exit-2 failure modes ----------------------------------------

@test "failure mode 1 exits 2 when the pinned sha is not in the clone" {
  fuzz case --name F --reference-sha "$SHA_ABSENT"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"$SHA_ABSENT"* ]]
  [[ "$stderr" == *"git fetch --unshallow"* ]]
}

@test "failure mode 2 exits 2 when the bad commit is not in the clone" {
  fuzz case --name F --candidate-sha "$SHA_ABSENT"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"$SHA_ABSENT"* ]]
  [[ "$stderr" == *"git fetch origin refs/pull/217/head"* ]]
}

@test "failure mode 3 exits 2 when gitleaks mode has no gitleaks" {
  # PATH is narrowed for the helper only: bats' own `run` needs its tools.
  local nogl py; nogl="$(path_without_gitleaks)"; py="$(command -v python3)"
  run --separate-stderr env PATH="$nogl" "$py" "$HELPER" fuzz --mode gitleaks
  show fuzz --mode gitleaks "(PATH without gitleaks)"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"gitleaks not found"* ]]
}

@test "failure mode 4 exits 2 when gitleaks is visible in builtin mode" {
  write_stub "$BATS_TEST_TMPDIR/stub4" <<'PY'
def gitleaks_present():
    return True


def redact_texts(texts):
    return list(texts), False
PY
  fuzz fuzz --mode builtin --seed 1 --n 20 --candidate-dir "$BATS_TEST_TMPDIR/stub4"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"gitleaks present in builtin mode"* ]]
}

@test "failure mode 5 exits 2 when the candidate raises" {
  write_stub "$BATS_TEST_TMPDIR/stub5" <<'PY'
def gitleaks_present():
    return False


def redact_texts(texts):
    raise RuntimeError("stub candidate failure")
PY
  fuzz fuzz --mode builtin --seed 1 --n 20 --candidate-dir "$BATS_TEST_TMPDIR/stub5"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"candidate error"* ]]
}

@test "failure mode 6 exits 2 when the output count differs from the input count" {
  write_stub "$BATS_TEST_TMPDIR/stub6" <<'PY'
def gitleaks_present():
    return False


def redact_texts(texts):
    return list(texts)[:-1], False
PY
  fuzz fuzz --mode builtin --seed 1 --n 20 --candidate-dir "$BATS_TEST_TMPDIR/stub6"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"output count"* ]]
}

@test "failure mode 7 exits 2 when gitleaks reports failed" {
  write_stub "$BATS_TEST_TMPDIR/stub7" <<'PY'
def gitleaks_present():
    return True


def redact_texts(texts):
    return list(texts), True
PY
  fuzz fuzz --mode gitleaks --candidate-dir "$BATS_TEST_TMPDIR/stub7"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"gitleaks failed"* ]]
}

# write_stub8 — leaks on any batch call (more than one text). With a single
# text it follows $STUB_ALONE: "clean" delegates to the real lib (not worse),
# anything else returns the text untouched (worse).
write_stub8() {
  write_stub "$BATS_TEST_TMPDIR/stub8" <<'PY'
import importlib.util
import os


def _real():
    spec = importlib.util.spec_from_file_location("real_redact", os.environ["REAL_LIB"])
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def gitleaks_present():
    return _real().gitleaks_present()


def redact_texts(texts):
    if len(texts) == 1 and os.environ.get("STUB_ALONE") == "clean":
        return _real().redact_texts(texts)
    return list(texts), False
PY
}

@test "failure mode 8 exits 2 when over the cap and none of the first flagged is confirmed" {
  write_stub8
  export STUB_ALONE=clean
  fuzz fuzz --mode gitleaks --candidate-dir "$BATS_TEST_TMPDIR/stub8" --confirm-cap 5
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"too many to confirm"* ]]
}

@test "more than 40 flagged with a confirmed text exits 1" {
  write_stub8
  export STUB_ALONE=leak
  fuzz fuzz --mode gitleaks --candidate-dir "$BATS_TEST_TMPDIR/stub8" --confirm-cap 5
  [ "$status" -eq 1 ]
  has_match '^flagged=[0-9]+ confirmed=[1-9][0-9]*$'
}

# --- AC6b: marker rule ------------------------------------------------------

@test "marker with a name outside the allowed set keeps its piece" {
  run python3 "$HELPER" selftest
  echo "# [exit $status]" >&3
  while IFS= read -r l; do printf '# %s\n' "$l" >&3; done <<<"$output"
  [ "$status" -eq 0 ]
  grep -Eq '^check=uppercase-marker score=[1-9][0-9]*$' <<<"$output"
}

# --- AC7: no real secrets in the test files ---------------------------------

@test "gitleaks finds no leak in the helper" {
  run gitleaks dir --no-banner "$HELPER"
  printf '# %s\n' "$output" >&3
  [ "$status" -eq 0 ]
  [[ "$output" == *"no leaks found"* ]]
}

@test "gitleaks finds no leak in this bats file" {
  run gitleaks dir --no-banner "$BATS_TEST_FILENAME"
  printf '# %s\n' "$output" >&3
  [ "$status" -eq 0 ]
  [[ "$output" == *"no leaks found"* ]]
}

# --- AC9: pin rule ----------------------------------------------------------

@test "the pinned sha appears once outside the changelogs and that is the helper" {
  # Split so this file does not hold the sha it counts.
  local pin="0da91ef40956""fb99b0b78da59d3cb2dfb8e809cf"
  # release-please writes commit links with full shas into CHANGELOG.md.
  run git grep -c --untracked -e "$pin" -- . ':(exclude)*CHANGELOG.md'
  printf '# %s\n' "$output" >&3
  [ "$status" -eq 0 ]
  [ "$output" = "plugins/worklog/hooks/tests/redact_diff_fuzz.py:1" ]
}
