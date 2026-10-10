# Coverage map for claude-plugins#211 — with gitleaks absent the worklog
# redacts with the built-in rules only and logs one note. Not executable: each
# Scenario carries a "# proves:" comment naming the bats test that proves it.

Feature: The worklog says when gitleaks is missing, and the built-ins cover the common shapes
  gitleaks is a second redaction layer on top of the built-in rules. When it is
  not usable the hook still stores and judges the row, and writes one
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

  # proves: hooks/tests/worklog-record.bats "a live key glued to another token leaves no raw key body"
  Scenario: A live key glued to another token leaves no raw key body
    Given a live key directly after a test key, a slack token, a webhook URL, or a short live key
    When the built-in rules run
    Then the raw key body is gone

  # proves: hooks/tests/worklog-record.bats "a short keyword value before a new token shape is not left raw"
  Scenario: A short keyword value before a new token shape is not left raw
    Given a keyword and a short value glued to a gitlab or slack token
    When the built-in rules run
    Then the short value is gone

  # proves: hooks/tests/worklog-record.bats "a token glued after another token leaves no raw token body"
  Scenario: A token glued after another token leaves no raw token body
    Given a shopify, digitalocean, or AWS key directly followed by another token
    When the built-in rules run
    Then the output is the two markers back to back

  # proves: hooks/tests/worklog-record.bats "running the built-ins twice on any two or three glued tokens gives the same text as once"
  Scenario: Running the built-in rules twice on glued tokens gives the same text as once
    Given every ordered pair and triple of token shapes and keyword fragments
    When the built-in rules run twice
    Then the second pass changes nothing

  # proves: hooks/tests/worklog-record.bats "a chain of glued tokens that needs more than 8 passes fails closed to one marker"
  Scenario: A chain of glued tokens that needs more than 8 passes fails closed to one marker
    Given a grafana token glued to a shopify token, repeated 7 times
    When the built-in rules run
    Then the output is exactly the glued-secrets marker

  # proves: hooks/tests/worklog-record.bats "a chain of glued tokens that settles within the cap is redacted token by token"
  Scenario: A chain of glued tokens that settles within the cap is redacted token by token
    Given a grafana token glued to a shopify token, repeated 6 times
    When the built-in rules run
    Then the output is the grafana and shopify markers, repeated 6 times

  # proves: hooks/tests/worklog-record.bats "a 200000 character chain of glued tokens uses under 10 seconds of CPU time"
  Scenario: A 200000 character chain of glued tokens uses under 10 seconds of CPU time
    Given a chain of glued tokens at least 200000 characters long
    When the built-in rules run
    Then the call uses under 10 seconds of CPU time

  # proves: hooks/tests/worklog-record.bats "two glued ghp tokens leave no raw token body"
  Scenario: Two glued ghp tokens leave no raw token body
    Given two different ghp bodies, or ghp then gho, at the string start, after a space and after an equals sign
    When the built-in rules run
    Then a marker is present, the text around the pair is kept, and no 8-character window of either body is left

  # proves: hooks/tests/worklog-record.bats "two glued aws key ids leave no raw key body"
  Scenario: Two glued AWS key ids leave no raw key body
    Given two different AKIA ids, or AKIA then ASIA, at the string start, after a space and after an equals sign
    When the built-in rules run
    Then a marker is present, the text around the pair is kept, and no 8-character window of either body is left

  # proves: hooks/tests/worklog-record.bats "three glued ghp tokens leave no raw token body"
  Scenario: Three glued ghp tokens leave no raw token body
    Given three ghp tokens with no separator
    When the built-in rules run
    Then no 8-character window of any body is left

  # proves: hooks/tests/worklog-record.bats "three glued aws key ids leave no raw key body"
  Scenario: Three glued AWS key ids leave no raw key body
    Given three AWS key ids with no separator
    When the built-in rules run
    Then no 8-character window of any body is left

  # proves: hooks/tests/worklog-record.bats "forty uppercase letters and digits with no key id prefix are kept"
  Scenario: A long uppercase run with no key id prefix is kept
    Given forty uppercase letters and digits that do not start with AKIA or ASIA
    When the built-in rules run
    Then the output equals the input

  # proves: hooks/tests/worklog-record.bats "a token then a space then a long word redacts only the token"
  Scenario: A word after a token and a space is kept
    Given a ghp token, a space, then a 20-character word
    When the built-in rules run
    Then only the token becomes a marker

  # proves: hooks/tests/worklog-record.bats "a token then a git remote path keeps the path"
  Scenario: A git remote path after a token is kept
    Given a ghp token directly followed by @github.com/owner/repository-name.git
    When the built-in rules run
    Then the output is the marker followed by the path

  # proves: hooks/tests/worklog-record.bats "known limit: a token then a 7 character tail keeps the tail"
  Scenario: A 7-character tail after a token is kept
    Given a ghp token directly followed by a 7-character tail
    When the built-in rules run
    Then the output is the marker followed by the tail

  # proves: hooks/tests/worklog-record.bats "a token then an 8 character tail sweeps the tail"
  Scenario: An 8-character tail after a token is swept
    Given a ghp token directly followed by an 8-character tail
    When the built-in rules run
    Then the output is the github-pat marker then the glued-secrets marker

  # proves: hooks/tests/worklog-record.bats "known limit: a word character glued in front of a token keeps the token raw"
  Scenario: A word character glued in front of a token keeps the token raw
    Given an npm token preceded by x and a digitalocean token preceded by an underscore
    When the built-in rules run
    Then the output equals the input

  # proves: hooks/tests/worklog-record.bats "known limit: an uppercase letter glued in front of an aws key id keeps the id raw"
  Scenario: An uppercase letter glued in front of an AWS key id keeps the id raw
    Given an AWS key id preceded by an uppercase letter
    When the built-in rules run
    Then the output equals the input

  # proves: hooks/tests/worklog-record.bats "known limit: with gitleaks, a word character glued in front of an npm token or aws key id still keeps it raw"
  Scenario: With gitleaks, a word character glued in front of an npm token or AWS key id keeps it raw
    Given an npm token preceded by x, an npm token preceded by FOO_, and an AWS key id preceded by A
    When the real gitleaks runs
    Then each output equals its input
    And the same npm token with nothing glued in front is redacted
    And a Shopify token preceded by x is redacted and holds no raw body

  # proves: hooks/tests/worklog-record.bats "known limit: a pulumi token in the middle of a URL path is not found by gitleaks"
  Scenario: A Pulumi token in the middle of a URL path is not found by gitleaks
    Given a Pulumi token in the middle of a URL path
    When the real gitleaks runs
    Then the output equals the input
    And the same token at the end of the URL path is redacted
    And the same token in a query string is redacted

  # proves: hooks/tests/worklog-record.bats "known limit: a body can settle where the same text as a quote hits the step cap"
  Scenario: A body can settle where the same text as a quote hits the step cap
    Given six grafana and shopify pairs followed by a glued ghp pair
    And six grafana and shopify pairs, a space, then two glued AWS key ids
    When each text runs as a quote and as a body with gitleaks absent
    Then each quote is exactly the glued-secrets marker
    And the first body is not that marker and ends with the github-pat marker then the glued-secrets marker
    And the second body holds no glued-secrets marker and ends with the shopify marker, a space, the aws marker
    And no body holds a raw token body

  # proves: hooks/tests/worklog-record.bats "known limit: a quote of a long glued chain is dropped by the hook and nothing raw is stored"
  Scenario: A quote of a long glued chain is dropped by the hook and nothing raw is stored
    Given a prompt of six grafana and shopify pairs followed by a glued ghp pair
    And a model reply whose one request quotes the raw chain
    When the hook runs with gitleaks absent
    Then the row is stored with no requests
    And neither the row nor the model stdin holds a raw ghp body

  # proves: hooks/tests/worklog-record.bats "six grafana shopify pairs then a glued ghp pair fail closed to one marker"
  Scenario: A settled chain plus a glued ghp pair fails closed
    Given six grafana and shopify pairs followed by a glued ghp pair
    When the built-in rules run
    Then the output is exactly the glued-secrets marker

  # proves: hooks/tests/worklog-record.bats "a 200000 character run of glued ghp tokens, glued aws key ids or uppercase letters uses under 10 seconds of CPU time each"
  Scenario: Long glued runs use under 10 seconds of CPU time
    Given 200000 characters of glued ghp tokens, of glued AWS key ids, and of uppercase letters
    When the built-in rules run on each
    Then each call uses under 10 seconds of CPU time

  # proves: hooks/tests/worklog-record.bats "a token directly after an open-ended body leaves no raw token body"
  Scenario: A token directly after an open-ended body leaves no raw token body
    Given npm then sk_test, huggingface then npm, ghp then ghp, or shopify then digitalocean
    When the built-in rules run
    Then the output starts with the first token's marker and no 8-character window of either body is left

  # proves: hooks/tests/worklog-record.bats "with gitleaks absent a glued ghp pair in the prompt is stored redacted"
  Scenario: Absent gitleaks: a glued ghp pair in the prompt is stored redacted
    Given gitleaks is not on PATH and a prompt with a glued ghp pair in a plain sentence
    When a turn is recorded
    Then the row keeps one request with a marker in its quote, the row and the model stdin hold no body, and the words around the pair reach the model

  # proves: hooks/tests/worklog-record.bats "with gitleaks absent a glued aws key id pair in the prompt is stored redacted"
  Scenario: Absent gitleaks: a glued AWS key id pair in the prompt is stored redacted
    Given gitleaks is not on PATH and a prompt with a glued AWS key id pair in a plain sentence
    When a turn is recorded
    Then the row keeps one request with a marker in its quote, the row and the model stdin hold no body, and the words around the pair reach the model

  # proves: hooks/tests/worklog-record.bats "with the real gitleaks a glued ghp pair in the prompt is stored redacted"
  Scenario: Real gitleaks: a glued ghp pair in the prompt is stored redacted
    Given the real gitleaks and a prompt with a glued ghp pair in a plain sentence
    When a turn is recorded
    Then the row keeps one request with a marker in its quote, and the row and the model stdin hold no body

  # proves: hooks/tests/worklog-record.bats "with the real gitleaks a glued aws key id pair in the prompt is stored redacted"
  Scenario: Real gitleaks: a glued AWS key id pair in the prompt is stored redacted
    Given the real gitleaks and a prompt with a glued AWS key id pair in a plain sentence
    When a turn is recorded
    Then the row keeps one request with a marker in its quote, and the row and the model stdin hold no body

  # proves: hooks/tests/worklog-record.bats "a gitleaks marker directly before a URL path is swept in the quote and the body alike"
  Scenario: A gitleaks marker before a URL path is swept in the quote and the body
    Given a Pulumi token that only gitleaks flags, once alone and once directly before a URL path
    When a turn is recorded with the real gitleaks
    Then the entry is stored and its quote holds the glued-secrets marker

  # proves: hooks/tests/worklog-record.bats "an aws-shaped run inside a longer token does not split the token"
  Scenario: An AWS-shaped run keeps a longer token whole
    Given an npm or gitlab token with an AWS-shaped run inside it
    When the built-in rules run
    Then the token gets its own single marker

  # proves: hooks/tests/worklog-record.bats "a long uppercase word that starts like an aws key id is redacted"
  Scenario: A long AKIA or ASIA word is redacted
    Given an uppercase word of 20 or more characters that starts with ASIA
    When the built-in rules run
    Then the word gets the aws-access-key marker

  # proves: hooks/tests/worklog-record.bats "an aws-shaped run inside a blocked token does not split the token"
  Scenario: An AWS-shaped run inside a still-blocked token keeps the token whole
    Given a Shopify token directly followed by a gitlab or npm token that holds an AWS-shaped run
    When the built-in rules run
    Then each token gets its own single marker and the run is not cut out of it

  # proves: hooks/tests/worklog-record.bats "a stubbed gitleaks marker directly before a URL path is swept in the quote and the body alike"
  Scenario: A stubbed gitleaks marker before a URL path is swept in the quote and the body
    Given a Pulumi token that a stubbed gitleaks flags, once alone and once directly before a URL path
    When a turn is recorded
    Then the entry is stored and its quote holds the glued-secrets marker

  # proves: hooks/tests/worklog-record.bats "swept and collapsed outputs are stable under a second run"
  Scenario: Swept and collapsed outputs are stable under a second run
    Given a glued ghp pair, a glued AWS key id pair, and a long chain of token pairs
    When the built-in rules run twice
    Then the second run changes nothing

  # proves: hooks/tests/worklog-record.bats "with gitleaks, a short tail after a glued aws key id run is not left raw"
  Scenario: With gitleaks, a short tail after a glued AWS key id run is not left raw
    Given a value that holds two AWS key ids in a row followed by a short mixed-case tail
    When the text is redacted with the real gitleaks
    Then the short tail is not in the output

  # proves: hooks/tests/worklog-record.bats "with gitleaks, a short piece in front of an aws key id run is not left raw"
  Scenario: With gitleaks, a short piece in front of an AWS key id run is not left raw
    Given a Stripe key and a short piece directly in front of an AWS key id run
    When the text is redacted with the real gitleaks
    Then the short piece is not in the output
