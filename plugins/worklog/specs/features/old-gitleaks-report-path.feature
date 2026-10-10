# Coverage map for claude-plugins#245 — gitleaks older than 8.22.0 reads a lone
# dash as the report path as a file name: it writes the raw findings to a file
# named "-" in the working directory and prints nothing, which the hook read as
# "no findings". The hook asks for /dev/stdout instead. Not executable: each
# Scenario carries a "# proves:" comment naming the bats test that proves it, or
# the terminal evidence / grep that proves it where the suite cannot.

Feature: Old gitleaks versions redact, and leave no report file behind
  The hook runs gitleaks with --report-path /dev/stdout. On 8.19.1 and later
  that gives the findings on stdout and creates no file. On 8.19.0 and older
  gitleaks exits 1, which the hook records as gitleaks-failed. Before the call
  the redact library checks the report path without following it: absent or a
  regular file means the scan fails and gitleaks is not run.

  # AC1
  # proves: hooks/tests/worklog-record.bats "gitleaks 8.21.2 stores the pulumi marker in the worklog"
  # proves: hooks/tests/worklog-record.bats "gitleaks 8.21.2 keeps the raw pulumi token out of the worklog"
  # proves: hooks/tests/worklog-record.bats "gitleaks 8.21.2 keeps the raw pulumi token out of the stdin the model receives"
  # proves: hooks/tests/worklog-record.bats "gitleaks 8.21.2 on a secret turn logs no gitleaks-failed"
  # proves: hooks/tests/worklog-record.bats "gitleaks 8.21.2 on a secret turn stores a judged row"
  Scenario: A secret turn on gitleaks 8.21.2 is redacted in the prompt and in the model reply
    Given gitleaks 8.21.2 is first on PATH and the hook runs in a fresh empty directory
    And a fake Pulumi token is in the prompt and in the model reply text
    When the hook records the turn
    Then the worklog holds the pulumi-api-token marker and the token 0 times
    And the stdin the model receives holds the token 0 times
    And no gitleaks-failed note is logged and the row is judged

  # AC2
  # proves: hooks/tests/worklog-record.bats "gitleaks 8.21.2 on a secret turn leaves the working directory empty"
  # proves: hooks/tests/worklog-record.bats "gitleaks 8.21.2 on a clean turn leaves the working directory empty"
  Scenario: No report file is left in the working directory
    Given gitleaks 8.21.2 is first on PATH and the hook runs in a fresh empty directory
    When the hook records a turn with a secret, and a turn with no secret
    Then after each run the directory is still empty

  # AC2b
  # proves: hooks/tests/worklog-record.bats "gitleaks 8.21.2 on a clean turn stores a judged row"
  # proves: hooks/tests/worklog-record.bats "gitleaks 8.21.2 on a clean turn logs no gitleaks-failed"
  Scenario: A clean turn on gitleaks 8.21.2 stays quiet
    Given gitleaks 8.21.2 is first on PATH
    When the hook records a turn with no secret
    Then the row is judged and no gitleaks-failed note is logged

  # AC3 and AC-matrix: terminal evidence, quoted in the PR
  # proves: terminal loop of the real hook over 8.18.4 8.19.0 8.19.1 8.19.2 8.19.3 8.20.0 8.21.0 8.21.1 8.21.2 8.22.0 8.30.1
  Scenario: Versions 8.19.0 and older are loud, 8.19.1 and later redact
    Given a real binary of each listed version first on PATH, each run in a fresh empty directory
    When the real hook records a turn with a fake token
    Then 8.19.0 and older give one gitleaks-failed line and an unjudged row
    And every version leaves the token 0 times in the worklog and the directory empty

  # AC4c
  # proves: hooks/tests/worklog-record.bats "gitleaks is invoked with the stdin report flags"
  Scenario: The call shape names /dev/stdout as the report path
    Given the gitleaks stub logs its arguments
    When the hook scans a turn
    Then the logged arguments hold --report-path /dev/stdout

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
    Given the report path the library uses does not exist
    When a scan is asked for on text with a fake token
    Then the scan reports failure and gitleaks is called 0 times

  # proves: hooks/tests/worklog-record.bats "a report path that is a regular file makes the scan report failure"
  # proves: hooks/tests/worklog-record.bats "a report path that is a regular file never runs gitleaks"
  # proves: hooks/tests/worklog-record.bats "a report path that is a regular file keeps its bytes"
  Scenario: A regular file as report path fails the scan and is left unchanged
    Given the report path the library uses is a regular file with known bytes
    When a scan is asked for on text with a fake token
    Then the scan reports failure, gitleaks is called 0 times and the bytes are unchanged

  # proves: hooks/tests/worklog-record.bats "the real /dev/stdout with the caller's stdout closed still returns the finding"
  Scenario: A closed stdout of the caller does not trip the guard
    Given the real /dev/stdout and a calling process whose stdout is closed
    When a scan is asked for on text with a fake token
    Then the finding is returned

  # AC9 namespace run: terminal evidence, quoted in the PR
  # proves: terminal run in a private namespace with an empty writable /dev and real 8.21.2 shows gitleaks-failed and no file in /dev
  Scenario: A system without /dev/stdout is loud
    Given a private namespace with an empty writable /dev
    When the real hook records a turn on real 8.21.2
    Then one gitleaks-failed line is logged and /dev holds no file

  # AC8
  # proves: hooks/tests/worklog-record.bats "no call site under plugins/worklog passes the dash report path as an argv string"
  # proves: hooks/tests/worklog-record.bats "no call site under plugins/worklog passes the dash report path as a python list"
  Scenario: No call site keeps the dash report path
    Given the plugins/worklog tree
    When git grep looks for the dash report path in both spellings
    Then it prints nothing
    And every test helper that runs the real gitleaks pipes its stdout
