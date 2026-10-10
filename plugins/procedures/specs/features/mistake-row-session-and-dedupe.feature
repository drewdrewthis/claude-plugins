# Coverage map for claude#41 (procedures side) — judge transcripts were read by
# the librarian as sessions, and log-record.sh had no session or duplicate guard,
# so one mistake was logged twice under a wrong id. Not executable: each
# Scenario carries a "# proves:" comment naming the bats test under
# plugins/procedures/hooks/tests/.

Feature: Mistake rows carry the session and refuse a duplicate
  The librarian skips worklog judge transcripts. log-record.sh mistake takes
  --source <id>:<a>-<b>, fills the session from it, and refuses a second row for
  the same session and an overlapping or touching line range in any store root.

  # proves: librarian-batch.bats "a worklog judge transcript is never issued and gets no cursor", "a judge transcript's text is absent from the batch"
  @integration
  Scenario: A judge transcript is skipped
    Given a transcript whose first line is the judge's enqueue record
    When the librarian batch is built
    Then it is absent from the batch text and the manifest and has no cursor

  # proves: librarian-batch.bats "a session transcript holding that text on a later line is still issued"
  @integration
  Scenario: A session that quotes the judge text later is still issued
    Given a transcript that holds the enqueue text on a later line
    When the librarian batch is built
    Then it is issued

  # proves: librarian-batch.bats "an empty transcript file does not abort the batch", "a transcript whose first line does not parse does not abort the batch"
  @integration
  Scenario: An empty or garbled transcript does not abort the batch
    Given an empty file and a file whose first line does not parse
    When the librarian batch is built
    Then the other transcripts are still issued

  # proves: log-record.bats "--source fills the session and stores the source", "an explicit --session wins over the session in --source"
  @integration
  Scenario: --source sets the session
    Given a call with --source s1:653-670
    When the row is appended
    Then session is s1 and source is s1:653-670, and an explicit --session wins

  # proves: log-record.bats "a --source of the wrong shape exits non-zero", "a --source of the wrong shape appends nothing"
  @integration
  Scenario: A malformed --source is refused
    Given a --source that is not <id>:<int>-<int> with a <= b
    When the call runs
    Then it exits non-zero and appends nothing

  # proves: log-record.bats "with neither flag the row is appended with an empty session", "with neither flag stderr says no session"
  @integration
  Scenario: No session flag still appends, with a note
    Given a call with neither --source nor --session
    When the row is appended
    Then session is empty and stderr says no session

  # proves: log-record.bats "the same session and range again appends nothing and exits 0", "the duplicate note names the session, the range and the matched row's ts"
  @integration
  Scenario: The same session and range is a duplicate
    Given a row for s1:653-670
    When the same --source is given again
    Then nothing is appended, the exit is 0, and stderr names duplicate, the session, the range and the matched ts

  # proves: log-record.bats "an overlapping range in the same session is a duplicate", "a range touching at one line in the same session is a duplicate", "the same range with another category is still a duplicate"
  @integration
  Scenario: Overlapping, touching and re-categorised ranges are duplicates
    Given a row for s1:653-670
    When 660-675, 670-675 or the same range with another category is given
    Then nothing is appended

  # proves: log-record.bats "the same range in another session appends", "a range that does not touch, in the same session, appends", "rows with no source key never match"
  @integration
  Scenario: Other sessions, distant ranges and source-less rows do not match
    Given a row for s1:653-670 and a source-less row for s1
    When another session, a distant range, or the same session is given
    Then the row is appended

  # proves: log-record.bats "a match in another store root's mistakes.jsonl is a duplicate"
  @integration
  Scenario: A match in another store root counts
    Given the first row sits in another root's mistakes.jsonl from CODEX_STORE_ROOTS
    When an overlapping --source is given
    Then nothing is appended

  # proves: log-record.bats "a refused duplicate leaves the earlier bytes unchanged", "an accepted append leaves the earlier bytes unchanged"
  @integration
  Scenario: Earlier rows are never rewritten
    Given a file with rows
    When a call is refused or accepted
    Then the earlier bytes are identical

  # proves: log-record.bats "ten parallel identical calls leave one new row", "after ten parallel calls every line parses as JSON"
  @integration
  Scenario: Ten parallel identical calls leave one row
    Given ten parallel calls with one --source
    When all finish
    Then exactly one row is new and every line parses

  # proves: skill-surface.bats "the librarian's mistake write row passes --source"
  @unit
  Scenario: The librarian brief passes --source
    Given agents/librarian.md
    When its mistake write row is read
    Then it contains --source

  # proves: commit-records.bats "AC11: a commit that adds a mistake row with a source key is accepted", "AC11: a call with only the old flags appends to a file that already holds source rows"
  @integration
  Scenario: The gate accepts source rows and old-flag calls still append
    Given a mistakes.jsonl holding rows with a source key
    When the gate commits a new source row, or the old flags append one
    Then both succeed

# --- AC Coverage Map ---
# AC2 -> A judge transcript is skipped; A session that quotes the judge text later is still issued; An empty or garbled transcript does not abort the batch
# AC3 -> --source sets the session; A malformed --source is refused; No session flag still appends, with a note
# AC4 -> The same session and range is a duplicate; Overlapping, touching and re-categorised ranges are duplicates; Other sessions, distant ranges and source-less rows do not match; A match in another store root counts; Earlier rows are never rewritten; Ten parallel identical calls leave one row
# AC11 -> The gate accepts source rows and old-flag calls still append
# (A4, no AC number) -> The librarian brief passes --source
