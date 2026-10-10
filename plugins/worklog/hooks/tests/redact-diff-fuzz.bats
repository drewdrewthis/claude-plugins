#!/usr/bin/env bats
# Tests for hooks/tests/redact_diff_fuzz.py — the differential fuzz of hooks/lib/redact.py.
#
# WHAT THIS FILE PROVES (claude-plugins#218, #240):
#   A candidate redact lib is compared with a reference lib that the harness
#   works out from git history on every run (merge base when the lib changed,
#   else the parent of the last change on main). No sha is stored anywhere.
#   A text is "worse" when the candidate leaves more of the planted fake tokens
#   in the output than the reference does. Exit 0 = no worse text, 1 = one or
#   more, 2 = the harness could not run. These tests pin that contract, how the
#   reference is chosen, the named regressions from PR 217 (their bad libs are
#   checked-in fixtures, so no PR ref is fetched), and the exit-2 failure modes.
#
# Tests that need another git history build a temp repo under BATS_TEST_TMPDIR
# and run a COPY of the harness there: the harness finds its repo from its own
# file location. Every temp repo sets its own git identity and ignores the
# global and system git config.
#
# ⚠ NO TOKEN LITERALS IN THIS FILE. Every fake token is made by the helper at
# run time (prefix + seeded random characters). This file only holds recipe
# names (F, G1, ...), seeds, and commit ids. Do not paste a token here: the
# gitleaks tests at the end of this file (AC7) scan it.
#
# ⚠ THE OUTPUT OF PASSING TESTS IS PRINTED ON PURPOSE. Bats hides stdout of a
# passing test, and the CI log is the evidence (corpus_sha256, mode, worse=).
# show() copies the helper call, exit code and output to fd 3, which bats
# always prints. Do not remove it.
#
# ⚠ NEVER skip A TEST HERE. A missing gitleaks, a missing origin/main or a
# missing sha must FAIL (exit 2 is not ok). A skipped test would read as a
# pass in the log. A test below checks this file for that call.
#
# Run: bats hooks/tests/redact-diff-fuzz.bats

bats_require_minimum_version 1.5.0

# A public commit id on main (not a secret) for the builtin teeth run.
SHA_TEETH=05b246073138548869adc73427eed69f980c9567
# Absent from any clone.
SHA_ABSENT=0000000000000000000000000000000000000001
# git blob ids of the three checked-in bad libs under fixtures/redact-regress.
BLOB_CB0AB84=1fb239a6e64ba14a251e6024e2e3fc0ab728cacc
BLOB_3854DC2=b2fe72cdd7571765ead3ae5bcd84b7b6510d0935
BLOB_F1F1F8A=a749eeeb36f53fc1514118de638d6a147c0651a5
LIBREL=plugins/worklog/hooks/lib/redact.py

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
  # Summary lines come first in the helper output, so a cap loses only masked texts.
  local n=0 total
  total="$(grep -c '' <<<"$output")"
  while IFS= read -r l; do
    n=$((n + 1))
    [ "$n" -le 12 ] && printf '# %s\n' "$l" >&3
  done <<<"$output"
  [ "$total" -gt 12 ] && printf '# ... (%s more lines)\n' "$((total - 12))" >&3
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
# A gitleaks bump means changing this constant and the workflow install step together.
GITLEAKS_VERSION=8.30.1
GITLEAKS_MODE="mode=gitleaks gitleaks_present=True version=$GITLEAKS_VERSION failed=False"

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
  [[ "$(first_line)" == reference=* ]]
  has_line "$2"
  has_line worse=0
}

# first_line — the first stdout line.
first_line() { head -n 1 <<<"$output"; }

# REFERENCE_LINE_RE — the first stdout line of every fuzz and case run (AC9).
REFERENCE_LINE_RE='^reference=[0-9a-f]{40} rule=(merge-base library_changed=True|parent-of-last-change library_changed=False last_change=[0-9a-f]{40})$'

# teeth_case <name> <fixture> — AC3: the bad lib is worse, the output starts
# with the derived reference line, and nothing planted leaks into the log.
teeth_case() {
  local pl="$BATS_TEST_TMPDIR/planted"
  fuzz case --name "$1" --candidate-fixture "$2" --dump-planted "$pl"
  [ "$status" -eq 1 ]
  [[ "$(first_line)" == reference=* ]]
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

@test "the pinned gitleaks version is installed on this runner" {
  run gitleaks version
  echo "# gitleaks version: $output" >&3
  [ "$status" -eq 0 ]
  [[ "$output" == *"$GITLEAKS_VERSION"* ]]
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
  has_line confirm_cap=40
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

@test "named case F is worse with cb0ab84" { teeth_case F cb0ab84; }
@test "named case G1 is worse with 3854dc2" { teeth_case G1 3854dc2; }
@test "named case G2b is worse with 3854dc2" { teeth_case G2b 3854dc2; }
@test "named case H1 is worse with f1f1f8a" { teeth_case H1 f1f1f8a; }
@test "named case H2 is worse with f1f1f8a" { teeth_case H2 f1f1f8a; }

@test "named case G2 changes only marker names" {
  fuzz case --name G2 --candidate-fixture 3854dc2
  [ "$status" -eq 0 ]
  # The outputs differ (marker names) yet nothing is worse.
  has_line outputs_differ=1
  has_line worse=0
}

# --- AC5 / AC5b: teeth of the fuzz ------------------------------------------

@test "builtin fuzz has teeth against 05b2460" {
  local pl="$BATS_TEST_TMPDIR/planted"
  fuzz fuzz --mode builtin --seed 2 --n 1000 --candidate-sha "$SHA_TEETH" --dump-planted "$pl"
  [ "$status" -eq 1 ]
  [[ "$(first_line)" == reference=* ]]
  has_match '^worse=[1-9][0-9]*$'
  no_planted_leak "$pl"
}

@test "gitleaks fuzz has teeth against f1f1f8a" {
  local pl="$BATS_TEST_TMPDIR/planted" confirmed
  # A small cap still confirms one or more texts; the default cap is kept by the clean run.
  fuzz fuzz --mode gitleaks --candidate-fixture f1f1f8a --confirm-cap 8 --dump-planted "$pl"
  [ "$status" -eq 1 ]
  [[ "$(first_line)" == reference=* ]]
  # The cap given on the command line is the cap used.
  has_line "confirm_cap=8"
  has_match '^flagged=[0-9]+ confirmed=[1-9][0-9]*$'
  confirmed="$(grep -Eo 'confirmed=[0-9]+' <<<"$output" | head -n 1 | sed 's/confirmed=//')"
  has_line "worse=$confirmed"
  # 17 texts are flagged, so an ignored cap would confirm more than 8.
  [ "$confirmed" -le 8 ]
  no_planted_leak "$pl"
}

# --- AC6: exit-2 failure modes -----------------------------------------------

@test "failure mode 1 exits 2 when the candidate commit is not in the clone" {
  fuzz case --name F --candidate-sha "$SHA_ABSENT"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"$SHA_ABSENT"* ]]
}

@test "failure mode 2 exits 2 when gitleaks mode has no gitleaks" {
  # PATH is narrowed for the helper only: bats' own `run` needs its tools.
  local nogl py; nogl="$(path_without_gitleaks)"; py="$(command -v python3)"
  run --separate-stderr env PATH="$nogl" "$py" "$HELPER" fuzz --mode gitleaks
  show fuzz --mode gitleaks "(PATH without gitleaks)"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"gitleaks not found"* ]]
}

@test "failure mode 3 exits 2 when gitleaks is visible in builtin mode" {
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

@test "failure mode 4 exits 2 when the candidate raises" {
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

@test "failure mode 5 exits 2 when the output count differs from the input count" {
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

@test "failure mode 6 exits 2 when gitleaks reports failed" {
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
    log = os.environ.get("STUB_ALONE_LOG")
    if len(texts) == 1 and log:
        with open(log, "a") as f:
            f.write("alone\n")
    if len(texts) == 1 and os.environ.get("STUB_ALONE") == "clean":
        return _real().redact_texts(texts)
    return list(texts), False
PY
}

@test "failure mode 7 exits 2 when over the cap and none of the first flagged is confirmed" {
  write_stub8
  export STUB_ALONE=clean STUB_ALONE_LOG="$BATS_TEST_TMPDIR/alone.log"
  fuzz fuzz --mode gitleaks --candidate-dir "$BATS_TEST_TMPDIR/stub8" --confirm-cap 2
  [ "$status" -eq 2 ]
  # The candidate lib runs alone once per confirmed attempt, so an ignored cap gives 1,000 lines.
  [ "$(wc -l <"$STUB_ALONE_LOG")" -eq 2 ]
  [[ "$stderr" == *"too many to confirm"* ]]
  # The message names the cap that was passed, so an ignored --confirm-cap fails here.
  [[ "$stderr" == *"none of the first 2 "* ]]
}

@test "failure mode 8 exits 2 when a lib reports no gitleaks in gitleaks mode" {
  write_stub "$BATS_TEST_TMPDIR/stub9" <<'PY'
def gitleaks_present():
    return False


def redact_texts(texts):
    return list(texts), False
PY
  fuzz case --name H1 --candidate-dir "$BATS_TEST_TMPDIR/stub9"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"gitleaks not present in gitleaks mode"* ]]
}

@test "failure mode 9 exits 2 when an option is not used in the mode" {
  fuzz fuzz --mode gitleaks --seed 3
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"option not used in this mode: --seed"* ]]
  fuzz fuzz --mode builtin --seed 1 --n 20 --confirm-cap 5
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"option not used in this mode: --confirm-cap"* ]]
}

@test "failure mode 10 exits 2 on a malformed sha" {
  fuzz case --name F --candidate-sha not-a-sha
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"bad sha: --candidate-sha"* ]]
  [[ "$stderr" != *not-a-sha* ]]
}

@test "more flagged than the cap, with a confirmed text, exits 1" {
  local confirmed
  write_stub8
  export STUB_ALONE=leak STUB_ALONE_LOG="$BATS_TEST_TMPDIR/alone.log"
  fuzz fuzz --mode gitleaks --candidate-dir "$BATS_TEST_TMPDIR/stub8" --confirm-cap 2
  [ "$status" -eq 1 ]
  has_line "confirm_cap=2"
  has_match '^flagged=[0-9]+ confirmed=[1-9][0-9]*$'
  confirmed="$(grep -Eo 'confirmed=[0-9]+' <<<"$output" | head -n 1 | sed 's/confirmed=//')"
  # The leak stub is worse on every text alone, so every attempt is confirmed.
  [ "$confirmed" -eq 2 ]
  [ "$(wc -l <"$STUB_ALONE_LOG")" -eq 2 ]
}

@test "failure mode 11 exits 2 when a fixture blob id differs" {
  # AC12: one changed byte in a copied fixture. The repo copy keeps the real
  # fixtures untouched.
  tr_new fx
  tr_first_lib one
  tr_lib two
  tr_origin "$LAST"
  printf 'x' >>"$TR/plugins/worklog/hooks/tests/fixtures/redact-regress/redact-3854dc2.py.txt"
  fuzz case --name G1 --candidate-fixture 3854dc2
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"redact-3854dc2.py.txt"* ]]
  [[ "$stderr" == *"blob id"* ]]
}

# --- AC6b: marker rule ------------------------------------------------------

@test "marker with a name outside the allowed set keeps its piece" {
  run --separate-stderr python3 "$HELPER" selftest
  show selftest
  [ "$status" -eq 0 ]
  grep -Eq '^check=uppercase-marker score=[1-9][0-9]*$' <<<"$output"
  # A marker named after 6+ random chars of a piece keeps the piece, a 41-char
  # name is no marker, and a plain name with digits and hyphens is still cut out.
  # A name sharing only fixed shape text with a piece (slack) is cut out too.
  grep -Eq '^check=piece-in-marker-name score=([4-9]|[1-9][0-9]+)$' <<<"$output"
  grep -Eq '^check=long-marker score=[1-9][0-9]*$' <<<"$output"
  grep -Eq '^check=digit-hyphen-marker score=0$' <<<"$output"
  grep -Eq '^check=shape-text-in-marker-name score=0$' <<<"$output"
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

# --- temp repos -------------------------------------------------------------

# tr_new <name> — an empty repo in BATS_TEST_TMPDIR with a COPY of the harness,
# the fixtures and the real lib at the same relative paths. Sets TR, HELPER.
# `git init -b` is missing on old git, so the branch is set with symbolic-ref.
tr_new() {
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com \
    GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com \
    GIT_AUTHOR_DATE="2026-01-01T00:00:00+0000" GIT_COMMITTER_DATE="2026-01-01T00:00:00+0000"
  TR="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$TR/plugins/worklog/hooks/lib"
  git -C "$TR" init -q
  git -C "$TR" symbolic-ref HEAD refs/heads/main
  cp "$REAL_LIB" "$TR/$LIBREL"
  tr_equip "$TR"
}

# tr_equip <dir> — copy the harness and the fixtures into a repo (untracked).
tr_equip() {
  mkdir -p "$1/plugins/worklog/hooks/tests"
  cp "$BATS_TEST_DIRNAME/redact_diff_fuzz.py" "$1/plugins/worklog/hooks/tests/redact_diff_fuzz.py"
  cp -R "$BATS_TEST_DIRNAME/fixtures" "$1/plugins/worklog/hooks/tests/"
  HELPER="$1/plugins/worklog/hooks/tests/redact_diff_fuzz.py"
}

tg() { git -C "$TR" "$@"; }

# tr_first_lib <msg> — commit the lib as copied. Sets LAST to the new sha.
tr_first_lib() { tg add "$LIBREL"; tg commit -q -m "$1"; LAST="$(tg rev-parse HEAD)"; }

# tr_lib <msg> — change the lib bytes with an appended comment line, commit.
tr_lib() { printf '# %s\n' "$1" >>"$TR/$LIBREL"; tg add "$LIBREL"; tg commit -q -m "$1"; LAST="$(tg rev-parse HEAD)"; }

# tr_lib_top <msg> — like tr_lib, but a comment line near the top (no merge conflict with an append).
tr_lib_top() {
  { head -n 1 "$TR/$LIBREL"; printf '# %s\n' "$1"; tail -n +2 "$TR/$LIBREL"; } >"$TR/lib.new"
  cat "$TR/lib.new" >"$TR/$LIBREL"
  tg add "$LIBREL"; tg commit -q -m "$1"; LAST="$(tg rev-parse HEAD)"
}

# tr_other <msg> — commit a change that does not touch the lib.
tr_other() { printf '%s\n' "$1" >>"$TR/note.txt"; tg add note.txt; tg commit -q -m "$1"; LAST="$(tg rev-parse HEAD)"; }

# tr_origin <sha> — simulate origin/main.
tr_origin() { tg update-ref refs/remotes/origin/main "$1"; }

# tr_weaken — drop the ghp_ shape from the github-pat built-in rule (working tree only).
tr_weaken() {
  python3 - "$TR/$LIBREL" <<'PY'
import sys
s = open(sys.argv[1]).read()
assert "gh[pousr]_" in s
open(sys.argv[1], "w").write(s.replace("gh[pousr]_", "gh[ousr]_", 1))
PY
}

MB_LINE_PREFIX='rule=merge-base library_changed=True'

# --- AC1: no stored reference, no reference option ---------------------------

@test "fuzz --help lists no option with reference in its name" {
  fuzz fuzz --help
  [ "$status" -eq 0 ]
  [ "$(grep -Eic -- '--[a-z-]*reference|reference_' <<<"$output")" -eq 0 ]
}

@test "case --help lists no option with reference in its name" {
  fuzz case --help
  [ "$status" -eq 0 ]
  [ "$(grep -Eic -- '--[a-z-]*reference|reference_' <<<"$output")" -eq 0 ]
}

@test "a reference option is an unrecognized argument and exits 2" {
  fuzz fuzz --mode builtin --reference-sha "$SHA_ABSENT"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"unrecognized arguments"* ]]
}

@test "no file under plugins or .github holds a stored reference constant" {
  # Split so this file does not hold the word it counts.
  local pat="PINNED""_SHA"
  run git grep -c --untracked -e "$pat" -- plugins .github
  printf '# %s\n' "$output" >&3
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "an environment variable does not change the reference line" {
  tr_new env1
  tr_first_lib one
  local c1="$LAST"
  tr_lib two
  tr_other three
  tr_origin "$LAST"
  fuzz reference
  local plain="$output"
  REDACT_FUZZ_REFERENCE="$c1" fuzz reference
  [ "$status" -eq 0 ]
  [ -n "$plain" ]
  [ "$output" = "$plain" ]
}

# --- AC2: a changed lib uses the merge base ----------------------------------

@test "reference is the merge base when a branch commit changes the lib" {
  local mb
  tr_new mb1
  tr_first_lib one
  tr_lib two
  tr_origin "$LAST"
  tg checkout -q -b feature
  tr_lib three
  mb="$(tg merge-base HEAD refs/remotes/origin/main)"
  fuzz reference
  [ "$status" -eq 0 ]
  [ "$output" = "reference=$mb $MB_LINE_PREFIX" ]
}

@test "reference is the merge base when only the working tree lib changed" {
  local mb
  tr_new mb2
  tr_first_lib one
  tr_lib two
  tr_origin "$LAST"
  tg checkout -q -b feature
  printf '# uncommitted\n' >>"$TR/$LIBREL"
  mb="$(tg merge-base HEAD refs/remotes/origin/main)"
  fuzz reference
  [ "$status" -eq 0 ]
  [ "$output" = "reference=$mb $MB_LINE_PREFIX" ]
}

@test "the reference subcommand prints one line" {
  tr_new one1
  tr_first_lib one
  tr_lib two
  tr_origin "$LAST"
  tr_lib three
  fuzz reference
  [ "$status" -eq 0 ]
  [ "$(grep -c '' <<<"$output")" -eq 1 ]
}

# --- AC3: an unchanged lib uses the parent of the last change ----------------

@test "reference is the commit before the last lib change on a linear history" {
  local c1 c2
  tr_new lin
  tr_first_lib one
  c1="$LAST"
  tr_lib two
  c2="$LAST"
  tr_other three
  tr_origin "$LAST"
  fuzz reference
  [ "$status" -eq 0 ]
  [ "$output" = "reference=$c1 rule=parent-of-last-change library_changed=False last_change=$c2" ]
}

@test "reference is the first parent of a no-ff merge that changed the lib" {
  local c2 m
  tr_new mrg
  tr_first_lib one
  tr_lib two
  c2="$LAST"
  tg checkout -q -b topic
  tr_lib topic-one
  tr_lib topic-two
  tg checkout -q main
  tg merge -q --no-ff -m merge-topic topic
  m="$(tg rev-parse HEAD)"
  tr_origin "$m"
  fuzz reference
  [ "$status" -eq 0 ]
  [ "$output" = "reference=$c2 rule=parent-of-last-change library_changed=False last_change=$m" ]
}

@test "reference on the real history at 1d2a9fd is the parent of the last lib change" {
  local clone="$BATS_TEST_TMPDIR/real"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  git clone -q "$REPO" "$clone"
  TR="$clone"
  tg checkout -q --detach 1d2a9fd4fa9b2b6fb3649ff3196ffca4d1049719
  tr_origin 1d2a9fd4fa9b2b6fb3649ff3196ffca4d1049719
  tr_equip "$clone"
  fuzz reference
  [ "$status" -eq 0 ]
  [ "$output" = "reference=92308c9505265b98cb4b4157430c4b3b74ad0198 rule=parent-of-last-change library_changed=False last_change=f2c5a3fe79c67c3b825be1ceed518aafc370295a" ]
}

# --- AC4: a mode-only commit is not a change ---------------------------------

@test "a mode-only commit does not count as the last lib change" {
  local c1 c2
  tr_new mode
  tr_first_lib one
  c1="$LAST"
  tr_lib two
  c2="$LAST"
  tg update-index --chmod=+x "$LIBREL"
  tg commit -q -m mode-only
  tr_origin "$(tg rev-parse HEAD)"
  fuzz reference
  [ "$status" -eq 0 ]
  [ "$output" = "reference=$c1 rule=parent-of-last-change library_changed=False last_change=$c2" ]
}

# --- AC5: the reference is never the candidate -------------------------------

@test "a candidate commit equal to the reference exits 2 with no worse line" {
  local c1
  tr_new same
  tr_first_lib one
  c1="$LAST"
  tr_lib two
  tr_origin "$LAST"
  fuzz case --name F --candidate-sha "$c1"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"reference is identical to the candidate"* ]]
  [ "$(grep -c '^worse=' <<<"$output")" -eq 0 ]
}

# --- AC6: clone problems, in the fixed order ---------------------------------

@test "clone problem a: a depth 1 clone exits 2 and names git fetch --unshallow" {
  local src clone="$BATS_TEST_TMPDIR/shallow"
  tr_new src
  src="$TR"
  tr_first_lib one
  tr_lib two
  tr_lib three
  git clone -q --depth 1 "file://$src" "$clone"
  tr_equip "$clone"
  fuzz reference
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"git fetch --unshallow"* ]]
  [[ "$stderr" != *"no earlier version"* ]]
}

@test "clone problem b: a missing origin/main exits 2 and names git fetch origin main" {
  tr_new noorig
  tr_first_lib one
  tr_lib two
  fuzz reference
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"git fetch origin main"* ]]
}

@test "clone problem c: unrelated histories exit 2 with no single merge base" {
  local root
  tr_new unrel
  tr_first_lib one
  root="$(tg commit-tree -m unrelated "$(tg mktree </dev/null)")"
  tr_origin "$root"
  fuzz reference
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"no single merge base"* ]]
}

@test "clone problem d: a criss-cross merge exits 2 with no single merge base" {
  local tree r a b m1 m2
  tr_new criss
  tr_first_lib one
  tree="$(tg rev-parse HEAD^{tree})"
  r="$(tg rev-parse HEAD)"
  a="$(tg commit-tree -p "$r" -m side-a "$tree")"
  b="$(tg commit-tree -p "$r" -m side-b "$tree")"
  m1="$(tg commit-tree -p "$a" -p "$b" -m merge-1 "$tree")"
  m2="$(tg commit-tree -p "$b" -p "$a" -m merge-2 "$tree")"
  tg update-ref refs/heads/main "$m1"
  tr_origin "$m2"
  fuzz reference
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"no single merge base"* ]]
}

@test "clone problem e: a lib whose only commit is its first exits 2 with no earlier version" {
  tr_new first1
  tr_other readme
  tr_first_lib one
  tr_other later
  tr_origin "$LAST"
  fuzz reference
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"no earlier version"* ]]
}

@test "clone problem e: a root commit that adds the lib exits 2 with no earlier version" {
  tr_new first2
  tr_first_lib one
  tr_other later
  tr_origin "$LAST"
  fuzz reference
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"no earlier version"* ]]
}

@test "clone problem f: a base without the lib file exits 2 with no earlier version" {
  local c0
  tr_new nolib
  tr_other readme
  c0="$LAST"
  tr_first_lib one
  tr_origin "$c0"
  fuzz reference
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"no earlier version"* ]]
}

# --- AC7: detached HEAD and a fork-shaped PR ---------------------------------

@test "a detached HEAD gives the same reference line as the branch" {
  local on_branch
  tr_new det
  tr_first_lib one
  tr_lib two
  tr_origin "$LAST"
  tg checkout -q -b feature
  tr_lib three
  fuzz reference
  on_branch="$output"
  tg checkout -q --detach
  fuzz reference
  [ "$status" -eq 0 ]
  [[ "$on_branch" == reference=* ]]
  [ "$output" = "$on_branch" ]
}

@test "a merge of origin/main and a commit outside origin uses the origin/main tip" {
  local tip
  tr_new fork
  tr_first_lib one
  tr_lib two
  tip="$LAST"
  tr_origin "$tip"
  tg checkout -q -b fork-pr HEAD~1
  tr_lib_top fork-change
  tg checkout -q -b pr-merge "$tip"
  tg merge -q --no-ff -m merge-fork fork-pr
  fuzz reference
  [ "$status" -eq 0 ]
  [ "$output" = "reference=$tip $MB_LINE_PREFIX" ]
}

# --- AC8: a harness failure is red, never a skip -----------------------------

@test "this file holds no skip call" {
  # Split so this file does not match its own check.
  local pat='^[[:space:]]*sk''ip([[:space:]]|$)'
  run grep -cE "$pat" "$BATS_TEST_FILENAME"
  printf '# skip calls: %s\n' "$output" >&3
  [ "$output" = "0" ]
}

# --- AC9: the derived reference is shown -------------------------------------

@test "a fuzz run prints the reference line first" {
  tr_new line1
  tr_first_lib one
  tr_lib two
  tr_origin "$LAST"
  tr_lib three
  fuzz fuzz --mode builtin --seed 1 --n 20
  [ "$status" -eq 0 ]
  [[ "$(first_line)" =~ $REFERENCE_LINE_RE ]]
}

@test "a case run prints the reference line first" {
  tr_new line2
  tr_first_lib one
  tr_lib two
  tr_origin "$LAST"
  fuzz case --name F
  [ "$status" -eq 0 ]
  [[ "$(first_line)" =~ $REFERENCE_LINE_RE ]]
}

@test "a planted weaker lib in the working tree is worse against the merge base" {
  local mb
  tr_new weak1
  tr_first_lib one
  tr_lib two
  tr_origin "$LAST"
  tg checkout -q -b feature
  tr_weaken
  mb="$(tg merge-base HEAD refs/remotes/origin/main)"
  fuzz fuzz --mode builtin --seed 1 --n 1000
  [ "$status" -eq 1 ]
  [ "$(first_line)" = "reference=$mb $MB_LINE_PREFIX" ]
  has_match '^worse=[1-9][0-9]*$'
  [ "$(grep -c '^not from this change:' <<<"$output")" -eq 0 ]
}

@test "a worse lib change already on main prints the not from this change line" {
  local c1 c2
  tr_new weak2
  tr_first_lib one
  c1="$LAST"
  tr_weaken
  tg add "$LIBREL"
  tg commit -q -m weaken
  c2="$(tg rev-parse HEAD)"
  tr_origin "$c2"
  fuzz fuzz --mode builtin --seed 1 --n 1000
  [ "$status" -eq 1 ]
  [ "$(first_line)" = "reference=$c1 rule=parent-of-last-change library_changed=False last_change=$c2" ]
  has_line "not from this change: the library change $c2 on main is worse than its parent"
}

# --- AC12: fixtures are checked and inert ------------------------------------

FIXTURE_DIR=plugins/worklog/hooks/tests/fixtures/redact-regress

@test "the fixture directory holds exactly the three bad libs" {
  run bash -c 'cd "$1" && ls -A | tr "\n" " "' _ "$REPO/$FIXTURE_DIR"
  [ "$output" = "redact-3854dc2.py.txt redact-cb0ab84.py.txt redact-f1f1f8a.py.txt " ]
}

@test "fixture redact-cb0ab84 has its recorded blob id" {
  run git hash-object --no-filters "$REPO/$FIXTURE_DIR/redact-cb0ab84.py.txt"
  [ "$output" = "$BLOB_CB0AB84" ]
}

@test "fixture redact-3854dc2 has its recorded blob id" {
  run git hash-object --no-filters "$REPO/$FIXTURE_DIR/redact-3854dc2.py.txt"
  [ "$output" = "$BLOB_3854DC2" ]
}

@test "fixture redact-f1f1f8a has its recorded blob id" {
  run git hash-object --no-filters "$REPO/$FIXTURE_DIR/redact-f1f1f8a.py.txt"
  [ "$output" = "$BLOB_F1F1F8A" ]
}

@test "no python file sits under the fixtures directory" {
  run find "$REPO/plugins/worklog" -name '*.py' -path '*/fixtures/*'
  [ -z "$output" ]
}

@test "gitleaks finds no leak in the fixtures" {
  run gitleaks dir --no-banner "$REPO/$FIXTURE_DIR"
  printf '# %s\n' "$output" >&3
  [ "$status" -eq 0 ]
  [[ "$output" == *"no leaks found"* ]]
}

@test "no fixture holds the gitleaks allow string" {
  # Built from two parts so this file does not hold it either.
  local allow="gitleaks:""allow"
  run grep -rc -e "$allow" "$REPO/$FIXTURE_DIR"
  [[ "$output" != *":"[1-9]* ]]
}

# --- AC13: no PR 217 ref -----------------------------------------------------

@test "no file under plugins or .github names the PR 217 ref" {
  # Split so this file does not hold the pattern it counts.
  local pat="pull/217""/head"
  run git grep -c --untracked -e "$pat" -- plugins .github
  printf '# %s\n' "$output" >&3
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}
