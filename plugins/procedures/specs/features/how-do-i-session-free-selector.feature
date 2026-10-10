# Coverage map for claude-plugins#198 — how-do-i.sh stage 1 resumed a stored
# session primed with the index, so a rewriting proxy could compact that history
# and the selector collapsed to false NOT FOUNDs. Stage 1 is now session-free:
# the select instruction and the index ride in --system-prompt-file, the question
# is the only user message, and no session state is written. Not executable: each
# Scenario carries a "# proves:" comment naming the bats test or command that
# proves it. Bats names are in hooks/tests/how-do-i.bats under plugins/procedures/.

Feature: Stage 1 of how-do-i is session-free
  Each stage-1 call stands alone. Nothing is resumed, so no history exists for a
  proxy or a compaction to rewrite, and a run never depends on a prior run.

  # proves: how-do-i.bats "stage 1 never carries --resume, even with a legacy session.id in the index dir", "stage 1 passes --system-prompt-file", "stage 1 passes --no-session-persistence", "the system prompt file holds the select instruction", "the system prompt file holds every line of index.txt", "stage 1 stdin is the question", "stage 1 stdin carries no Index: block", "two consecutive runs with an unchanged index send byte-identical system prompt files", "the second of two consecutive runs does not carry --resume", "no call ever carries --resume, across a stage-1 retry"
  @integration
  Scenario: Stage 1 passes the index as a system prompt file and the question as stdin
    Given an index and a stub CLI that copies the --system-prompt-file at call time
    When two consecutive runs ask different questions
    Then no stage-1 call carries --resume
    And each carries --system-prompt-file and --no-session-persistence
    And the file holds the select instruction and every line of index.txt
    And stdin is "Question:" and the question, with no Index: block
    And the two files are byte-identical

  # proves: how-do-i.bats "on attempt 2 the retry reminder is appended to stdin", "on attempt 2 stdin still starts with the question", "on attempt 2 the system prompt file is byte-identical to attempt 1", "on attempt 2 the system prompt path is the same as attempt 1"
  @integration
  Scenario: A stage-1 retry changes stdin only
    Given a stage-1 reply that is prose, not a JSON array
    When the script retries once
    Then the reminder text is appended to stdin on attempt 2
    And the system prompt file is byte-identical to attempt 1

  # proves: how-do-i.bats "the CLI is called with CLAUDE_CODE_DISABLE_CLAUDE_MDS=1"
  @integration
  Scenario: The model calls skip the user's instruction files
    When the script calls the CLI
    Then CLAUDE_CODE_DISABLE_CLAUDE_MDS is 1 in the CLI's environment

  # proves: how-do-i.bats "a successful run leaves no session.id in the index dir", "a successful run leaves no session.fingerprint in the index dir", "a legacy session.id is deleted on a normal run", "a legacy session.fingerprint is deleted on a normal run", "a legacy session.id is deleted on a --rebuild run", "a legacy session.fingerprint is deleted on a --rebuild run", "a legacy session id never reaches the CLI args", "--dry-run leaves a legacy session.id in place", "--dry-run leaves a legacy session.fingerprint in place"; command form: a real run in a scratch index dir seeded with session.id, then `ls` of the dir
  @integration
  Scenario: No session state is written and legacy state is removed
    Given session.id and session.fingerprint left by 0.17.3 or older
    When a normal run or a --rebuild run finishes
    Then neither file exists and the old id never reached the CLI args
    But a --dry-run leaves both files in place

  # proves: command form (live use-proof, drew-sweatshop): quote `env | grep -E 'HTTPS_PROXY|ROLLING_CONTEXT_TRIGGER'` with the proxy on; build an index from a scratch copy of the real record roots (at least 1400 records); run `how-do-i.sh --json --question "<q>"` 8 times in a row, each within 5 minutes of the last — 6 off-topic questions, then "How do I merge a pull request safely with squash and match-head-commit", then "How do I file a GitHub issue"; quote the exit code, not_found and resolved_ids of each run
  @e2e
  Scenario: Eight consecutive runs behind the proxy keep selecting correctly
    Given the rolling-context proxy is on and a real index of at least 1400 records
    When 8 consecutive how-do-i.sh --json runs start within 5 minutes of each other
    Then each off-topic run exits 0 with not_found true
    And each on-topic run exits 0 with a non-empty answer
    And its resolved_ids hold the matching procedure id

  # proves: command form (live use-proof): the same 8 runs as above; quote stages.select.usage per run for runs 2 to 8 — cache_read_input_tokens at least 80000 and cache_creation_input_tokens at most 5000
  @e2e
  Scenario: Runs 2 to 8 hit the prompt cache
    Given the 8 runs of the use-proof scenario
    When the stage-1 usage of runs 2 to 8 is read
    Then cache_read_input_tokens is at least 80000
    And cache_creation_input_tokens is at most 5000

  # proves: how-do-i.bats "an empty stage-1 selection exits 0 with a NOT FOUND answer and never invokes compile-records.sh", "--json on an empty selection reports not_found with empty selection arrays and a null answer stage", "stage 1 prose reply triggers exactly one retry, then a loud non-zero failure", "stage 1 is_error true fails the run loudly and non-zero, with no retry consumed" (assertions unchanged)
  @integration
  Scenario: The selection contract is unchanged
    Given a stage-1 reply of "[]", a prose reply, or an is_error reply
    When the script runs
    Then an empty selection prints NOT FOUND, exits 0, and --json has not_found true
    And a prose reply retries exactly once, then exits 1
    And an is_error reply exits 1 with no retry

  # proves: how-do-i.bats "a null structured_output reply on call 1: call 1 carries --json-schema", "a null structured_output reply on call 1: call 2 drops --json-schema", "a null structured_output reply: both calls carry --system-prompt-file"
  @integration
  Scenario: A gateway that drops --json-schema falls back to the text contract
    Given reply 1 has structured_output null and result "null"
    When the script retries
    Then call 1 carries --json-schema and call 2 does not
    And both calls carry --system-prompt-file

  # proves: how-do-i.bats "--timing prints a stage=select line labeled mode=n/a", "--json reports stages.select.mode as n/a", "--dry-run plain text prints a stage-1 SYSTEM prompt section with the instruction", "--dry-run plain text prints the Index in the stage-1 system prompt section", "--dry-run plain text reports mode: n/a", "--dry-run --json carries stage1_system_prompt with the instruction and the index", "--dry-run --json stage1_prompt is the question with no Index: block", "--dry-run --json reports mode n/a", "--dry-run --json prints a JSON object with both prompts and makes zero calls" (still carries stage2_prompt_template), "--dry-run makes zero calls to the stub and prints both prompts (plain text)"
  @integration
  Scenario: The output contract reports mode n/a and shows the system prompt in --dry-run
    When --timing, --json and --dry-run run
    Then the stage=select line and stages.select.mode read n/a
    And --dry-run prints the stage-1 system prompt and the stage-1 user prompt, with 0 CLI calls
    And --dry-run --json carries stage1_system_prompt, stage1_prompt, mode "n/a" and stage2_prompt_template

  # proves: how-do-i.bats "--help output names none of session.id, session.fingerprint, warm, --resume", "the header comment names none of session.id, session.fingerprint, warm, --resume"
  @unit
  Scenario: Help and header no longer describe sessions
    When --help prints and the header comment is read up to `set -uo pipefail`
    Then neither contains session.id, session.fingerprint, warm or --resume

  # proves: how-do-i.bats "a non-zero stage-1 CLI exit fails the run with exit 1", "a non-zero stage-1 CLI exit surfaces the CLI's stderr text on stderr", "a non-zero stage-1 CLI exit never prints NOT FOUND on stdout", "with orwrap on PATH and raw claude failing, the run exits 1 after exactly 2 calls", "the orwrap retry reuses the same --system-prompt-file path as the raw call", "the second failing call goes through orwrap claude", "a raw-claude spawn failure retries the attempt THROUGH the orwrap wrapper, not raw claude again"; command form: `HOWDOI_CLAUDE_BIN=false how-do-i.sh --question q` with its quoted exit code and stderr
  @integration
  Scenario: A rejected CLI call fails loudly, not as NOT FOUND
    Given the stage-1 CLI exits non-zero
    When the script runs
    Then it exits 1 and stderr holds the CLI's stderr text
    And stdout has no NOT FOUND
    And with orwrap on PATH it retries once through orwrap claude, then exits 1 after exactly 2 calls with the same system prompt path

  # proves: how-do-i.bats "a successful run leaves no how-do-i.* work dir under TMPDIR", "a failed run leaves no how-do-i.* work dir under TMPDIR", "stage 1 passes --no-session-persistence", "stage 2 carries --no-session-persistence", "stage 2 never carries --resume"; command form: `ls "$TMPDIR"/how-do-i.*` after a real run
  @integration
  Scenario: A run leaves no work dir and persists no transcript
    When a run succeeds or fails
    Then no how-do-i.* work dir remains under TMPDIR
    And both stages carry --no-session-persistence

  # proves: command `bats plugins/procedures/hooks/tests/how-do-i.bats` exits 0 with the count quoted and 0 skipped; CI job procedures-tests green on ubuntu-latest and macos-latest for the PR head; the PR title starts with `fix(procedures):` and the release-title check passes
  @integration
  Scenario: The suite and release checks pass
    When the how-do-i suite runs locally and in CI
    Then it exits 0 with no skip on both platforms
    And the PR title passes the release-title check

# --- AC Coverage Map ---
# AC1 -> Stage 1 passes the index as a system prompt file and the question as stdin; A stage-1 retry changes stdin only; The model calls skip the user's instruction files
# AC2 -> No session state is written and legacy state is removed
# AC3 -> Eight consecutive runs behind the proxy keep selecting correctly
# AC4 -> Runs 2 to 8 hit the prompt cache
# AC5 -> The selection contract is unchanged; A gateway that drops --json-schema falls back to the text contract
# AC6 -> The output contract reports mode n/a and shows the system prompt in --dry-run; Help and header no longer describe sessions
# AC7 -> A rejected CLI call fails loudly, not as NOT FOUND
# AC8 -> A run leaves no work dir and persists no transcript
# AC9 -> The suite and release checks pass
