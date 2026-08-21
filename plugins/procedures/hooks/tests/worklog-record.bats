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
#   6. ONE ROW PER TURN SURVIVES THE DEPLOYED SHAPE, not just the test shape.
#      Two Stop fires per turn is the normal path here, and on the default
#      dispatch they run CONCURRENTLY — see section 8b.
#
# ⚠ WORKLOG_SYNC=1 AND WORKLOG_SETTLE_SECS=0 HIDE THE RACE. drive() pins both,
# which serializes the two fires and lets the first finish writing before the
# second starts — the two conditions under which the dedup cannot be raced.
# They are pinned because a suite that paid the settle wait and detached every
# call would be slow and non-deterministic, NOT because the deployed path looks
# like that. Anything about ordering between fires belongs in section 8b, which
# drives the real detached path; a new test added to the sections above proves
# nothing about concurrency.
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
  # The transcript lives in its OWN directory, whose basename is the project
  # slug the default store is keyed by ("proj"). Keeping it out of $SCRATCH
  # also keeps the default store and the overridden store distinct paths, so a
  # test asserting where the default lands cannot pass by accident.
  TXDIR="$SCRATCH/proj"
  mkdir -p "$TXDIR"
  TX="$TXDIR/$SID.jsonl"

  # The stub model. Prints whatever CLAUDE_STUB holds, so each test states the
  # judgment it is testing against inline.
  STUB="$SCRATCH/bin"
  mkdir -p "$STUB"
  # CLAUDE_ARGV_LOG / CLAUDE_STDIN_LOG capture HOW the hook called the model,
  # not just that it did. Without them the stub is blind to which channel
  # carried the brief, and the delivery-channel regression below cannot fail.
  export CLAUDE_ARGV_LOG="$SCRATCH/claude-argv.txt"
  export CLAUDE_STDIN_LOG="$SCRATCH/claude-stdin.txt"
  cat > "$STUB/claude" <<'SH'
#!/usr/bin/env bash
[ -n "${CLAUDE_ARGV_LOG:-}" ] && printf '%s\0' "$@" >>"$CLAUDE_ARGV_LOG"
if [ -n "${CLAUDE_STDIN_LOG:-}" ]; then cat >>"$CLAUDE_STDIN_LOG"; else cat >/dev/null; fi
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
  U7="77777777-7777-4777-8777-77777777aaa7"
  U8="88888888-8888-4888-8888-88888888aaa8"
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

# A SECOND turn appended to the same transcript. Distinct from firing the hook
# twice over the same transcript: that is one turn seen twice, and the dedup
# key exists precisely to tell the two apart.
fixture_next_turn() {
  {
    user_line "$U7" "do another thing"
    text_line "$U8" "did another thing"
  } >> "$TX"
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

# The default model response. Its quote is VERBATIM from $U1's body ("do the
# thing") because an entry whose quote cannot be located in the candidate it
# cites is dropped — a fixture with an invented quote would silently produce
# empty arrays and every assertion built on it would pass for the wrong reason.
CLEAN="$(jq -nc --arg u "11111111-1111-4111-8111-11111111aaa1" \
  '{requests:[{text:"asked for the thing",quote:"do the thing",uuid:$u}],
    outcomes:[],mistakes:[]}')"

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
  [ "$output" = "ask_uuid,end_uuid,mistakes,outcomes,requests,session,ts" ]
}

@test "every entry carries text, quote and a uuid pointer — never a bare claim" {
  fixture_full
  drive "$CLEAN"
  run bash -c "jq -r '.requests[0]|keys|sort|join(\",\")' '$WORKLOG_JSONL'"
  [ "$output" = "quote,text,uuid" ]
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

# `changed` was dropped FROM THE ROW — it overlapped `outcomes` — but the
# slicer still computes it and the path detection is still worth protecting
# from regression. So these assert against wl_slice's own output rather than
# against a row field that no longer exists. Deleting them instead would have
# silently discarded the detection coverage along with the field.
# The hook cannot be sourced as a library: its top-level dispatch reads stdin
# and exits. So the function is lifted out by text and run on its own. Lifting
# the DEFINITION rather than re-implementing it is what keeps this a test of
# production code instead of a test of a copy.
slice_changed() {
  python3 - "$HOOK" > "$SCRATCH/slice.fn" <<'PY'
import sys
src = open(sys.argv[1]).read()
i = src.index('wl_slice() {')
j = src.index('\nPY\n}\n', i) + len('\nPY\n}\n')
sys.stdout.write(src[i:j])
PY
  bash -c "source '$SCRATCH/slice.fn'; wl_slice '$TX' 60" 2>/dev/null \
    | jq -r '.changed|join(",")'
}

@test "changed is pulled from Write and Edit tool calls" {
  fixture_full
  run slice_changed
  [[ "$output" == *"/repo/a.md"* ]]
  [[ "$output" == *"/repo/b.md"* ]]
}

@test "changed picks up a Bash redirect target and a sed -i target" {
  fixture_full
  run slice_changed
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
  run slice_changed
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
  run slice_changed
  [ -z "$output" ]
}

@test "a key the schema does not name cannot enter the record" {
  # THE LOAD-BEARING TEST. The stub returns extra top-level keys, including the
  # dropped `changed`. The row is BUILT from a fixed jq template rather than
  # merged from the model's object, so none of them can appear.
  fixture_full
  drive '{"requests":[],"outcomes":[],"mistakes":[],"changed":["/fabricated/by-the-model.md"],"severity":"high","did":"x"}'
  run bash -c "jq -r 'keys|sort|join(\",\")' '$WORKLOG_JSONL'"
  [ "$output" = "ask_uuid,end_uuid,mistakes,outcomes,requests,session,ts" ]
  run bash -c "cat '$WORKLOG_JSONL'"
  [[ "$output" != *"fabricated"* ]]
}

@test "a quote the model invented is dropped, not written as evidence" {
  # The whole point of the quote field. The stub cites a real uuid but a quote
  # that appears in NO candidate body; the entry must not survive, because a
  # summary carrying an unverifiable quote reads as evidence.
  fixture_full
  drive "$(jq -nc --arg u "$U1" \
    '{requests:[{text:"claims a thing",quote:"words nobody in this transcript said",uuid:$u}],
      outcomes:[],mistakes:[]}')"
  [ "$(field '.requests|length')" -eq 0 ]
}

@test "a quote cited to the WRONG line is dropped even though the text is real" {
  # Verbatim from $U0's body, but attributed to $U1. Matching the quote against
  # the whole blob would accept this; matching it against the body of the line
  # it CITES is what makes the uuid a real pointer rather than decoration.
  fixture_full
  drive "$(jq -nc --arg u "$U1" \
    '{requests:[{text:"misaddressed",quote:"an earlier prompt",uuid:$u}],
      outcomes:[],mistakes:[]}')"
  [ "$(field '.requests|length')" -eq 0 ]
}

@test "a uuid outside the candidate set is dropped" {
  fixture_full
  drive '{"requests":[{"text":"bad pointer","quote":"do the thing","uuid":"99999999-9999-4999-8999-99999999zzzz"}],"outcomes":[],"mistakes":[]}'
  [ "$(field '.requests|length')" -eq 0 ]
}

@test "a mistake needs BOTH the offense and the correction to be recorded" {
  # One uuid names a moment, not a correction. Without the pair there is
  # nothing for a reader to compare, so the entry is dropped.
  fixture_full
  drive "$(jq -nc --arg u "$U1" \
    '{requests:[],outcomes:[],
      mistakes:[{text:"only one anchor",quote:"do the thing",uuids:[$u]}]}')"
  [ "$(field '.mistakes|length')" -eq 0 ]
}

@test "a mistake pair spanning two turns is kept, and keeps both uuids" {
  fixture_full
  drive "$(jq -nc --arg a "$U0" --arg b "$U1" \
    '{requests:[],outcomes:[],
      mistakes:[{text:"offense then correction",quote:"do the thing",uuids:[$a,$b]}]}')"
  [ "$(field '.mistakes|length')" -eq 1 ]
  [ "$(field '.mistakes[0].uuids|length')" -eq 2 ]
}

@test "an over-long text is truncated to the documented cap, not dropped" {
  fixture_full
  local long
  long="$(python3 -c 'print("x"*400)')"
  drive "$(jq -nc --arg u "$U1" --arg t "$long" \
    '{requests:[{text:$t,quote:"do the thing",uuid:$u}],outcomes:[],mistakes:[]}')"
  [ "$(field '.requests[0].text|length')" -eq 100 ]
}

@test "the stored quote is SLICED from the transcript, not the model's retyping" {
  # The model sends the quote with mangled spacing. What lands must be the run
  # as it appears in the candidate body, so the field cannot drift from what
  # was actually verified.
  fixture_full
  drive "$(jq -nc --arg u "$U1" \
    '{requests:[{text:"spacing mangled",quote:"do   the    thing",uuid:$u}],
      outcomes:[],mistakes:[]}')"
  [ "$(field '.requests[0].quote')" = "do the thing" ]
}

@test "the model cannot overwrite session, ts, ask_uuid or end_uuid either" {
  fixture_full
  drive '{"requests":[],"outcomes":[],"mistakes":[],"session":"evil","ts":"1999-01-01T00:00:00Z","ask_uuid":"nope","end_uuid":"nope"}'
  [ "$(field .session)" = "$SID" ]
  [ "$(field .ask_uuid)" = "$U1" ]
  [ "$(field .end_uuid)" = "$U5" ]
  run bash -c "jq -r '.ts' '$WORKLOG_JSONL'"
  [[ "$output" != "1999-01-01T00:00:00Z" ]]
}

# ==========================================================================
# 2. uuid discipline
# ==========================================================================

@test "a mistake uuid that is not in the candidate set is dropped" {
  # The bad uuid is removed and the entry survives on the remaining pair.
  fixture_full
  drive "$(jq -nc --arg a "$U0" --arg b "$U1" \
    '{requests:[],outcomes:[],
      mistakes:[{text:"x",quote:"do the thing",
                 uuids:[$a,$b,"deadbeef-0000-4000-8000-000000000000"]}]}')"
  run bash -c "jq -r '.mistakes[0].uuids|join(\",\")' '$WORKLOG_JSONL'"
  [ "$output" = "$U0,$U1" ]
}

@test "a transposed uuid resolves to nothing and is dropped, not written" {
  # 11111111-...-aaa1 with two characters swapped. Valid-looking, points nowhere.
  # With only the transposed uuid left the pair is incomplete, so the whole
  # entry goes — a mistake anchored to one line cannot be audited.
  fixture_full
  drive "$(jq -nc --arg a "$U0" \
    '{requests:[],outcomes:[],
      mistakes:[{text:"x",quote:"an earlier prompt",
                 uuids:[$a,"11111111-1111-4111-8111-11111111aa1a"]}]}')"
  [ "$(field '.mistakes|length')" -eq 0 ]
}

@test "a non-string in a uuid list cannot reach the record" {
  fixture_full
  drive "$(jq -nc --arg a "$U0" --arg b "$U1" \
    '{requests:[],outcomes:[],
      mistakes:[{text:"x",quote:"do the thing",uuids:[$a,7,null,{},$b]}]}')"
  run bash -c "jq -r '.mistakes[0].uuids|join(\",\")' '$WORKLOG_JSONL'"
  [ "$output" = "$U0,$U1" ]
}

# ==========================================================================
# 3. the mistakes array is inert and narrow
# ==========================================================================

@test "mistakes is empty on an ordinary turn" {
  fixture_full
  drive "$CLEAN"
  [ "$(field '.mistakes|length')" -eq 0 ]
}

@test "an entry with no text is dropped even when its quote verifies" {
  # text is the claim; a quote with nothing claimed about it is not a record.
  fixture_full
  drive "$(jq -nc --arg u "$U1" \
    '{requests:[{text:"",quote:"do the thing",uuid:$u}],outcomes:[],mistakes:[]}')"
  [ "$(field '.requests|length')" -eq 0 ]
}

@test "a quote copied from a candidate line survives verification" {
  # POSITIVE CONTROL for the dropping tests: verification must be capable of
  # PASSING, or "the array was empty" proves nothing about the check.
  fixture_full
  drive "$CLEAN"
  [ "$(field '.requests|length')" -eq 1 ]
  [ "$(field '.requests[0].quote')" = "do the thing" ]
}

@test "one bad entry is dropped without taking the good ones with it" {
  # Per-entry verification, not all-or-nothing: a single unverifiable quote
  # must not cost the reader the rest of the row.
  fixture_full
  drive "$(jq -nc --arg u "$U1" --arg e "$U0" \
    '{requests:[{text:"good",quote:"do the thing",uuid:$u},
                {text:"bad",quote:"never said anywhere",uuid:$e}],
      outcomes:[],mistakes:[]}')"
  [ "$(field '.requests|length')" -eq 1 ]
  [ "$(field '.requests[0].text')" = "good" ]
}

@test "a quote cannot be stitched together from two different candidates" {
  # "an earlier answer" and "do the thing" are separate records. Matching over
  # the joined candidate blob rather than per line would accept a span crossing
  # them, which points at a line that does not exist.
  fixture_full
  drive "$(jq -nc --arg u "$U1" \
    '{requests:[{text:"stitched",quote:"an earlier answer do the thing",uuid:$u}],
      outcomes:[],mistakes:[]}')"
  [ "$(field '.requests|length')" -eq 0 ]
}

@test "no severity, category or failure-mode key can enter an entry" {
  fixture_full
  drive "$(jq -nc --arg u "$U1" \
    '{requests:[{text:"x",quote:"do the thing",uuid:$u,
                 severity:"high",category:"process",pattern:"some-fm"}],
      outcomes:[],mistakes:[]}')"
  run bash -c "jq -r '.requests[0]|keys|sort|join(\",\")' '$WORKLOG_JSONL'"
  [ "$output" = "quote,text,uuid" ]
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

@test "with no override the store is under ~/.claude/worklog, NOT beside the transcript" {
  # The transcript lives under ~/.claude/projects/<slug>/, and other tools glob
  # that directory for `*.jsonl` and treat what they find as session data: one
  # sweeps it into corpus, another takes the NEWEST match as the transcript —
  # and a file rewritten every turn is permanently the newest. So the store is
  # keyed by project slug OUTSIDE that tree. Asserting the absence beside the
  # transcript is the half of this test that protects the other tools.
  fixture_full
  run env -u CLAUDE_CODE_ENTRYPOINT -u WORKLOG_DISABLE -u WORKLOG_JSONL \
    PATH="$STUB:$PATH" HOME="$FAKE_HOME" \
    GATE_FAILOPEN_LOG="$GATE_FAILOPEN_LOG" \
    WORKLOG_SYNC=1 WORKLOG_SETTLE_SECS=0 CLAUDE_STUB="$CLEAN" \
    bash -c "printf '%s' \"\$1\" | bash \"\$2\"" _ "$(payload)" "$HOOK"
  [ "$status" -eq 0 ]
  # TXDIR is named "proj", so the slug is "proj"
  [ -s "$FAKE_HOME/.claude/worklog/proj.jsonl" ]
  [ ! -e "$TXDIR/worklog.jsonl" ]       # NOT beside the transcript
  [ ! -e "$SCRATCH/worklog.jsonl" ]     # not where the override would have put it
  # nothing new in the transcript's own directory at all
  run bash -c "ls '$TXDIR' | wc -l"
  [ "$output" -eq 1 ]
  # and the transcript itself is untouched
  run bash -c "wc -l < '$TX'"
  [ "$output" -eq 9 ]
}

@test "the default store directory is created when absent" {
  # ~/.claude/worklog/ will not exist on a first run. Failing to make it must
  # not lose the row.
  fixture_full
  [ ! -d "$FAKE_HOME/.claude/worklog" ]
  run env -u CLAUDE_CODE_ENTRYPOINT -u WORKLOG_DISABLE -u WORKLOG_JSONL \
    PATH="$STUB:$PATH" HOME="$FAKE_HOME" \
    GATE_FAILOPEN_LOG="$GATE_FAILOPEN_LOG" \
    WORKLOG_SYNC=1 WORKLOG_SETTLE_SECS=0 CLAUDE_STUB="$CLEAN" \
    bash -c "printf '%s' \"\$1\" | bash \"\$2\"" _ "$(payload)" "$HOOK"
  [ "$status" -eq 0 ]
  [ -d "$FAKE_HOME/.claude/worklog" ]
  no_log
}

@test "a project slug full of dashes is not mistaken for a session file" {
  # The store-safety check refuses anything shaped like a session transcript.
  # A project slug is all dashes — `-home-ubuntu--claude` has four — so a check
  # that merely COUNTS dashes would refuse the hook's own default store and
  # every row would be lost to a fail-open. It matches the real uuid shape.
  fixture_full
  SLUGDIR="$SCRATCH/-home-ubuntu--claude"
  mkdir -p "$SLUGDIR"
  mv "$TX" "$SLUGDIR/$SID.jsonl"
  PAYLOAD="$(payload "$SLUGDIR/$SID.jsonl")"
  run env -u CLAUDE_CODE_ENTRYPOINT -u WORKLOG_DISABLE -u WORKLOG_JSONL \
    PATH="$STUB:$PATH" HOME="$FAKE_HOME" \
    GATE_FAILOPEN_LOG="$GATE_FAILOPEN_LOG" \
    WORKLOG_SYNC=1 WORKLOG_SETTLE_SECS=0 CLAUDE_STUB="$CLEAN" \
    bash -c "printf '%s' \"\$1\" | bash \"\$2\"" _ "$PAYLOAD" "$HOOK"
  [ "$status" -eq 0 ]
  [ -s "$FAKE_HOME/.claude/worklog/-home-ubuntu--claude.jsonl" ]
  no_log
}

@test "a traversal session_id cannot escape into the projects glob" {
  # The payload is harness-controlled, so this is hardening rather than a live
  # exploit — but a session_id is interpolated into a path, and a traversal
  # that reaches a glob is not a thing to leave standing on the grounds that
  # today's caller is trusted. Sanitized through the same character class
  # turn-state.sh uses.
  fixture_full

  # (a) with transcript_path present the glob is never reached, but the same
  # id still lands in the row — so prove it is sanitized there too.
  PAYLOAD="$(jq -nc --arg tp "$TX" \
    '{session_id:"../../../../tmp/pwned", hook_event_name:"Stop",
      transcript_path:$tp, cwd:"/tmp"}')"
  run drive "$CLEAN"
  [ "$status" -eq 0 ]
  run bash -c "jq -r '.session' '$WORKLOG_JSONL'"
  case "$output" in */*|*..*) false ;; esac

  # (b) with transcript_path ABSENT the hook falls back to the
  # $HOME/.claude/projects/*/<sid>.jsonl glob — the path the traversal was
  # aiming at. It must resolve nothing and write nothing outside scratch.
  : > "$WORKLOG_JSONL"
  : > "$GATE_FAILOPEN_LOG"
  PAYLOAD="$(jq -nc \
    '{session_id:"../../../../tmp/pwned", hook_event_name:"Stop", cwd:"/tmp"}')"
  run drive "$CLEAN"
  [ "$status" -eq 0 ]
  no_row
  [ ! -e "/tmp/pwned.jsonl" ]
  [ "$(why)" = "transcript-unreadable" ]
}

@test "a payload with no session_id records under the same 'unknown' bucket turn-state uses" {
  # ts_session_id falls back to a single stable "unknown". Falling back to
  # empty here instead would name one condition two different things across
  # hooks that are meant to be joinable on `session`.
  fixture_full
  PAYLOAD="$(jq -nc --arg tp "$TX" \
    '{hook_event_name:"Stop", transcript_path:$tp, cwd:"/tmp"}')"
  drive "$CLEAN"
  [ "$(field .session)" = "unknown" ]
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
  # durable part; the row lands with three EMPTY arrays — never a missing key,
  # so a reader can tell "nothing was judged" from "the field is absent" — and
  # the reason is on the record so a later reader does not mistake it for a
  # turn where nothing happened.
  fixture_full
  drive ""
  [ -s "$WORKLOG_JSONL" ]
  [ "$(field '.requests|length')" -eq 0 ]
  [ "$(field '.outcomes|length')" -eq 0 ]
  [ "$(field '.mistakes|length')" -eq 0 ]
  run bash -c "jq -r 'keys|sort|join(\",\")' '$WORKLOG_JSONL'"
  [ "$output" = "ask_uuid,end_uuid,mistakes,outcomes,requests,session,ts" ]
  [ "$(field .ask_uuid)" = "$U1" ]
  [ "$(why)" = "judgment-unavailable" ]
}

@test "BLIND: an unparseable judgment is treated as unavailable, not as content" {
  fixture_full
  drive 'I could not comply with that request.'
  [ "$(field '.requests|length')" -eq 0 ]
  [ "$(why)" = "judgment-unavailable" ]
}

@test "BLIND: a detach that cannot start is recorded as detach-failed" {
  # NOT store-unwritable. wl_detach fails when mktemp fails or $TMPDIR is
  # unwritable; the store is never touched on that path, so naming it sends a
  # later reader to the wrong directory to look for a fault that is not there.
  #
  # Drives the DEFAULT path deliberately — no WORKLOG_SYNC — because the branch
  # under test only exists there.
  fixture_full

  # POSITIVE CONTROL: the same invocation with a usable $TMPDIR detaches fine
  # and records nothing, so the record below is the missing TMPDIR and not the
  # harness.
  run env -u CLAUDE_CODE_ENTRYPOINT -u WORKLOG_DISABLE \
    PATH="$STUB:$PATH" HOME="$FAKE_HOME" \
    GATE_FAILOPEN_LOG="$GATE_FAILOPEN_LOG" WORKLOG_JSONL="$WORKLOG_JSONL" \
    TMPDIR="$SCRATCH" WORKLOG_SETTLE_SECS=0 CLAUDE_STUB="$CLEAN" \
    bash -c "printf '%s' \"\$1\" | bash \"\$2\"" _ "$(payload)" "$HOOK"
  [ "$status" -eq 0 ]
  no_log
  # Let the detached child of the control finish before the real case runs, so
  # its row cannot land mid-assertion below.
  for _ in $(seq 1 40); do
    if [ -s "$WORKLOG_JSONL" ]; then break; fi
    sleep 0.25
  done
  : > "$WORKLOG_JSONL"
  : > "$GATE_FAILOPEN_LOG"

  run env -u CLAUDE_CODE_ENTRYPOINT -u WORKLOG_DISABLE \
    PATH="$STUB:$PATH" HOME="$FAKE_HOME" \
    GATE_FAILOPEN_LOG="$GATE_FAILOPEN_LOG" WORKLOG_JSONL="$WORKLOG_JSONL" \
    TMPDIR="$SCRATCH/no-such-dir" WORKLOG_SETTLE_SECS=0 CLAUDE_STUB="$CLEAN" \
    bash -c "printf '%s' \"\$1\" | bash \"\$2\"" _ "$(payload)" "$HOOK"
  [ "$status" -eq 0 ]                    # never blocks, even blind
  no_row
  [ "$(why)" = "detach-failed" ]
}

@test "every why this hook emits survives gate-failopen's closed set unchanged" {
  # An unrecognized why is quarantined under an `unrecognized:` prefix, which
  # would silently keep these rows out of any rate a consumer computes.
  for w in transcript-unreadable judgment-unavailable store-unwritable \
           malformed-payload non-object-payload no-jq detach-failed; do
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

@test "the default path returns before the model call finishes, and the child still lands the row" {
  # The whole point of detaching: several workers land at once, and a
  # synchronous per-turn model call would serialize every one of them.
  #
  # THE SLEEP IS SHORT ON PURPOSE. An earlier version slept 10s and asserted
  # only that the parent returned inside 5 — which left a child still running
  # against $SCRATCH when teardown deleted it, and proved nothing about
  # whether the detached half ever did the work. Sleep just long enough to
  # separate parent from child, then WAIT for the child instead of abandoning
  # it.
  fixture_full
  cat > "$STUB/claude" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
sleep 2
printf '%s' "${CLAUDE_STUB:-}"
SH
  chmod +x "$STUB/claude"

  start=$(date +%s)
  printf '%s' "$(payload)" | env -u CLAUDE_CODE_ENTRYPOINT -u WORKLOG_DISABLE \
    PATH="$STUB:$PATH" HOME="$FAKE_HOME" GATE_FAILOPEN_LOG="$GATE_FAILOPEN_LOG" \
    WORKLOG_JSONL="$WORKLOG_JSONL" WORKLOG_SETTLE_SECS=0 CLAUDE_STUB="$CLEAN" \
    bash "$HOOK"
  elapsed=$(( $(date +%s) - start ))

  # The parent returned while the child was still inside its 2s model call.
  [ "$elapsed" -lt 2 ]
  # ...which is only meaningful because the row was NOT there yet.
  no_row

  # Bounded poll: the child is reparented to init, so it cannot be `wait`ed
  # for. Poll up to ~10s, well past the stub's 2s, and fail loudly rather than
  # hanging if it never arrives.
  for _ in $(seq 1 40); do
    if [ -s "$WORKLOG_JSONL" ]; then break; fi
    sleep 0.25
  done
  [ -s "$WORKLOG_JSONL" ]
  [ "$(field '.requests[0].text')" = "asked for the thing" ]
  # The child is done before teardown removes $SCRATCH out from under it.
}

# ==========================================================================
# 7. record integrity
# ==========================================================================

@test "an apostrophe in text survives — the jq -n rule, not an echoed brace literal" {
  # scripts/log-record.sh's hard rule. An inline single-quoted JSON literal is
  # truncated by an apostrophe, and apostrophes in a one-line summary are the
  # common case, not the edge one.
  fixture_full
  drive "$(jq -nc --arg u "$U1" \
    '{requests:[{text:"didn'"'"'t finish the agent'"'"'s edit",quote:"do the thing",uuid:$u}],
      outcomes:[],mistakes:[]}')"
  [ "$(field '.requests[0].text')" = "didn't finish the agent's edit" ]
}

@test "a newline in text cannot split one record across two lines" {
  fixture_full
  drive "$(jq -nc --arg u "$U1" \
    '{requests:[{text:"line one\nline two",quote:"do the thing",uuid:$u}],
      outcomes:[],mistakes:[]}')"
  run bash -c "wc -l < '$WORKLOG_JSONL'"
  [ "$output" -eq 1 ]
  run bash -c "jq -e . '$WORKLOG_JSONL'"
  [ "$status" -eq 0 ]
}

@test "an over-long text is truncated rather than the entry dropped" {
  fixture_full
  long="$(printf 'x%.0s' $(seq 1 900))"
  drive "$(jq -nc --arg u "$U1" --arg d "$long" \
    '{requests:[{text:$d,quote:"do the thing",uuid:$u}],outcomes:[],mistakes:[]}')"
  [ "$(field '.requests|length')" -eq 1 ]
  run bash -c "jq -r '.requests[0].text|length' '$WORKLOG_JSONL'"
  [ "$output" -eq 100 ]
}

@test "an over-long quote is truncated rather than the entry dropped" {
  # The candidate bodies are themselves capped at 200 by the slicer's flat(),
  # so the reachable ceiling here is that cap; what matters is that a long
  # verified quote is trimmed to the documented bound and kept.
  fixture_full
  {
    user_line "$U1" "$(printf 'y%.0s' $(seq 1 190))"
    text_line "$U6" "ok"
  } > "$TX"
  drive "$(jq -nc --arg u "$U1" --arg q "$(printf 'y%.0s' $(seq 1 190))" \
    '{requests:[{text:"long quote",quote:$q,uuid:$u}],outcomes:[],mistakes:[]}')"
  [ "$(field '.requests|length')" -eq 1 ]
  run bash -c "jq -r '.requests[0].quote|length' '$WORKLOG_JSONL'"
  [ "$output" -eq 120 ]
}

@test "a judgment wrapped in a markdown fence is still read" {
  fixture_full
  drive "$(printf '```json\n%s\n```' "$CLEAN")"
  [ "$(field '.requests[0].text')" = "asked for the thing" ]
  no_log
}

@test "two DIFFERENT turns append rather than replace" {
  fixture_full
  drive "$CLEAN"
  fixture_next_turn
  drive "$CLEAN"
  run bash -c "wc -l < '$WORKLOG_JSONL'"
  [ "$output" -eq 2 ]
  # and they are two distinct turns, not one turn written twice
  run bash -c "jq -r '.ask_uuid' '$WORKLOG_JSONL' | sort -u | wc -l"
  [ "$output" -eq 2 ]
}

# ==========================================================================
# 8. one row per turn — Stop fires twice for one turn on the NORMAL path
# ==========================================================================
# am-i-done-gate.sh BLOCKS the first Stop and releases the next, so a turn
# firing Stop twice is this fleet's ordinary behaviour, not an edge case. Both
# fires bracket the same turn, so both slice to the same ask_uuid; without a
# key the "one line per turn" contract in the README is simply false.

@test "firing twice for ONE turn writes one row" {
  fixture_full
  drive "$CLEAN"
  drive "$CLEAN"
  run bash -c "wc -l < '$WORKLOG_JSONL'"
  [ "$output" -eq 1 ]
}

@test "a repeat fire is a decline, not a fail-open" {
  # The hook DID its job on the first fire. Recording the second as a blind
  # failure would put a fail-open in the log for a turn that was logged fine,
  # which is the exact blurring gate-failopen.sh forbids.
  fixture_full
  drive "$CLEAN"
  : > "$GATE_FAILOPEN_LOG"
  run drive "$CLEAN"
  [ "$status" -eq 0 ]
  no_log
}

@test "a repeat fire does not pay for a second model call" {
  # Dedup is checked BEFORE the judgment. If it were checked after, every
  # double-Stop turn would buy an answer and throw it away.
  fixture_full
  COUNT="$SCRATCH/model-calls"
  : > "$COUNT"
  cat > "$STUB/claude" <<SH
#!/usr/bin/env bash
cat >/dev/null
printf 'x' >> "$COUNT"
printf '%s' "\${CLAUDE_STUB:-}"
SH
  chmod +x "$STUB/claude"
  drive "$CLEAN"
  drive "$CLEAN"
  run bash -c "wc -c < '$COUNT'"
  [ "$output" -eq 1 ]
}

# --------------------------------------------------------------------------
# 8b. ...and the two fires OVERLAP, so a store scan alone cannot key them
# --------------------------------------------------------------------------
# Every test above pins WORKLOG_SYNC=1 and WORKLOG_SETTLE_SECS=0, which are
# exactly the two conditions that make the race structurally impossible: the
# fires serialize, and the first has finished writing before the second starts.
# The deployed path does neither. Both fires detach, so fire 2 lands while fire
# 1 is still inside a judgment call that has written nothing — a scan-then-
# write reads "not seen", buys a second answer and appends a duplicate. These
# tests drive the REAL detached path.

# fire_detached — one Stop fire on the default (detached) dispatch.
fire_detached() {
  printf '%s' "${PAYLOAD:-$(payload)}" | env -u CLAUDE_CODE_ENTRYPOINT -u WORKLOG_DISABLE \
    PATH="$STUB:$PATH" HOME="$FAKE_HOME" \
    GATE_FAILOPEN_LOG="$GATE_FAILOPEN_LOG" WORKLOG_JSONL="$WORKLOG_JSONL" \
    WORKLOG_SETTLE_SECS=0 CLAUDE_STUB="${1:-$CLEAN}" \
    bash "$HOOK"
}

@test "two OVERLAPPING detached fires write one row and pay for one model call" {
  fixture_full
  COUNT="$SCRATCH/model-calls"

  # POSITIVE CONTROLS. Both assertions at the end are counts, and a count that
  # can never exceed 1 proves nothing. Seed each surface with the duplicate
  # this test exists to forbid and watch the check SEE it, then reset.
  printf '%s\n%s\n' '{"ask_uuid":"x"}' '{"ask_uuid":"x"}' > "$WORKLOG_JSONL"
  run bash -c "wc -l < '$WORKLOG_JSONL'"
  [ "$output" -eq 2 ]
  printf 'xx' > "$COUNT"
  run bash -c "wc -c < '$COUNT'"
  [ "$output" -eq 2 ]
  : > "$WORKLOG_JSONL"
  : > "$COUNT"

  # The stub counts the call BEFORE it sleeps, so a second call is visible
  # immediately rather than only after the window closes. The sleep is what
  # holds the race open: fire 1 sits in here, having written nothing, for the
  # whole time fire 2 is deciding.
  cat > "$STUB/claude" <<SH
#!/usr/bin/env bash
cat >/dev/null
printf 'x' >> "$COUNT"
sleep 4
printf '%s' "\${CLAUDE_STUB:-}"
SH
  chmod +x "$STUB/claude"

  fire_detached "$CLEAN"
  sleep 1                    # fire 1 is now inside the stub's 4s call
  fire_detached "$CLEAN"     # ...and fire 2 arrives mid-window, as it does live

  # Poll for the row, then wait past the stub's sleep so a SECOND child that
  # wrongly ran to completion would have landed its duplicate before counting.
  for _ in $(seq 1 60); do
    if [ -s "$WORKLOG_JSONL" ]; then break; fi
    sleep 0.25
  done
  sleep 3

  run bash -c "wc -l < '$WORKLOG_JSONL'"
  [ "$output" -eq 1 ]
  run bash -c "wc -c < '$COUNT'"
  [ "$output" -eq 1 ]
  # The loser is a legitimate decline — another fire IS recording the turn —
  # so it must not leave a fail-open behind.
  no_log
  # And the claim is released once the row is durable, so markers do not
  # accumulate one-per-turn beside the store forever.
  [ ! -d "$SCRATCH/.worklog.jsonl.claims/$U1" ]
}

@test "a claim marker cannot permanently suppress its turn" {
  # A fire that claims and is then killed before appending leaves a marker
  # nobody will release. Markers are per-ask_uuid, so a stuck one can only ever
  # suppress its own turn — and it must not suppress even that one forever.
  fixture_full
  CLAIMS="$SCRATCH/.worklog.jsonl.claims"
  mkdir -p "$CLAIMS/$U1"

  # CONTROL: a FRESH marker really does hold the turn back. Without this, the
  # reclaim below could pass on a marker that was never load-bearing.
  run drive "$CLEAN"
  [ "$status" -eq 0 ]
  no_row
  no_log

  # Aged past any live fire, the marker is stolen and the turn is recorded.
  touch -d '@1' "$CLAIMS/$U1"
  run drive "$CLEAN"
  [ "$status" -eq 0 ]
  [ -s "$WORKLOG_JSONL" ]
  [ "$(field .ask_uuid)" = "$U1" ]
  no_log
  [ ! -d "$CLAIMS/$U1" ]
}

@test "a claim directory that cannot be created fails OPEN rather than dropping the turn" {
  # ADR-001: an environmental failure to claim is not evidence that someone
  # else owns the turn. A possible duplicate row beats a silently dropped one.
  fixture_full
  CLAIMS="$SCRATCH/.worklog.jsonl.claims"
  # A FILE where the claims directory must go — mkdir -p cannot proceed.
  printf 'in the way\n' > "$CLAIMS"
  run drive "$CLEAN"
  [ "$status" -eq 0 ]
  [ -s "$WORKLOG_JSONL" ]
  [ "$(field .ask_uuid)" = "$U1" ]
  no_log
}

@test "a non-numeric WORKLOG_DEDUP_SCAN falls back rather than disabling the dedup" {
  # WORKLOG_DEDUP_SCAN is the count that reaches `tail -n`. A typo'd value makes
  # tail error, the error is swallowed by 2>/dev/null, wl_seen reports "not
  # seen", and the second Stop fire of EVERY turn writes a duplicate row — the
  # one-row-per-turn key silently off, with no failure anywhere to notice it.
  # `0` is rejected for the same reason by a quieter route: `tail -n 0` is not
  # an error, it just prints nothing.
  fixture_full

  # POSITIVE CONTROL, same reason the recursion-guard tests carry one: with a
  # VALID value the identical drive must write a row. Absence-only assertions
  # cannot tell a working dedup from a harness that never ran the hook.
  run drive_with WORKLOG_DEDUP_SCAN=500 -- "$CLEAN"
  [ "$status" -eq 0 ]
  [ -s "$WORKLOG_JSONL" ]
  run drive_with WORKLOG_DEDUP_SCAN=500 -- "$CLEAN"
  [ "$status" -eq 0 ]
  run bash -c "wc -l < '$WORKLOG_JSONL'"
  [ "$output" -eq 1 ]

  for bad in abc 0 -5 " " 12abc; do
    : > "$WORKLOG_JSONL"
    : > "$GATE_FAILOPEN_LOG"
    run drive_with WORKLOG_DEDUP_SCAN="$bad" -- "$CLEAN"
    [ "$status" -eq 0 ]
    [ -s "$WORKLOG_JSONL" ]              # the first fire still records the turn
    run drive_with WORKLOG_DEDUP_SCAN="$bad" -- "$CLEAN"
    [ "$status" -eq 0 ]
    run bash -c "wc -l < '$WORKLOG_JSONL'"
    [ "$output" -eq 1 ]                  # ...and the second fire is deduped
  done
}

@test "null-keyed rows already in the store do not block a new row" {
  # wl_seen refuses to treat an empty ask as a key: a null key would collapse
  # every degraded turn in the file into one row — a dedup that deletes data on
  # exactly the turns that were already having a bad day. This pins the
  # consequence that is reachable from outside: a store containing null-keyed
  # rows still accepts the next real turn.
  fixture_full
  printf '%s\n' '{"ask_uuid":null,"session":"a"}' >> "$WORKLOG_JSONL"
  printf '%s\n' '{"ask_uuid":null,"session":"b"}' >> "$WORKLOG_JSONL"
  drive "$CLEAN"
  run bash -c "jq -r 'select(.ask_uuid != null) | .ask_uuid' '$WORKLOG_JSONL' | wc -l"
  [ "$output" -eq 1 ]
}

@test "a malformed line in the store does not abort the dedup scan" {
  # Same hazard the uuid-presence scan has: `fromjson?` binds to fromjson only,
  # so an unparseable or non-object line must be selected out rather than
  # indexed. If the scan aborted, dedup would silently stop working.
  fixture_full
  printf 'not json at all\n' >> "$WORKLOG_JSONL"
  printf '"a bare string"\n' >> "$WORKLOG_JSONL"
  drive "$CLEAN"
  drive "$CLEAN"
  # Read with -R: the store deliberately holds junk lines here, so a plain
  # `jq .` over the file would fail on the fixture rather than on the bug.
  run bash -c "jq -R -r 'fromjson? | select(type == \"object\") | select(.ask_uuid != null) | .ask_uuid' '$WORKLOG_JSONL' | wc -l"
  [ "$output" -eq 1 ]
}

@test "every line is independently valid JSON" {
  fixture_full
  drive "$CLEAN"
  # A SECOND turn, not a second fire of the first: one row per turn is keyed on
  # ask_uuid, so re-driving the same transcript would leave this test asserting
  # over a single line while still passing.
  fixture_next_turn
  drive "$(jq -nc --arg a "$U7" '{requests:[{text:"second",quote:"do another thing",uuid:$a}],outcomes:[],mistakes:[]}')"
  run bash -c "wc -l < '$WORKLOG_JSONL'"
  [ "$output" -eq 2 ]
  run bash -c "while IFS= read -r l; do printf '%s' \"\$l\" | jq -e . >/dev/null || exit 1; done < '$WORKLOG_JSONL'"
  [ "$status" -eq 0 ]
}

# --- how the brief reaches the model -------------------------------------
#
# These two pin the DELIVERY CHANNEL, which every other test in this file is
# blind to: the stub returns CLAUDE_STUB no matter how it was invoked, so the
# whole suite passed while the brief was arriving as user content. Measured on
# a real transcript, n=6 per arm, that difference was 0/6 vs 5/6 on catching
# the correction in the window. A behaviour worth 0-vs-5 needs a test that
# fails when it regresses.

@test "the judgment brief is delivered as a system prompt, not as user content" {
  fixture_full
  drive "$CLEAN"
  # argv is NUL-delimited, so a brief containing newlines stays one field.
  run bash -c "tr '\0' '\n' < '$CLAUDE_ARGV_LOG' | grep -Fxq -- '--system-prompt'"
  [ "$status" -eq 0 ]
  # The brief itself must be the value, not a path or a placeholder.
  run bash -c "tr '\0' '\n' < '$CLAUDE_ARGV_LOG' | grep -q 'writing a single worklog row'"
  [ "$status" -eq 0 ]
}

@test "the candidates go on stdin and the brief does not" {
  fixture_full
  drive "$CLEAN"
  run bash -c "grep -q 'CANDIDATES' '$CLAUDE_STDIN_LOG'"
  [ "$status" -eq 0 ]
  # The instruction text belongs to the system channel only. If it shows up on
  # stdin too, the split silently regressed back to one blob.
  run bash -c "grep -q 'writing a single worklog row' '$CLAUDE_STDIN_LOG'"
  [ "$status" -ne 0 ]
}
