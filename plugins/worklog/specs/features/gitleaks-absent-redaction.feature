# Coverage map for claude-plugins#211 — with gitleaks absent the worklog
# redacted with the built-in rules only, and said nothing. Not executable: each
# Scenario carries a "# proves:" comment naming the bats test that proves it.

Feature: The worklog says when gitleaks is missing, and the built-ins cover the common shapes
  gitleaks is a second redaction layer on top of the built-in rules. When it is
  not usable the hook still stores and judges the row, but it now writes one
  gitleaks-absent note per session to the fail-open log, and the built-in rules
  cover the common gitleaks-only token shapes so the gap is small.

  # proves: hooks/tests/worklog-record.bats "with gitleaks absent one gitleaks-absent note is logged, stored literally"
  Scenario: Absent gitleaks leaves one note, stored as the closed-set why
    Given gitleaks is not on PATH
    When a turn is recorded
    Then the fail-open log holds one line with why gitleaks-absent, with no unrecognized: prefix

  # proves: hooks/tests/worklog-record.bats "the gitleaks-absent note is attributed to this writer and this session"
  Scenario: The note names the writer and the session
    Given gitleaks is not on PATH
    When a turn is recorded
    Then the line has gate worklog-record and the session id of the turn

  # proves: hooks/tests/worklog-record.bats "a second turn of the same session adds no gitleaks-absent note"
  Scenario: The note is written once per session
    Given gitleaks is not on PATH and turn 1 of session S is recorded
    When turn 2 of session S is recorded
    Then the log still holds exactly one gitleaks-absent line

  # proves: hooks/tests/worklog-record.bats "the first turn of a different session adds one more gitleaks-absent note"
  Scenario: A new session gets its own note
    Given the note was written for session S
    When the first turn of session S2 is recorded
    Then the log holds one gitleaks-absent line for S and one for S2

  # proves: hooks/tests/worklog-record.bats "a gitleaks file without the execute bit gives the same note as no file"
  Scenario: A non-executable gitleaks counts as absent
    Given a gitleaks file on PATH without the execute bit
    When a turn is recorded
    Then exactly one gitleaks-absent line is logged

  # proves: hooks/tests/worklog-record.bats "with gitleaks absent and the fail-open log unwritable the row is still stored"
  Scenario: An unwritable log never loses the row
    Given gitleaks is not on PATH and the fail-open log cannot be written
    When a turn is recorded
    Then the hook exits 0 and the row is stored

  # proves: hooks/tests/worklog-record.bats "with gitleaks absent the row is judged"
  Scenario: Absent gitleaks does not skip judgment
    Given gitleaks is not on PATH
    When a turn is recorded
    Then the stored row holds the judged request

  # proves: hooks/tests/worklog-record.bats "with gitleaks absent and the model unavailable exactly one gitleaks-absent is logged"
  Scenario: Absent gitleaks and an unavailable model log one gitleaks-absent
    Given gitleaks is not on PATH and the model returns nothing
    When a turn is recorded
    Then exactly one gitleaks-absent line is logged

  # proves: hooks/tests/worklog-record.bats "with gitleaks absent and the model unavailable exactly one judgment-unavailable is logged"
  Scenario: Absent gitleaks and an unavailable model log one judgment-unavailable
    Given gitleaks is not on PATH and the model returns nothing
    When a turn is recorded
    Then exactly one judgment-unavailable line is logged

  # proves: hooks/tests/worklog-record.bats "with a working gitleaks no gitleaks-absent note is logged"
  Scenario: A working gitleaks writes no note
    Given a gitleaks that runs
    When a turn is recorded
    Then no gitleaks-absent line is logged

  # proves: hooks/tests/worklog-record.bats "every why this hook emits survives gate-failopen's closed set unchanged"
  Scenario: gitleaks-absent is in the closed set of reasons
    Given the fail-open recorder
    When it is asked to record gitleaks-absent
    Then the stored why is gitleaks-absent

  # proves: hooks/tests/worklog-record.bats "every listed token shape redacts to exactly its own marker"
  Scenario: Each listed token shape redacts to its marker
    Given a token of each shape in the marker table
    When the built-in rules run on text holding it
    Then the text is the same with the token replaced by its marker

  # proves: hooks/tests/worklog-record.bats "a longer token of every listed shape leaves no raw tail"
  Scenario: A longer token leaves no raw tail
    Given a token of each shape in the marker table with extra characters appended
    When the built-in rules run on text holding it
    Then the text is the same with the whole token replaced by its marker

  # proves: hooks/tests/worklog-record.bats "running the built-ins twice on every listed token gives the same text as once"
  Scenario: Redaction is idempotent
    Given text holding every listed token shape
    When the built-in rules run twice
    Then the result equals the result of one run

  # proves: hooks/tests/worklog-record.bats "the real gitleaks flags every fake in the table, so the fakes are realistic"
  Scenario: The fake tokens are shapes the real gitleaks flags
    Given the real gitleaks binary
    When it scans each fake token
    Then it reports at least one finding for each

  # proves: hooks/tests/worklog-record.bats "ordinary code text that resembles a short prefix comes back unchanged"
  Scenario: Code text that looks like a prefix is not redacted
    Given npm_config_registry, hf_hub_download(repo_id), SG.fields, a short eyJ string, lin_api_version, dp.pt.x, glpat-short, hvs.short and a backslash before task_test_ConfigurationSettings
    When the built-in rules run
    Then each comes back unchanged

  # proves: hooks/tests/worklog-record.bats "a stripe key right after a literal backslash-n still redacts"
  Scenario: A key right after a JSON escape is still redacted
    Given a stripe live key directly after a literal backslash and n
    When the built-in rules run
    Then the key is replaced by its marker and the backslash-n is kept

  # proves: hooks/tests/worklog-record.bats "a stripe live key right after KEY_ or a literal equals sign still redacts"
  Scenario: A live stripe key is redacted after an identifier or an escaped equals sign
    Given a stripe live key directly after KEY_, and directly after a literal backslash-u equals sign
    When the built-in rules run
    Then the raw key body is gone and the stripe marker is present

  # proves: hooks/tests/worklog-record.bats "with gitleaks absent an npm token in the prompt is stored as its marker"
  Scenario: An npm token in the prompt is stored redacted
    Given gitleaks is not on PATH and an npm token in the prompt
    When a turn is recorded
    Then the row holds npm-token and not the token

  # proves: hooks/tests/worklog-record.bats "with gitleaks absent an npm token in the prompt is not in the stdin the model receives"
  Scenario: The model never sees the npm token
    Given gitleaks is not on PATH and an npm token in the prompt
    When a turn is recorded
    Then the model stdin does not hold the token

  # proves: hooks/tests/worklog-record.bats "with gitleaks absent a model-written text holding an npm token is stored redacted"
  Scenario: A model-written npm token is stored redacted
    Given gitleaks is not on PATH and a model reply that holds an npm token
    When a turn is recorded
    Then the stored text holds the marker and not the token

  # proves: hooks/tests/worklog-record.bats "a gitleaks-only secret in the prompt is redacted in the stored row"
  Scenario: The gitleaks-only fixture is a Pulumi token
    Given a Pulumi token that no built-in rule matches and a gitleaks finding for it
    When a turn is recorded
    Then the row holds pulumi-api-token and not the token
