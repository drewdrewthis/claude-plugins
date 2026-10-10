# Coverage map for claude-plugins#218 — a differential fuzz test compares the
# candidate redact lib with a pinned reference, the uuid race in the hook is
# fixed, and both run in CI. Token shapes are recipes (prefix plus seeded random
# characters), never literals. Each Scenario carries a "# proves:" comment naming
# the bats test or CI step that proves it.

Feature: The redact fuzz test catches a redaction that leaks more than the pinned reference
  The helper hooks/tests/redact_diff_fuzz.py scores each text by what is left
  after marker text is cut out. A text is worse when the candidate score is
  higher than the pinned reference score (sha 0da91ef).
  Exit 0 means no worse text, exit 1 means one or more, exit 2 means the test
  could not run.

  # proves: hooks/tests/redact-diff-fuzz.bats "corpus hash is stable across runs"
  @integration
  Scenario: The corpus hash and verdict follow the seed
    Given the helper runs twice with the same seed and N
    When both runs finish
    Then both print the same corpus_sha256 line
    And a run with no worse text exits 0 and prints worse=0
    And a run with one or more worse texts exits 1, prints worse=N, and prints each worse text masked

  # proves: hooks/tests/redact-diff-fuzz.bats "builtin mode is clean at seed 1" to "builtin mode is clean at seed 5"
  @integration
  Scenario Outline: Builtin mode gives no worse text with the candidate lib
    Given gitleaks is hidden from the helper on a runner that has gitleaks installed
    When the helper runs with N 3000 and seed <seed>
    Then it prints mode=builtin gitleaks_present=False
    And it exits 0 and prints worse=0

    Examples:
      | seed |
      | 1    |
      | 2    |
      | 3    |
      | 4    |
      | 5    |

  # proves: hooks/tests/redact-diff-fuzz.bats "gitleaks mode is clean on the first 1000 pairs texts"
  @integration
  Scenario: Gitleaks mode confirms each flagged text alone
    Given WORKLOG_GITLEAKS_TIMEOUT is 120 and gitleaks 8.30.1 is installed
    When the helper scans the first 1000 texts of the pairs enumeration in one batch
    Then it prints mode=gitleaks gitleaks_present=True version=8.30.1 failed=False
    And at most the first 40 flagged texts are re-run alone
    And it prints flagged=A confirmed=0 worse=0 and exits 0

  # proves: .github/workflows/worklog-tests.yml step "redact diff fuzz"
  @integration
  Scenario Outline: The fuzz step runs on both legs inside the time budget
    Given the workflow has a named step that runs redact-diff-fuzz.bats
    When the step runs on <leg>
    Then the step takes 120 seconds or less

    Examples:
      | leg           |
      | ubuntu-latest |
      | macos-latest  |

  # proves: hooks/tests/redact-diff-fuzz.bats "named case <case> is clean with the candidate" and "named case <case> is worse with <bad_commit>"
  @integration
  Scenario Outline: A named case from PR 217 is clean now and worse with its bad commit
    Given the case <case> is built from its recipe with a fixed literal seed in <mode> mode
    When the helper runs it alone with the candidate hooks/lib
    Then it exits 0 and prints worse=0
    When the helper runs it alone with the lib of <bad_commit>
    Then it exits 1 and prints worse=1

    Examples:
      | case | mode     | bad_commit |
      | F    | builtin  | cb0ab84    |
      | G1   | builtin  | 3854dc2    |
      | G2b  | builtin  | 3854dc2    |
      | H1   | gitleaks | f1f1f8a    |
      | H2   | gitleaks | f1f1f8a    |

  # proves: hooks/tests/redact-diff-fuzz.bats "named case G2 changes only marker names"
  @integration
  Scenario: A marker-name-only change is not worse
    Given case G2 in the exact PR 217 shape, where only marker names differ
    When the helper runs it alone with the lib of 3854dc2
    Then it exits 0 and prints worse=0

  # proves: hooks/tests/worklog-record.bats "BLIND race: asked uuid on the first line of a 1 MB transcript"
  @integration
  Scenario: A large uuid list does not drop the asked uuid
    Given a transcript whose uuid lines total 1 MB or more with the asked uuid on the first line
    When the hook runs
    Then the stored row has ask_uuid equal to that uuid
    And the test asserts the hook run ended in 5 seconds or less
    And on the test-first commit with the old hook the test is not ok on both legs

  # proves: hooks/tests/worklog-record.bats "uuid check uses no pipe"
  @integration
  Scenario: The hook has no pipe into grep -Fxq
    Given the fixed hook file
    When grep -cF '| grep -Fxq' runs on it
    Then the count is 0
    And the comment at the uuid check names SIGPIPE, pipefail and exit 141

  # proves: hooks/tests/worklog-record.bats "ask_uuid absent from the jq list is stored null"
  @integration
  Scenario Outline: A uuid that jq does not list is stored as null
    Given a fixture whose last user-prompt record ends in a bare CR so the slicer sees it and jq does not
    And the uuid case is <case>
    When the unmodified hook file runs in full
    Then the row holds null for <field>

    Examples:
      | case                                 | field     |
      | no other record holds the uuid       | ask_uuid  |
      | strict prefix of another uuid        | ask_uuid  |
      | other uuid with last 4 chars as star | ask_uuid  |
      | no other record holds the uuid       | end_uuid  |
      | strict prefix of another uuid        | end_uuid  |
      | other uuid with last 4 chars as star | end_uuid  |

  # proves: hooks/tests/worklog-record.bats "a uuid in the transcript is stored unchanged"
  @integration
  Scenario: A listed uuid is stored unchanged
    Given a transcript that holds the asked uuid
    When the hook runs
    Then ask_uuid equals that uuid

  # proves: the load-run command output (supporting, not the proof)
  @integration
  Scenario: The BLIND test is stable under load
    Given 16 busy loops are running
    When the BLIND test runs 40 times
    Then 40 of 40 runs pass

  # proves: hooks/tests/redact-diff-fuzz.bats "builtin fuzz has teeth against 05b2460"
  @integration
  Scenario: The builtin fuzz fails a known-bad lib
    Given the lib of 05b2460 is the candidate
    When the helper runs in builtin mode at seed 2 with N 3000
    Then it exits 1 and prints worse=N with N above 0

  # proves: hooks/tests/redact-diff-fuzz.bats "gitleaks fuzz has teeth against f1f1f8a"
  @integration
  Scenario: The gitleaks fuzz fails a known-bad lib
    Given the lib of f1f1f8a is the candidate and gitleaks mode is on
    When the helper scans the first 1000 texts of the pairs enumeration
    Then it exits 1 and prints flagged=A confirmed=B worse=B with B at least 1

  # proves: hooks/tests/redact-diff-fuzz.bats "failure mode <row> exits 2 ..." (rows 1 to 7), "failure mode 8 exits 2 when over the cap and none of the first flagged is confirmed"
  @integration
  Scenario Outline: Setup failures exit 2 with a named stderr token
    Given the setup <setup>
    When the helper runs
    Then it exits 2
    And stderr holds <token>

    Examples:
      | row | setup                                                              | token                                    |
      | 1   | the pinned sha is not in the clone                                 | the sha and git fetch --unshallow        |
      | 2   | a bad-commit ref is not in the clone                               | the sha and git fetch origin refs/pull/217/head |
      | 3   | gitleaks mode with no gitleaks                                     | gitleaks not found                       |
      | 4   | builtin mode with gitleaks visible                                 | gitleaks present in builtin mode         |
      | 5   | the candidate raises                                               | candidate error                          |
      | 6   | the output count differs from the input count                      | output count                             |
      | 7   | gitleaks reports failed true                                       | gitleaks failed                          |
      | 8   | more than 40 flagged texts and none of the first 40 is confirmed worse alone | too many to confirm            |

  # proves: hooks/tests/redact-diff-fuzz.bats "more than 40 flagged with a confirmed text exits 1"
  @integration
  Scenario: A confirmed text among the first 40 gives exit 1, not exit 2
    Given more than 40 flagged texts and one or more of the first 40 is confirmed worse alone
    When the helper runs
    Then it exits 1

  # proves: CI log of redact-diff-fuzz.bats
  @integration
  Scenario: No test is skipped in CI
    Given the bats output of the new file in CI
    When the output is read
    Then it holds zero "# skip" lines

  # proves: hooks/tests/redact-diff-fuzz.bats "marker with a name outside the allowed set keeps its piece"
  @unit
  Scenario: A planted piece inside an odd-named marker still counts as leaked
    Given a candidate output that puts a planted piece inside a marker named with uppercase letters
    When the helper self-test scores the text
    Then the piece is kept in the leak score

  # proves: gitleaks dir output and the AC5 assertion line
  @integration
  Scenario: The test files hold no real secret and the output does not echo planted pieces
    Given all token values are made at run time from a prefix plus seeded random characters
    When gitleaks dir runs on redact_diff_fuzz.py and on redact-diff-fuzz.bats
    Then it reports no leaks found
    And in every exit-1 run stdout and stderr hold no run of 8 or more consecutive chars of any planted piece

  # proves: CI TAP plan lines and the git diff output
  @integration
  Scenario: The existing suites stay green and the diff stays small
    Given worklog-record.bats has the 187 tests from fe9b664 plus the new ones, and gate-failopen.bats has 29
    When both run on ubuntu-latest and macos-latest
    Then each has 0 not ok and 0 "# skip"
    And git diff --name-only origin/main...HEAD lists none of redact.py, plugin.json, CHANGELOG.md
    And the diff touches only the five paths in the plan

  # proves: the helper header quoted in the PR body
  @integration
  Scenario: The helper header states the pin rule
    Given the helper file header
    Then it says the pinned sha is one constant and appears once in the repo
    And it says to move the sha after each merged change to redact.py
    And it says that after a move the named-case and teeth runs must give the same exit codes
    And it says a PR that makes a text worse on purpose must change the score or the corpus and give the reason in the PR body
    And git grep -c 0da91ef40956 prints one file with count 1

  # proves: gh pr view --json title
  @integration
  Scenario: The PR title makes a patch release
    Given the pull request for this change
    Then its title starts with "fix(worklog):"

  # --- AC Coverage Map ---
  # AC1   : The corpus hash and verdict follow the seed
  # AC2a  : Builtin mode gives no worse text with the candidate lib
  # AC2b  : Gitleaks mode confirms each flagged text alone
  # AC2c  : The fuzz step runs on both legs inside the time budget
  # AC3   : A named case from PR 217 is clean now and worse with its bad commit; A marker-name-only change is not worse
  # AC4a  : A large uuid list does not drop the asked uuid
  # AC4b  : The hook has no pipe into grep -Fxq
  # AC4c  : A uuid that jq does not list is stored as null; A listed uuid is stored unchanged
  # AC4d  : The BLIND test is stable under load
  # AC5   : The builtin fuzz fails a known-bad lib
  # AC5b  : The gitleaks fuzz fails a known-bad lib
  # AC6   : Setup failures exit 2 with a named stderr token; A confirmed text among the first 40 gives exit 1, not exit 2; No test is skipped in CI
  # AC6b  : A planted piece inside an odd-named marker still counts as leaked
  # AC7   : The test files hold no real secret and the output does not echo planted pieces
  # AC8   : The existing suites stay green and the diff stays small
  # AC9   : The helper header states the pin rule
  # AC10  : The PR title makes a patch release
