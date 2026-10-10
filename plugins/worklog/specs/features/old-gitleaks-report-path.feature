# Coverage map for claude-plugins#245 (contract 3) — gitleaks before 8.22.0 reads
# a lone dash as the report path as a file name: it writes the raw findings to a
# file named "-" in the working directory and prints nothing, which the hook read
# as "no findings". The library asks for /dev/stdout on Linux and for the dash
# elsewhere (macOS gives no report on /dev/stdout). The hook deletes nothing,
# ever. Not executable: each Scenario carries a "# proves:" comment naming the
# bats test that proves it, or the terminal evidence / grep that proves it where
# the suite cannot.

Feature: Old gitleaks versions redact on Linux and are refused elsewhere
  Per-system minimums: on Linux 8.19.1, on other systems 8.22.0 (the first
  version where "-" means stdout). On Linux, before the call, the redact library
  checks /dev/stdout without following it: absent or a regular file means the
  scan fails and gitleaks is not run; "gitleaks version" is not called. On other
  systems it runs "gitleaks version" first; below 8.22.0, or with no readable
  version, "gitleaks stdin" is not run, the scan fails and the hook notes
  gitleaks-failed and gitleaks-too-old. A "-" entry that appears or changes
  during a run on a version read as safe fails the scan and is noted as
  gitleaks-report-file. An unchanged "-" that existed before the run is
  ignored. Nothing is removed. With
  8.21.2 a Linux turn is redacted; a turn on any other system is loud (unjudged
  row, no model call, built-in redaction still on). 8.19.0 and older on Linux
  exit 1, recorded as gitleaks-failed.

  # AC1
  # proves: hooks/tests/worklog-record.bats "gitleaks 8.21.2 stores the pulumi marker in the worklog on Linux"
  # proves: hooks/tests/worklog-record.bats "gitleaks 8.21.2 keeps the raw pulumi token out of the worklog"
  # proves: hooks/tests/worklog-record.bats "gitleaks 8.21.2 keeps the raw pulumi token out of the stdin the model receives"
  # proves: hooks/tests/worklog-record.bats "gitleaks 8.21.2 on a secret turn logs gitleaks-failed once off Linux and never on Linux"
  # proves: hooks/tests/worklog-record.bats "gitleaks 8.21.2 on a secret turn stores one row"
  # proves: hooks/tests/worklog-record.bats "gitleaks 8.21.2 on a secret turn judges the row on Linux and leaves it unjudged elsewhere"
  # proves: hooks/tests/worklog-record.bats "gitleaks 8.21.2 on a secret turn calls the model on Linux and never elsewhere"
  # proves: hooks/tests/worklog-record.bats "gitleaks 8.21.2 on a secret turn logs gitleaks-too-old once off Linux and never on Linux"
  Scenario: A secret turn on gitleaks 8.21.2 never leaks the token, on either system
    Given gitleaks 8.21.2 is first on PATH and the hook runs in a fresh empty directory
    And a fake Pulumi token is in the prompt and in the model reply text
    When the hook records the turn
    Then the worklog and the stdin the model receives hold the token 0 times
    And on Linux the worklog holds the pulumi-api-token marker, no gitleaks-failed note is logged and the row is judged
    And on other systems one gitleaks-failed note and one gitleaks-too-old note are logged, the row is unjudged and the model is called 0 times

  # AC2
  # proves: hooks/tests/worklog-record.bats "gitleaks 8.21.2 on a secret turn leaves the working directory empty"
  # proves: hooks/tests/worklog-record.bats "gitleaks 8.21.2 on a clean turn leaves the working directory empty"
  # proves: hooks/tests/worklog-record.bats "gitleaks 8.21.2 on a secret turn logs no gitleaks-report-file"
  # proves: hooks/tests/worklog-record.bats "gitleaks 8.21.2 on a clean turn logs no gitleaks-report-file"
  Scenario: No report file is left in the working directory
    Given gitleaks 8.21.2 is first on PATH and the hook runs in a fresh empty directory
    When the hook records a turn with a secret, and a turn with no secret
    Then after each run the directory is still empty

  # AC2b
  # proves: hooks/tests/worklog-record.bats "gitleaks 8.21.2 on a clean turn stores one row"
  # proves: hooks/tests/worklog-record.bats "gitleaks 8.21.2 on a clean turn judges the row on Linux and leaves it unjudged elsewhere"
  # proves: hooks/tests/worklog-record.bats "gitleaks 8.21.2 on a clean turn logs gitleaks-failed once off Linux and never on Linux"
  # proves: hooks/tests/worklog-record.bats "gitleaks 8.21.2 on a clean turn calls the model on Linux and never elsewhere"
  # proves: hooks/tests/worklog-record.bats "gitleaks 8.21.2 on a clean turn logs gitleaks-too-old once off Linux and never on Linux"
  Scenario: A clean turn on gitleaks 8.21.2 is quiet on Linux and loud elsewhere
    Given gitleaks 8.21.2 is first on PATH
    When the hook records a turn with no secret
    Then exactly one row is stored
    And on Linux the row is judged, no gitleaks-failed note is logged and the model is called
    And on other systems the row is unjudged, one gitleaks-failed note and one gitleaks-too-old note are logged and the model is called 0 times

  # AC3 and AC-matrix: terminal evidence, quoted in the PR
  # proves: terminal loop of the real hook over 8.18.4 8.19.0 8.19.1 8.19.2 8.19.3 8.20.0 8.21.0 8.21.1 8.21.2 8.22.0 8.30.1
  Scenario: Versions 8.19.0 and older are loud, 8.19.1 and later redact
    Given a real binary of each listed version first on PATH, each run in a fresh empty directory
    When the real hook records a turn with a fake token
    Then 8.19.0 and older give one gitleaks-failed line and an unjudged row
    And every version leaves the token 0 times in the worklog and the directory empty

  # AC4c
  # proves: hooks/tests/worklog-record.bats "gitleaks is invoked with the stdin report flags"
  # proves: hooks/tests/worklog-record.bats "the default report path asks for the version only off Linux"
  Scenario: The call shape names the platform report path
    Given the gitleaks stub logs its arguments
    When the hook scans a turn
    Then the logged arguments hold --report-path /dev/stdout on Linux and --report-path - elsewhere
    And the version log is empty on Linux and holds only "version" elsewhere

  # AC4 a, b, d: CI log lines and one terminal comparison, quoted in the PR
  # proves: CI log of "the real gitleaks redacts a pulumi token from prompt to stored row" on both legs, the fuzz run result line, and the fuzz corpus diff at seed 1
  Scenario: Nothing changes on gitleaks 8.30.1
    Given gitleaks 8.30.1 on both CI legs
    When the suite and the differential fuzz run
    Then the real-binary test reads ok, not skip, and the redacted fuzz output is byte-identical to main

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
    Then it states minimum gitleaks 8.19.1 on Linux and 8.22.0 elsewhere and lists only the matrix versions as tested
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
  # (the test uses a gitleaks that writes to its --report-path, so it fails if the guard lets a scan run)
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

  # AC10 (report path forced to the dash from python, fresh temporary working directory)
  # proves: hooks/tests/worklog-record.bats "dash path: gitleaks 8.21.2 makes the scan report failure and sets the too-old flag"
  # proves: hooks/tests/worklog-record.bats "dash path: gitleaks 8.21.2 leaves no entry in the working directory"
  Scenario: Gitleaks 8.21.2 is refused before it runs
    Given the report path is the dash and gitleaks 8.21.2 is first on PATH
    When a scan is asked for on text with a fake token
    Then the scan reports failure with the too-old flag set and the report-file flag clear
    And the working directory holds no entry

  # proves: hooks/tests/worklog-record.bats "dash path: a gitleaks whose version call fails makes the scan report failure and sets the too-old flag"
  # proves: hooks/tests/worklog-record.bats "dash path: a gitleaks whose version call fails never runs gitleaks stdin"
  # proves: hooks/tests/worklog-record.bats "dash path: a gitleaks whose version call fails leaves no entry in the working directory"
  # proves: hooks/tests/worklog-record.bats "dash path: a gitleaks whose version call prints no version makes the scan report failure and sets the too-old flag"
  # proves: hooks/tests/worklog-record.bats "dash path: a gitleaks whose version call prints no version never runs gitleaks stdin"
  # proves: hooks/tests/worklog-record.bats "dash path: a gitleaks whose version call prints no version leaves no entry in the working directory"
  Scenario: An unreadable version is treated as too old
    Given the report path is the dash and the version call fails, or prints no version
    When a scan is asked for on text with a fake token
    Then the scan reports failure with the too-old flag set, gitleaks stdin is called 0 times and the working directory holds no entry

  # proves: hooks/tests/worklog-record.bats "dash path: gitleaks 8.30.1 with no dash entry before returns the finding and sets no flag"
  # proves: hooks/tests/worklog-record.bats "dash path: gitleaks 8.30.1 with no dash entry before leaves no entry in the working directory"
  # proves: hooks/tests/worklog-record.bats "dash path: the real gitleaks returns the finding without failure and leaves both flags clear"
  # proves: hooks/tests/worklog-record.bats "dash path: the real gitleaks leaves no entry named dash"
  Scenario: Gitleaks 8.30.1 returns the finding and leaves no file
    Given the report path is the dash and gitleaks 8.30.1 is first on PATH
    When a scan is asked for on text with a fake token
    Then the finding is returned, the scan is not failed, both flags are clear and no entry named "-" exists

  # proves: hooks/tests/worklog-record.bats "dash path: gitleaks 8.30.1 with a regular file named dash before returns the finding and sets no flag"
  # proves: hooks/tests/worklog-record.bats "dash path: gitleaks 8.30.1 with a regular file named dash before keeps its bytes"
  # proves: hooks/tests/worklog-record.bats "dash path: gitleaks 8.30.1 with a symbolic link named dash before returns the finding and sets no flag"
  # proves: hooks/tests/worklog-record.bats "dash path: gitleaks 8.30.1 with a symbolic link named dash before leaves it a link"
  # proves: hooks/tests/worklog-record.bats "dash path: gitleaks 8.30.1 with a symbolic link named dash before leaves its target bytes"
  # proves: hooks/tests/worklog-record.bats "dash path: gitleaks 8.30.1 with a directory named dash before returns the finding and sets no flag"
  # proves: hooks/tests/worklog-record.bats "dash path: gitleaks 8.30.1 with a directory named dash before leaves it a directory"
  Scenario: A dash entry that existed before the run is ignored and left unchanged
    Given the report path is the dash, gitleaks 8.30.1 is first on PATH and "-" is a regular file, a symbolic link or a directory
    When a scan is asked for on text with a fake token
    Then the finding is returned, the scan is not failed, both flags are clear and the entry is unchanged

  # proves: hooks/tests/worklog-record.bats "dash path: a dash file that appears during a run claimed safe makes the scan report failure and sets the report-file flag"
  # proves: hooks/tests/worklog-record.bats "dash path: a dash file that appears during a run claimed safe stays in place"
  # proves: hooks/tests/worklog-record.bats "dash path: a dash file that appears during a run claimed safe keeps the bytes gitleaks wrote"
  Scenario: A misread version that still writes a dash file fails the scan and keeps the file
    Given the report path is the dash and a gitleaks that prints 8.30.1 for version but writes a file named "-" for stdin
    When a scan is asked for on text with a fake token
    Then the scan reports failure with the report-file flag set and the file is still there with its bytes

  # proves: hooks/tests/worklog-record.bats "dash path: a pre-existing dash file overwritten during a run claimed safe makes the scan report failure and sets the report-file flag"
  # proves: hooks/tests/worklog-record.bats "dash path: a pre-existing dash file overwritten during a run claimed safe stays in place with the bytes gitleaks wrote"
  # proves: hooks/tests/worklog-record.bats "dash path: an empty pre-existing dash file overwritten during a run claimed safe makes the scan report failure and sets the report-file flag"
  # proves: hooks/tests/worklog-record.bats "dash path: an empty pre-existing dash file overwritten during a run claimed safe stays in place with the bytes gitleaks wrote"
  # proves: hooks/tests/worklog-record.bats "dash path: the real gitleaks 8.21.2 claimed as 8.30.1 overwriting an empty pre-existing dash file makes the scan report failure and sets the report-file flag"
  Scenario: A pre-existing dash file that a misread version overwrites fails the scan and keeps the file
    Given the report path is the dash, "-" is an existing regular file (non-empty, or empty) and a gitleaks prints 8.30.1 (a stub, or the real 8.21.2 behind a version wrapper) but overwrites "-" for stdin
    When a scan is asked for on text with a fake token
    Then the scan reports failure with the report-file flag set, the too-old flag clear and no findings, and the file is still there with the bytes gitleaks wrote
    # An existing "-" whose inode, size or mtime changed during the run counts as written by the run.

  # proves: hooks/tests/worklog-record.bats "dash path: a normal run asks for the version exactly once"
  # proves: hooks/tests/worklog-record.bats "dash path: a normal run scans once"
  Scenario: A normal dash run makes one version call and one scan call
    Given the report path is the dash and gitleaks 8.30.1 is first on PATH
    When a scan is asked for on text with a fake token
    Then the version log holds one version call and the call log holds one stdin call

  # proves: hooks/tests/worklog-record.bats "the redact library never removes a file"
  Scenario: The library deletes nothing
    Given the redact library source
    Then it holds no os.unlink, os.remove or shutil.rmtree

  # proves: hooks/tests/worklog-record.bats "a pre-existing dash file in the working directory keeps its bytes through a secret turn"
  # proves: hooks/tests/worklog-record.bats "a pre-existing dash file in the working directory never lets the raw token into the worklog"
  # proves: hooks/tests/worklog-record.bats "a pre-existing dash file in the working directory logs no gitleaks-failed"
  # proves: hooks/tests/worklog-record.bats "a pre-existing dash file in the working directory logs no gitleaks-too-old"
  # proves: hooks/tests/worklog-record.bats "a pre-existing dash file in the working directory logs no gitleaks-report-file"
  # proves: hooks/tests/worklog-record.bats "a pre-existing dash file in the working directory judges the row"
  # proves: hooks/tests/worklog-record.bats "a pre-existing dash file in the working directory stores the marker"
  Scenario: A dash file that was there before a secret turn changes nothing, on either system
    Given the real gitleaks and a working directory holding a regular "-" file with known bytes
    When the hook records a turn with a fake token
    Then the file keeps its bytes, the row is judged, the marker is stored, no gitleaks-failed, gitleaks-too-old or gitleaks-report-file note is logged and the worklog holds the token 0 times

  # Hook level, the dash path forced on either system: a sitecustomize.py on PYTHONPATH sets sys.platform to darwin; production code has no test switch.
  # proves: hooks/tests/worklog-record.bats "forced dash path: gitleaks 8.21.2 logs gitleaks-too-old once"
  # proves: hooks/tests/worklog-record.bats "forced dash path: gitleaks 8.21.2 logs gitleaks-failed once"
  # proves: hooks/tests/worklog-record.bats "forced dash path: gitleaks 8.21.2 logs no gitleaks-report-file"
  # proves: hooks/tests/worklog-record.bats "forced dash path: gitleaks 8.21.2 stores one row"
  # proves: hooks/tests/worklog-record.bats "forced dash path: gitleaks 8.21.2 does not call the model"
  # proves: hooks/tests/worklog-record.bats "forced dash path: gitleaks 8.21.2 never runs gitleaks stdin"
  # proves: hooks/tests/worklog-record.bats "forced dash path: gitleaks 8.21.2 leaves no entry in the working directory"
  # proves: hooks/tests/worklog-record.bats "forced dash path: a gitleaks whose version call fails logs gitleaks-too-old once"
  Scenario: The hook notes gitleaks-too-old and runs no scan when the dash path is forced and the version is old or unreadable
    Given the hook runs with sys.platform forced to darwin, a gitleaks stub that prints 8.21.2 (or fails the version call), and a fresh empty working directory
    When the hook records a turn with a fake token
    Then one gitleaks-too-old note and one gitleaks-failed note are logged, no gitleaks-report-file note, one row, the model is called 0 times, gitleaks stdin is called 0 times and the directory is empty

  # proves: hooks/tests/worklog-record.bats "forced dash path: gitleaks-too-old is logged once per session across two turns"
  # proves: hooks/tests/worklog-record.bats "forced dash path: gitleaks-failed is logged on each of two turns"
  Scenario: gitleaks-too-old is noted once per session, gitleaks-failed on each turn
    Given the hook runs with sys.platform forced to darwin and a gitleaks stub that prints 8.21.2
    When the hook records two turns of one session
    Then gitleaks-too-old appears once and gitleaks-failed twice

  # proves: hooks/tests/worklog-record.bats "forced dash path: a dash file written during a run claimed safe logs gitleaks-report-file once"
  # proves: hooks/tests/worklog-record.bats "forced dash path: a dash file written during a run claimed safe logs gitleaks-failed once"
  # proves: hooks/tests/worklog-record.bats "forced dash path: a dash file written during a run claimed safe logs no gitleaks-too-old"
  # proves: hooks/tests/worklog-record.bats "forced dash path: a dash file written during a run claimed safe does not call the model"
  # proves: hooks/tests/worklog-record.bats "forced dash path: a dash file written during a run claimed safe stays with its bytes"
  Scenario: The hook notes gitleaks-report-file when a misread version leaves a dash file
    Given the hook runs with sys.platform forced to darwin and a gitleaks that prints 8.30.1 but writes a file named "-"
    When the hook records a turn with a fake token
    Then one gitleaks-report-file note and one gitleaks-failed note are logged, no gitleaks-too-old note, the model is called 0 times and the file keeps its bytes

  # proves: hooks/tests/worklog-record.bats "forced dash path: a pre-existing dash file overwritten during a run claimed safe logs gitleaks-report-file once"
  # proves: hooks/tests/worklog-record.bats "forced dash path: a pre-existing dash file overwritten during a run claimed safe logs gitleaks-failed once"
  # proves: hooks/tests/worklog-record.bats "forced dash path: a pre-existing dash file overwritten during a run claimed safe does not call the model"
  Scenario: The hook notes gitleaks-report-file when a misread version overwrites a pre-existing dash file
    Given the hook runs with sys.platform forced to darwin, "-" is an existing regular file and a gitleaks prints 8.30.1 but overwrites it
    When the hook records a turn with a fake token
    Then one gitleaks-report-file note and one gitleaks-failed note are logged and the model is called 0 times

  # proves: hooks/tests/worklog-record.bats "forced dash path: the real gitleaks 8.21.2 logs gitleaks-too-old once"
  # proves: hooks/tests/worklog-record.bats "forced dash path: the real gitleaks 8.21.2 leaves no entry in the working directory"
  # proves: hooks/tests/worklog-record.bats "forced dash path: the real gitleaks 8.21.2 keeps the raw token out of the worklog"
  Scenario: Real gitleaks 8.21.2 is refused by the hook when the dash path is forced
    Given the hook runs with sys.platform forced to darwin and the real gitleaks 8.21.2 first on PATH
    When the hook records a turn with a fake token
    Then one gitleaks-too-old note is logged, the directory is empty and the worklog holds the token 0 times

  # Guards found by mutation review. lstat, not stat: with the caller's stdout a regular file, /dev/stdout still counts as usable.
  # proves: hooks/tests/worklog-record.bats "the default report path with the caller's stdout a regular file still returns the finding"
  Scenario: The report path check does not follow the caller's stdout
    Given Linux and a scan whose process stdout is a regular file
    When the scan runs with the default report path
    Then the finding is returned and the scan does not fail

  # proves: hooks/tests/worklog-record.bats "dash path: gitleaks 8.22.0 returns the finding and sets no flag"
  # proves: hooks/tests/worklog-record.bats "dash path: gitleaks 8.21.99 makes the scan report failure and sets the too-old flag"
  Scenario: 8.22.0 is the exact minimum for the dash path
    Given the dash path is forced
    When gitleaks reports version 8.22.0, and then 8.21.99
    Then 8.22.0 returns the finding with no flag and 8.21.99 fails the scan and sets the too-old flag

  # proves: hooks/tests/worklog-record.bats "forced dash path: gitleaks too old only on the model-entries pass logs gitleaks-too-old once"
  # proves: hooks/tests/worklog-record.bats "forced dash path: gitleaks too old only on the model-entries pass still calls the model"
  # proves: hooks/tests/worklog-record.bats "forced dash path: gitleaks too old only on the model-entries pass logs gitleaks-failed once"
  # proves: hooks/tests/worklog-record.bats "forced dash path: a dash file written only on the model-entries pass logs gitleaks-report-file once"
  # proves: hooks/tests/worklog-record.bats "forced dash path: a dash file written only on the model-entries pass still calls the model"
  # proves: hooks/tests/worklog-record.bats "forced dash path: a dash file written only on the model-entries pass stays with its bytes"
  Scenario: The hook notes a problem that shows only on the model-entries pass
    Given the dash path is forced and the candidate pass succeeds
    When the model-entries pass meets a gitleaks that is too old, or one that writes a file named "-"
    Then one gitleaks-too-old (or gitleaks-report-file) note and one gitleaks-failed note are logged, the model was called and the file keeps its bytes

  # proves: hooks/tests/worklog-record.bats "dash path: a version call slower than the timeout makes the scan report failure and sets the too-old flag"
  # proves: hooks/tests/worklog-record.bats "dash path: a version call slower than the timeout never runs gitleaks stdin"
  # proves: hooks/tests/worklog-record.bats "dash path: a version read that uses up the budget makes the scan report failure without too-old, and runs no scan"
  Scenario: The version read and the scan share one timeout budget
    Given the dash path is forced
    When the version call is slower than the timeout, or the version read uses up the whole budget
    Then the scan fails, gitleaks stdin is not run, and the too-old flag is set only in the first case

  # proves: hooks/tests/worklog-record.bats "dash path: a version read that costs part of the budget leaves the scan only the remainder"
  Scenario: The scan gets only the budget the version read left
    Given the dash path is forced and the version read costs part of the timeout
    When the scan runs
    Then gitleaks stdin gets a timeout above zero and at most the remainder

  # proves: hooks/tests/worklog-record.bats "dash path: a gitleaks that prints nothing on a clean scan returns no findings without failure"
  # proves: hooks/tests/worklog-record.bats "a gitleaks that prints nothing on a clean scan returns no findings without failure"
  Scenario: Empty stdout from gitleaks is a clean scan
    Given a gitleaks 8.22.0 that prints nothing and exits 0 on a clean scan
    When the scan runs on the dash path or the default path
    Then it returns no findings, does not fail, and sets no flag

  # proves: hooks/tests/worklog-record.bats "dash path: a timeout that is not a number makes the scan report failure without raising"
  Scenario: A timeout that is not a number fails the scan
    Given the dash path is forced and WORKLOG_GITLEAKS_TIMEOUT is "abc"
    When the scan runs
    Then it reports failure and raises nothing

  # proves: hooks/tests/worklog-record.bats "dash path: a run claimed safe that writes through a dash link to an empty file makes the scan report failure and sets the report-file flag"
  # proves: hooks/tests/worklog-record.bats "dash path: a run claimed safe that writes through a dash link to an empty file leaves the link a link"
  # proves: hooks/tests/worklog-record.bats "dash path: a run claimed safe that writes through a dash link to an empty file leaves the bytes gitleaks wrote in the target"
  # proves: hooks/tests/worklog-record.bats "dash path: a run claimed safe that writes through a dangling dash link makes the scan report failure and sets the report-file flag"
  # proves: hooks/tests/worklog-record.bats "dash path: a run claimed safe that writes through a dangling dash link leaves the link a link"
  # proves: hooks/tests/worklog-record.bats "dash path: a run claimed safe that writes through a dangling dash link creates the target with the bytes gitleaks wrote"
  # proves: hooks/tests/worklog-record.bats "dash path: the real gitleaks 8.21.2 claimed as 8.30.1 writing through a dash link to an empty file makes the scan report failure and sets the report-file flag"
  # proves: hooks/tests/worklog-record.bats "dash path: the real gitleaks 8.21.2 claimed as 8.30.1 writing through a dash link to an empty file leaves the link a link"
  # proves: hooks/tests/worklog-record.bats "dash path: gitleaks 8.30.1 with a symbolic link named dash before returns the finding and sets no flag"
  Scenario: A run claimed safe that writes through a symbolic link named "-" fails the scan
    Given the dash path is forced and "-" is a symbolic link to an empty file, or a dangling one
    When a gitleaks read as safe writes its report through the link, or the real 8.21.2 does so behind a version-lying wrapper
    Then the scan fails with the report-file flag set, the link stays a link and the target holds the written bytes
    But an unchanged symbolic link named "-" is ignored and the finding is returned
