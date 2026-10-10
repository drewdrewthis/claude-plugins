# Coverage map for claude-plugins#166 — the librarian drain's pressure gate
# deferred only strictly over its ceilings, checked once at spawn, and the
# batch's corpus scan (the part that stormed the box) ran unguarded at normal
# priority. Not executable: each Scenario carries a "# proves:" comment naming
# the bats test(s) or command that prove it. Paths are under plugins/procedures/.
#
# Terms. Worker run = `bash hooks/librarian-poke.sh --worker` with a stub
# `claude` on PATH, LIBRARIAN_LOAD_CEILING=8, LIBRARIAN_IOWAIT_CEILING=30,
# LIBRARIAN_MIN_INTERVAL_SECS=0 and LIBRARIAN_NO_FLOCK=1 unless stated; pressure
# comes from fixture files through LP_LOADAVG_FILE / LP_STAT_FILE /
# LP_STAT_SAMPLE_SLEEP. Calm = load 1.00, iowait 9%. Sample counter = a file the
# LP_STAT_SAMPLE_SLEEP command appends a line to, once per pressure check that
# reaches the iowait sample.

Feature: The librarian drain yields to a busy box, at spawn and while it scans
  The hook defers at or over a ceiling, not only above it. The batch script
  re-checks pressure as it walks the transcript corpus and aborts the whole
  batch (reserved exit 75, no manifest) when the box is busy. The hook treats
  that as a defer: no claude, no cursor move, one log line, and the cooldown
  stamp so the scan is not repeated every turn. The batch runs at idle priority.

  # proves: hooks/tests/librarian-poke.bats "spawn gate: load equal to the ceiling defers — claude never runs, exit 0", "spawn gate: load equal to the ceiling logs exactly one '>=' defer line", "spawn gate: load far over the ceiling logs the '>=' defer line", "spawn gate: a spawn-check defer writes no last-drain-start", and the updated "load gate: over the load ceiling defers — claude never runs, defer logged"
  @integration
  Scenario: Load at or over the ceiling defers at spawn
    Given a transcript with unread lines and ceiling 8
    When a worker run sees load 8.00, or load 50.00, with iowait 9%
    Then claude is not started and the exit code is 0
    And the log has exactly one line containing "deferred, load=8.00 >= ceiling=8" (or "load=50.00")
    And no last-drain-start is written

  # proves: hooks/tests/librarian-poke.bats "spawn gate: iowait equal to the ceiling defers — claude never runs, exit 0", "spawn gate: iowait equal to the ceiling logs exactly one '>=' defer line", and the updated "load gate: over the iowait ceiling (two fixtures swapped between samples) defers — claude never runs, defer logged"
  @integration
  Scenario: Iowait at the ceiling defers at spawn
    Given a transcript with unread lines and an iowait ceiling of 30%
    When a worker run sees load 1.00 and iowait exactly 30 (delta 30 of 100)
    Then claude is not started and the exit code is 0
    And the log has exactly one line containing "deferred, iowait=30% >= ceiling=30%"

  # proves: hooks/tests/librarian-poke.bats "spawn gate: just under both ceilings drains — claude runs once", "spawn gate: just under both ceilings advances the transcript cursor to its line count"
  @integration
  Scenario: Just under both ceilings still drains
    Given one unread transcript
    When a worker run sees load 7.99 and iowait 29%
    Then claude is started exactly once
    And the transcript's cursor file holds its line count

  # proves: hooks/tests/librarian-poke.bats "mid-batch defer on load: ..." (6 tests), "mid-batch defer on iowait: ...", "mid-batch defer at re-check 2: ...", plus the contract tests "load-ok mode: load at the ceiling exits 75 ...", "load-ok mode: iowait at the ceiling exits 75 ...", "load-ok mode: calm pressure exits 0"
  @integration
  Scenario: Pressure that rises during the batch defers the drain
    Given LIBRARIAN_RECHECK_SECS=0 and two transcripts with unread lines
    And pressure is calm at the spawn check
    When the first re-check sees load 8.00, or iowait 30%, or re-check 2 sees load 8.00
    Then claude is not started and the exit code is 0
    And no batch.manifest, batch.manifest.tmp or batch.txt.part exists
    And no cursor file exists and the claim dir librarian.lock.d is gone
    And the log has one "deferred, ... >= ceiling" line and one "batch deferred" line
    And the log has no "batch failed" line

  # proves: hooks/tests/librarian-poke.bats "after a mid-batch defer, the next calm drain issues one range per transcript from 0", "after a mid-batch defer, the next calm drain advances both cursors to their line counts"
  @integration
  Scenario: A deferred drain loses nothing
    Given a drain that was deferred mid-batch
    When a second worker run is calm throughout
    Then claude is started once
    And batch.manifest has one range per transcript, each starting at 0
    And both cursor files hold their transcript's line count

  # proves: hooks/tests/librarian-poke.bats "a mid-batch defer writes last-drain-start", "after a mid-batch defer, the next drain inside the cooldown runs no re-check scan", "after a mid-batch defer, the next drain inside the cooldown logs one cooldown defer"; the spawn-check half is "spawn gate: a spawn-check defer writes no last-drain-start"
  @integration
  Scenario: A mid-batch defer backs off
    Given a drain that was deferred mid-batch
    When a second worker run starts with LIBRARIAN_MIN_INTERVAL_SECS=1800 and calm pressure
    Then claude is not started
    And the sample counter holds exactly 1 line, so the scan did not run
    And the log gains exactly one "deferred, cooldown" line

  # proves: hooks/tests/librarian-poke.bats "running drain: claude finishes and is never signalled when pressure rises mid-run", "running drain: cursors still advance when pressure rises mid-run", "running drain: no defer line is logged when pressure rises mid-run"
  @integration
  Scenario: A running drain is never signalled by the gate
    Given a stub claude that traps TERM and INT, raises the load fixture to 50.00 and runs for 2 seconds
    When a worker run is calm until claude starts
    Then the stub's finished marker exists and its signalled marker does not
    And the cursors hold the transcript line counts
    And the log has no "deferred" line

  # proves: hooks/tests/librarian-poke.bats "load-ok mode: both pressure files absent exits 0", "load-ok mode: both pressure files absent adds no log line", "fail-open drain: with re-checks on and no pressure files, ..." (3 tests); hooks/tests/librarian-batch.bats "hook as the check with both pressure files absent: re-checks run per file and both ranges are issued"
  @integration
  Scenario: Unreadable pressure during a re-check fails open, quietly
    Given both pressure files are absent
    When the hook runs with --load-ok, or a worker run has LIBRARIAN_RECHECK_SECS=0 and two unread transcripts
    Then --load-ok exits 0 and adds no log line
    And both ranges are in batch.manifest and claude is started once
    And the log has exactly one "fail-open, loadavg unreadable" and one "fail-open, iowait unreadable" line
    And the batch, given a recording wrapper around --load-ok, calls it twice and issues both ranges

  # proves: hooks/tests/librarian-poke.bats "re-check timing: with a long interval only the spawn check samples", "re-check timing: with interval 0 the spawn check and one re-check per corpus file sample"; hooks/tests/librarian-batch.bats "the check also runs for fully-read transcripts, not only unread ones", "a long interval: the check never runs in a fast batch"
  @integration
  Scenario: The re-check is time-triggered, not per file
    Given a corpus of 20 fully-read transcripts and 3 unread ones, all under the batch byte budget
    When a worker run is calm with LIBRARIAN_RECHECK_SECS=3600
    Then the sample counter has exactly 1 line
    And with LIBRARIAN_RECHECK_SECS=0 it has exactly 24 lines

  # proves: hooks/tests/librarian-batch.bats "no --pressure-check: the batch ignores pressure and issues both ranges"
  @integration
  Scenario: The batch script alone is not gated
    Given fixture load 50.00 and two unread transcripts
    When librarian-batch.sh runs with no --pressure-check
    Then it exits 0
    And both ranges are in batch.manifest

  # proves: hooks/tests/librarian-batch.bats "check exits 75: ..." (4 tests), "check exits 1: ...", "check exits 127: ...", "check path missing: ...", "check that drains stdin and exits 0: ...", "interval 0: the check is invoked as '--load-ok'"
  @integration
  Scenario: Only exit 75 from the check is a defer
    Given LIBRARIAN_RECHECK_SECS=0 and two unread transcripts
    When the check exits 75
    Then the batch exits 75, prints "librarian-batch: deferred" and leaves no manifest
    When the check exits 1, exits 127, or its path does not exist
    Then the batch exits 0 with both ranges in batch.manifest
    When the check reads all of stdin and exits 0
    Then both ranges are still in batch.manifest

  # proves: hooks/tests/librarian-poke.bats "failed batch: logs exactly one 'batch failed, drain skipped' line", "failed batch: logs no defer line", "failed batch: writes no last-drain-start"
  @integration
  Scenario: A failed batch is still a failure
    Given LIBRARIAN_BATCH_BYTES=nope
    When a worker run drains
    Then the log has exactly one "batch failed, drain skipped" line and no "deferred" line
    And no last-drain-start exists

  # proves: hooks/tests/librarian-poke.bats "idle priority: ionice -c3 wraps librarian-batch.sh exactly once", "idle priority: nice -n19 wraps librarian-batch.sh exactly once"
  @integration
  Scenario: The batch runs at idle priority
    Given ionice and nice shims first on PATH that record their arguments and then exec the command
    When a worker run drains
    Then the ionice record has exactly one line containing "-c3" and "librarian-batch.sh"
    And the nice record has exactly one line containing "-n19" and "librarian-batch.sh"

  # proves: command `grep -nF "> ceiling" hooks/librarian-poke.sh` (no output); `grep -c "at or over" hooks/librarian-poke.sh` (3 or more); `grep -n "pressure-check" scripts/librarian-batch.sh` (a header line naming exit code 75); `grep -n LIBRARIAN_RECHECK_SECS hooks/librarian-poke.sh scripts/librarian-batch.sh` (a line with "default 5"); `grep -n 'ceiling of 0' hooks/librarian-poke.sh` (at least 1 line); quoted in the PR body
  @unit
  Scenario: Docs match behaviour
    Given the finished hook and batch script
    When the five grep checks run
    Then none returns a result that contradicts the behaviour above

  # proves: hooks/tests/librarian-poke.bats "bad re-check interval: a non-numeric value still drains once and advances both cursors", "bad re-check interval: an empty value still drains once and advances both cursors", "bad re-check interval: neither value is logged as a batch failure"; hooks/tests/librarian-batch.bats "a non-numeric interval falls back to 5s: ...", "an empty interval falls back to 5s: ..."
  @integration
  Scenario: A bad re-check interval cannot stop the drain
    Given two unread transcripts and calm pressure
    When LIBRARIAN_RECHECK_SECS is "nope", and again when it is empty
    Then claude is started once and both cursor files hold their line counts
    And the log has no "batch failed" line

  # proves: command `gh pr view --json title,files` on the PR: the title starts with "fix(procedures):" and the files include neither plugins/procedures/.claude-plugin/plugin.json nor .release-please-manifest.json
  @unit
  Scenario: The version bump is automated
    Given the pull request for this change
    When its title and changed files are read
    Then the title starts with "fix(procedures):"
    And release-please owns plugin.json and the manifest

  # --- AC Coverage Map ---
  # AC 1  Load at or over the ceiling defers at spawn ........ Scenario "Load at or over the ceiling defers at spawn"
  # AC 2  Iowait at the ceiling defers at spawn .............. Scenario "Iowait at the ceiling defers at spawn"
  # AC 3  Just under both ceilings still drains .............. Scenario "Just under both ceilings still drains"
  # AC 4  Pressure rising during the batch defers the drain .. Scenario "Pressure that rises during the batch defers the drain"
  # AC 5  A deferred drain loses nothing ..................... Scenario "A deferred drain loses nothing"
  # AC 6  A mid-batch defer backs off ........................ Scenario "A mid-batch defer backs off"
  # AC 7  A running drain is never signalled ................. Scenario "A running drain is never signalled by the gate"
  # AC 8  Unreadable pressure fails open, quietly ............ Scenario "Unreadable pressure during a re-check fails open, quietly"
  # AC 9  Re-check is time-triggered, not per file ........... Scenario "The re-check is time-triggered, not per file"
  # AC 10 The batch script alone is not gated ................ Scenario "The batch script alone is not gated"
  # AC 11 Only exit 75 from the check is a defer ............. Scenario "Only exit 75 from the check is a defer"
  # AC 12 A failed batch is still a failure .................. Scenario "A failed batch is still a failure"
  # AC 13 The batch runs at idle priority .................... Scenario "The batch runs at idle priority"
  # AC 14 Docs match behaviour ............................... Scenario "Docs match behaviour"
  # AC 15 A bad re-check interval cannot stop the drain ...... Scenario "A bad re-check interval cannot stop the drain"
  # AC 16 The version bump is automated ...................... Scenario "The version bump is automated"
