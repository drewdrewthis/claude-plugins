#!/usr/bin/env bats
# Behavioural tests for scripts/heartbeats.py and scripts/units.py.
#
# WHY THIS SHAPE. The dangerous failure here is not a crash -- it is a quiet
# one: a partial block spliced into a live crontab deletes the jobs that failed
# to parse, and a rewrite that reflows the file loses the lines nobody was
# managing. Neither raises. So the assertions are about what SURVIVES a write
# (the lines outside the markers, byte for byte) and about the exit code of the
# rejection paths, never about a happy-path string alone.
#
# The `m*` and `q*` tests each pin a reproduced data-loss counterexample: an
# orphan BEGIN marker that made the next install delete every line under it, a
# second stale block that made drift-check report clean, field values that forge
# crontab structure (an exotic line break that reads back as two lines, an
# unescaped `%` that cron reads as newline-plus-stdin, a CR that smuggles in a
# field the unit never declares), and a lossy decode that corrupts bytes it was
# only meant to read. Deleting any one of them re-opens a way to lose a real job.
#
# The `p*` tests are the only ones that reach the real `crontab -l` / `crontab -`
# subprocess branches. They do it by putting a FAKE `crontab` first on PATH --
# still never a real crontab, but no longer skipping the code that decides
# whether a failed `crontab -l` means "empty" or "stop".
#
# Every fixture is synthetic -- invented unit names, invented commands,
# invented log paths. No real host, schedule, or command line appears anywhere
# here, and no test ever reads or writes a real crontab: `--crontab-file`
# substitutes a plain file, and where that is bypassed on purpose, the PATH
# shim stands in for the binary.
#
# Requires bats >= 1.4 for $BATS_TEST_TMPDIR (guarded in setup). Deliberately
# avoids bats >= 1.5 features such as `run --separate-stderr`.
#
# Run: cd plugins/heartbeats && bats scripts/tests

setup() {
  # Every test writes into $BATS_TEST_TMPDIR. On bats < 1.4 it is unset, and
  # each of those writes would land in the current directory instead -- so fail
  # loudly here rather than scattering files through the checkout.
  if [ -z "$BATS_TEST_TMPDIR" ]; then
    printf 'BATS_TEST_TMPDIR is unset: this suite needs bats >= 1.4.\n' >&2
    return 1
  fi

  SCRIPT="$BATS_TEST_DIRNAME/../heartbeats.py"
  FIXTURES="$BATS_TEST_DIRNAME/fixtures"
  BASIC="$FIXTURES/units-basic"
  ERRFILE="$BATS_TEST_TMPDIR/stderr"
  CRONTAB="$BATS_TEST_TMPDIR/crontab.txt"
  # Ambient units config must not reach the script under test.
  unset HEARTBEATS_UNITS_DIR CODEX_ROOT
  # The crontab injection point is POINTED AT THE SANDBOX rather than unset, so
  # a future test that forgets --crontab-file writes a temp file instead of
  # this machine's real crontab.
  export HEARTBEATS_CRONTAB_FILE="$BATS_TEST_TMPDIR/sandbox-crontab.txt"
}

# Runs the script capturing stdout in $output and stderr in $ERRFILE, so a
# "no partial render output" assertion can look at stdout alone. Written this
# way rather than with `run --separate-stderr`, which needs bats >= 1.5.
hb() {
  run bash -c "python3 '$SCRIPT' \"\$@\" 2>'$ERRFILE'" bash "$@"
}

# The crontab with the managed region excised -- what must survive an install.
strip_block() {
  sed '/heartbeats:begin/,/heartbeats:end/d' "$1"
}

# stdin -> stdout with every LF turned into CRLF. Done in Python rather than
# with sed so the byte rewrite is exact and portable.
to_crlf() {
  python3 -c 'import sys; sys.stdout.buffer.write(sys.stdin.buffer.read().replace(b"\n", b"\r\n"))'
}

seed_crontab_with_block() {
  printf 'pre-line-one\npre-line-two\npre-line-three\n' >"$CRONTAB"
  python3 "$SCRIPT" render --units-dir "$BASIC" >>"$CRONTAB"
  printf 'post-line-one\npost-line-two\n' >>"$CRONTAB"
}

# A correct block, an unmanaged line, then a second stale copy of the block.
seed_crontab_with_two_blocks() {
  seed_crontab_with_block
  printf 'middle-unmanaged-line\n' >>"$CRONTAB"
  python3 "$SCRIPT" render --units-dir "$BASIC" >>"$CRONTAB"
}

# Puts a fake `crontab` first on PATH and takes the file-based injection point
# away, so the script falls through to the real subprocess branches. The shim
# reads its behaviour out of $SHIM_DIR so each test can set exit code, stdout
# and stderr without rewriting the script.
install_crontab_shim() {
  export SHIM_DIR="$BATS_TEST_TMPDIR/shim"
  mkdir -p "$SHIM_DIR" "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/crontab" <<'SHIM'
#!/usr/bin/env bash
if [ "$1" = "-l" ]; then
  if [ -f "$SHIM_DIR/stdout" ]; then cat "$SHIM_DIR/stdout"; fi
  if [ -f "$SHIM_DIR/stderr" ]; then cat "$SHIM_DIR/stderr" >&2; fi
  if [ -f "$SHIM_DIR/exit" ]; then exit "$(cat "$SHIM_DIR/exit")"; fi
  exit 0
fi
if [ "$1" = "-" ]; then
  cat >"$SHIM_DIR/stdin"
  exit 0
fi
exit 99
SHIM
  chmod +x "$BATS_TEST_TMPDIR/bin/crontab"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  # The whole point is to exercise the branch this variable bypasses.
  unset HEARTBEATS_CRONTAB_FILE
}

# --- (a) drift-check red-capability ----------------------------------------

@test "a1: drift-check exits 3 and names the drifted unit when a managed line is mutated" {
  seed_crontab_with_block
  # One character of schedule, inside the block. Nothing else changes.
  sed -i 's|^30 6 |31 6 |' "$CRONTAB"

  hb drift-check --units-dir "$BASIC" --crontab-file "$CRONTAB"
  [ "$status" -eq 3 ]
  [[ "$output" == *"example-daily-report"* ]]
}

@test "a2: drift-check exits 0 and says nothing on the unmutated twin of the drifted fixture" {
  seed_crontab_with_block

  hb drift-check --units-dir "$BASIC" --crontab-file "$CRONTAB"
  [ "$status" -eq 0 ]
  # Clean has to be SILENT, not "clean plus a line that looks like a finding".
  [ -z "$output" ]
}

@test "a3: drift-check exits 3 and names every unit on both sides of the mismatch" {
  seed_crontab_with_block
  # Same crontab, different units dir: the seeded units now have no files, and
  # the alt dir's unit is missing from the crontab.
  hb drift-check --units-dir "$FIXTURES/units-alt" --crontab-file "$CRONTAB"
  [ "$status" -eq 3 ]
  [[ "$output" == *"example-daily-report"* ]]
  [[ "$output" == *"example-weekly-sweep"* ]]
  [[ "$output" == *"example-hourly-probe"* ]]
}

# --- (b) boundary safety ----------------------------------------------------

@test "b1: install leaves the 3 lines before and 2 lines after the managed block byte-identical" {
  seed_crontab_with_block
  sed -i 's|^30 6 |31 6 |' "$CRONTAB"   # force install to actually rewrite the block
  strip_block "$CRONTAB" >"$BATS_TEST_TMPDIR/outside.before"

  hb install --approve --units-dir "$BASIC" --crontab-file "$CRONTAB"
  [ "$status" -eq 0 ]

  strip_block "$CRONTAB" >"$BATS_TEST_TMPDIR/outside.after"
  run diff "$BATS_TEST_TMPDIR/outside.before" "$BATS_TEST_TMPDIR/outside.after"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "b2: first install appends the block and leaves every pre-existing line untouched" {
  printf 'pre-line-one\npre-line-two\npre-line-three\n' >"$CRONTAB"
  cp "$CRONTAB" "$BATS_TEST_TMPDIR/outside.before"

  hb install --approve --units-dir "$BASIC" --crontab-file "$CRONTAB"
  [ "$status" -eq 0 ]

  grep -q 'heartbeats:begin' "$CRONTAB"
  strip_block "$CRONTAB" >"$BATS_TEST_TMPDIR/outside.after"
  run diff "$BATS_TEST_TMPDIR/outside.before" "$BATS_TEST_TMPDIR/outside.after"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- (c) fail-closed rejection ---------------------------------------------

# Each case asserts all three halves of "fails closed": exit 1, the offending
# FILENAME in the error, and not one line of block on stdout. Takes a directory
# PATH so a runtime-generated fixture can use it too. Every caller additionally
# asserts a fragment of the REASON: filename-plus-exit-1 alone would pass for
# any rejection, including the wrong one.
assert_rejects() {
  local dir="$1" filename="$2"
  hb render --units-dir "$dir"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  grep -q "$filename" "$ERRFILE"
  # A rejection is an error message, never a stack trace.
  ! grep -q "Traceback" "$ERRFILE"
}

@test "c1: rejects a unit whose frontmatter cannot be parsed" {
  assert_rejects "$FIXTURES/bad-frontmatter" unparseable-frontmatter.md
  grep -q "no closing" "$ERRFILE"
}

@test "c2: rejects a unit missing a required field" {
  assert_rejects "$FIXTURES/bad-missing-field" missing-log-field.md
  grep -q "missing required field 'log'" "$ERRFILE"
}

@test "c3: rejects enabled:false without both suspension_reason and restore_condition" {
  assert_rejects "$FIXTURES/bad-suspension" half-suspended.md
  grep -q "missing restore_condition" "$ERRFILE"
}

@test "c4: rejects a cron value that is not 5 whitespace-separated fields" {
  assert_rejects "$FIXTURES/bad-cron" four-field-cron.md
  grep -q "exactly 5 whitespace-separated fields" "$ERRFILE"
}

@test "c5: rejects a frontmatter key the plugin does not implement" {
  assert_rejects "$FIXTURES/bad-unknown-key" unknown-key.md
  grep -q "retries" "$ERRFILE"
}

@test "c6: rejects the same key given twice in one unit file" {
  assert_rejects "$FIXTURES/bad-duplicate-key" duplicate-key.md
  grep -q "duplicate field" "$ERRFILE"
}

@test "c7: rejects two unit files claiming the same unit name, naming both" {
  assert_rejects "$FIXTURES/bad-duplicate-name" second-copy.md
  grep -q "first-copy.md" "$ERRFILE"
  grep -q "example-duplicated-unit" "$ERRFILE"
}

@test "c8: rejects a field whose value is empty" {
  assert_rejects "$FIXTURES/bad-empty-value" empty-value.md
  grep -q "empty value" "$ERRFILE"
}

@test "c9: a units directory that does not exist is an error naming the directory" {
  hb render --units-dir "$BATS_TEST_TMPDIR/absent-units-dir"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  grep -q "absent-units-dir" "$ERRFILE"
  grep -q "units directory does not exist" "$ERRFILE"
}

@test "c10: rejects a unit name that cannot round-trip through the header line" {
  assert_rejects "$FIXTURES/bad-name" invalid-name.md
  grep -q "field 'name' must match" "$ERRFILE"
}

@test "c11: rejects a non-boolean enabled value rather than guessing what it meant" {
  assert_rejects "$FIXTURES/bad-enabled" non-boolean-enabled.md
  grep -q "must be exactly 'true' or 'false'" "$ERRFILE"
}

@test "c12: a units directory that cannot be listed is a named error, not a traceback" {
  if [ "$(id -u)" -eq 0 ]; then
    skip "root ignores permission bits"
  fi
  local locked="$BATS_TEST_TMPDIR/locked-units"
  mkdir -p "$locked"
  cp "$BASIC"/*.md "$locked/"
  chmod 000 "$locked"

  hb render --units-dir "$locked"
  local seen="$status"
  # Restored BEFORE the assertions, so a failing assertion still leaves bats
  # able to clean up its own temp dir.
  chmod 755 "$locked"

  [ "$seen" -eq 1 ]
  [ -z "$output" ]
  grep -q "cannot list" "$ERRFILE"
  grep -q "locked-units" "$ERRFILE"
  ! grep -q "Traceback" "$ERRFILE"
}

@test "c13: a unit file behind a UTF-8 BOM is told it has a BOM, not that '---' is missing" {
  local dir="$BATS_TEST_TMPDIR/bom-units"
  mkdir -p "$dir"
  # Written as bytes rather than checked in as a fixture: a BOM is invisible in
  # an editor, which is the whole reason it earns its own diagnostic, and an
  # invisible byte in a fixture is a trap for the next reader.
  python3 - "$dir/bom-unit.md" <<'BOMPY'
import pathlib, sys
body = (
    "---\n"
    "name: example-bom-unit\n"
    "cron: 30 6 * * *\n"
    "command: /usr/local/bin/example-job --flag\n"
    "log: /var/log/example/bom-unit.log\n"
    "enabled: true\n"
    "---\n"
)
pathlib.Path(sys.argv[1]).write_bytes(b"\xef\xbb\xbf" + body.encode("utf-8"))
BOMPY

  hb render --units-dir "$dir"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  grep -q "bom-unit.md" "$ERRFILE"
  grep -q "BOM" "$ERRFILE"
  ! grep -q "Traceback" "$ERRFILE"
}

# --- (d) suspended units stay visible --------------------------------------

@test "d1: a suspended unit renders commented, carrying both its reason and its restore condition" {
  hb render --units-dir "$BASIC"
  [ "$status" -eq 0 ]
  [[ "$output" == *"example-weekly-sweep [SUSPENDED] upstream endpoint returns 503"* ]]
  [[ "$output" == *"# heartbeats-restore: re-enable once the upstream status page reports steady state"* ]]
  [[ "$output" == *"#0 4 * * 0 /usr/local/bin/example-sweep"* ]]
  # Commented, therefore never an uncommented schedule line.
  run grep -c '^0 4 \* \* 0' <<<"$output"
  [ "$status" -ne 0 ]
}

# --- (e) no auto-install ---------------------------------------------------

@test "e1: install without the approval flag exits 2 and leaves the crontab unchanged" {
  seed_crontab_with_block
  sed -i 's|^30 6 |31 6 |' "$CRONTAB"
  cp "$CRONTAB" "$BATS_TEST_TMPDIR/crontab.before"

  hb install --units-dir "$BASIC" --crontab-file "$CRONTAB"
  [ "$status" -eq 2 ]

  run diff "$BATS_TEST_TMPDIR/crontab.before" "$CRONTAB"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- (f) empty units dir ---------------------------------------------------

@test "f1: an empty units directory renders an empty block with both markers intact" {
  mkdir -p "$BATS_TEST_TMPDIR/units-empty"

  hb render --units-dir "$BATS_TEST_TMPDIR/units-empty"
  [ "$status" -eq 0 ]
  [ "$(wc -l <<<"$output")" -eq 2 ]
  [[ "$output" == *"heartbeats:begin"* ]]
  [[ "$output" == *"heartbeats:end"* ]]
}

# --- (g) the units dir is a runtime input ----------------------------------

@test "g1: render against two different units dirs in one run produces each dir's own units" {
  hb render --units-dir "$BASIC"
  [ "$status" -eq 0 ]
  [[ "$output" == *"example-daily-report"* ]]
  [[ "$output" != *"example-hourly-probe"* ]]

  hb render --units-dir "$FIXTURES/units-alt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"example-hourly-probe"* ]]
  [[ "$output" != *"example-daily-report"* ]]
}

@test "g2: the units dir can come from HEARTBEATS_UNITS_DIR instead of the flag" {
  export HEARTBEATS_UNITS_DIR="$FIXTURES/units-alt"
  hb render
  [ "$status" -eq 0 ]
  [[ "$output" == *"example-hourly-probe"* ]]
}

# --- (h) supporting behaviour ----------------------------------------------

@test "h1: prose below the frontmatter never reaches the rendered block" {
  hb render --units-dir "$BASIC"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Synthetic fixture"* ]]
}

@test "h2: drift-check exits 3 reporting a missing managed block rather than claiming clean" {
  printf 'pre-line-one\n' >"$CRONTAB"

  hb drift-check --units-dir "$BASIC" --crontab-file "$CRONTAB"
  [ "$status" -eq 3 ]
  [[ "$output" == *"not present"* ]]
}

@test "h3: install is idempotent -- a second approved install writes nothing at all" {
  seed_crontab_with_block
  cp "$CRONTAB" "$BATS_TEST_TMPDIR/crontab.before"

  hb install --approve --units-dir "$BASIC" --crontab-file "$CRONTAB"
  [ "$status" -eq 0 ]
  # Not merely "same bytes afterwards" -- it says outright that it skipped the
  # write, which is what keeps a no-drift repair run out of the audit trail.
  [[ "$output" == *"already current"* ]]

  run diff "$BATS_TEST_TMPDIR/crontab.before" "$CRONTAB"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "h4: an install that drops previously managed units says so, not just 'installed 0'" {
  seed_crontab_with_block
  local empty="$BATS_TEST_TMPDIR/no-units"
  mkdir -p "$empty"

  hb install --approve --units-dir "$empty" --crontab-file "$CRONTAB"
  [ "$status" -eq 0 ]
  # "installed 0 unit(s)" on its own reads like a no-op. The crontab just lost
  # every job it was managing, and that is the half worth saying out loud.
  [[ "$output" == *"installed 0 unit(s)"* ]]
  [[ "$output" == *"removed"* ]]

  # Lines outside the block are untouched by the removal.
  grep -q "^pre-line-one$" "$CRONTAB"
  grep -q "^post-line-two$" "$CRONTAB"
  # ...and no unit header survived inside it.
  run grep -c "heartbeats-unit:" "$CRONTAB"
  [ "$status" -ne 0 ]
}

# --- (i) the diff operation -------------------------------------------------

@test "i1: diff shows the whole block as an addition when the crontab has no managed region" {
  printf 'pre-line-one\n' >"$CRONTAB"

  hb diff --units-dir "$BASIC" --crontab-file "$CRONTAB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"+# heartbeats-unit: example-daily-report"* ]]
  [[ "$output" == *"heartbeats:begin"* ]]
}

@test "i2: diff prints nothing when the live block already matches the units" {
  seed_crontab_with_block

  hb diff --units-dir "$BASIC" --crontab-file "$CRONTAB"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- (m) reproduced data-loss counterexamples -------------------------------

@test "m1: install refuses a crontab whose BEGIN marker has no END, leaving it byte-identical" {
  python3 "$SCRIPT" render --units-dir "$BASIC" | head -n 1 >"$BATS_TEST_TMPDIR/begin-marker"
  {
    printf 'unmanaged-user-job-line\n'
    cat "$BATS_TEST_TMPDIR/begin-marker"
    printf 'another-unmanaged-line\n'
  } >"$CRONTAB"
  cp "$CRONTAB" "$BATS_TEST_TMPDIR/crontab.before"

  hb install --approve --units-dir "$BASIC" --crontab-file "$CRONTAB"
  [ "$status" -eq 1 ]
  grep -q "malformed managed block" "$ERRFILE"

  run diff "$BATS_TEST_TMPDIR/crontab.before" "$CRONTAB"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -q "unmanaged-user-job-line" "$CRONTAB"
  grep -q "another-unmanaged-line" "$CRONTAB"
}

@test "m2: drift-check refuses to report clean when a second stale managed block is present" {
  seed_crontab_with_two_blocks

  hb drift-check --units-dir "$BASIC" --crontab-file "$CRONTAB"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  grep -q "malformed managed block" "$ERRFILE"
}

@test "m3: install refuses a crontab with two managed blocks, leaving it byte-identical" {
  seed_crontab_with_two_blocks
  cp "$CRONTAB" "$BATS_TEST_TMPDIR/crontab.before"

  hb install --approve --units-dir "$BASIC" --crontab-file "$CRONTAB"
  [ "$status" -eq 1 ]

  run diff "$BATS_TEST_TMPDIR/crontab.before" "$CRONTAB"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -q "middle-unmanaged-line" "$CRONTAB"
}

@test "m4: rejects a command carrying an unescaped percent sign, naming the escape" {
  assert_rejects "$FIXTURES/bad-percent" unescaped-percent.md
  grep -q "escape it as" "$ERRFILE"
}

@test "m5: rejects a field value carrying an exotic line-break character" {
  # Generated here rather than committed as a fixture: the point of U+2028 is
  # that it is invisible, so a committed file would be silently normalised by
  # some editor or tool and the test would quietly stop testing anything. The
  # character is spelled as a code point for the same reason. The value forges
  # an END marker on the second line the old reader would have split it into.
  mkdir -p "$BATS_TEST_TMPDIR/units-exotic"
  python3 - "$BATS_TEST_TMPDIR/units-exotic/exotic-value.md" <<'PY'
import sys

reason = "paused" + chr(0x2028) + "# <<< heartbeats:end <<<"
open(sys.argv[1], "w", encoding="utf-8").write(
    "---\n"
    "name: example-exotic-unit\n"
    "cron: 0 5 * * *\n"
    "command: /usr/local/bin/example-job\n"
    "log: /var/log/example/exotic-unit.log\n"
    "enabled: false\n"
    "suspension_reason: " + reason + "\n"
    "restore_condition: restore when the upstream recovers\n"
    "---\n"
)
PY

  assert_rejects "$BATS_TEST_TMPDIR/units-exotic" exotic-value.md
  grep -q "U+2028" "$ERRFILE"
}

@test "m6: install preserves the CR bytes of CRLF lines outside the managed block" {
  printf 'crlf-line-one\r\ncrlf-line-two\r\n' >"$CRONTAB"
  cp "$CRONTAB" "$BATS_TEST_TMPDIR/crlf.before"
  local before_bytes
  before_bytes=$(wc -c <"$BATS_TEST_TMPDIR/crlf.before" | tr -d ' ')

  hb install --approve --units-dir "$BASIC" --crontab-file "$CRONTAB"
  [ "$status" -eq 0 ]

  head -c "$before_bytes" "$CRONTAB" >"$BATS_TEST_TMPDIR/crlf.after"
  run diff "$BATS_TEST_TMPDIR/crlf.before" "$BATS_TEST_TMPDIR/crlf.after"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "m7: rejects an unescaped percent sign in the schedule, not only in the command" {
  # Five fields, so the arity check passes and the value reaches the live line.
  assert_rejects "$FIXTURES/bad-percent-cron" percent-in-cron.md
  grep -q "field 'cron'" "$ERRFILE"
  grep -q "escape it as" "$ERRFILE"
}

@test "m8: a cron value starting with '#' is refused by every operation, installing nothing" {
  local dir="$FIXTURES/bad-cron-comment"
  printf 'untouched-user-line\n' >"$CRONTAB"
  cp "$CRONTAB" "$BATS_TEST_TMPDIR/hash.before"

  # Without the guard this renders a crontab COMMENT: install reports success,
  # drift-check reports clean, and the job never fires.
  assert_rejects "$dir" "leading-hash-cron.md"
  grep -q "starts with '#'" "$ERRFILE"
  grep -q "never runs" "$ERRFILE"

  hb install --approve --units-dir "$dir" --crontab-file "$CRONTAB"
  [ "$status" -eq 1 ]
  [ -z "$output" ]

  hb drift-check --units-dir "$dir" --crontab-file "$CRONTAB"
  [ "$status" -eq 1 ]
  [ -z "$output" ]

  run diff "$BATS_TEST_TMPDIR/hash.before" "$CRONTAB"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "m9: the same guard refuses a cron value that would forge a unit header" {
  # Five fields again, but the rendered line would begin with the per-unit
  # header prefix and be attributed to a unit that has no file at all.
  assert_rejects "$FIXTURES/bad-cron-phantom" "phantom-header-cron.md"
  grep -q "starts with '#'" "$ERRFILE"
}

# --- (n) the one documented normalisation -----------------------------------

@test "n1: a crontab with no final newline keeps its line content and gains the newline" {
  printf 'no-trailing-newline-one\nno-trailing-newline-two' >"$CRONTAB"

  hb install --approve --units-dir "$BASIC" --crontab-file "$CRONTAB"
  [ "$status" -eq 0 ]

  run head -n 2 "$CRONTAB"
  [ "${lines[0]}" = "no-trailing-newline-one" ]
  [ "${lines[1]}" = "no-trailing-newline-two" ]
  # Command substitution strips trailing newlines, so an empty result is proof
  # the final byte is one.
  [ -z "$(tail -c 1 "$CRONTAB")" ]
}

# --- (p) the real crontab subprocess branches --------------------------------

@test "p1: a 'no crontab for' failure with empty stdout is treated as an empty crontab" {
  install_crontab_shim
  printf 'no crontab for example-user\n' >"$SHIM_DIR/stderr"
  printf '1\n' >"$SHIM_DIR/exit"

  hb drift-check --units-dir "$BASIC"
  # Exit 3 "block not present" is the proof it PROCEEDED: an error would be 1.
  [ "$status" -eq 3 ]
  [[ "$output" == *"not present"* ]]
}

@test "p2: any other 'crontab -l' failure refuses rather than assuming empty" {
  install_crontab_shim
  printf 'crontab: cannot connect to cron daemon\n' >"$SHIM_DIR/stderr"
  printf '1\n' >"$SHIM_DIR/exit"

  hb drift-check --units-dir "$BASIC"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  grep -q "refusing to treat this as an empty crontab" "$ERRFILE"
}

@test "p3: 'no crontab for' with NON-EMPTY stdout still refuses -- both halves must hold" {
  install_crontab_shim
  printf 'unmanaged-user-job-line\n' >"$SHIM_DIR/stdout"
  printf 'no crontab for example-user\n' >"$SHIM_DIR/stderr"
  printf '1\n' >"$SHIM_DIR/exit"

  # If this were an OR, the jobs on stdout would be discarded as "empty" and
  # the next install would delete them.
  hb drift-check --units-dir "$BASIC"
  [ "$status" -eq 1 ]
  grep -q "refusing to treat this as an empty crontab" "$ERRFILE"
}

@test "p4: install feeds 'crontab -' exactly the rendered payload and nothing else" {
  install_crontab_shim
  printf '0\n' >"$SHIM_DIR/exit"
  python3 "$SCRIPT" render --units-dir "$BASIC" >"$BATS_TEST_TMPDIR/expected-payload"

  hb install --approve --units-dir "$BASIC"
  [ "$status" -eq 0 ]

  [ -f "$SHIM_DIR/stdin" ]
  run diff "$BATS_TEST_TMPDIR/expected-payload" "$SHIM_DIR/stdin"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "p5: no crontab binary on PATH is a clean error, not a traceback" {
  # PATH is narrowed to just the interpreter and the shell the runner needs, so
  # the absence is deterministic rather than depending on the host having cron.
  mkdir -p "$BATS_TEST_TMPDIR/minimal-bin"
  ln -sf "$(command -v python3)" "$BATS_TEST_TMPDIR/minimal-bin/python3"
  ln -sf "$(command -v bash)" "$BATS_TEST_TMPDIR/minimal-bin/bash"
  unset HEARTBEATS_CRONTAB_FILE

  local saved_path="$PATH"
  export PATH="$BATS_TEST_TMPDIR/minimal-bin"
  hb drift-check --units-dir "$BASIC"
  export PATH="$saved_path"

  [ "$status" -eq 1 ]
  [ -z "$output" ]
  grep -q "cannot run" "$ERRFILE"
  ! grep -q "Traceback" "$ERRFILE"
}

# --- (q) bytes that must be refused, never re-encoded ------------------------

@test "q1: a crontab that is not valid UTF-8 is refused and left byte-identical" {
  python3 - "$CRONTAB" <<'PY'
import sys

open(sys.argv[1], "wb").write(b"unmanaged-user-job-line\n\xff\xfe\n")
PY
  cp "$CRONTAB" "$BATS_TEST_TMPDIR/crontab.before"

  # A lossy decode would "succeed" here and then write the replacement
  # characters back over the user's bytes.
  hb install --approve --units-dir "$BASIC" --crontab-file "$CRONTAB"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  grep -q "not valid UTF-8" "$ERRFILE"
  ! grep -q "Traceback" "$ERRFILE"
  [ "$(wc -l <"$ERRFILE")" -eq 1 ]

  run diff "$BATS_TEST_TMPDIR/crontab.before" "$CRONTAB"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "q2: a unit file that is not valid UTF-8 is a named error, not a traceback" {
  mkdir -p "$BATS_TEST_TMPDIR/units-binary"
  python3 - "$BATS_TEST_TMPDIR/units-binary/binary-unit.md" <<'PY'
import sys

open(sys.argv[1], "wb").write(
    b"---\n"
    b"name: example-binary-unit\n"
    b"cron: 0 5 * * *\n"
    b"command: /usr/local/bin/example-job\n"
    b"log: /var/log/example/binary-unit.log\xff\xfe\n"
    b"enabled: true\n"
    b"---\n"
)
PY

  assert_rejects "$BATS_TEST_TMPDIR/units-binary" binary-unit.md
  grep -q "cannot read" "$ERRFILE"
}

@test "q3: a CR inside a field value cannot smuggle in a field the unit never declares" {
  # The file declares no `enabled` line of its own -- the CR is what would make
  # one appear, if the reader translated it to a newline before checking.
  mkdir -p "$BATS_TEST_TMPDIR/units-cr"
  python3 - "$BATS_TEST_TMPDIR/units-cr/cr-smuggle.md" <<'PY'
import sys

open(sys.argv[1], "wb").write(
    b"---\n"
    b"name: example-cr-smuggle-unit\n"
    b"cron: 0 5 * * *\n"
    b"command: /usr/local/bin/example-job\n"
    b"log: /var/log/example/cr-smuggle.log\renabled: true\n"
    b"---\n"
)
PY

  assert_rejects "$BATS_TEST_TMPDIR/units-cr" cr-smuggle.md
  grep -q "U+000D" "$ERRFILE"
}

# --- (r) the managed block inside a CRLF crontab -----------------------------

@test "r1: a CRLF crontab already holding the block gets it updated, never duplicated" {
  {
    printf 'crlf-user-line\n'
    python3 "$SCRIPT" render --units-dir "$BASIC"
  } | to_crlf >"$CRONTAB"

  # If marker matching were CR-blind, the block would be invisible and each
  # install would append another copy.
  hb install --approve --units-dir "$BASIC" --crontab-file "$CRONTAB"
  [ "$status" -eq 0 ]
  hb install --approve --units-dir "$BASIC" --crontab-file "$CRONTAB"
  [ "$status" -eq 0 ]

  [ "$(grep -c 'heartbeats:begin' "$CRONTAB")" -eq 1 ]
  [ "$(grep -c 'heartbeats:end' "$CRONTAB")" -eq 1 ]
  grep -q 'crlf-user-line' "$CRONTAB"

  hb drift-check --units-dir "$BASIC" --crontab-file "$CRONTAB"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "r2: a CR-bearing orphan BEGIN marker is refused, leaving the crontab byte-identical" {
  {
    printf 'unmanaged-user-job-line\n'
    python3 "$SCRIPT" render --units-dir "$BASIC" | head -n 1
  } | to_crlf >"$CRONTAB"
  cp "$CRONTAB" "$BATS_TEST_TMPDIR/crontab.before"

  hb install --approve --units-dir "$BASIC" --crontab-file "$CRONTAB"
  [ "$status" -eq 1 ]
  grep -q "malformed managed block" "$ERRFILE"

  run diff "$BATS_TEST_TMPDIR/crontab.before" "$CRONTAB"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- (t) the remaining malformed-marker branches -----------------------------

@test "t1: install refuses an END marker with no BEGIN, leaving the crontab byte-identical" {
  {
    printf 'unmanaged-user-job-line\n'
    python3 "$SCRIPT" render --units-dir "$BASIC" | tail -n 1
  } >"$CRONTAB"
  cp "$CRONTAB" "$BATS_TEST_TMPDIR/crontab.before"

  hb install --approve --units-dir "$BASIC" --crontab-file "$CRONTAB"
  [ "$status" -eq 1 ]
  grep -q "END marker" "$ERRFILE"
  grep -q "no.*BEGIN marker" "$ERRFILE"

  run diff "$BATS_TEST_TMPDIR/crontab.before" "$CRONTAB"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "t2: install refuses an END marker that precedes its BEGIN, leaving the crontab byte-identical" {
  python3 "$SCRIPT" render --units-dir "$BASIC" >"$BATS_TEST_TMPDIR/rendered"
  {
    tail -n 1 "$BATS_TEST_TMPDIR/rendered"
    printf 'unmanaged-user-job-line\n'
    head -n 1 "$BATS_TEST_TMPDIR/rendered"
  } >"$CRONTAB"
  cp "$CRONTAB" "$BATS_TEST_TMPDIR/crontab.before"

  hb install --approve --units-dir "$BASIC" --crontab-file "$CRONTAB"
  [ "$status" -eq 1 ]
  grep -q "precedes the" "$ERRFILE"

  run diff "$BATS_TEST_TMPDIR/crontab.before" "$CRONTAB"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- (x) configuration resolution -------------------------------------------

@test "x1: the crontab path can come from HEARTBEATS_CRONTAB_FILE instead of the flag" {
  seed_crontab_with_block
  export HEARTBEATS_CRONTAB_FILE="$CRONTAB"

  hb drift-check --units-dir "$BASIC"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "x2: CODEX_ROOT relocates the default units directory" {
  mkdir -p "$BATS_TEST_TMPDIR/codex-root/heartbeats/units"
  cp "$FIXTURES/units-alt/gamma-only.md" "$BATS_TEST_TMPDIR/codex-root/heartbeats/units/"
  export CODEX_ROOT="$BATS_TEST_TMPDIR/codex-root"

  hb render
  [ "$status" -eq 0 ]
  [[ "$output" == *"example-hourly-probe"* ]]
}

@test "x3: with no flag and no CODEX_ROOT, the units directory falls back under the home dir" {
  mkdir -p "$BATS_TEST_TMPDIR/fake-home/.claude/heartbeats/units"
  cp "$FIXTURES/units-alt/gamma-only.md" "$BATS_TEST_TMPDIR/fake-home/.claude/heartbeats/units/"
  export HOME="$BATS_TEST_TMPDIR/fake-home"

  hb render
  [ "$status" -eq 0 ]
  [[ "$output" == *"example-hourly-probe"* ]]
}

# --- (y) the remaining drift branches ---------------------------------------

@test "y1: drift-check reports a line inside the block that belongs to no unit" {
  python3 "$SCRIPT" render --units-dir "$BASIC" >"$CRONTAB"
  sed -i '1a # a hand-added comment inside the managed block' "$CRONTAB"

  hb drift-check --units-dir "$BASIC" --crontab-file "$CRONTAB"
  [ "$status" -eq 3 ]
  [[ "$output" == *"unattributed"* ]]
}

@test "y2: drift-check reports the same units in a different order as drift" {
  python3 "$SCRIPT" render --units-dir "$BASIC" >"$CRONTAB"
  python3 - "$CRONTAB" <<'PY'
import sys

path = sys.argv[1]
lines = open(path, encoding="utf-8").read().split("\n")
if lines and lines[-1] == "":
    lines.pop()
begin, end, body = lines[0], lines[-1], lines[1:-1]

groups = []
for line in body:
    if line.startswith("# heartbeats-unit: "):
        groups.append([line])
    else:
        groups[-1].append(line)
groups.reverse()

reordered = [begin] + [line for group in groups for line in group] + [end]
open(path, "w", encoding="utf-8").write("\n".join(reordered) + "\n")
PY

  hb drift-check --units-dir "$BASIC" --crontab-file "$CRONTAB"
  [ "$status" -eq 3 ]
  [[ "$output" == *"ordering"* ]]
}

# --- (z) headers that cannot be attributed to a unit -------------------------

@test "z1: drift-check reports a unit header inside the block that carries no name" {
  python3 "$SCRIPT" render --units-dir "$BASIC" >"$CRONTAB"
  sed -i 's|^# heartbeats-unit: example-daily-report$|# heartbeats-unit: |' "$CRONTAB"

  hb drift-check --units-dir "$BASIC" --crontab-file "$CRONTAB"
  [ "$status" -eq 3 ]
  [[ "$output" == *"carries no unit name"* ]]
}

@test "z2: drift-check reports two headers for one unit rather than merging them" {
  python3 "$SCRIPT" render --units-dir "$BASIC" >"$CRONTAB"
  # Line 1 is the BEGIN marker, line 2 the first unit's header.
  sed -i '2a # heartbeats-unit: example-daily-report' "$CRONTAB"

  hb drift-check --units-dir "$BASIC" --crontab-file "$CRONTAB"
  [ "$status" -eq 3 ]
  [[ "$output" == *"more than one header"* ]]
}
