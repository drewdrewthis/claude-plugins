# Coverage map for claude-plugins#245 — gitleaks older than 8.22.0 reads a lone
# dash as the report path as a file name: it writes the raw findings to a file
# named "-" in the working directory and prints nothing, which the hook read as
# "no findings". The library asks for /dev/stdout on Linux and for the dash
# elsewhere (macOS gives no report on /dev/stdout), and guards each path. Not
# executable: each Scenario carries a "# proves:" comment naming the bats test
# that proves it, or the terminal evidence / grep that proves it where the suite
# cannot.

Feature: Old gitleaks versions redact, and leave no report file behind
  The report path is /dev/stdout on Linux and a lone dash on other systems.
  On Linux, before the call, the redact library checks /dev/stdout without
  following it: absent or a regular file means the scan fails and gitleaks is
  not run. Elsewhere it refuses a symbolic link named "-" in the working
  directory, and after the call a "-" that gitleaks created or changed means the
  scan fails and the file is removed. With 8.21.2 a Linux turn is redacted; a
  turn on any other system is loud (gitleaks-failed, unjudged row, no model
  call). 8.19.1 and later on Linux give the findings on stdout and no file;
  8.19.0 and older exit 1, recorded as gitleaks-failed.

  # AC1
  # proves: hooks/tests/worklog-record.bats "gitleaks 8.21.2 stores the pulumi marker in the worklog on Linux"
  # proves: hooks/tests/worklog-record.bats "gitleaks 8.21.2 keeps the raw pulumi token out of the worklog"
  # proves: hooks/tests/worklog-record.bats "gitleaks 8.21.2 keeps the raw pulumi token out of the stdin the model receives"
  # proves: hooks/tests/worklog-record.bats "gitleaks 8.21.2 on a secret turn logs gitleaks-failed once off Linux and never on Linux"
  # proves: hooks/tests/worklog-record.bats "gitleaks 8.21.2 on a secret turn stores one row"
  # proves: hooks/tests/worklog-record.bats "gitleaks 8.21.2 on a secret turn judges the row on Linux and leaves it unjudged elsewhere"
  # proves: hooks/tests/worklog-record.bats "gitleaks 8.21.2 on a secret turn calls the model on Linux and never elsewhere"
  Scenario: A secret turn on gitleaks 8.21.2 never leaks the token, on either system
    Given gitleaks 8.21.2 is first on PATH and the hook runs in a fresh empty directory
    And a fake Pulumi token is in the prompt and in the model reply text
    When the hook records the turn
    Then the worklog and the stdin the model receives hold the token 0 times
    And on Linux the worklog holds the pulumi-api-token marker, no gitleaks-failed note is logged and the row is judged
    And on other systems one gitleaks-failed note is logged, the row is unjudged and the model is called 0 times

  # AC2
  # proves: hooks/tests/worklog-record.bats "gitleaks 8.21.2 on a secret turn leaves the working directory empty"
  # proves: hooks/tests/worklog-record.bats "gitleaks 8.21.2 on a clean turn leaves the working directory empty"
  Scenario: No report file is left in the working directory
    Given gitleaks 8.21.2 is first on PATH and the hook runs in a fresh empty directory
    When the hook records a turn with a secret, and a turn with no secret
    Then after each run the directory is still empty

  # AC2b
  # proves: hooks/tests/worklog-record.bats "gitleaks 8.21.2 on a clean turn stores one row"
  # proves: hooks/tests/worklog-record.bats "gitleaks 8.21.2 on a clean turn judges the row on Linux and leaves it unjudged elsewhere"
  # proves: hooks/tests/worklog-record.bats "gitleaks 8.21.2 on a clean turn logs gitleaks-failed once off Linux and never on Linux"
  # proves: hooks/tests/worklog-record.bats "gitleaks 8.21.2 on a clean turn calls the model on Linux and never elsewhere"
  Scenario: A clean turn on gitleaks 8.21.2 is quiet on Linux and loud elsewhere
    Given gitleaks 8.21.2 is first on PATH
    When the hook records a turn with no secret
    Then exactly one row is stored
    And on Linux the row is judged, no gitleaks-failed note is logged and the model is called
    And on other systems the row is unjudged, one gitleaks-failed note is logged and the model is called 0 times

  # AC3 and AC-matrix: terminal evidence, quoted in the PR
  # proves: terminal loop of the real hook over 8.18.4 8.19.0 8.19.1 8.19.2 8.19.3 8.20.0 8.21.0 8.21.1 8.21.2 8.22.0 8.30.1
  Scenario: Versions 8.19.0 and older are loud, 8.19.1 and later redact
    Given a real binary of each listed version first on PATH, each run in a fresh empty directory
    When the real hook records a turn with a fake token
    Then 8.19.0 and older give one gitleaks-failed line and an unjudged row
    And every version leaves the token 0 times in the worklog and the directory empty

  # AC4c
  # proves: hooks/tests/worklog-record.bats "gitleaks is invoked with the stdin report flags"
  Scenario: The call shape names the platform report path
    Given the gitleaks stub logs its arguments
    When the hook scans a turn
    Then the logged arguments hold --report-path /dev/stdout on Linux and --report-path - elsewhere

  # AC4 a, b, d: CI log lines and one terminal comparison, quoted in the PR
  # proves: CI log of "the real gitleaks redacts a pulumi token from prompt to stored row" on both legs, the fuzz run result line, and the fuzz corpus diff at seed 1
  Scenario: Nothing changes on gitleaks 8.30.1
    Given gitleaks 8.30.1 on both CI legs
    When the suite and the differential fuzz run
    Then the real-binary test reads ok, not skip, and the redacted fuzz output is byte-identical to main

  # AC5: grep evidence
  # proves: git log -1 --format=%H origin/main -- plugins/worklog/hooks/lib/redact.py equals PINNED_SHA and the split string in the pin test
  Scenario: The fuzz pin moves in both places
    Given the redact library changed on main
    When the PR is marked ready
    Then both pins hold the newest main commit that changed the library
    And git grep for the old pin prints nothing outside the changelogs

  # AC6
  # proves: hooks/tests/worklog-record.bats "the old binary under test reports version 8.21.2"
  # proves: CI log line ok for that test on both legs, and a local run with CI=1 and WORKLOG_TEST_OLD_GITLEAKS unset reading not ok
  Scenario: CI provides the old binary or fails
    Given CI is set
    When WORKLOG_TEST_OLD_GITLEAKS is unset or names no executable file
    Then the old-binary tests fail instead of skipping
    And with CI unset they skip with "old gitleaks binary not provided"

  # AC7: documentation, proven by running the documented commands
  # proves: README text greps and the documented find and git log commands run in a fresh temp directory
  Scenario: The README states the minimum version and how to find old report files
    Given the README line for worklog-record
    Then it states minimum gitleaks 8.19.1 and lists only the matrix versions as tested
    And it gives a find command and a git history command that print paths only

  # AC9
  # proves: hooks/tests/worklog-record.bats "a report path that is absent makes the scan report failure"
  # proves: hooks/tests/worklog-record.bats "a report path that is absent never runs gitleaks"
  Scenario: An absent report path fails the scan without running gitleaks
    Given the report path (a non-dash path set by the test) does not exist
    When a scan is asked for on text with a fake token
    Then the scan reports failure and gitleaks is called 0 times

  # proves: hooks/tests/worklog-record.bats "a report path that is a regular file makes the scan report failure"
  # proves: hooks/tests/worklog-record.bats "a report path that is a regular file never runs gitleaks"
  # proves: hooks/tests/worklog-record.bats "a report path that is a regular file keeps its bytes"
  Scenario: A regular file as report path fails the scan and is left unchanged
    Given the report path (a non-dash path set by the test) is a regular file with known bytes
    When a scan is asked for on text with a fake token
    Then the scan reports failure, gitleaks is called 0 times and the bytes are unchanged

  # proves: hooks/tests/worklog-record.bats "the real /dev/stdout with the caller's stdout closed still returns the finding"
  Scenario: A closed stdout of the caller does not trip the guard
    Given the platform default report path and a calling process whose stdout is closed
    When a scan is asked for on text with a fake token
    Then the finding is returned

  # AC9 namespace run: terminal evidence, quoted in the PR
  # proves: terminal run in a private namespace with an empty writable /dev and real 8.21.2 shows gitleaks-failed and no file in /dev
  Scenario: A system without /dev/stdout is loud
    Given a private namespace with an empty writable /dev
    When the real hook records a turn on real 8.21.2
    Then one gitleaks-failed line is logged and /dev holds no file

  # AC8 withdrawn: the dash is the report path on non-Linux systems, so a grep
  # for it proves nothing. Every test helper that runs the real gitleaks still
  # pipes its stdout and takes its report path from gl_report_path.

  # AC10 (report path forced to the dash from python, run in a fresh empty directory, on both systems)
  # proves: hooks/tests/worklog-record.bats "with the dash report path the old binary's file report makes the scan report failure"
  # proves: hooks/tests/worklog-record.bats "with the dash report path the old binary leaves no entry named dash behind"
  Scenario: A report written to a file named dash fails the scan and is removed
    Given the report path is the dash and gitleaks 8.21.2 is first on PATH
    When a scan is asked for on text with a fake token
    Then the scan reports failure and no entry named "-" remains

  # proves: hooks/tests/worklog-record.bats "with the dash report path a pre-existing dash file is no failure when the binary reports on stdout"
  # proves: hooks/tests/worklog-record.bats "with the dash report path a pre-existing dash file keeps its bytes when the binary reports on stdout"
  Scenario: A file named dash that gitleaks does not touch is left alone
    Given the report path is the dash, gitleaks 8.30.1 is first on PATH and "-" is a regular file with known bytes
    When a scan is asked for on text with a fake token
    Then the finding is returned, the scan is not failed and the bytes are unchanged

  # proves: hooks/tests/worklog-record.bats "with the dash report path a symbolic link named dash makes the scan report failure"
  # proves: hooks/tests/worklog-record.bats "with the dash report path a symbolic link named dash never runs gitleaks"
  # proves: hooks/tests/worklog-record.bats "with the dash report path a symbolic link named dash leaves its target bytes"
  # proves: hooks/tests/worklog-record.bats "with the dash report path a symbolic link named dash stays a symbolic link"
  Scenario: A symbolic link named dash fails the scan without running gitleaks
    Given the report path is the dash and "-" is a symbolic link to a file with known bytes
    When a scan is asked for on text with a fake token
    Then the scan reports failure, gitleaks is called 0 times, the target keeps its bytes and the link still exists

  # proves: hooks/tests/worklog-record.bats "with the dash report path a pre-existing dash file and the old binary make the scan report failure"
  # proves: hooks/tests/worklog-record.bats "with the dash report path a pre-existing dash file and the old binary leave no entry named dash"
  Scenario: A file named dash that gitleaks overwrites fails the scan and is removed
    Given the report path is the dash, gitleaks 8.21.2 is first on PATH and "-" is a regular file with known bytes
    When a scan is asked for on text with a fake token
    Then the scan reports failure and no entry named "-" remains
