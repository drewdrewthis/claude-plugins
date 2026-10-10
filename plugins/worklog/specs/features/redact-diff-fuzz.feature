# Coverage map for claude-plugins#218 — a differential fuzz test compares the
# candidate redact lib with a pinned reference, and the uuid check in the hook no
# longer drops a valid uuid. Token shapes are recipes (prefix plus seeded random
# characters), never literals. Not executable: each Scenario carries a
# proves comment naming the bats test or CI step that proves it.

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

  # proves: hooks/tests/redact-diff-fuzz.bats "builtin mode is clean at seed 1", "builtin mode is clean at seed 2", "builtin mode is clean at seed 3", "builtin mode is clean at seed 4", "builtin mode is clean at seed 5"
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
    And it prints confirm_cap=40, the default cap
    And at most the first 40 flagged texts are re-run alone
    And it prints flagged=A confirmed=0 worse=0 and exits 0

  # proves: .github/workflows/worklog-tests.yml step "redact differential fuzz suite"
  @integration
  Scenario Outline: The fuzz step runs on both legs inside the time budget
    Given the workflow has a named step that runs redact-diff-fuzz.bats
    When the step runs on <leg>
    Then the step takes 120 seconds or less

    Examples:
      | leg           |
      | ubuntu-latest |
      | macos-latest  |

  # proves: hooks/tests/redact-diff-fuzz.bats "named case F is clean with the candidate", "named case G1 is clean with the candidate", "named case G2b is clean with the candidate", "named case H1 is clean with the candidate", "named case H2 is clean with the candidate"
  # proves: hooks/tests/redact-diff-fuzz.bats "named case F is worse with cb0ab84", "named case G1 is worse with 3854dc2", "named case G2b is worse with 3854dc2", "named case H1 is worse with f1f1f8a", "named case H2 is worse with f1f1f8a"
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
    Then it exits 0 and prints outputs_differ=1 and worse=0
    # The outputs differ, yet nothing is worse: marker names do not count.

  # proves: hooks/tests/worklog-record.bats "UUID-CHECK: a valid ask_uuid survives a 1 MB uuid list"
  @integration
  Scenario: A large uuid list does not drop the asked uuid
    Given a transcript whose uuid lines total 1 MB or more with the asked uuid on the first line
    When the hook runs
    Then the stored row has ask_uuid equal to that uuid
    And the test asserts the hook run ended in 60 seconds or less (a wide bound; a tight one fails under load)

  # proves: hooks/tests/worklog-record.bats "UUID-CHECK: the hook checks uuids without a grep pipe"
  @integration
  Scenario: The hook has no pipe into grep -Fxq
    Given the fixed hook file
    When grep -cF '| grep -Fxq' runs on it
    Then the count is 0
    And the comment at the uuid check names SIGPIPE, pipefail and exit 141

  # proves: hooks/tests/worklog-record.bats "UUID-CHECK: given an ask_uuid no jq-listed record holds, it is written null", "UUID-CHECK: given an ask_uuid that is a strict prefix of another record's uuid, it is written null", "UUID-CHECK: given an ask_uuid that is another uuid with its last 4 chars starred, it is written null", "UUID-CHECK: given an end_uuid no jq-listed record holds, it is written null", "UUID-CHECK: given an end_uuid that is a strict prefix of another record's uuid, it is written null", "UUID-CHECK: given an end_uuid that is another uuid with its last 4 chars starred, it is written null"
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

  # proves: hooks/tests/worklog-record.bats "UUID-CHECK: a uuid held by the transcript is written unchanged"
  @integration
  Scenario: A listed uuid is stored unchanged
    Given a transcript that holds the asked uuid
    When the hook runs
    Then ask_uuid equals that uuid

  # proves: hooks/tests/worklog-record.bats "UUID-CHECK: given an ask_uuid that holds a newline spanning two listed uuids, it is written null", "UUID-CHECK: given an end_uuid that holds a newline spanning two listed uuids, it is written null"
  @integration
  Scenario Outline: A uuid that holds a newline is stored as null
    Given a transcript whose <field> value holds a newline between two listed uuids
    When the hook runs
    Then the row holds null for <field>

    Examples:
      | field    |
      | ask_uuid |
      | end_uuid |

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

  # proves: hooks/tests/redact-diff-fuzz.bats "failure mode 1 exits 2 when the pinned sha is not in the clone", "failure mode 2 exits 2 when the bad commit is not in the clone", "failure mode 3 exits 2 when gitleaks mode has no gitleaks", "failure mode 4 exits 2 when gitleaks is visible in builtin mode", "failure mode 5 exits 2 when the candidate raises", "failure mode 6 exits 2 when the output count differs from the input count", "failure mode 7 exits 2 when gitleaks reports failed", "failure mode 8 exits 2 when over the cap and none of the first flagged is confirmed", "failure mode 9 exits 2 when a lib reports no gitleaks in gitleaks mode"
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
      | 9   | gitleaks mode and a lib reports no gitleaks                        | gitleaks not present in gitleaks mode    |

  # proves: hooks/tests/redact-diff-fuzz.bats "more flagged than the cap, with a confirmed text, exits 1"
  @integration
  Scenario: A confirmed text among the first 40 gives exit 1, not exit 2
    Given more than 40 flagged texts and one or more of the first 40 is confirmed worse alone
    When the helper runs
    Then it exits 1

  # proves: hooks/tests/redact-diff-fuzz.bats "marker with a name outside the allowed set keeps its piece"
  @unit
  Scenario: A planted piece inside an odd-named marker still counts as leaked
    Given a candidate output that puts a planted piece inside a marker named with uppercase letters
    When the helper self-test scores the text
    Then the piece is kept in the leak score

  # proves: hooks/tests/redact-diff-fuzz.bats "gitleaks finds no leak in the helper", "gitleaks finds no leak in this bats file", "builtin fuzz has teeth against 05b2460"
  @integration
  Scenario: The test files hold no real secret and the output does not echo planted pieces
    Given all token values are made at run time from a prefix plus seeded random characters
    When gitleaks dir runs on redact_diff_fuzz.py and on redact-diff-fuzz.bats
    Then it reports no leaks found
    And in every exit-1 run stdout and stderr hold no run of 8 or more consecutive chars of any planted piece

  # proves: hooks/tests/redact-diff-fuzz.bats "the pinned sha appears once outside the changelogs and that is the helper"
  @integration
  Scenario: The helper header states the pin rule
    Given the helper file header states the pin rule
    Then git grep -c <the full pinned sha> -- . ':(exclude)*CHANGELOG.md' prints the helper with count 1

  # --- AC Coverage Map ---
  # AC1   : The corpus hash and verdict follow the seed
  # AC2a  : Builtin mode gives no worse text with the candidate lib
  # AC2b  : Gitleaks mode confirms each flagged text alone
  # AC2c  : The fuzz step runs on both legs inside the time budget
  # AC3   : A named case from PR 217 is clean now and worse with its bad commit; A marker-name-only change is not worse
  # AC4a  : A large uuid list does not drop the asked uuid
  # AC4b  : The hook has no pipe into grep -Fxq
  # AC4c  : A uuid that jq does not list is stored as null; A listed uuid is stored unchanged; A uuid that holds a newline is stored as null
  # AC5   : The builtin fuzz fails a known-bad lib
  # AC5b  : The gitleaks fuzz fails a known-bad lib
  # AC6   : Setup failures exit 2 with a named stderr token; A confirmed text among the first 40 gives exit 1, not exit 2
  # AC6b  : A planted piece inside an odd-named marker still counts as leaked
  # AC7   : The test files hold no real secret and the output does not echo planted pieces
  # AC9   : The helper header states the pin rule
