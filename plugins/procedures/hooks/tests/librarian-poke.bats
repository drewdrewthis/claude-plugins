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
  unset LIBRARIAN_MIN_INTERVAL_SECS LIBRARIAN_CLAIM_TTL_SECS LIBRARIAN_MAX_RUNTIME_SEC CODEX_STORE_ROOTS CODEX_ROOT
  # A drain with no store root is skipped (no write rules), so every test gets
  # one by default; a test that needs none unsets it.
  mkdir -p "$HOME/default-store/records"
  export CODEX_STORE_ROOTS="$HOME/default-store"
  # Pin a calm load so a busy box cannot defer the worker; an exported
  # LP_LOADAVG_FILE (e.g. /proc/loadavg) still wins for a real-load run.
  if [ -z "${LP_LOADAVG_FILE:-}" ]; then
    printf '0.10 0.10 0.10 1/100 1\n' > "$TURN_STATE_DIR/loadavg"
    export LP_LOADAVG_FILE="$TURN_STATE_DIR/loadavg"
  fi

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
printf '%s\n' "\$@" > "$STUB_BIN/last-claude-argv"
printf '%s\n' "\${MISTAKES_JSONL-UNSET}" > "$STUB_BIN/last-claude-mistakes"
printf '%s\n' "\${DECISIONS_DIR-UNSET}" "\${SOLUTIONS_DIR-UNSET}" "\${FAILURE_MODES_DIR-UNSET}" "\${CODEX_RECORDS_DIR-UNSET}" > "$STUB_BIN/last-claude-overrides"
pwd -P > "$STUB_BIN/last-claude-cwd"
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
# An unread line, so the worker's batch issues something and claude runs.
unread_line() { user_prompt; }

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
  grep -q -- '-p --setting-sources user --permission-mode dontAsk ' "$STUB_BIN/last-claude-args"
  grep -q -- ' --agent procedures:librarian Drain the transcript queue. State dir: ' "$STUB_BIN/last-claude-args"
}

@test "worker: the drain is scoped to its own commands, per store root, never auto or bypass" {
  ROOT="$HOME/store"; mkdir -p "$ROOT/records"
  export CODEX_STORE_ROOTS="$ROOT"
  LIBRARIAN_SYNC=1 run_poke
  [ "$status" -eq 0 ]
  argv="$STUB_BIN/last-claude-argv"
  PR="$(cd "$HOOKS/.." && pwd)"
  ! grep -qx -- 'auto' "$argv"
  ! grep -q -- 'bypassPermissions\|dangerously' "$argv"
  grep -qx -- 'dontAsk' "$argv"
  # Reads: the root and the plugin are added dirs; writes: only record .md
  # files in the root's records dir (see the narrowed-Edit test below).
  grep -qxF -- "$ROOT" "$argv"
  grep -qxF -- "$PR" "$argv"
  grep -qxF -- "Edit(/$ROOT/records/decisions/*.md)" "$argv"
  ! grep -qxF -- "Edit(/$ROOT/records/**)" "$argv"
  ! grep -qxF -- "Edit(/$ROOT/**)" "$argv"
  # The quoting the agent doc uses for the commit gate matches a literal rule,
  # with --root pinned to the same root; no commit-gate rule leaves --root open.
  grep -qxF -- "Bash(CODEX_ROOT='$ROOT' bash \"$PR/scripts/commit-records.sh\" --root '$ROOT' *)" "$argv"
  ! grep -xF -- "Bash(CODEX_ROOT='$ROOT' bash \"$PR/scripts/commit-records.sh\" *)" "$argv"
  [ -z "$(grep -F 'commit-records.sh' "$argv" | grep -vF -- "commit-records.sh\" --root " | grep -vF -- "commit-records.sh --root ")" ]
  grep -qxF -- "Bash(CODEX_ROOT=$ROOT MISTAKES_JSONL=$ROOT/mistakes.jsonl bash $PR/scripts/log-record.sh *)" "$argv"
  # No mkdir rule (Write creates the tmp dir) and no rm rule (the poke cleans up).
  ! grep -q -- 'Bash(mkdir' "$argv"
  ! grep -q -- 'Bash(rm' "$argv"
  # No rule leaves the root to a wildcard, and the agent cannot move cursors.
  ! grep -q -- 'CODEX_ROOT=\*' "$argv"
  ! grep -q -- 'librarian-advance' "$argv"
  # The prompt names the roots.
  grep -q -- "Store roots (CODEX_STORE_ROOTS): $ROOT\." "$argv"
}

# _argv_section <argv-file> <flag> — the argv words after <flag> up to the
# next word starting with "--".
_argv_section() {
  awk -v f="$2" '$0 == f { on = 1; next } on && /^--/ { on = 0 } on' "$1"
}

@test "worker: Edit allows only record .md kinds; scripts, invariants, common-mistakes, non-.md are denied" {
  ROOT="$HOME/store"; mkdir -p "$ROOT/records"
  export CODEX_STORE_ROOTS="$ROOT"
  LIBRARIAN_SYNC=1 run_poke
  [ "$status" -eq 0 ]
  argv="$STUB_BIN/last-claude-argv"
  RD="$ROOT/records"
  _argv_section "$argv" --allowedTools > "$STUB_BIN/allow"
  _argv_section "$argv" --disallowedTools > "$STUB_BIN/deny"
  # Allowed: exactly the record kinds the librarian writes, .md only.
  for k in decisions solutions failure-modes policies standards; do
    grep -qxF -- "Edit(/$RD/$k/*.md)" "$STUB_BIN/allow"
  done
  grep -qxF -- "Edit(/$RD/procedures/**/*.md)" "$STUB_BIN/allow"
  # Every Edit allow under the records dir ends in *.md, and none is the old
  # catch-all or names invariants/ or common-mistakes.md.
  [ -z "$(grep -F "Edit(/$RD/" "$STUB_BIN/allow" | grep -v '\*\.md)$')" ]
  ! grep -qxF -- "Edit(/$RD/**)" "$STUB_BIN/allow"
  ! grep -q -- 'invariants\|common-mistakes' "$STUB_BIN/allow"
  # Denied (deny wins over allow), inside the --disallowedTools list.
  grep -qxF -- "Edit(/$RD/**/scripts/**)" "$STUB_BIN/deny"
  grep -qxF -- "Edit(/$RD/invariants/**)" "$STUB_BIN/deny"
  grep -qxF -- "Edit(/$RD/common-mistakes.md)" "$STUB_BIN/deny"
  for e in sh py js json jsonl yml yaml; do
    grep -qxF -- "Edit(/$RD/**/*.$e)" "$STUB_BIN/deny"
  done
  # The deny list ends before --agent, so the prompt is not swallowed as a rule.
  [ "$(grep -n -x -- '--disallowedTools' "$argv" | cut -d: -f1)" -lt "$(grep -n -x -- '--agent' "$argv" | cut -d: -f1)" ]
  grep -qx -- 'procedures:librarian' "$argv"
}

@test "worker: every auto-loaded memory filename is denied under each records dir and the state dir" {
  A="$HOME/store-a"; B="$HOME/store-b"; mkdir -p "$A/records" "$B/records"
  export CODEX_STORE_ROOTS="$A:$B"
  LIBRARIAN_SYNC=1 run_poke
  [ "$status" -eq 0 ]
  argv="$STUB_BIN/last-claude-argv"
  _argv_section "$argv" --allowedTools > "$STUB_BIN/allow"
  _argv_section "$argv" --disallowedTools > "$STUB_BIN/deny"
  SD="$(sed -n 's|^Edit(/\(.*\)/tmp/\*\*)$|\1|p' "$STUB_BIN/allow")"
  [ -n "$SD" ]
  # The allow glob does match the name, so only the deny keeps it out.
  grep -qxF -- "Edit(/$A/records/decisions/*.md)" "$STUB_BIN/allow"
  for d in "$A/records" "$B/records" "$SD"; do
    for n in CLAUDE.md CLAUDE.local.md AGENTS.md; do
      grep -qxF -- "Edit(/$d/$n)" "$STUB_BIN/deny"
      grep -qxF -- "Edit(/$d/**/$n)" "$STUB_BIN/deny"
    done
    grep -qxF -- "Edit(/$d/.claude/**)" "$STUB_BIN/deny"
    grep -qxF -- "Edit(/$d/**/.claude/**)" "$STUB_BIN/deny"
  done
  # None of them leaked into the allow list.
  ! grep -q -- 'CLAUDE\|AGENTS\|\.claude/' "$STUB_BIN/allow"
}

@test "worker: the drain env carries none of log-record.sh's path overrides" {
  A="$HOME/store-a"; B="$HOME/store-b"; mkdir -p "$A/records" "$B/records"
  export CODEX_STORE_ROOTS="$A:$B"
  # Inherited from the session: each would move or refuse a pinned call.
  export MISTAKES_JSONL="$A/mistakes.jsonl" DECISIONS_DIR="$HOME/.claude/agents" \
    SOLUTIONS_DIR="$HOME/x" FAILURE_MODES_DIR="$HOME/y" CODEX_RECORDS_DIR="../z"
  LIBRARIAN_SYNC=1 run_poke
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_BIN/last-claude-mistakes")" = "UNSET" ]
  [ "$(sort -u "$STUB_BIN/last-claude-overrides")" = "UNSET" ]
}

@test "worker: the drain reads user settings only, with its cwd in the state dir" {
  LIBRARIAN_SYNC=1 run_poke
  [ "$status" -eq 0 ]
  argv="$STUB_BIN/last-claude-argv"
  # --setting-sources user, as two argv words, before --agent.
  n="$(grep -n -x -- '--setting-sources' "$argv" | cut -d: -f1)"
  [ -n "$n" ]
  [ "$(sed -n "$((n + 1))p" "$argv")" = "user" ]
  [ "$n" -lt "$(grep -n -x -- '--agent' "$argv" | cut -d: -f1)" ]
  [ "$(grep -c -x -- '--setting-sources' "$argv")" -eq 1 ]
  ! grep -qx -- 'project\|local\|user,project\|user,project,local' "$argv"
  # The cwd is the state dir (the Edit(<sd>/tmp/**) rule names it), not the
  # session's cwd.
  _argv_section "$argv" --allowedTools > "$STUB_BIN/allow"
  SD="$(sed -n 's|^Edit(/\(.*\)/tmp/\*\*)$|\1|p' "$STUB_BIN/allow")"
  [ -n "$SD" ]
  [ "$(cat "$STUB_BIN/last-claude-cwd")" = "$(cd "$SD" && pwd -P)" ]
  [ "$(cat "$STUB_BIN/last-claude-cwd")" != "$(pwd -P)" ]
}

@test "worker: no store roots resolved => drain skipped and logged, nothing issued, cursors kept" {
  unset CODEX_STORE_ROOTS CODEX_ROOT
  [ ! -e "$HOME/.knowledge" ]
  unread_line
  LIBRARIAN_NO_FLOCK=1 run bash "$HOOKS/librarian-poke.sh" --worker
  [ "$status" -eq 0 ]
  claude_never_ran
  local st="$HOME/.local/state/procedures/librarian"
  grep -q 'librarian-poke: no store roots resolved, drain skipped' "$st/librarian-poke.log"
  [ ! -s "$st/batch.manifest" ]
  [ ! -e "$st/cursors/$SID.line" ]
  # With a root back, the same line is issued and the drain runs.
  export CODEX_STORE_ROOTS="$HOME/default-store"
  LIBRARIAN_NO_FLOCK=1 run bash "$HOOKS/librarian-poke.sh" --worker
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$CLAUDE_LOG")" -eq 1 ]
  [ "$(cat "$st/cursors/$SID.line")" = "1" ]
}

@test "worker: the poke removes <state-dir>/tmp/commit-* after the drain, and nothing else" {
  unread_line
  local st="$HOME/.local/state/procedures/librarian"
  cat > "$STUB_BIN/claude" <<EOF
#!/usr/bin/env bash
echo ran >> "$CLAUDE_LOG"
mkdir -p "$st/tmp/commit-a" "$st/tmp/keep"
echo w > "$st/tmp/commit-a/why.txt"; echo k > "$st/tmp/keep/x"
echo o > "$HOME/outside"; ln -s "$HOME/outside" "$st/tmp/commit-link"
exit 1
EOF
  LIBRARIAN_NO_FLOCK=1 run bash "$HOOKS/librarian-poke.sh" --worker
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$CLAUDE_LOG")" -eq 1 ]
  [ ! -e "$st/tmp/commit-a" ]
  [ ! -L "$st/tmp/commit-link" ]
  [ -f "$HOME/outside" ]
  [ -f "$st/tmp/keep/x" ]
}

@test "worker: a pre-seeded claim (concurrent holder) is never stolen — claude never invoked" {
  mkdir -p "$LIBRARIAN_LOCK.d"
  LIBRARIAN_NO_FLOCK=1 run bash "$HOOKS/librarian-poke.sh" --worker
  [ "$status" -eq 0 ]
  claude_never_ran
  [ -d "$LIBRARIAN_LOCK.d" ]   # untouched: still owned by the other holder
}

@test "worker: an uncontended claim runs the librarian once and cleans up after" {
  unread_line
  LIBRARIAN_NO_FLOCK=1 run bash "$HOOKS/librarian-poke.sh" --worker
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$CLAUDE_LOG")" -eq 1 ]
  [ ! -d "$LIBRARIAN_LOCK.d" ]   # released after the run
}

@test "worker: the batch is issued before claude runs, inside the claim" {
  unread_line
  STATE="$HOME/.local/state/procedures/librarian"
  cat > "$STUB_BIN/claude" <<EOF
#!/usr/bin/env bash
echo ran >> "$CLAUDE_LOG"
cp "$STATE/batch.manifest" "$STUB_BIN/manifest-at-call" 2>/dev/null || true
EOF
  LIBRARIAN_NO_FLOCK=1 run bash "$HOOKS/librarian-poke.sh" --worker
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$CLAUDE_LOG")" -eq 1 ]
  grep -q "^$SID	0	1$" "$STUB_BIN/manifest-at-call"
}

@test "worker: an empty batch skips claude entirely" {
  LIBRARIAN_NO_FLOCK=1 run bash "$HOOKS/librarian-poke.sh" --worker
  [ "$status" -eq 0 ]
  claude_never_ran
  [ -f "$HOME/.local/state/procedures/librarian/batch.manifest" ]
  [ ! -s "$HOME/.local/state/procedures/librarian/batch.manifest" ]
  [ ! -d "$LIBRARIAN_LOCK.d" ]
}

@test "worker: a transcript the batch skipped is logged even when the batch succeeds" {
  unread_line
  printf '{"type":"user","message":{"content":"BOOM"}}\n' > "$PROJ/bad.jsonl"
  local real; real="$(command -v jq)"
  cat > "$STUB_BIN/jq" <<EOF
#!/usr/bin/env bash
[[ " \$* " == *" -R "* ]] || exec "$real" "\$@"
in="\$(cat)"
[[ "\$in" == *BOOM* ]] && exit 5
printf '%s\n' "\$in" | "$real" "\$@"
EOF
  chmod +x "$STUB_BIN/jq"
  LIBRARIAN_NO_FLOCK=1 run bash "$HOOKS/librarian-poke.sh" --worker
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$CLAUDE_LOG")" -eq 1 ]
  grep -q "librarian-batch: skipped $PROJ/bad.jsonl" "$HOME/.local/state/procedures/librarian/librarian-poke.log"
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

# Same isolation as the cursors test: HOME is a mktemp dir with no ~/.knowledge,
# so the default resolver lands the state dir (and thus the index cache's new
# home) at $HOME/.local/state/procedures/librarian.
@test "one-time migration moves the legacy how-do-i index cache into state/, marks the old location, then no-ops" {
  local STATE="$HOME/.local/state/procedures/librarian"
  local LEGACY="$HOME/.cache/how-do-i-index"
  mkdir -p "$LEGACY"
  printf 'idx line\n' > "$LEGACY/index.txt"
  printf 'a\tb\n'      > "$LEGACY/map.tsv"

  LIBRARIAN_SYNC=1 run_poke
  [ "$status" -eq 0 ]

  # index files moved to the new state dir, contents intact
  [ -f "$STATE/how-do-i-index/index.txt" ]
  [ -f "$STATE/how-do-i-index/map.tsv" ]
  [ "$(cat "$STATE/how-do-i-index/index.txt")" = "idx line" ]
  # a marker is left in the OLD location pointing at where the cache went
  ls "$LEGACY/"MIGRATED-to-* >/dev/null 2>&1
  grep -q "$STATE/how-do-i-index" "$LEGACY/"MIGRATED-to-*

  # Idempotent: a NEW file dropped into the legacy dir after migration is NOT
  # swept a second time, because the new dir is now populated. Replay the same
  # payload (same turn => gating releases, but migration still runs first).
  printf 'late\n' > "$LEGACY/late.txt"
  LIBRARIAN_SYNC=1 run bash "$HOOKS/librarian-poke.sh" < "$TURN_STATE_DIR/payload.json"
  [ "$status" -eq 0 ]
  [ ! -f "$STATE/how-do-i-index/late.txt" ]   # not migrated again
  [ -f "$LEGACY/late.txt" ]                    # left where it was
}

# ---------- load gate (lp_load_ok) via its test-injection seams ------------
#
# PLUGIN ADAPTATION: this pressure-gate suite (cases below) is plugin-local —
# it covers the vendored fork's load/iowait defer behaviour, which has no
# upstream equivalent, and drives it through the hook's LP_*_FILE /
# LP_STAT_SAMPLE_SLEEP injection seams.
#
# LP_LOADAVG_FILE / LP_STAT_FILE / LP_STAT_SAMPLE_SLEEP let these tests drive
# lp_load_ok deterministically off fixture files instead of the real
# /proc/loadavg + /proc/stat, and swap the /proc/stat fixture BETWEEN
# lp_iowait_pct's two samples instead of sleeping 1s against a live,
# unrepeatable counter. All four drive the worker directly via `--worker`
# (LIBRARIAN_NO_FLOCK=1, same shape as the two "worker:" tests above) so
# lp_load_ok runs exactly where production calls it, before the claim.
#
# /proc/stat cpu-line fields (lp_iowait_pct's own comment): $2 user $3 nice
# $4 system $5 idle $6 iowait $7 irq $8 softirq $9 steal.
#   fixture "under": cpu 1010 0 1010 8080 110 0 0 0 vs the base sample below
#     -> total delta 110, iowait delta 10 -> 9% (< ceiling 30)
#   fixture "over":  cpu 1000 0 1000 8000 600 0 0 0 vs the base sample below
#     -> total delta 500, iowait delta 500 -> 100% (> ceiling 30)
#   base sample: cpu 1000 0 1000 8000 100 0 0 0

lp_gate_setup() {
  export LIBRARIAN_LOAD_CEILING=8
  export LIBRARIAN_IOWAIT_CEILING=30
  export LP_LOADAVG_FILE="$BATS_TEST_TMPDIR/loadavg"
  export LP_STAT_FILE="$BATS_TEST_TMPDIR/stat"
  printf 'cpu 1000 0 1000 8000 100 0 0 0\n' > "$LP_STAT_FILE"
}

@test "load gate: under both ceilings proceeds — claude runs" {
  unread_line
  lp_gate_setup
  printf '1.00 0.50 0.10 1/200 123\n' > "$LP_LOADAVG_FILE"
  printf 'cpu 1010 0 1010 8080 110 0 0 0\n' > "$BATS_TEST_TMPDIR/stat-under"
  export LP_STAT_SAMPLE_SLEEP="cp '$BATS_TEST_TMPDIR/stat-under' '$LP_STAT_FILE'"

  LIBRARIAN_NO_FLOCK=1 run bash "$HOOKS/librarian-poke.sh" --worker
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$CLAUDE_LOG")" -eq 1 ]
  [ ! -d "$LIBRARIAN_LOCK.d" ]
}

@test "load gate: over the load ceiling defers — claude never runs, defer logged" {
  lp_gate_setup
  printf '50.00 0.50 0.10 1/200 123\n' > "$LP_LOADAVG_FILE"

  LIBRARIAN_NO_FLOCK=1 run bash "$HOOKS/librarian-poke.sh" --worker
  [ "$status" -eq 0 ]
  claude_never_ran
  grep -q "librarian-poke: deferred, load=50.00 > ceiling=8" \
    "$HOME/.local/state/procedures/librarian/librarian-poke.log"
}

@test "load gate: over the iowait ceiling (two fixtures swapped between samples) defers — claude never runs, defer logged" {
  lp_gate_setup
  printf '1.00 0.50 0.10 1/200 123\n' > "$LP_LOADAVG_FILE"
  printf 'cpu 1000 0 1000 8000 600 0 0 0\n' > "$BATS_TEST_TMPDIR/stat-over"
  export LP_STAT_SAMPLE_SLEEP="cp '$BATS_TEST_TMPDIR/stat-over' '$LP_STAT_FILE'"

  LIBRARIAN_NO_FLOCK=1 run bash "$HOOKS/librarian-poke.sh" --worker
  [ "$status" -eq 0 ]
  claude_never_ran
  grep -q "librarian-poke: deferred, iowait=100% > ceiling=30%" \
    "$HOME/.local/state/procedures/librarian/librarian-poke.log"
}

@test "load gate: unreadable loadavg AND stat fail open — claude runs, both fail-opens logged" {
  unread_line
  lp_gate_setup
  rm -f "$LP_LOADAVG_FILE" "$LP_STAT_FILE"   # unreadable: never created

  LIBRARIAN_NO_FLOCK=1 run bash "$HOOKS/librarian-poke.sh" --worker
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$CLAUDE_LOG")" -eq 1 ]
  local LOG="$HOME/.local/state/procedures/librarian/librarian-poke.log"
  grep -q "librarian-poke: fail-open, loadavg unreadable" "$LOG"
  grep -q "librarian-poke: fail-open, iowait unreadable" "$LOG"
}

# ---------- the hook owns the cursors (issue #25) ----------------------------
#
# The model no longer moves cursors: after `claude -p` exits 0 the worker
# advances every manifest range to its issued end; on a nonzero exit it
# advances nothing, so the same lines are re-issued (at-least-once).
# LIBRARIAN_MIN_INTERVAL_SECS=0 disables the cooldown so back-to-back wakes run.

lp_state() { printf '%s' "$HOME/.local/state/procedures/librarian"; }
# Copies the batch the hook issued, so a later wake cannot overwrite it.
claude_keeps_batch() {
  cat > "$STUB_BIN/claude" <<EOF
#!/usr/bin/env bash
echo ran >> "$CLAUDE_LOG"
cp "$(lp_state)/batch.txt" "$STUB_BIN/batch-\$(wc -l < "$CLAUDE_LOG" | tr -d ' ').txt"
exit ${1:-0}
EOF
  chmod +x "$STUB_BIN/claude"
}
wake() { LIBRARIAN_MIN_INTERVAL_SECS="${1:-0}" LIBRARIAN_NO_FLOCK=1 run bash "$HOOKS/librarian-poke.sh" --worker; }

@test "cursors: a clean exit advances every issued range; the next wake gets only newer lines" {
  claude_keeps_batch 0
  user_prompt                                        # L1
  wake; [ "$status" -eq 0 ]
  [ "$(cat "$(lp_state)/cursors/$SID.line")" = "1" ]
  grep -q '^\[L1\] ' "$STUB_BIN/batch-1.txt"
  user_prompt                                        # L2, appended after wake 1
  wake; [ "$status" -eq 0 ]
  grep -q '^\[L2\] ' "$STUB_BIN/batch-2.txt"
  run grep -q '^\[L1\] ' "$STUB_BIN/batch-2.txt"
  [ "$status" -ne 0 ]
  [ "$(cat "$(lp_state)/cursors/$SID.line")" = "2" ]
  wake; [ "$status" -eq 0 ]                          # nothing new: no session
  [ "$(wc -l < "$CLAUDE_LOG")" -eq 2 ]
}

@test "cursors: a nonzero claude exit advances nothing and the lines are re-issued" {
  claude_keeps_batch 1
  user_prompt
  wake; [ "$status" -eq 0 ]
  [ ! -f "$(lp_state)/cursors/$SID.line" ]
  grep -q 'librarian-poke: drain exited 1, cursors not advanced' "$(lp_state)/librarian-poke.log"
  wake; [ "$status" -eq 0 ]
  [ "$(wc -l < "$CLAUDE_LOG")" -eq 2 ]
  grep -q '^\[L1\] ' "$STUB_BIN/batch-2.txt"
}

@test "cooldown: a drain started under LIBRARIAN_MIN_INTERVAL_SECS ago defers — claude never runs" {
  user_prompt
  mkdir -p "$(lp_state)"; date +%s > "$(lp_state)/last-drain-start"
  wake 1800; [ "$status" -eq 0 ]
  claude_never_ran
  grep -q 'librarian-poke: deferred, cooldown' "$(lp_state)/librarian-poke.log"
}

@test "cooldown: the first drain stamps its start; LIBRARIAN_MIN_INTERVAL_SECS=0 disables the cooldown" {
  user_prompt
  wake 1800; [ "$status" -eq 0 ]
  [ "$(wc -l < "$CLAUDE_LOG")" -eq 1 ]
  [ -s "$(lp_state)/last-drain-start" ]
  user_prompt
  wake 0; [ "$status" -eq 0 ]
  [ "$(wc -l < "$CLAUDE_LOG")" -eq 2 ]
}

@test "cursors: a manifest changed during the wake is not advanced from" {
  cat > "$STUB_BIN/claude" <<EOF
#!/usr/bin/env bash
echo ran >> "$CLAUDE_LOG"
printf 'other\t0\t5\n' >> "$(lp_state)/batch.manifest"
EOF
  chmod +x "$STUB_BIN/claude"
  user_prompt
  wake; [ "$status" -eq 0 ]
  [ ! -f "$(lp_state)/cursors/$SID.line" ]
  grep -q 'manifest changed during drain, not advancing' "$(lp_state)/librarian-poke.log"
}

# The claim TTL must outlive a drain at its runtime cap, or a live drain's
# claim is stolen and two librarians write at once.
@test "claim: the default TTL derives from the runtime cap — a 1000s-old claim is kept, then stolen under a 100s cap" {
  user_prompt
  mkdir -p "$LIBRARIAN_LOCK.d"; touch -d "@$(( $(date +%s) - 1000 ))" "$LIBRARIAN_LOCK.d"
  wake; [ "$status" -eq 0 ]
  claude_never_ran
  [ -d "$LIBRARIAN_LOCK.d" ]
  LIBRARIAN_MAX_RUNTIME_SEC=100 wake; [ "$status" -eq 0 ]
  [ "$(wc -l < "$CLAUDE_LOG")" -eq 1 ]
}

@test "cooldown: the gating half defers before spawning any worker" {
  mkdir -p "$(lp_state)"; date +%s > "$(lp_state)/last-drain-start"
  LIBRARIAN_SYNC=1 run_poke
  [ "$status" -eq 0 ]
  claude_never_ran
  run grep -q 'deferred, cooldown' "$(lp_state)/librarian-poke.log"
  [ "$status" -ne 0 ]                     # no worker ran to log its under-lock defer
}

@test "store visibility: a wake that leaves uncommitted store writes logs them, cursors still advance" {
  local store="$BATS_TEST_TMPDIR/store"
  git init -q "$store"
  export CODEX_STORE_ROOTS="$store"
  cat > "$STUB_BIN/claude" <<EOF
#!/usr/bin/env bash
echo ran >> "$CLAUDE_LOG"
echo x > "$store/stray.md"
EOF
  chmod +x "$STUB_BIN/claude"
  user_prompt
  wake; [ "$status" -eq 0 ]
  grep -q "wake left uncommitted store writes in $store: 1 paths" "$(lp_state)/librarian-poke.log"
  [ "$(cat "$(lp_state)/cursors/$SID.line")" = "1" ]
}

@test "cooldown: a stamp in the future counts as stale, not as a fresh drain" {
  mkdir -p "$(lp_state)"; echo $(( $(date +%s) + 3600 )) > "$(lp_state)/last-drain-start"
  user_prompt
  LIBRARIAN_MIN_INTERVAL_SECS=1800 wake 1800; [ "$status" -eq 0 ]
  [ "$(wc -l < "$CLAUDE_LOG")" -eq 1 ]
}

@test "store visibility: a path already dirty before the wake and written again is logged" {
  local store="$BATS_TEST_TMPDIR/store"
  git init -q "$store"
  git -C "$store" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  printf '{"a":1}\n' > "$store/mistakes.jsonl"
  git -C "$store" add mistakes.jsonl
  git -C "$store" -c user.email=t@t -c user.name=t commit -qm jsonl
  printf '{"b":2}\n' >> "$store/mistakes.jsonl"            # dirty before the wake
  export CODEX_STORE_ROOTS="$store"
  cat > "$STUB_BIN/claude" <<EOF
#!/usr/bin/env bash
echo ran >> "$CLAUDE_LOG"
printf '{"c":3}\n' >> "$store/mistakes.jsonl"
EOF
  chmod +x "$STUB_BIN/claude"
  user_prompt
  wake; [ "$status" -eq 0 ]
  grep -q "wake left uncommitted store writes in $store: 1 paths" "$(lp_state)/librarian-poke.log"
}

@test "store visibility: a renamed path with a space, written during the wake, is logged" {
  local store="$BATS_TEST_TMPDIR/store"
  git init -q "$store"
  printf 'a\n' > "$store/a.md"
  git -C "$store" add a.md
  git -C "$store" -c user.email=t@t -c user.name=t commit -qm init
  git -C "$store" mv a.md "b c.md"                          # staged rename before the wake,
  printf 'dirty\n' >> "$store/b c.md"                        # already modified too
  export CODEX_STORE_ROOTS="$store"
  cat > "$STUB_BIN/claude" <<EOF
#!/usr/bin/env bash
echo ran >> "$CLAUDE_LOG"
printf 'more\n' >> "$store/b c.md"
EOF
  chmod +x "$STUB_BIN/claude"
  user_prompt
  wake; [ "$status" -eq 0 ]
  grep -q "wake left uncommitted store writes in $store: 1 paths" "$(lp_state)/librarian-poke.log"
}
