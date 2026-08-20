#!/usr/bin/env bats
# Tests for hooks/worklog-record.sh — the per-turn worklog writer.
#
# WHAT THIS FILE PROVES, in priority order:
#
#   1. THE MECHANICAL/JUDGMENT SPLIT HOLDS. `changed` comes out of the turn's
#      tool_use blocks and NEVER out of the model, so a stubbed judgment that
#      names a fabricated path cannot get one into the record. This is the
#      whole reason the split exists; if only one test in here survives, this
#      is it.
#   2. NO UUID SURVIVES UNCHECKED. The model is handed a candidate list and may
#      only copy from it. A uuid it returns that is not in that list is
#      dropped. A uuid is 36 characters and one transposition yields a pointer
#      that resolves to nothing forever, so this is checked, never trusted.
#   3. THE TWO FORBIDDEN WRITES ARE REFUSED BY CONSTRUCTION — never the
#      harness-owned session transcript, never a mistakes.jsonl (whose rows are
#      promoted into fleet-wide rules by a path this hook has no standing to
#      feed).
#   4. THE BLIND/LEGITIMATE LINE IS NOT BLURRED. gate-failopen.sh draws it and
#      ADR-001 states it: a hook that could not do its job records, a hook that
#      correctly decided there was nothing to do does not. A transcript that
#      is GONE is blind; a transcript that reads fine and holds no turn is a
#      decline. Blurring the two makes the log useless as a rate numerator.
#   5. IT NEVER BLOCKS. am-i-done-gate.sh is the Stop hook that emits a
#      `decision`, and it must stay the only one — two blocking Stop hooks make
#      an unclearable turn.
#
# ⚠ GATE_FAILOPEN_LOG DANGER — the same one gate-failopen.bats documents at
# length. gate_failopen() defaults to the REAL $HOME/.claude/gate-failopen.jsonl
# when the var is unset, which is how a test suite once leaked its own runs into
# production telemetry. Every invocation below goes through drive(), which pins
# GATE_FAILOPEN_LOG, WORKLOG_JSONL and HOME to scratch paths on every call.
# Never call the hook directly without it.
#
# ⚠ NO REAL MODEL CALL. drive() puts a stub `claude` first on PATH. A test that
# reached the real one would be slow, priced, and non-deterministic — and the
# hook's own re-entrancy guard means a live call fires this hook again.
#
# Run: bats hooks/tests/worklog-record.bats

setup() {
  HOOKS="$BATS_TEST_DIRNAME/.."
  HOOK="$HOOKS/worklog-record.sh"

  SCRATCH="$(mktemp -d "${BATS_TMPDIR:-/tmp}/wl.XXXXXX")"
  export GATE_FAILOPEN_LOG="$SCRATCH/gate-failopen.jsonl"
  export WORKLOG_JSONL="$SCRATCH/worklog.jsonl"

  FAKE_HOME="$(mktemp -d "${BATS_TMPDIR:-/tmp}/wl-home.XXXXXX")"
  mkdir -p "$FAKE_HOME/.claude/projects"

  SID="bats-wl-$$-$BATS_TEST_NUMBER"
  # The transcript lives in its OWN directory, one below the explicit store.
  # Without that separation the default store (a sibling of the transcript) and
  # the overridden store resolve to the same path, and the test that claims to
  # prove the default is a sibling proves nothing.
  TXDIR="$SCRATCH/proj"
  mkdir -p "$TXDIR"
  TX="$TXDIR/$SID.jsonl"

  # The stub model. Prints whatever CLAUDE_STUB holds, so each test states the
  # judgment it is testing against inline.
  STUB="$SCRATCH/bin"
  mkdir -p "$STUB"
  cat > "$STUB/claude" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf '%s' "${CLAUDE_STUB:-}"
SH
  chmod +x "$STUB/claude"

  # A PATH that has everything the hook touches BEFORE the jq check — and no
  # jq. Used as the WHOLE PATH (not a prefix), so jq is genuinely absent
  # rather than shadowed. `date` is here because gate-failopen.sh stamps its
  # line with it; without it the fail-open record loses its own timestamp.
  NOJQ="$SCRATCH/nojq"
  mkdir -p "$NOJQ"
  for _b in bash sh date cat rm mktemp sed grep tr timeout python3; do
    if _p="$(command -v "$_b" 2>/dev/null)"; then ln -sf "$_p" "$NOJQ/$_b"; fi
  done

  U0="00000000-0000-4000-8000-00000000aaa0"
  U1="11111111-1111-4111-8111-11111111aaa1"
  U2="22222222-2222-4222-8222-22222222aaa2"
  U3="33333333-3333-4333-8333-33333333aaa3"
  U4="44444444-4444-4444-8444-44444444aaa4"
  U5="55555555-5555-4555-8555-55555555aaa5"
  U6="66666666-6666-4666-8666-66666666aaa6"
}

teardown() {
  rm -rf "$SCRATCH" "$FAKE_HOME" 2>/dev/null || true
}

# --- fixtures -------------------------------------------------------------

user_line()  { jq -nc --arg u "$1" --arg t "$2" '{type:"user",uuid:$u,message:{role:"user",content:$t}}'; }
text_line()  { jq -nc --arg u "$1" --arg t "$2" '{type:"assistant",uuid:$u,message:{role:"assistant",content:[{type:"text",text:$t}]}}'; }
tool_line()  { jq -nc --arg u "$1" --arg n "$2" --argjson i "$3" '{type:"assistant",uuid:$u,message:{role:"assistant",content:[{type:"tool_use",name:$n,input:$i}]}}'; }
result_line(){ jq -nc --arg u "$1" --arg t "$2" '{type:"user",uuid:$u,message:{role:"user",content:[{type:"tool_result",content:$t}]}}'; }

# A transcript with one PRIOR turn and one current turn. The current turn
# writes two files by tool and two more by shell, and it ends on a bookkeeping
# line that carries NO uuid — the shape that makes "the last line" the wrong
# answer for end_uuid.
fixture_full() {
  {
    printf '{"type":"queue-operation"}\n'
    user_line  "$U0" "an earlier prompt"
    text_line  "$U6" "an earlier answer"
    user_line  "$U1" "do the thing"
    tool_line  "$U2" Write '{"file_path":"/repo/a.md"}'
    tool_line  "$U3" Edit  '{"file_path":"/repo/b.md"}'
    tool_line  "$U4" Bash  '{"command":"echo hi > /repo/c.txt && sed -i s/x/y/ /repo/d.md"}'
    result_line "$U5" "ok"
    printf '{"type":"atis-latch"}\n'
  } > "$TX"
}

payload() {
  jq -nc --arg s "$SID" --arg tp "${1:-$TX}" \
    '{session_id:$s, hook_event_name:"Stop", transcript_path:$tp, cwd:"/tmp"}'
}

# drive [stub-json] — run the hook inline with every path pinned to scratch.
# `env -u` clears the two variables that would make the hook decline for a
# reason unrelated to the test: this suite itself runs inside a Claude session.
drive() {
  printf '%s' "${PAYLOAD:-$(payload)}" | env -u CLAUDE_CODE_ENTRYPOINT -u WORKLOG_DISABLE \
    PATH="$STUB:$PATH" \
    HOME="$FAKE_HOME" \
    GATE_FAILOPEN_LOG="$GATE_FAILOPEN_LOG" \
    WORKLOG_JSONL="$WORKLOG_JSONL" \
    WORKLOG_SYNC=1 WORKLOG_SETTLE_SECS=0 \
    CLAUDE_STUB="${1:-}" \
    bash "$HOOK"
}

# drive_with VAR=VAL ... -- [stub-json]
# drive() with named overrides appended. `env` applies assignments left to
# right after option parsing, so an override here beats the pinned value above
# and beats the matching `-u`. Needed by the recursion-guard tests, which must
# SET exactly the two variables drive() clears.
#
# Overrides go through env's own argument list rather than a `bash -c` string.
# An earlier version interpolated PATH='...:$PATH' inside single quotes, which
# does not expand: PATH became a literal with a dollar in it, /bin left the
# search path, `bash` was unresolvable, and env exited 127 before the hook ran.
# Two guard tests "passed their no-row assertion" on a process that never
# started. Keep the environment structured; never rebuild it as a string.
drive_with() {
  local -a over=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do over+=("$1"); shift; done
  # `if`, not `[ … ] && shift`: bats runs tests under errexit, where a bare
  # failing `&&` list aborts the test rather than falling through.
  if [ "${1:-}" = "--" ]; then shift; fi
  printf '%s' "${PAYLOAD:-$(payload)}" | env -u CLAUDE_CODE_ENTRYPOINT -u WORKLOG_DISABLE \
    PATH="$STUB:$PATH" \
    HOME="$FAKE_HOME" \
    GATE_FAILOPEN_LOG="$GATE_FAILOPEN_LOG" \
    WORKLOG_JSONL="$WORKLOG_JSONL" \
    WORKLOG_SYNC=1 WORKLOG_SETTLE_SECS=0 \
    CLAUDE_STUB="${1:-}" \
    "${over[@]}" bash "$HOOK"
}

row()      { jq -c . "$WORKLOG_JSONL"; }
field()    { jq -r "$1" "$WORKLOG_JSONL"; }
why()      { jq -r '.why' "$GATE_FAILOPEN_LOG" 2>/dev/null; }
no_log()   { [ ! -s "$GATE_FAILOPEN_LOG" ]; }
no_row()   { [ ! -s "$WORKLOG_JSONL" ]; }

CLEAN='{"did":"did a thing","flag":null,"flag_uuids":[],"flag_quote":null}'

# ==========================================================================
# 1. the mechanical half
# ==========================================================================

@test "one turn produces exactly one line" {
  fixture_full
  run drive "$CLEAN"
  [ "$status" -eq 0 ]
  run bash -c "wc -l < '$WORKLOG_JSONL'"
  [ "$output" -eq 1 ]
}

@test "the line carries the full schema and nothing else" {
  fixture_full
  drive "$CLEAN"
  run bash -c "jq -r 'keys|sort|join(\",\")' '$WORKLOG_JSONL'"
  [ "$output" = "ask_uuid,changed,did,end_uuid,flag,flag_quote,flag_uuids,session,ts" ]
}

@test "ask_uuid is the LAST genuine user prompt, not the first in the file" {
  fixture_full
  drive "$CLEAN"
  [ "$(field .ask_uuid)" = "$U1" ]
}

@test "end_uuid skips trailing bookkeeping lines that carry no uuid" {
  # The fixture ends on an atis-latch. "The last line" would be a dead pointer.
  fixture_full
  drive "$CLEAN"
  [ "$(field .end_uuid)" = "$U5" ]
}

@test "ask_uuid and end_uuid both resolve to real records in the transcript" {
  fixture_full
  drive "$CLEAN"
  for u in "$(field .ask_uuid)" "$(field .end_uuid)"; do
    run bash -c "jq -R -r 'fromjson? | .uuid // empty' '$TX' | grep -Fxq -- '$u'"
    [ "$status" -eq 0 ]
  done
}

@test "changed is pulled from Write and Edit tool calls" {
  fixture_full
  drive "$CLEAN"
  run bash -c "jq -r '.changed|join(\",\")' '$WORKLOG_JSONL'"
  [[ "$output" == *"/repo/a.md"* ]]
  [[ "$output" == *"/repo/b.md"* ]]
}

@test "changed picks up a Bash redirect target and a sed -i target" {
  fixture_full
  drive "$CLEAN"
  run bash -c "jq -r '.changed|join(\",\")' '$WORKLOG_JSONL'"
  [[ "$output" == *"/repo/c.txt"* ]]
  [[ "$output" == *"/repo/d.md"* ]]
}

@test "a sed SCRIPT is never mistaken for a changed path" {
  # `s/x/y/` contains slashes, so a naive looks-like-a-path test records the
  # expression itself as a file. Both the bare and the -e form.
  # (A `|`-delimited script — `s|a|b|` — is a known blind spot: the segment
  # splitter treats those pipes as shell pipes. Not asserted here.)
  {
    user_line "$U1" "edit"
    tool_line "$U2" Bash '{"command":"sed -i s/x/y/ /repo/one.md"}'
    tool_line "$U3" Bash '{"command":"sed -i -e s/a/b/ /repo/two.md"}'
    text_line "$U6" "edited"
  } > "$TX"
  drive "$CLEAN"
  run bash -c "jq -r '.changed|join(\",\")' '$WORKLOG_JSONL'"
  [[ "$output" != *"s/x/y/"* ]]
  [[ "$output" != *"s/a/b/"* ]]
  [[ "$output" == *"/repo/one.md"* ]]
  [[ "$output" == *"/repo/two.md"* ]]
}

@test "a read-only turn reports no changed files" {
  {
    user_line "$U1" "just look"
    tool_line "$U2" Read '{"file_path":"/repo/a.md"}'
    tool_line "$U3" Bash '{"command":"grep -rn foo /repo > /dev/null"}'
    text_line "$U6" "looked"
  } > "$TX"
  drive "$CLEAN"
  [ "$(field '.changed|length')" -eq 0 ]
}

@test "changed comes from the transcript, NEVER from the model" {
  # THE LOAD-BEARING TEST. The stub names a file that was never touched and
  # omits the two that were. The record must ignore it entirely.
  fixture_full
  drive '{"did":"x","changed":["/fabricated/by-the-model.md"],"flag":null,"flag_uuids":[],"flag_quote":null}'
  run bash -c "jq -r '.changed|join(\",\")' '$WORKLOG_JSONL'"
  [[ "$output" != *"fabricated"* ]]
  [[ "$output" == *"/repo/a.md"* ]]
}

@test "the model cannot overwrite session, ts, ask_uuid or end_uuid either" {
  fixture_full
  drive '{"did":"x","session":"evil","ts":"1999-01-01T00:00:00Z","ask_uuid":"nope","end_uuid":"nope","flag":null,"flag_uuids":[],"flag_quote":null}'
  [ "$(field .session)" = "$SID" ]
  [ "$(field .ask_uuid)" = "$U1" ]
  [ "$(field .end_uuid)" = "$U5" ]
  run bash -c "jq -r '.ts' '$WORKLOG_JSONL'"
  [[ "$output" != "1999-01-01T00:00:00Z" ]]
}

# ==========================================================================
# 2. uuid discipline
# ==========================================================================

@test "a flag_uuid that is not in the candidate set is dropped" {
  fixture_full
  drive "$(jq -nc --arg a "$U1" '{did:"x",flag:"mistake",flag_uuids:[$a,"deadbeef-0000-4000-8000-000000000000"],flag_quote:"no"}')"
  run bash -c "jq -r '.flag_uuids|join(\",\")' '$WORKLOG_JSONL'"
  [ "$output" = "$U1" ]
}

@test "a transposed uuid resolves to nothing and is dropped, not written" {
  # 11111111-...-aaa1 with two characters swapped. Valid-looking, points nowhere.
  fixture_full
  drive "$(jq -nc '{did:"x",flag:"mistake",flag_uuids:["11111111-1111-4111-8111-11111111aa1a"],flag_quote:"no"}')"
  [ "$(field '.flag_uuids|length')" -eq 0 ]
}

@test "flag_uuids spanning two turns are both kept — a mistake needs an offense and a correction" {
  fixture_full
  drive "$(jq -nc --arg a "$U0" --arg b "$U1" '{did:"x",flag:"mistake",flag_uuids:[$a,$b],flag_quote:"do the thing"}')"
  run bash -c "jq -r '.flag_uuids|join(\",\")' '$WORKLOG_JSONL'"
  [ "$output" = "$U0,$U1" ]
}

@test "a non-string in flag_uuids cannot reach the record" {
  fixture_full
  drive "$(jq -nc --arg a "$U1" '{did:"x",flag:"mistake",flag_uuids:[$a,7,null,{}],flag_quote:"q"}')"
  run bash -c "jq -r '.flag_uuids|join(\",\")' '$WORKLOG_JSONL'"
  [ "$output" = "$U1" ]
}

# ==========================================================================
# 3. the flag is inert and narrow
# ==========================================================================

@test "flag is null on an ordinary turn" {
  fixture_full
  drive "$CLEAN"
  [ "$(field .flag)" = "null" ]
}

@test "any flag value other than the exact string mistake becomes null" {
  fixture_full
  drive '{"did":"x","flag":"severe","flag_uuids":[],"flag_quote":null}'
  [ "$(field .flag)" = "null" ]
}

@test "an unflagged row carries no anchors and no quote" {
  # Schema coherence: a reader must never have to ask what a quote with no
  # flag was supposed to mean.
  fixture_full
  drive "$(jq -nc --arg a "$U1" '{did:"x",flag:null,flag_uuids:[$a],flag_quote:"stray"}')"
  [ "$(field '.flag_uuids|length')" -eq 0 ]
  [ "$(field .flag_quote)" = "null" ]
}

@test "no severity, category or failure-mode key can enter the record" {
  fixture_full
  drive '{"did":"x","flag":"mistake","flag_uuids":[],"flag_quote":"q","severity":"high","category":"process","pattern":"some-fm"}'
  run bash -c "jq -r 'keys|sort|join(\",\")' '$WORKLOG_JSONL'"
  [ "$output" = "ask_uuid,changed,did,end_uuid,flag,flag_quote,flag_uuids,session,ts" ]
}

# ==========================================================================
# 4. the forbidden writes
# ==========================================================================

@test "it never writes the session transcript" {
  fixture_full
  before="$(cat "$TX")"
  drive "$CLEAN"
  [ "$(cat "$TX")" = "$before" ]
}

@test "a worklog path aimed at the transcript is refused" {
  fixture_full
  before="$(cat "$TX")"
  WORKLOG_JSONL="$TX" drive "$CLEAN"
  [ "$(cat "$TX")" = "$before" ]
  [ "$(why)" = "store-unwritable" ]
}

@test "a worklog path aimed at a mistakes.jsonl is refused" {
  # mistakes.jsonl rows are promoted into references/failure-modes/ and thence
  # into the @-imported common-mistakes.md. One row there becomes a fleet rule.
  fixture_full
  M="$SCRATCH/mistakes.jsonl"
  WORKLOG_JSONL="$M" drive "$CLEAN"
  [ ! -f "$M" ]
  [ "$(why)" = "store-unwritable" ]
}

@test "a worklog path shaped like any session jsonl is refused" {
  fixture_full
  S="$SCRATCH/aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee.jsonl"
  WORKLOG_JSONL="$S" drive "$CLEAN"
  [ ! -f "$S" ]
  [ "$(why)" = "store-unwritable" ]
}

@test "with no override the store is a sibling of the transcript" {
  fixture_full
  run env -u CLAUDE_CODE_ENTRYPOINT -u WORKLOG_DISABLE -u WORKLOG_JSONL \
    PATH="$STUB:$PATH" HOME="$FAKE_HOME" \
    GATE_FAILOPEN_LOG="$GATE_FAILOPEN_LOG" \
    WORKLOG_SYNC=1 WORKLOG_SETTLE_SECS=0 CLAUDE_STUB="$CLEAN" \
    bash -c "printf '%s' \"\$1\" | bash \"\$2\"" _ "$(payload)" "$HOOK"
  [ "$status" -eq 0 ]
  [ -s "$TXDIR/worklog.jsonl" ]         # beside the transcript
  [ ! -e "$SCRATCH/worklog.jsonl" ]     # not where the override would have put it
  # and the transcript itself is untouched
  run bash -c "wc -l < '$TX'"
  [ "$output" -eq 9 ]
}

# ==========================================================================
# 5. blind vs legitimate — the line ADR-001 and gate-failopen.sh draw
# ==========================================================================

@test "LEGITIMATE: a non-Stop event writes nothing and records nothing" {
  fixture_full
  PAYLOAD="$(jq -nc --arg s "$SID" --arg tp "$TX" '{session_id:$s,hook_event_name:"PreToolUse",transcript_path:$tp}')" \
    drive "$CLEAN"
  no_row
  no_log
}

@test "LEGITIMATE: a subagent turn is not logged" {
  fixture_full
  PAYLOAD="$(jq -nc --arg s "$SID" --arg tp "$TX" '{session_id:$s,hook_event_name:"Stop",transcript_path:$tp,agent_id:"a123"}')" \
    drive "$CLEAN"
  no_row
  no_log
}

@test "LEGITIMATE: a transcript that reads fine but holds no user prompt is a decline" {
  # NOT blind. The surface was readable and correctly held nothing to bracket
  # a turn with. Recording it would poison the fail-open rate.
  { printf '{"type":"queue-operation"}\n'; text_line "$U6" "orphan"; } > "$TX"
  drive "$CLEAN"
  no_row
  no_log
}

@test "LEGITIMATE: an empty transcript is a decline, not a fail-open" {
  : > "$TX"
  drive "$CLEAN"
  no_row
  no_log
}

@test "BLIND: a missing transcript is recorded as transcript-unreadable" {
  PAYLOAD="$(jq -nc --arg s "$SID" --arg tp "$SCRATCH/does-not-exist.jsonl" \
    '{session_id:$s,hook_event_name:"Stop",transcript_path:$tp}')" drive "$CLEAN"
  no_row
  [ "$(why)" = "transcript-unreadable" ]
}

@test "BLIND: an unparseable payload is recorded as malformed-payload" {
  PAYLOAD='not json at all' drive "$CLEAN"
  [ "$(why)" = "malformed-payload" ]
}

@test "BLIND: a payload that parses but is not an envelope is recorded separately" {
  PAYLOAD='"a bare string"' drive "$CLEAN"
  [ "$(why)" = "non-object-payload" ]
}

@test "BLIND: no jq is recorded, and reached without needing jq" {
  # The subject is a MISSING JQ, not a missing everything. An earlier version
  # used `env -i PATH=/nonexistent`, under which `bash` itself is unresolvable:
  # env exited 127 and the hook never ran, so the test proved nothing about jq.
  # $NOJQ therefore holds every binary the pre-jq path touches — and no jq.
  fixture_full

  # Harness self-check, first-class: assert the fixture is the shape claimed.
  run env PATH="$NOJQ" sh -c 'command -v bash'
  [ "$status" -eq 0 ]                       # bash IS reachable
  run env PATH="$NOJQ" sh -c 'command -v jq'
  [ "$status" -ne 0 ]                       # jq is NOT

  run env -u CLAUDE_CODE_ENTRYPOINT -u WORKLOG_DISABLE \
    PATH="$NOJQ" HOME="$FAKE_HOME" \
    GATE_FAILOPEN_LOG="$GATE_FAILOPEN_LOG" WORKLOG_JSONL="$WORKLOG_JSONL" \
    WORKLOG_SYNC=1 WORKLOG_SETTLE_SECS=0 \
    bash -c "printf '%s' \"\$1\" | bash \"\$2\"" _ "$(payload)" "$HOOK"
  [ "$status" -eq 0 ]                       # never blocks, even blind
  no_row
  [ "$(why)" = "no-jq" ]                    # and the fail-open IS on the record
}

@test "BLIND: the mechanical row is still written when the judgment is unavailable" {
  # A model outage must not lose the turn. The machine-settled half is the
  # durable part; the row lands, `did` is null, and the reason is on the record
  # so a later reader does not mistake it for a turn where nothing happened.
  fixture_full
  drive ""
  [ -s "$WORKLOG_JSONL" ]
  [ "$(field .did)" = "null" ]
  [ "$(field .ask_uuid)" = "$U1" ]
  run bash -c "jq -r '.changed|join(\",\")' '$WORKLOG_JSONL'"
  [[ "$output" == *"/repo/a.md"* ]]
  [ "$(why)" = "judgment-unavailable" ]
}

@test "BLIND: an unparseable judgment is treated as unavailable, not as content" {
  fixture_full
  drive 'I could not comply with that request.'
  [ "$(field .did)" = "null" ]
  [ "$(why)" = "judgment-unavailable" ]
}

@test "every why this hook emits survives gate-failopen's closed set unchanged" {
  # An unrecognized why is quarantined under an `unrecognized:` prefix, which
  # would silently keep these rows out of any rate a consumer computes.
  for w in transcript-unreadable judgment-unavailable store-unwritable \
           malformed-payload non-object-payload no-jq; do
    : > "$GATE_FAILOPEN_LOG"
    env HOME="$FAKE_HOME" GATE_FAILOPEN_LOG="$GATE_FAILOPEN_LOG" \
      bash -c ". '$HOOKS/lib/gate-failopen.sh'; gate_failopen 'worklog-record' '$w' 'sess1'"
    run bash -c "jq -r '.why' '$GATE_FAILOPEN_LOG'"
    [ "$output" = "$w" ]
  done
}

@test "fail-open rows are attributed to this writer, not to a gate" {
  PAYLOAD='not json at all' drive "$CLEAN"
  run bash -c "jq -r '.gate' '$GATE_FAILOPEN_LOG'"
  [ "$output" = "worklog-record" ]
}

# ==========================================================================
# 6. it never blocks, and never recurses
# ==========================================================================

@test "it never emits a decision — am-i-done-gate stays the only blocking Stop hook" {
  fixture_full
  run drive "$CLEAN"
  [ "$status" -eq 0 ]
  [[ "$output" != *'"decision"'* ]]
  [[ "$output" != *'"block"'* ]]
}

# Both guard tests below open with a POSITIVE CONTROL: the identical
# invocation WITHOUT the guard must write a row. A guard test that only
# asserts absence cannot tell "the guard stopped it" from "nothing ran" — and
# that is not hypothetical, it is how these two tests previously passed their
# no-row assertion on a process that exited 127 before reaching the hook.
# A recursion guard that silently does not work takes the machine down, so the
# control is the load-bearing half of each test, not ceremony.

@test "WORKLOG_DISABLE stops the hook dead — the recursion guard" {
  # The judgment call is itself a `claude` invocation, which fires this same
  # Stop hook in the child. Unguarded that is unbounded recursion.
  fixture_full

  run drive_with -- "$CLEAN"                 # control: the hook DOES run here
  [ "$status" -eq 0 ]
  [ -s "$WORKLOG_JSONL" ]
  : > "$WORKLOG_JSONL"
  : > "$GATE_FAILOPEN_LOG"

  run drive_with WORKLOG_DISABLE=1 -- "$CLEAN"
  [ "$status" -eq 0 ]
  no_row
  no_log
}

@test "sdk-cli is the second recursion guard, independent of the first" {
  fixture_full

  run drive_with -- "$CLEAN"                 # control
  [ "$status" -eq 0 ]
  [ -s "$WORKLOG_JSONL" ]
  : > "$WORKLOG_JSONL"
  : > "$GATE_FAILOPEN_LOG"

  # WORKLOG_DISABLE stays cleared by drive_with, so this proves the sdk-cli
  # arm alone — the two guards are independent, not one guard counted twice.
  run drive_with CLAUDE_CODE_ENTRYPOINT=sdk-cli -- "$CLEAN"
  [ "$status" -eq 0 ]
  no_row
  no_log
}

@test "the default path returns immediately rather than waiting on the model" {
  # The whole point of detaching: several workers land at once, and a
  # synchronous per-turn model call would serialize every one of them. The
  # stub sleeps well past what the parent may take.
  fixture_full
  cat > "$STUB/claude" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
sleep 10
printf '%s' "${CLAUDE_STUB:-}"
SH
  chmod +x "$STUB/claude"
  start=$(date +%s)
  printf '%s' "$(payload)" | env -u CLAUDE_CODE_ENTRYPOINT -u WORKLOG_DISABLE \
    PATH="$STUB:$PATH" HOME="$FAKE_HOME" GATE_FAILOPEN_LOG="$GATE_FAILOPEN_LOG" \
    WORKLOG_JSONL="$WORKLOG_JSONL" WORKLOG_SETTLE_SECS=0 CLAUDE_STUB="$CLEAN" \
    bash "$HOOK"
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -lt 5 ]
}

# ==========================================================================
# 7. record integrity
# ==========================================================================

@test "an apostrophe in did survives — the jq -n rule, not an echoed brace literal" {
  # scripts/log-record.sh's hard rule. An inline single-quoted JSON literal is
  # truncated by an apostrophe, and apostrophes in a one-line summary are the
  # common case, not the edge one.
  fixture_full
  drive "$(jq -nc '{did:"didn'"'"'t finish the agent'"'"'s edit",flag:null,flag_uuids:[],flag_quote:null}')"
  [ "$(field .did)" = "didn't finish the agent's edit" ]
}

@test "a newline in did cannot split one record across two lines" {
  fixture_full
  drive "$(jq -nc '{did:"line one\nline two",flag:null,flag_uuids:[],flag_quote:null}')"
  run bash -c "wc -l < '$WORKLOG_JSONL'"
  [ "$output" -eq 1 ]
  run bash -c "jq -e . '$WORKLOG_JSONL'"
  [ "$status" -eq 0 ]
}

@test "an over-long did is truncated rather than dropped" {
  fixture_full
  long="$(printf 'x%.0s' $(seq 1 900))"
  drive "$(jq -nc --arg d "$long" '{did:$d,flag:null,flag_uuids:[],flag_quote:null}')"
  run bash -c "jq -r '.did|length' '$WORKLOG_JSONL'"
  [ "$output" -le 200 ]
  [ "$output" -gt 0 ]
}

@test "a judgment wrapped in a markdown fence is still read" {
  fixture_full
  drive "$(printf '```json\n%s\n```' "$CLEAN")"
  [ "$(field .did)" = "did a thing" ]
  no_log
}

@test "two turns append rather than replace" {
  fixture_full
  drive "$CLEAN"
  drive "$CLEAN"
  run bash -c "wc -l < '$WORKLOG_JSONL'"
  [ "$output" -eq 2 ]
}

@test "every line is independently valid JSON" {
  fixture_full
  drive "$CLEAN"
  drive "$(jq -nc --arg a "$U1" '{did:"second",flag:"mistake",flag_uuids:[$a],flag_quote:"do the thing"}')"
  run bash -c "while IFS= read -r l; do printf '%s' \"\$l\" | jq -e . >/dev/null || exit 1; done < '$WORKLOG_JSONL'"
  [ "$status" -eq 0 ]
}
