# Coverage map for claude#41 (worklog side) — the judge's own `claude -p` run
# left a session transcript for the librarian to read, and a Discord turn's
# <channel ...> wrapper ate the 200-char candidate cap so the owner's words
# never reached the model or the stored quote. Not executable: each Scenario
# carries a "# proves:" comment naming the bats test in
# hooks/tests/worklog-record.bats under plugins/worklog/.

Feature: The worklog judge leaves no transcript and quotes the owner, not the wrapper
  The judge call saves no session. A user turn wrapped in a <channel ...> tag is
  cut down to the owner's text before redaction and the 200-char cap.

  # proves: worklog-record.bats "the judge call is made with --no-session-persistence"
  @integration
  Scenario: The judge call saves no transcript
    Given a recorded turn and a stub claude that logs its arguments
    When the hook calls the judge
    Then the arguments include --no-session-persistence

  # proves: worklog-record.bats "a wrapped 300-char message reaches the model starting at the owner's first character"
  @integration
  Scenario: The candidate body starts at the owner's first character
    Given a user turn that is a channel wrapper around a 300-char message
    When the candidates are built
    Then the body shown to the model starts with the owner's first character

  # proves: worklog-record.bats "a wrapped 300-char message with a 150-char quote span stores a 120-char quote", "a stored quote from a wrapped message holds no channel tag"
  @integration
  Scenario: A long quote span from a wrapped message is capped at 120 with no tag
    Given a wrapped 300-char message and a request whose quote span is 150 chars
    When the row is stored
    Then the quote is 120 chars and holds no <channel

  # proves: worklog-record.bats "a wrapped 60-char message stores exactly those 60 chars", "a stored quote from a wrapped message holds no closing channel tag"
  @integration
  Scenario: A short wrapped message is quoted whole, without the closing tag
    Given a wrapped 60-char message
    When the row is stored
    Then the quote equals those 60 chars and holds no </channel>

  # proves: worklog-record.bats "a 256-char opening tag gives the same stored quote"
  @integration
  Scenario: A 256-char opening tag changes nothing
    Given a 60-char message in a wrapper whose opening tag is 256 chars
    When the row is stored
    Then the quote equals the 60 chars

  # proves: worklog-record.bats "a secret inside the wrapped text is stored redacted"
  @integration
  Scenario: A secret in the wrapped text is redacted in the quote
    Given a wrapped message that pastes a key
    When the row is stored
    Then the quote holds the redaction marker and not the key

  # proves: worklog-record.bats "no tag attribute reaches the stored row"
  @integration
  Scenario: No tag attribute is stored
    Given a wrapped message with chat_id and user_id attributes
    When the row is stored
    Then the row holds neither chat_id= nor user_id=

  # proves: worklog-record.bats "a wrapper with empty text gives no request entry", "a wrapper with empty text logs no error", "a wrapper with empty text shows the model no tag attribute"
  @integration
  Scenario: A wrapper with empty text gives no request and no error
    Given a channel wrapper with empty text
    When the turn is recorded
    Then there is no request entry, no fail-open line, and no tag attribute shown to the model

  # proves: worklog-record.bats "a channel tag in the middle of the text is left unchanged"
  @integration
  Scenario: A channel tag that is not at the start is left alone
    Given a user line with "<channel" in the middle of the text
    When the row is stored
    Then the quote is unchanged

  # proves: worklog-record.bats "an opening tag with no closing tag is still removed from the candidate body"
  @integration
  Scenario: An unclosed opening tag is still removed; A record of two wrapped text blocks is unwrapped per block
    Given a user turn with an opening channel tag and no closing tag
    When the candidates are built
    Then the body shown to the model is the text after the tag

  # proves: worklog-record.bats "a record of two wrapped text blocks shows the model both texts and no channel tag"
  @integration
  Scenario: A record of two wrapped text blocks is unwrapped per block
    Given a user record with two text blocks, each a wrapped message
    When the candidates are built
    Then the body shown to the model holds both texts and no channel tag

  # proves: worklog-record.bats "a plain user line stores the same quote as before"
  @integration
  Scenario: A plain user line is unchanged
    Given a user line with no channel tag
    When the row is stored
    Then the quote equals the line

# --- AC Coverage Map ---
# AC1 -> (real-run evidence, not a bats test; the flag itself) The judge call saves no transcript
# AC9 -> The candidate body starts at the owner's first character; A long quote span from a wrapped message is capped at 120 with no tag; A short wrapped message is quoted whole, without the closing tag; A 256-char opening tag changes nothing; A secret in the wrapped text is redacted in the quote; No tag attribute is stored; A wrapper with empty text gives no request and no error
# AC10 -> A plain user line is unchanged; A channel tag that is not at the start is left alone; An unclosed opening tag is still removed
