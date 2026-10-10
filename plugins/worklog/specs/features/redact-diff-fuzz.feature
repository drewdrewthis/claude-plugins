# Coverage map for claude-plugins#218 and #240 — a differential fuzz test compares
# the candidate redact lib with a reference that the harness works out from git
# history on every run (no stored sha), and the uuid check in the hook no longer
# drops a valid uuid. Token shapes are recipes (prefix plus seeded random
# characters), never literals. Not executable: each Scenario carries a
# proves comment naming the bats test or CI step that proves it.

Feature: The redact fuzz test catches a redaction that leaks more than the computed reference
  The helper hooks/tests/redact_diff_fuzz.py scores each text by what is left
  after marker text is cut out. A text is worse when the candidate score is
  higher than the reference score. The reference is the merge base with
  origin/main when the library bytes changed, else the parent of the last
  library change on main. Exit 0 means no worse text, exit 1 means one or more,
  exit 2 means the test could not run.

  # proves: hooks/tests/redact-diff-fuzz.bats "corpus hash is stable across runs", "corpus hash follows the seed", "corpus hash at seed 1 and N 200 equals the pinned value on every leg", "builtin fuzz has teeth against 05b2460"
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
    Then the step ends in 120 seconds or less
    And the step timeout of 2 minutes enforces it

    Examples:
      | leg           |
      | ubuntu-latest |
      | macos-latest  |

  # proves: hooks/tests/redact-diff-fuzz.bats "named case F is clean with the candidate", "named case G1 is clean with the candidate", "named case G2b is clean with the candidate", "named case H1 is clean with the candidate", "named case G2 is clean with the candidate", "named case H2 is clean with the candidate"
  # proves: hooks/tests/redact-diff-fuzz.bats "named case F is worse with cb0ab84", "named case G1 is worse with 3854dc2", "named case G2b is worse with 3854dc2", "named case H1 is worse with f1f1f8a", "named case H2 is worse with f1f1f8a"
  @integration
  Scenario Outline: A named case from PR 217 is clean now and worse with its bad commit
    Given the case <case> is built from its recipe with a fixed literal seed in <mode> mode
    When the helper runs it alone with the candidate hooks/lib
    Then it prints the reference line first
    And it exits 0 and prints worse=0
    When the helper runs it alone with the checked-in fixture of <bad_commit>
    Then it prints the reference line first
    And it exits 1 and prints worse=1

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
    When the helper runs it alone with the checked-in fixture of 3854dc2
    Then it exits 0 and prints outputs_differ=1 and worse=0
    # The outputs differ, yet nothing is worse: marker names do not count.

  # proves: hooks/tests/worklog-record.bats "UUID-CHECK: a valid ask_uuid survives a 1 MB uuid list", "UUID-CHECK: a valid end_uuid survives a long uuid list"
  @integration
  Scenario: A large uuid list does not drop the asked uuid
    Given a transcript whose uuid lines total 1 MB or more with the asked uuid on the first line
    When the hook runs
    Then the stored row has ask_uuid equal to that uuid
    And the test asserts the hook run ended in 60 seconds or less (a wide bound; a tight one fails under load)

  # proves: hooks/tests/worklog-record.bats "UUID-CHECK: the hook has no pipe into an early-exit grep"
  @integration
  Scenario: The hook has no pipe into grep -Fxq
    Given the fixed hook file
    When grep -cE for a pipe into an early-exit grep (grep -q, -Fxq) runs on it
    Then the count is 0

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
    When the helper runs in builtin mode at seed 2 with N 1000
    Then the output starts with the reference line
    And it exits 1 and prints worse=N with N above 0

  # proves: hooks/tests/redact-diff-fuzz.bats "gitleaks fuzz has teeth against f1f1f8a"
  @integration
  Scenario: The gitleaks fuzz fails a known-bad lib
    Given the checked-in fixture of f1f1f8a is the candidate and gitleaks mode is on
    When the helper scans the first 1000 texts of the pairs enumeration
    Then the output starts with the reference line
    And it exits 1 and prints flagged=A confirmed=B worse=B with B at least 1

  # proves: hooks/tests/redact-diff-fuzz.bats "failure mode 1 exits 2 when the candidate commit is not in the clone", "failure mode 2 exits 2 when gitleaks mode has no gitleaks", "failure mode 3 exits 2 when gitleaks is visible in builtin mode", "failure mode 4 exits 2 when the candidate raises", "failure mode 5 exits 2 when the output count differs from the input count", "failure mode 6 exits 2 when gitleaks reports failed", "failure mode 7 exits 2 when over the cap and none of the first flagged is confirmed", "failure mode 8 exits 2 when a lib reports no gitleaks in gitleaks mode", "failure mode 9 exits 2 when an option is not used in the mode", "failure mode 10 exits 2 on a malformed sha", "failure mode 11 exits 2 when a fixture blob id differs"
  @integration
  Scenario Outline: Setup failures exit 2 with a named stderr token
    Given the setup <setup>
    When the helper runs
    Then it exits 2
    And stderr holds <token>

    Examples:
      | row | setup                                                              | token                                    |
      | 1   | the candidate commit is not in the clone                           | the sha                                  |
      | 2   | gitleaks mode with no gitleaks                                     | gitleaks not found                       |
      | 3   | builtin mode with gitleaks visible                                 | gitleaks present in builtin mode         |
      | 4   | the candidate raises                                               | candidate error                          |
      | 5   | the output count differs from the input count                      | output count                             |
      | 6   | gitleaks reports failed true                                       | gitleaks failed                          |
      | 7   | more flagged texts than the cap and none of the first flagged is confirmed worse alone | too many to confirm            |
      | 8   | gitleaks mode and a lib reports no gitleaks                        | gitleaks not present in gitleaks mode    |
      | 9   | --seed or --n in gitleaks mode, or --confirm-cap in builtin mode   | option not used in this mode: <flag>     |
      | 10  | --candidate-sha is not 7 to 40 lowercase hex                       | bad sha: <flag> (the value is not echoed) |
      | 11  | a checked-in fixture differs by one byte                           | the fixture file name and blob id        |

  # proves: hooks/tests/redact-diff-fuzz.bats "more flagged than the cap, with a confirmed text, exits 1"
  @integration
  Scenario: A confirmed text among the first 40 gives exit 1, not exit 2
    Given more than 40 flagged texts and one or more of the first 40 is confirmed worse alone
    When the helper runs with a cap of 2 and a stub lib that counts its alone calls
    Then it exits 1
    And the stub lib is run alone exactly 2 times, so the cap is applied

  # proves: hooks/tests/redact-diff-fuzz.bats "marker with a name outside the allowed set keeps its piece"
  @unit
  Scenario: A planted piece inside an odd-named marker still counts as leaked
    Given a candidate output that puts a planted piece inside a marker named with uppercase letters
    When the helper self-test scores the text
    Then the piece is kept in the leak score

  # proves: hooks/tests/redact-diff-fuzz.bats "marker with a name outside the allowed set keeps its piece"
  @unit
  Scenario: A marker named after a planted piece is not cut out
    Given a well-formed marker whose name shares 6 or more consecutive chars with a random part of a planted piece
    And a marker of 41 name chars that holds the piece
    And a well-formed marker with digits and hyphens that shares nothing with the piece
    And a well-formed marker that shares only fixed shape text with a piece
    When the helper self-test scores each text
    Then the first two keep the piece (score 4 or more) and the last two score 0
    # Real names such as aws-access-key are still cut out for the real corpus.

  # proves: hooks/tests/redact-diff-fuzz.bats "gitleaks finds no leak in the helper", "gitleaks finds no leak in this bats file", "builtin fuzz has teeth against 05b2460"
  @integration
  Scenario: The test files hold no real secret and the output does not echo planted pieces
    Given all token values are made at run time from a prefix plus seeded random characters
    When gitleaks dir runs on redact_diff_fuzz.py and on redact-diff-fuzz.bats
    Then it reports no leaks found
    And in every exit-1 run stdout and stderr hold no run of 8 or more consecutive chars of any planted piece

  # proves: hooks/tests/redact-diff-fuzz.bats "fuzz --help lists no option with reference in its name", "case --help lists no option with reference in its name", "a reference option is an unrecognized argument and exits 2", "no file under plugins or .github holds a stored reference constant", "an environment variable does not change the reference line"
  @integration
  Scenario: No reference is stored and none can be given
    Given the helper and the workflow
    Then no file under plugins or .github holds a stored reference constant
    And fuzz --help and case --help list no option with reference in its name
    And a reference option exits 2 with unrecognized arguments
    And an environment variable naming a sha does not change the reference line

  # proves: hooks/tests/redact-diff-fuzz.bats "reference is the merge base when a branch commit changes the lib", "reference is the merge base when only the working tree lib changed", "the reference subcommand prints one line"
  @integration
  Scenario: A changed library is compared with the merge base
    Given a branch whose lib bytes differ from the merge base with origin/main
    When the helper resolves the reference
    Then it prints reference=SHA rule=merge-base library_changed=True with the merge base sha
    And an uncommitted lib change on a branch with no commits gives the same rule

  # proves: hooks/tests/redact-diff-fuzz.bats "reference is the commit before the last lib change on a linear history", "reference is the first parent of a no-ff merge that changed the lib", "reference on the real history at 1d2a9fd is the parent of the last lib change", "a mode-only commit does not count as the last lib change"
  @integration
  Scenario: An unchanged library is compared with the parent of the last change on main
    Given the lib bytes equal the merge base
    When the helper resolves the reference
    Then it prints rule=parent-of-last-change library_changed=False and last_change=SHA
    And the reference is the first parent of the last commit that changed the lib bytes
    And a mode-only commit is not the last change

  # proves: hooks/tests/redact-diff-fuzz.bats "a candidate commit equal to the reference exits 2 with no worse line"
  @integration
  Scenario: The reference is never the candidate
    Given a candidate commit equal to the resolved reference
    When the helper runs a case
    Then it exits 2 with reference is identical to the candidate
    And stdout holds no worse= line

  # proves: hooks/tests/redact-diff-fuzz.bats "clone problem a: a depth 1 clone exits 2 and names git fetch --unshallow", "clone problem b: a missing origin/main exits 2 and names git fetch origin main", "clone problem c: unrelated histories exit 2 with no single merge base", "clone problem d: a criss-cross merge exits 2 with no single merge base", "clone problem e: a lib whose only commit is its first exits 2 with no earlier version", "clone problem e: a root commit that adds the lib exits 2 with no earlier version", "clone problem f: a base without the lib file exits 2 with no earlier version"
  @integration
  Scenario Outline: A clone that cannot give a reference exits 2 with the cure in stderr
    Given <clone>
    When the helper resolves the reference
    Then it exits 2
    And stderr holds <token>

    Examples:
      | clone                                          | token                    |
      | a depth 1 clone                                | git fetch --unshallow    |
      | no origin/main ref                             | git fetch origin main    |
      | unrelated histories                            | no single merge base     |
      | a criss-cross merge with 2 merge bases         | no single merge base     |
      | an unchanged lib added by the first commit     | no earlier version       |
      | a base without the lib file                    | no earlier version       |

  # proves: hooks/tests/redact-diff-fuzz.bats "a detached HEAD gives the same reference line as the branch", "a merge of origin/main and a commit outside origin uses the origin/main tip"
  @integration
  Scenario: A detached HEAD and a fork-shaped merge give the normal result
    Given a detached HEAD, or a merge commit of origin/main and a commit that is not in origin
    When the helper resolves the reference
    Then the line equals the branch line, or names the origin/main tip with rule=merge-base

  # proves: hooks/tests/redact-diff-fuzz.bats "this file holds no skip call", "gitleaks finds no leak in this bats file"
  @integration
  Scenario: A harness failure is red, never a skip
    Given the bats file
    Then it holds no skip call
    And the clean-run tests assert exit 0, so exit 2 reads not ok

  # proves: hooks/tests/redact-diff-fuzz.bats "a fuzz run prints the reference line first", "a case run prints the reference line first", "a planted weaker lib in the working tree is worse against the merge base", "a worse lib change already on main prints the not from this change line"
  @integration
  Scenario: The derived reference is shown and a weaker lib is caught
    Given any fuzz or case run
    Then the first stdout line is the reference line
    When the lib in the working tree loses its ghp_ rule
    Then the run uses the merge base, prints worse=N above 0 and exits 1
    When the weaker lib is already the last change on main
    Then the run also prints a not from this change line naming that commit

  # proves: hooks/tests/redact-diff-fuzz.bats "the fixture directory holds exactly the three bad libs", "fixture redact-cb0ab84 has its recorded blob id", "fixture redact-3854dc2 has its recorded blob id", "fixture redact-f1f1f8a has its recorded blob id", "no python file sits under the fixtures directory", "gitleaks finds no leak in the fixtures", "no fixture holds the gitleaks allow string", "failure mode 11 exits 2 when a fixture blob id differs"
  @integration
  Scenario: The bad libs are checked-in fixtures that are checked and inert
    Given three fixture files under hooks/tests/fixtures/redact-regress
    Then each has its recorded git blob id and the directory holds nothing else
    And no fixture is a python file, holds a leak or holds the gitleaks allow string
    And a fixture with one changed byte makes the helper exit 2 naming the file and blob id

  # proves: hooks/tests/redact-diff-fuzz.bats "no file under plugins or .github names the PR 217 ref"
  @integration
  Scenario: No PR ref is needed
    Given the named cases use checked-in fixtures
    Then no file under plugins or .github names the PR 217 ref

  # Note: the "clean with the candidate" runs compare redact.py with the
  # computed reference, so they can fail only after a change to redact.py. The
  # teeth runs are the failing side.

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
  # AC6b  : A planted piece inside an odd-named marker still counts as leaked; A marker named after a planted piece is not cut out
  # AC7   : The test files hold no real secret and the output does not echo planted pieces
  # AC1 (#240)  : No reference is stored and none can be given
  # AC2 (#240)  : A changed library is compared with the merge base
  # AC3, AC4 (#240) : An unchanged library is compared with the parent of the last change on main
  # AC5 (#240)  : The reference is never the candidate
  # AC6 (#240)  : A clone that cannot give a reference exits 2 with the cure in stderr
  # AC7 (#240)  : A detached HEAD and a fork-shaped merge give the normal result
  # AC8 (#240)  : A harness failure is red, never a skip
  # AC9 (#240)  : The derived reference is shown and a weaker lib is caught
  # AC12 (#240) : The bad libs are checked-in fixtures that are checked and inert
  # AC13 (#240) : No PR ref is needed
