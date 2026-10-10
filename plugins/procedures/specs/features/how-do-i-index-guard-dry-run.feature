# Coverage map for claude-plugins#231 — how-do-i.sh accepted any non-empty
# index.txt, so a whitespace-only or junk index (a proxy error page, a torn
# write) passed the size check and ended as a confident NOT FOUND from a stage-1
# call that never saw a record. A usable index now holds at least one line
# shaped "<digits> :: ". The refusal hint depends on the mode, and --dry-run
# --json makes no temp file so a signal cannot leak one. Not executable: each
# Scenario carries a "# proves:" comment naming the bats test or command that
# proves it. Bats names are in hooks/tests/how-do-i.bats under plugins/procedures/.

Feature: how-do-i refuses an index without a record, and --dry-run leaves nothing behind
  A run never asks the selector to choose from an index it cannot read a record
  from. The error names the one next step that works in the mode the user is in.

  # proves: how-do-i.bats "a whitespace-only index.txt aborts a real run: exit 1, no record on stderr, zero CLI calls, no NOT FOUND"
  @integration
  Scenario: A whitespace-only index aborts a real run
    Given index.txt holds only spaces, tabs and newlines
    When a real run starts
    Then it exits 1 with "no record" on stderr and no NOT FOUND on stdout
    And the stub CLI is called 0 times

  # proves: how-do-i.bats "a whitespace-only index.txt aborts --dry-run: exit 1, no record on stderr, empty stdout"
  @integration
  Scenario: A whitespace-only index aborts --dry-run
    Given index.txt holds only spaces, tabs and newlines
    When --dry-run runs
    Then it exits 1 with "no record" on stderr and an empty stdout

  # proves: how-do-i.bats "an index.txt with no record line (HTML error page) is refused with and without --dry-run", "an index.txt whose only line starts with a space is refused with and without --dry-run", "an index.txt whose only line has no spaces around :: is refused with and without --dry-run"
  @integration
  Scenario Outline: Text without a record line is refused in both modes
    Given index.txt holds "<text>" and no line matches "^[0-9]+ :: "
    When the script runs with and without --dry-run
    Then each exits 1 with "no record" on stderr, no NOT FOUND, and 0 stub calls

    Examples:
      | text                          |
      | <html>502 Bad Gateway</html>  |
      |  1 :: x                       |
      | 1::x                          |

  # proves: how-do-i.bats "--dry-run on a bad index names one full next step: without --dry-run and with --rebuild", "following the --dry-run hint rebuilds the index and answers"
  @integration
  Scenario: The --dry-run hint is one step that works
    Given a zero-byte, whitespace-only or no-record index.txt
    When --dry-run runs
    Then it exits 1 and stderr names "without --dry-run and with --rebuild", not "re-run with --rebuild"
    And running that step against a root with one record exits 0, rebuilds index.txt, and calls the stub

  # proves: how-do-i.bats "a bad index without --dry-run exits 1 and the hint names --rebuild", "a bad index without --dry-run is repaired by --rebuild and the stub answer reaches stdout"
  @integration
  Scenario: The real-run hint is --rebuild
    Given a zero-byte, whitespace-only or no-record index.txt
    When a real run starts
    Then it exits 1 and stderr names --rebuild
    And adding --rebuild exits 0, rebuilds index.txt, and prints the stub answer

  # proves: how-do-i.bats "SIGTERM during --dry-run --json exits 143, prints no complete JSON and leaves no how-do-i entry in TMPDIR", "SIGHUP during --dry-run --json exits 129, prints no complete JSON and leaves no how-do-i entry in TMPDIR"
  @integration
  Scenario Outline: A signal during the --dry-run --json render leaves no temp file
    Given a jq that waits 2 s on every call and a marker written when it starts
    When the script gets <signal> after the marker exists
    Then it exits <code>, stdout is not a complete JSON object, and TMPDIR holds no how-do-i entry

    Examples:
      | signal  | code |
      | SIGTERM | 143  |
      | SIGHUP  | 129  |

  # proves: how-do-i.bats "a failing jq render under --dry-run --json exits 1 with empty stdout, could not render on stderr and no how-do-i entry in TMPDIR"
  @integration
  Scenario: A failed render prints nothing
    Given a jq that prints a complete JSON object and then exits 1
    When --dry-run --json runs
    Then it exits 1 with an empty stdout and "could not render" on stderr
    And TMPDIR holds no how-do-i entry

  # proves: how-do-i.bats "a normal --dry-run leaves no how-do-i entry in TMPDIR", "a normal --dry-run --json leaves no how-do-i entry in TMPDIR"
  @integration
  Scenario: A normal --dry-run leaves nothing behind
    When --dry-run and --dry-run --json each succeed
    Then TMPDIR holds no how-do-i entry after either

  # proves: how-do-i.bats "--dry-run --json system prompt is byte-equal to the real call on a 3000-line index", "--dry-run --json system prompt is byte-equal to the real call on a 4 KB multibyte line, offset 0", "... offset 1", "... offset 2"
  @integration
  Scenario: The dry-run system prompt equals the real one byte for byte
    Given a 3000-line index, or a line over 4096 bytes of a multibyte character at offsets 0, 1 and 2
    When --dry-run --json and a real run use the same index
    Then .stage1_system_prompt equals the --system-prompt-file the stub recorded, byte for byte

  # proves: how-do-i.bats "an index with one record line between blank lines is accepted", "an index whose description holds :: is accepted", "an index with an empty description is accepted", "an index with CRLF line ends is accepted", "an index with one record line plus junk lines is accepted"
  @integration
  Scenario: Indexes with a record line are accepted
    Given one record between blank lines, a description holding " :: ", an empty description, CRLF line ends, or a record plus junk
    When --dry-run runs
    Then it exits 0 and prints the record line

  # proves: how-do-i.bats "an empty index.txt aborts the run: exit 1, stderr says empty, zero CLI calls, no NOT FOUND", "--dry-run on an empty index.txt aborts the same way" (assertions unchanged)
  @integration
  Scenario: A zero-byte index still reports empty
    Given a zero-byte index.txt
    When the script runs with and without --dry-run
    Then each exits 1 with "empty" on stderr

  # proves: how-do-i.bats "no file under plugins/procedures holds the old size-only guard message", "neither the script nor the skills tell a --dry-run user to put --rebuild on the same command", "--help tells a --dry-run user to re-run without --dry-run and with --rebuild"
  @unit
  Scenario: No text keeps the old message or the old advice
    When plugins/procedures, the script header, the skills and --help are searched
    Then the old message is gone and no text puts --rebuild on a --dry-run command
    And --help names "without --dry-run and with --rebuild"

  # proves: command form (use-proof, real CLI, temp copy of the real index): a question with a known record run with the real claude exits 0 with a non-empty stdout and no "NOT FOUND"; quote the command, exit code and stdout head
  @e2e
  Scenario: A valid copy of the real index still answers
    Given a temp copy of the real index
    When a question with a known record runs
    Then it exits 0 with a non-empty stdout and no NOT FOUND

  # proves: command form (use-proof): the same command on a whitespace-only temp index, with HOWDOI_CLAUDE_BIN set to a logging wrapper that runs the real claude; quote the exit code, stderr and `wc -l` of the log
  @e2e
  Scenario: A whitespace-only index never reaches the real CLI
    Given a whitespace-only temp index and a logging wrapper around the real claude
    When the question runs
    Then it exits 1 with "no record" on stderr
    And the wrapper log has 0 lines

# --- AC Coverage Map ---
# AC1 -> A whitespace-only index aborts a real run
# AC2 -> A whitespace-only index aborts --dry-run
# AC3 -> Text without a record line is refused in both modes
# AC4 -> The --dry-run hint is one step that works
# AC5 -> The real-run hint is --rebuild
# AC6 -> A signal during the --dry-run --json render leaves no temp file
# AC7 -> A failed render prints nothing
# AC8 -> A normal --dry-run leaves nothing behind
# AC9 -> The dry-run system prompt equals the real one byte for byte
# AC10 -> Indexes with a record line are accepted
# AC11 -> A zero-byte index still reports empty
# AC12 -> No text keeps the old message or the old advice
# AC13 -> this file (one scenario or more per AC1 to AC12); use-proof: A valid copy of the real index still answers; A whitespace-only index never reaches the real CLI
