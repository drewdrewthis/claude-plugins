#!/usr/bin/env bats
# Smoke tests for the librarian-poke Stop hook (async).
#
# NOT exhaustive — this proves the gating chain releases on the same cases
# evolve-sweep.bats already proves for its shared libraries (gate-libs.bats
# covers the libraries themselves), that LIBRARIAN_SYNC drives the exact
# `claude -p --agent procedures:librarian` command line, and that the
# single-writer mkdir claim actually excludes a concurrent holder.
#
# Run: bats hooks/tests/librarian-poke.bats

setup() {
  HOOKS="$BATS_TEST_DIRNAME/.."
  export HOME="$(mktemp -d "${BATS_TMPDIR:-/tmp}/lib-home.XXXXXX")"
  mkdir -p "$HOME/.claude"
  export TURN_STATE_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/lib.XXXXXX")"
  export GATE_FAILOPEN_LOG="$TURN_STATE_DIR/gate-failopen.jsonl"
  export GATE_ESCAPE_LOG="$TURN_STATE_DIR/gate-escape.jsonl"
  export LIBRARIAN_SETTLE_SECS=0
  export LIBRARIAN_LOCK="$TURN_STATE_DIR/librarian.lock"
  unset PROCEDURES_ENABLE_LIBRARIAN CLAUDE_CODE_ENTRYPOINT LIBRARIAN_SYNC LIBRARIAN_NO_FLOCK

  SID="bats-lp-$$-$BATS_TEST_NUMBER"
  PROJ="$HOME/.claude/projects/-bats-lp-$$-$BATS_TEST_NUMBER"
  mkdir -p "$PROJ"
  JSONL="$PROJ/$SID.jsonl"

  # claude stub: records that it ran AND captures its argument vector.
  STUB_BIN="$(mktemp -d "${BATS_TMPDIR:-/tmp}/lib-bin.XXXXXX")"
  CLAUDE_LOG="$STUB_BIN/claude-ran"
  cat > "$STUB_BIN/claude" <<EOF
#!/usr/bin/env bash
echo ran >> "$CLAUDE_LOG"
printf '%s\n' "\$*" > "$STUB_BIN/last-claude-args"
exit 0
EOF
  chmod +x "$STUB_BIN/claude"
  export PATH="$STUB_BIN:$PATH"
}

teardown() {
  rm -rf "$HOME" "$TURN_STATE_DIR" "$STUB_BIN" 2>/dev/null || true
}

user_prompt() { printf '{"type":"user","message":{"content":"do the thing"}}\n' >> "$JSONL"; }
tool_use()    { printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}\n' >> "$JSONL"; }

start_turn() { printf '{"session_id":"%s"}' "$SID" | bash "$HOOKS/turn-state-reset.sh"; }

# run_poke [extra-payload-json] — full tool-using turn, then Stop.
# ⚠ stdin reaches the hook via a FILE, never `printf | run`: a pipeline
# member runs in a subshell, which would discard run's $status/$output.
run_poke() {
  start_turn
  user_prompt
  tool_use
  local extra="${1:-}"
  jq -nc --arg sid "$SID" --arg tp "$JSONL" --arg cwd "$BATS_TEST_DIRNAME" \
    "{session_id:\$sid, hook_event_name:\"Stop\", transcript_path:\$tp, cwd:\$cwd${extra:+, $extra}}" \
    > "$TURN_STATE_DIR/payload.json"
  run bash "$HOOKS/librarian-poke.sh" < "$TURN_STATE_DIR/payload.json"
}

run_poke_payload() {
  printf '%s' "$1" > "$TURN_STATE_DIR/payload.json"
  run bash "$HOOKS/librarian-poke.sh" < "$TURN_STATE_DIR/payload.json"
}

marker_absent()  { [ ! -f "$TURN_STATE_DIR/$SID.librarian_poked" ]; }
marker_present() { [ -f "$TURN_STATE_DIR/$SID.librarian_poked" ]; }
claude_never_ran() { [ ! -f "$CLAUDE_LOG" ]; }

@test "hooks.json registers librarian-poke on Stop with async, no asyncRewake" {
  jq -e '.hooks.Stop[] | .hooks[] | select(.command == "bash ${CLAUDE_PLUGIN_ROOT}/hooks/librarian-poke.sh")
        | .async == true and (has("asyncRewake") | not)' "$HOOKS/hooks.json" >/dev/null
}

@test "non-Stop event releases silently: no marker, claude never invoked" {
  start_turn; user_prompt; tool_use
  run_poke_payload "{\"session_id\":\"$SID\",\"hook_event_name\":\"PreToolUse\"}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  marker_absent
  claude_never_ran
}

@test "subagent audience releases silently: claude never invoked" {
  LIBRARIAN_SYNC=1 run_poke '"agent_id":"agent-77"'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  claude_never_ran
}

@test "sdk-cli ephemeral sessions never poke" {
  CLAUDE_CODE_ENTRYPOINT=sdk-cli run_poke
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  marker_absent
  claude_never_ran
}

@test "clean no-tool turn releases silently" {
  start_turn; user_prompt   # no tool_use lines
  run_poke_payload "{\"session_id\":\"$SID\",\"hook_event_name\":\"Stop\"}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  marker_absent
  claude_never_ran
}

@test "already poked this turn => silent release even under LIBRARIAN_SYNC" {
  LIBRARIAN_SYNC=1 run_poke
  marker_present
  [ "$(wc -l < "$CLAUDE_LOG")" -eq 1 ]
  # Second Stop in the SAME turn: no new user prompt ran, so no reset —
  # replay the identical payload WITHOUT start_turn.
  LIBRARIAN_SYNC=1 run bash "$HOOKS/librarian-poke.sh" < "$TURN_STATE_DIR/payload.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(wc -l < "$CLAUDE_LOG")" -eq 1 ]
}

@test "kill-switch releases silently at the action point and records an escape" {
  PROCEDURES_ENABLE_LIBRARIAN=false LIBRARIAN_SYNC=1 run_poke
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  claude_never_ran
  grep -q '"gate":"LIBRARIAN"' "$GATE_ESCAPE_LOG"
}

@test "LIBRARIAN_SYNC=1 runs the worker inline with the exact librarian command line" {
  LIBRARIAN_SYNC=1 run_poke
  [ "$status" -eq 0 ]
  marker_present
  [ "$(wc -l < "$CLAUDE_LOG")" -eq 1 ]
  grep -q -- '-p --agent procedures:librarian Drain the transcript queue.' "$STUB_BIN/last-claude-args"
}

@test "worker: a pre-seeded claim (concurrent holder) is never stolen — claude never invoked" {
  mkdir -p "$LIBRARIAN_LOCK.d"
  LIBRARIAN_NO_FLOCK=1 run bash "$HOOKS/librarian-poke.sh" --worker
  [ "$status" -eq 0 ]
  claude_never_ran
  [ -d "$LIBRARIAN_LOCK.d" ]   # untouched: still owned by the other holder
}

@test "worker: an uncontended claim runs the librarian once and cleans up after" {
  LIBRARIAN_NO_FLOCK=1 run bash "$HOOKS/librarian-poke.sh" --worker
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$CLAUDE_LOG")" -eq 1 ]
  [ ! -d "$LIBRARIAN_LOCK.d" ]   # released after the run
}

# HOME is a mktemp dir (setup), so the DEFAULT state resolver lands at
# $HOME/.local/state/procedures/librarian — already isolated inside this
# test's tmp tree, no PROCEDURES_STATE_DIR/XDG override needed.
@test "one-time migration moves legacy cursors + queue out of ~/.claude, marks the old location, then no-ops" {
  local STATE="$HOME/.local/state/procedures/librarian"
  mkdir -p "$HOME/.claude/librarian/cursors"
  printf '10\n' > "$HOME/.claude/librarian/cursors/aaa.line"
  printf '20\n' > "$HOME/.claude/librarian/cursors/bbb.line"
  printf 'a queued note\n' > "$HOME/.claude/librarian/grooming-queue.md"

  LIBRARIAN_SYNC=1 run_poke
  [ "$status" -eq 0 ]

  # cursors moved to the new state dir, contents intact
  [ -f "$STATE/cursors/aaa.line" ]
  [ -f "$STATE/cursors/bbb.line" ]
  [ "$(cat "$STATE/cursors/aaa.line")" = "10" ]
  # grooming queue moved (mv, so the legacy copy is gone)
  [ -f "$STATE/grooming-queue.md" ]
  [ ! -f "$HOME/.claude/librarian/grooming-queue.md" ]
  # a marker is left in the OLD location pointing at where the state went
  ls "$HOME/.claude/librarian/"MIGRATED-to-* >/dev/null 2>&1
  grep -q "$STATE" "$HOME/.claude/librarian/"MIGRATED-to-*

  # Idempotent: a NEW legacy cursor dropped after migration is NOT swept a
  # second time, because the new dir is now populated. Replay the same payload
  # (same turn => gating releases, but migration still runs before gating).
  printf '30\n' > "$HOME/.claude/librarian/cursors/ccc.line"
  LIBRARIAN_SYNC=1 run bash "$HOOKS/librarian-poke.sh" < "$TURN_STATE_DIR/payload.json"
  [ "$status" -eq 0 ]
  [ ! -f "$STATE/cursors/ccc.line" ]                  # not migrated again
  [ -f "$HOME/.claude/librarian/cursors/ccc.line" ]   # left where it was
  # first-run contents untouched by the second run
  [ -f "$STATE/cursors/aaa.line" ]
  [ -f "$STATE/cursors/bbb.line" ]
}
