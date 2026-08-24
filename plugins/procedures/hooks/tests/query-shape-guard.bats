#!/usr/bin/env bats
# Policy tests for hooks/query-shape-guard.sh — the PreToolUse hook holding
# the two gate forks to their one-shot contracts.
#
# BOTH DIRECTIONS are asserted:
#   FIRES  — budget violations and unsanctioned shapes get a deny decision
#            naming QUERY-SHAPE-GUARD;
#   SILENT — compliant one-query use, non-audience sessions, and degenerate
#            environments pass with empty output and exit 0.
#
# The libraries are covered by gate-libs.bats / gate-escape.bats; these prove
# POLICY only — who is denied, when, and that every release path stays quiet.
#
# Run: bats hooks/tests/query-shape-guard.bats

setup() {
  HOOKS="$BATS_TEST_DIRNAME/.."
  GUARD="$HOOKS/query-shape-guard.sh"
  SCRIPTS="$BATS_TEST_DIRNAME/../../scripts"
  # Unique per test: the budget is one marker file per session+key under
  # QUERY_GUARD_STATE_DIR, so a shared SID would leak spend between tests.
  SID="bats-qsg-$$-$BATS_TEST_NUMBER"
  FIX="$(mktemp -d "${BATS_TMPDIR:-/tmp}/qsg.XXXXXX")"
  PF="$FIX/payload.json"
  export QUERY_GUARD_STATE_DIR="$FIX/state"
  # Same telemetry isolation as gates.bats: a fail-open or an off-switch
  # record must land in THIS run's files, never production logs. HOME is
  # redirected too — both libs default $HOME-relative paths.
  export HOME="$FIX/home"
  mkdir -p "$HOME/.claude"
  export GATE_FAILOPEN_LOG="$FIX/gate-failopen.jsonl"
  export GATE_ESCAPE_LOG="$FIX/gate-escape.jsonl"
}

teardown() {
  [ -n "${FIX:-}" ] && rm -rf "$FIX"
  true
}

# ---- payload builders (jq builds them so command quotes survive) ----

scout_bash() {
  jq -nc --arg sid "$SID" --arg c "$1" \
    '{session_id:$sid, agent_type:"procedures:procedure-scout", tool_name:"Bash", tool_input:{command:$c}}'
}

reviewer_bash() {
  jq -nc --arg sid "$SID" --arg c "$1" \
    '{session_id:$sid, agent_type:"procedures:work-reviewer", tool_name:"Bash", tool_input:{command:$c}}'
}

scout_tool() {  # scout_tool <tool_name>
  jq -nc --arg sid "$SID" --arg t "$1" \
    '{session_id:$sid, agent_type:"procedures:procedure-scout", tool_name:$t, tool_input:{path:"/tmp/x"}}'
}

reviewer_write() {
  jq -nc --arg sid "$SID" \
    '{session_id:$sid, agent_type:"procedures:work-reviewer", tool_name:"Write", tool_input:{file_path:"/tmp/x", content:"x"}}'
}

reviewer_dispatch() {  # reviewer_dispatch <subagent_type>
  jq -nc --arg sid "$SID" --arg s "$1" \
    '{session_id:$sid, agent_type:"procedures:work-reviewer", tool_name:"Agent", tool_input:{subagent_type:$s, prompt:"p"}}'
}

plain_agent() {  # plain_agent <agent_type> <tool_name> — no fork identity tricks
  jq -nc --arg sid "$SID" --arg a "$1" --arg t "$2" \
    '{session_id:$sid, agent_type:$a, tool_name:$t, tool_input:{path:"/tmp/x"}}'
}

run_guard() {  # run_guard <payload-json> [env VAR=value]...
  local p="$1"; shift
  printf '%s' "$p" > "$PF"
  run env "$@" bash -c "bash '$GUARD' < '$PF'"
}

denied() {  # denied [reason-fragment]
  [ "$status" -eq 0 ] || { echo "hook exited $status — decisions ride stdout, exit stays 0"; false; }
  [[ "$output" == *'QUERY-SHAPE-GUARD'* ]] || { echo "no guard marker in: $output"; false; }
  [[ "$output" == *'"deny"'* ]] || { echo "not a deny decision: $output"; false; }
  if [ -n "$1" ]; then
    [[ "$output" == *"$1"* ]] || { echo "reason is missing '$1': $output"; false; }
  fi
}

allowed_silent() {
  [ "$status" -eq 0 ] || { echo "expected silent allow, exited $status: $output"; false; }
  [ -z "$output" ] || { echo "expected silence, got: $output"; false; }
}

PIPELINE_CHAIN="bash '$SCRIPTS/session-digest-read.sh' --read \"$SID\" && bash '$SCRIPTS/how-do-i.sh' --question 'goal and terms here as one question'"

@test "a '|' inside the --question value is denied — prompts compose pipe-free questions" {
  # The guard splits statements on pipes without quote-awareness, by design.
  # That is why every prompt composes the question WITHOUT the caller's
  # GOAL|TERMS separator; this pins that the pipe-carrying form stays
  # denied so nobody "fixes" a prompt by reintroducing it.
  run_guard "$(scout_bash "bash '$SCRIPTS/how-do-i.sh' --question 'goal | terms here'")"
  denied "unsanctioned"
}

# ---------- audience: anyone but the two forks is untouched ----------

@test "a session with no fork identity is released untouched" {
  # The guard keys on .agent_type / CLAUDE_CODE_AGENT. A MAIN agent's Bash is
  # nobody's business here — the how-do-i-gate owns that surface.
  run_guard "$(jq -nc --arg sid "$SID" '{session_id:$sid, tool_name:"Bash", tool_input:{command:"ls references/"}}')"
  allowed_silent
}

@test "another plugin's fork (delegation:coder) is released untouched" {
  run_guard "$(plain_agent "delegation:coder" "Write")"
  allowed_silent
}

@test "the scout is recognized through the CLAUDE_CODE_AGENT env fallback" {
  # Payloads may lack .agent_type (older envelope shapes); the env var is the
  # documented fallback and must arm the guard, not bypass it.
  printf '%s' "$(jq -nc --arg sid "$SID" '{session_id:$sid, tool_name:"Read", tool_input:{path:"/tmp/x"}}')" > "$PF"
  run env CLAUDE_CODE_AGENT=procedures:procedure-scout bash -c "bash '$GUARD' < '$PF'"
  denied "Read"
}

# ---------- write/read toolset: denied by name, both forks ----------

@test "the scout loses the read-class tools outright" {
  local t
  for t in Read Grep Glob; do
    run_guard "$(scout_tool "$t")"
    denied "$t"
  done
}

@test "the reviewer's Write is denied and routed to the evolution agent" {
  # A fork inherits the parent toolset, so prose boundaries are not the
  # control. Record WRITES belong to procedures:procedure-evolver; the deny
  # reason must say so or the fork guesses at the seam.
  run_guard "$(reviewer_write)"
  denied "procedure-evolver"
}

# ---------- Bash shape: the guard FIRES on violations ----------

@test "an empty command is denied, not waved through" {
  run_guard "$(scout_bash "")"
  denied "empty command"
}

@test "an unsanctioned segment is denied and named" {
  run_guard "$(scout_bash "ls references/decisions/")"
  denied "unsanctioned"
  denied "ls references/decisions/"
}

@test "retired retrieval-mode flags are unsanctioned on surviving scripts too" {
  # The retired matcher's modes (keyword/cat/recall/id) died with their
  # script in the pipeline cutover. These assert the guard never blesses a
  # mode-flag shape on the scripts that remain: only the documented
  # per-script flag passes (--read for the digest, --question for the
  # pipeline).
  local cmd
  for cmd in \
    "bash '$SCRIPTS/how-do-i.sh' --keyword quokka" \
    "bash '$SCRIPTS/session-digest-read.sh' --recall quokka" \
    "bash '$SCRIPTS/compile-records.sh' --cat references/decisions/a.md"; do
    run_guard "$(scout_bash "$cmd")"
    denied "unsanctioned"
  done
}

@test "command substitution hides a segment and is denied outright" {
  local cmd
  for cmd in "bash '$SCRIPTS/how-do-i.sh' --question \$(echo terms)" "head -1 \`ls\`"; do
    run_guard "$(scout_bash "$cmd")"
    denied "hides a segment"
  done
}

@test "a multiline command hides segments behind the newline and is denied" {
  local nl=$'\n'
  run_guard "$(scout_bash "bash '$SCRIPTS/how-do-i.sh' --question 'terms'${nl}ls /")"
  denied "hides a segment"
}

@test "file redirection is a write and is denied" {
  run_guard "$(scout_bash "bash '$SCRIPTS/how-do-i.sh' --question 'terms' > /tmp/out.txt")"
  denied "file redirection is a write"
}

@test "jq outside the justfile-probe pipeline is denied" {
  run_guard "$(scout_bash "jq -r '.keywords' /tmp/notes.json")"
  denied "sanctioned only inside the justfile probe"
}

@test "a second retrieval call is denied after the budget is spent" {
  run_guard "$(scout_bash "$PIPELINE_CHAIN")"
  allowed_silent
  [ -f "$QUERY_GUARD_STATE_DIR/$SID.bash" ] || { echo "no budget marker written for an allowed call"; false; }

  run_guard "$(scout_bash "bash '$SCRIPTS/how-do-i.sh' --question 'a different question entirely'")"
  denied "spent its one retrieval call"
}

@test "a denied shape spends nothing — the retry is still possible" {
  # The grace that makes a strict budget livable: an unsanctioned ATTEMPT
  # must not consume the one call, or a typo'd first command bricks the fork.
  run_guard "$(scout_bash "grep -rn quokka references/")"
  denied "unsanctioned"
  [ ! -f "$QUERY_GUARD_STATE_DIR/$SID.bash" ] || { echo "a DENIED call consumed budget"; false; }

  run_guard "$(scout_bash "$PIPELINE_CHAIN")"
  allowed_silent
}

# ---------- Bash shape: SILENT on compliant one-query use ----------

@test "the documented one-call chain — digest replay && pipeline — is allowed silently" {
  run_guard "$(scout_bash "$PIPELINE_CHAIN")"
  allowed_silent
}

@test "discarding output is not mistaken for a write: 2>/dev/null, >/dev/null, 2>&1" {
  local cmd i=0
  for cmd in \
    "bash '$SCRIPTS/session-digest-read.sh' --read x 2>/dev/null && bash '$SCRIPTS/how-do-i.sh' --question 'terms' >/dev/null" \
    "bash '$SCRIPTS/how-do-i.sh' --question 'terms' 2>&1"; do
    i=$((i + 1))
    SID="${SID}-discard-$i"   # fresh budget per iteration: each shape is judged on ITS OWN first call
    run_guard "$(scout_bash "$cmd")"
    allowed_silent
  done
}

@test "the documented justfile probe pipeline is sanctioned end to end" {
  # KNOWN DEVIATION, deliberately left failing — fix the guard, not this test.
  # The exact command skills/how-do-i/SKILL.md step 4 documents is denied,
  # by two compounding defects in the segment scan:
  #   1. splitting on &&/||/;/&/| leaves the leading space on every segment
  #      after the first, while the "just "*/"jq "* patterns are anchored at
  #      the segment start — " just --dump ..." reads as unsanctioned;
  #   2. the jq program's own pipes ('.recipes | to_entries[] | ...') are
  #      indistinguishable from shell pipes, so the documented jq stage is
  #      shredded into fragments (" to_entries[] ") matching nothing.
  # Effect: a fork following its own prompt verbatim is denied on every repo
  # with a justfile. Fix: trim segments before matching, and judge the
  # pipe-tail of a "just --dump" producer together with it.
  run_guard "$(scout_bash "command -v just >/dev/null && just --dump --dump-format json | jq -r '.recipes | to_entries[] | \"\\(.key)\\t\\(.value.doc // \"-\")\"'")"
  allowed_silent
}

@test "probe segments DO pass as standalone statements, unchained" {
  # Documents the working subset under the deviation above: the sanctioned
  # shapes match when a segment starts the command, so a fork that writes the
  # probe without chaining still gets through.
  run_guard "$(scout_bash "just --dump --dump-format json")"
  allowed_silent
}

@test "a non-Bash, non-Agent tool the guard does not police is released silently" {
  run_guard "$(scout_tool "WebSearch")"
  allowed_silent
}

# ---------- Agent tool: scout never, reviewer once, evolver only ----------

@test "the scout gets NO Agent dispatch, ever" {
  run_guard "$(jq -nc --arg sid "$SID" --arg s "procedures:procedure-evolver" '{session_id:$sid, agent_type:"procedures:procedure-scout", tool_name:"Agent", tool_input:{subagent_type:$s, prompt:"p"}}')"
  denied "no Agent dispatches"
}

@test "the reviewer's evolution dispatch is allowed once, silently" {
  run_guard "$(reviewer_dispatch "procedures:procedure-evolver")"
  allowed_silent
  [ -f "$QUERY_GUARD_STATE_DIR/$SID.agent" ] || { echo "no agent-budget marker written"; false; }
}

@test "the reviewer's SECOND dispatch is denied" {
  run_guard "$(reviewer_dispatch "procedures:procedure-evolver")"
  allowed_silent
  run_guard "$(reviewer_dispatch "procedures:procedure-evolver")"
  denied "exactly ONE evolution dispatch"
}

@test "the reviewer's dispatch to any other agent is denied and names the target" {
  run_guard "$(reviewer_dispatch "general-purpose")"
  denied "procedures:procedure-evolver"
  denied "got: general-purpose"
}

# ---------- degradation: fail-open and the off-switch ----------

@test "the off-switch releases the guard silently and records the escape" {
  run_guard "$(reviewer_write)" "PROCEDURES_ENABLE_QUERY_SHAPE_GUARD=false"
  allowed_silent
  grep -q '"gate":"QUERY_SHAPE_GUARD"' "$GATE_ESCAPE_LOG" \
    || { echo "released switch left no escape record"; false; }
}

@test "a jq-less machine fails open, silently, exit 0" {
  printf '%s' "$(scout_bash "grep -rn quokka references/")" > "$PF"
  local EMPTY; EMPTY="$(mktemp -d)"
  # Absolute interpreter path: with PATH emptied, `bash` itself is
  # unresolvable, which would fail the rig rather than exercise the hook's
  # jq-less path (same rig as gates.bats).
  run env PATH="$EMPTY" /bin/bash -c "/bin/bash '$GUARD' < '$PF'"
  rm -rf "$EMPTY"
  allowed_silent
}
