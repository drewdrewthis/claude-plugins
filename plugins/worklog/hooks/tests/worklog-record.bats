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

  # The stub gitleaks. First on PATH so the real binary is never used by
  # default (non-deterministic across versions and absent on some CI images).
  # GITLEAKS_STUB selects the behaviour:
  #   unset             read stdin, report no findings
  #   fail              exit 2
  #   find:<Rule>:<s>   one finding when stdin contains <s>, else none
  #   passthrough       exec the real gitleaks found outside this dir
#   fail-after:N      succeed (no findings) for N calls, then exit 2; the call
#                     count lives in GITLEAKS_COUNT_FILE
#   hang              block for 30s (exec'd, so a killed child frees the pipe)
  # GITLEAKS_CALL_LOG, when set, gets one line per invocation.
  export GITLEAKS_CALL_LOG="$SCRATCH/gitleaks-calls.txt"
  export GITLEAKS_COUNT_FILE="$SCRATCH/gitleaks-count.txt"
  cat > "$STUB/gitleaks" <<'SH'
#!/usr/bin/env bash
[ -n "${GITLEAKS_CALL_LOG:-}" ] && echo "$*" >>"$GITLEAKS_CALL_LOG"
case "${GITLEAKS_STUB:-}" in
  fail) cat >/dev/null; exit 2 ;;
  fail-after:*)
    n="${GITLEAKS_STUB#fail-after:}"
    c="$(cat "$GITLEAKS_COUNT_FILE" 2>/dev/null || echo 0)"; c=$((c+1))
    echo "$c" >"$GITLEAKS_COUNT_FILE"
    cat >/dev/null
    [ "$c" -gt "$n" ] && exit 2
    echo '[]' ;;
  hang) exec sleep 30 ;;
  passthrough)
    here="$(cd "$(dirname "$0")" && pwd)"
    IFS=: read -ra dirs <<<"$PATH"
    for d in "${dirs[@]}"; do
      [ -n "$d" ] && [ "$(cd "$d" 2>/dev/null && pwd)" != "$here" ] && [ -x "$d/gitleaks" ] && exec "$d/gitleaks" "$@"
    done
    cat >/dev/null; exit 2 ;;
  find:*)
    spec="${GITLEAKS_STUB#find:}"; rule="${spec%%:*}"; secret="${spec#*:}"
    in="$(cat)"
    case "$in" in
      *"$secret"*) jq -nc --arg r "$rule" --arg s "$secret" '[{RuleID:$r,Secret:$s,Match:$s}]' ;;
      *) echo '[]' ;;
    esac ;;
  *) cat >/dev/null; echo '[]' ;;
esac
exit 0
SH
  chmod +x "$STUB/gitleaks"

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
# field — project an expression out of the row, but refuse to let an ABSENT key
# masquerade as an empty one. `jq '.requests|length'` yields 0 both when
# requests is [] and when the key was never emitted, so a `-eq 0` assertion
# cannot distinguish "the entry was dropped" (what the test means) from "the
# array never existed" (a wrong-reason pass). That shape has produced a vacuous
# pass six times in this branch's history, so the guard lives in the shared
# helper rather than in each call site.
field() {
    local expr="$1" k
    for k in $(printf '%s\n' "$expr" | grep -o '^\.[a-z_]\+' | tr -d '.'); do
        if [ "$(jq -r "has(\"$k\")" "$WORKLOG_JSONL" 2>/dev/null)" != "true" ]; then
            echo "field(): row has no key '$k' — an absent key is not an empty one (expr: $expr)" >&2
            return 1
        fi
    done
    jq -r "$expr" "$WORKLOG_JSONL"
}
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
  WL_REDACT_LIB="$HOOKS/lib" bash -c "source '$SCRATCH/slice.fn'; wl_slice '$TX' 60" 2>/dev/null \
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

@test "CAPS bounds how many entries one row can carry" {
  # CAPS is the only limit on array size in an append-only store, and until
  # this test it killed ZERO mutants: {6,6,4} -> {99,99,99} changed nothing
  # observable. Ask for more than the cap in every array at once.
  fixture_full
  drive "$(jq -nc --arg u "$U1" \
    '{requests:  [range(10)|{text:"r",quote:"do the thing",uuid:$u}],
      outcomes:  [range(10)|{text:"o",quote:"do the thing",uuid:$u}],
      mistakes:  []}')"
  [ "$(field '.requests|length')" -eq 6 ]
  [ "$(field '.outcomes|length')" -eq 6 ]
}

@test "the mistakes cap is 4, not the 6 the other two arrays use" {
  # Distinct constant; a single shared cap would pass the test above while
  # silently widening mistakes.
  fixture_full
  drive "$(jq -nc --arg a "$U0" --arg b "$U1" \
    '{requests:[],outcomes:[],
      mistakes:[range(10)|{text:"m",quote:"do the thing",uuids:[$a,$b]}]}')"
  [ "$(field '.mistakes|length')" -eq 4 ]
}

@test "an elided quote is rejected, and the brief never asks for one" {
  # The brief used to say: Cut the middle with "..." if it is too long.
  # verified_quote does an exact body.find(), so an elided quote is never a
  # substring and always drops — the instruction steered the model into the
  # one form the verifier always rejects, firing on exactly the long quotes
  # it targeted. The code behaviour is correct; the BRIEF was the defect.
  fixture_full
  drive "$(jq -nc --arg u "$U1" \
    '{requests:[{text:"x",quote:"do...thing",uuid:$u}],outcomes:[],mistakes:[]}')"
  [ "$(field '.requests|length')" -eq 0 ]

  # And the brief must not instruct the form that always fails.
  #
  # Newline-insensitive on purpose: the wording this guards against was
  # line-wrapped in the source ('Cut the middle' / newline+indent / 'with "..."'),
  # so a line-oriented grep cannot see it. Squash newlines to spaces first.
  #
  # Assert on STATUS, not on "$output": `grep -c` prints 0 AND exits 1 when it
  # finds nothing, so `[ "$output" -eq 0 ]` passes on the not-found path no
  # matter what the file says.
  run bash -c "tr '\n' ' ' < '$HOOK' | grep -q 'Cut the middle'"
  [ "$status" -ne 0 ]
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

@test "an unknown uuid in the MIDDLE is dropped and the real pair survives" {
  # The junk uuid sits between the offense and the correction, so the
  # correction is still the model's last-named uuid and is still in the
  # window. The bad uuid is filtered and the auditable pair is kept.
  fixture_full
  drive "$(jq -nc --arg a "$U0" --arg b "$U1" \
    '{requests:[],outcomes:[],
      mistakes:[{text:"x",quote:"do the thing",
                 uuids:[$a,"deadbeef-0000-4000-8000-000000000000",$b]}]}')"
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

@test "a mistake whose CORRECTION uuid is outside the window is dropped whole" {
  # [offense, mid, correction] where the correction fell out of the window.
  # Two uuids still survive, so the length-2 guard passes; anchoring to the
  # SURVIVING tail would audit `mid` — a line that was never the correction.
  # The pair lost the thing it needs, so the entry must not be recorded.
  fixture_full
  drive "$(jq -nc --arg a "$U0" --arg b "$U1" \
    '{requests:[],outcomes:[],
      mistakes:[{text:"x",quote:"do the thing",
                 uuids:[$a,$b,"deadbeef-0000-4000-8000-000000000000"]}]}')"
  [ "$(field '.mistakes|length')" -eq 0 ]
}

@test "a lost correction cannot be back-filled by a quote that fits the survivor" {
  # The misattribution case, not merely the dropped-entry case. U0 ("an
  # earlier prompt") and U6 ("an earlier answer") share the run "an earlier".
  # Model names [U0, U6, correction] with the correction outside the window.
  # Anchoring to the SURVIVING tail picks U6, where "an earlier" verifies —
  # so the old rule stored the entry with evidence pinned to a line that was
  # never the correction. Verifying against the wrong line is not a weaker
  # failure than dropping: it is the misattribution this schema exists to
  # prevent. The pair must go.
  fixture_full
  drive "$(jq -nc --arg a "$U0" --arg b "$U6" \
    '{requests:[],outcomes:[],
      mistakes:[{text:"x",quote:"an earlier",
                 uuids:[$a,$b,"deadbeef-0000-4000-8000-000000000000"]}]}')"
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
           malformed-payload non-object-payload no-jq detach-failed \
           gitleaks-failed lib-unreadable:redact redact-failed gitleaks-absent; do
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
  # `touch -t CCYYMMDDhhmm` (POSIX) rather than GNU-only `touch -d @1`, so the
  # staleness fixture is not silently skipped off Linux. The date is 2000, not
  # 1970: -t reads LOCAL time, and local midnight 1970 is a NEGATIVE epoch in
  # any positive-offset zone — where macOS `date -r` then prints e.g. `-3600`,
  # which wl_marker_age rejects as undeterminable (non-digit `-`) and never
  # steals. A year-2000 mtime is ~26y old (past any TTL) and positive worldwide.
  touch -t 200001010000 "$CLAIMS/$U1"
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

# ==========================================================================
# 10. secrets are redacted before the model sees them and before they are stored
# ==========================================================================
#
# Issue #172. The worklog is a durable file, and the candidates block is sent
# to a model, so a key pasted into a prompt would otherwise land in both. The
# contract: every candidate body is redacted inside wl_slice BEFORE truncation,
# and every stored text/quote is redacted again in wl_entries. A match becomes
# <redacted:NAME>.
#
# ⚠ FAKE KEYS ARE BUILT BY CONCATENATION. A literal key in this file would trip
# gitleaks on commit — and the fakes need to look real enough to match.
#
# ⚠ THE STUB MUST QUOTE THE REDACTED FORM. A quote is verified against the
# candidate body the model was shown, and that body is redacted. A stub quoting
# the raw key would be dropped as invented, and the "stored redacted" assertions
# would then pass-or-fail for the wrong reason.

# fake_key <prefix> <body> <len> — prefix, then <body> repeated and cut to <len>.
fake_key() {
  local out="" body="$2"
  while [ "${#out}" -lt "$3" ]; do out="$out$body"; done
  printf '%s%s' "$1" "${out:0:$3}"
}

fake_lw()  { fake_key "sk-""lw-" "aB3dE5gH7jK9mN1pQ3sT5vX7zA9cD1fG3hJ5kL7" 40; }
fake_ant() { fake_key "sk-""ant-""api03-" "Zy9Xw8Vu7Ts6Rq5Po4Nm3Lk2Ji1Hg0Fe" 40; }
fake_ghp() { fake_key "gh""p_" "Q1w2E3r4T5y6U7i8O9p0A1s2D3f4G5h6J7k8" 36; }
fake_slack() { printf '%s' "xo""xb-1234567890-1234567890123-AbCdEfGhIjKlMnOpQrStUvWx"; }
fake_aws() { printf '%s' "AK""IA""Q3XZ7RT5NB2KD8WP"; }
# An npm token. gitleaks 8.30.1 flags it (npm-access-token) AND the hook's
# built-in rules cover it (npm-token), so it is NOT a gitleaks-only fixture.
fake_npm() { fake_key "np""m_" "aB3dE5gH7jK9mN1pQ3sT5vX7zA9cD1fG3hJ5" 36; }
# A Pulumi token: gitleaks 8.30.1 flags it (pulumi-api-token) with no keyword
# context, and no built-in rule matches it. The gitleaks-only fixture.
fake_pulumi() { fake_key "pu""l-" "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678" 40; }

# real_gitleaks — path of the real binary, searched outside the stub dir.
real_gitleaks() {
  local d
  local -a dirs
  IFS=: read -ra dirs <<<"$PATH"
  for d in "${dirs[@]}"; do
    [ -n "$d" ] && [ "$d" != "$STUB" ] && [ -x "$d/gitleaks" ] && { printf '%s/gitleaks' "$d"; return 0; }
  done
  return 1
}

# assert_gitleaks_only <key> <rule-id> — premise guard (real binary): gitleaks
# names <rule-id> for the key and the built-in rules leave it untouched, so the
# stubbed tests model a real finding on a shape no built-in covers.
assert_gitleaks_only() {
  local gl; gl="$(real_gitleaks)"
  run bash -c "printf 'key = \"%s\"\n' '$1' | '$gl' stdin --no-banner --exit-code 0 --report-format json --report-path - 2>/dev/null | jq -r '.[].RuleID'"
  [ "$output" = "$2" ]
  run python3 -c "import sys; sys.path.insert(0, sys.argv[1]); import redact; sys.exit(0 if redact.builtin(sys.argv[2]) == sys.argv[2] else 1)" "$HOOKS/lib" "$1"
  [ "$status" -eq 0 ]
}

# fixture_secret_prompt <secret> — one turn whose prompt pastes the secret.
fixture_secret_prompt() {
  user_line "$U1" "my token is $1 please keep it" > "$TX"
}

# redacted_reply <name> — a stub reply quoting the line as the model is shown it.
redacted_reply() {
  jq -nc --arg u "$U1" --arg q "my token is <redacted:$1> please keep it" \
    '{requests:[{text:"user shared a token",quote:$q,uuid:$u}],outcomes:[],mistakes:[]}'
}

# assert_redacted_in_worklog <name> <raw> — the placeholder is stored, the raw
# secret is nowhere in the file.
assert_redacted_in_worklog() {
  grep -qF -- "<redacted:$1>" "$WORKLOG_JSONL"
  ! grep -qF -- "$2" "$WORKLOG_JSONL"
}

@test "a pasted sk-lw key never appears in the worklog file, only its marker" {
  KEY="$(fake_lw)"
  fixture_secret_prompt "$KEY"
  drive "$(redacted_reply sk-lw)"
  # The marker check guards against a vacuous pass: a dropped row is also
  # key-free.
  grep -qF -- "<redacted:sk-lw>" "$WORKLOG_JSONL"
  ! grep -qF -- "$KEY" "$WORKLOG_JSONL"
}

@test "the stdin the model receives carries the marker and no raw sk-lw key" {
  KEY="$(fake_lw)"
  fixture_secret_prompt "$KEY"
  drive "$(redacted_reply sk-lw)"
  grep -qF -- "<redacted:sk-lw>" "$CLAUDE_STDIN_LOG"
  ! grep -qF -- "$KEY" "$CLAUDE_STDIN_LOG"
}

@test "a raw key in a model-written text is stored redacted" {
  KEY="$(fake_ant)"
  fixture_full
  drive "$(jq -nc --arg u "$U1" --arg t "pasted $KEY" \
    '{requests:[{text:$t,quote:"do the thing",uuid:$u}],outcomes:[],mistakes:[]}')"
  [ "$(field '.requests[0].text')" = "pasted <redacted:sk-ant>" ]
}

@test "a raw key in a model-written quote is stored redacted" {
  # A built-in-shaped key in the quote is redacted, and the redacted quote then
  # matches the (redacted) candidate body, so the entry survives.
  KEY="$(fake_ant)"
  fixture_secret_prompt "$KEY"
  drive "$(jq -nc --arg u "$U1" --arg q "my token is $KEY please keep it" \
    '{requests:[{text:"shared a token",quote:$q,uuid:$u}],outcomes:[],mistakes:[]}')"
  grep -qF -- "<redacted:sk-ant>" "$WORKLOG_JSONL"
  ! grep -qF -- "$KEY" "$WORKLOG_JSONL"
}

@test "a pasted sk-ant key is redacted from the worklog" {
  KEY="$(fake_ant)"
  fixture_secret_prompt "$KEY"
  drive "$(redacted_reply sk-ant)"
  assert_redacted_in_worklog sk-ant "$KEY"
}

@test "a pasted GitHub ghp_ token is redacted from the worklog" {
  KEY="$(fake_ghp)"
  fixture_secret_prompt "$KEY"
  drive "$(redacted_reply github-pat)"
  assert_redacted_in_worklog github-pat "$KEY"
}

@test "a pasted Slack xoxb- token is redacted from the worklog" {
  KEY="$(fake_slack)"
  fixture_secret_prompt "$KEY"
  drive "$(redacted_reply slack-token)"
  assert_redacted_in_worklog slack-token "$KEY"
}

@test "a pasted AWS access key id is redacted from the worklog" {
  KEY="$(fake_aws)"
  fixture_secret_prompt "$KEY"
  drive "$(redacted_reply aws-access-key)"
  assert_redacted_in_worklog aws-access-key "$KEY"
}

@test "a gitleaks-only secret in the prompt is redacted in the stored row" {
  KEY="$(fake_pulumi)"
  fixture_secret_prompt "$KEY"
  drive_with "GITLEAKS_STUB=find:pulumi-api-token:$KEY" -- \
    "$(redacted_reply pulumi-api-token)"
  assert_redacted_in_worklog pulumi-api-token "$KEY"
}

@test "a gitleaks-only secret in the prompt is redacted in the stdin the model receives" {
  KEY="$(fake_pulumi)"
  fixture_secret_prompt "$KEY"
  drive_with "GITLEAKS_STUB=find:pulumi-api-token:$KEY" -- "$CLEAN"
  grep -qF -- "<redacted:pulumi-api-token>" "$CLAUDE_STDIN_LOG"
  ! grep -qF -- "$KEY" "$CLAUDE_STDIN_LOG"
}

@test "a gitleaks-only secret in a model-written text is stored redacted" {
  # Proves the gitleaks pass in wl_entries: no built-in matches this shape and
  # the candidate body never held it.
  KEY="$(fake_pulumi)"
  fixture_full
  drive_with "GITLEAKS_STUB=find:pulumi-api-token:$KEY" -- \
    "$(jq -nc --arg u "$U1" --arg t "leaked $KEY" \
      '{requests:[{text:$t,quote:"do the thing",uuid:$u}],outcomes:[],mistakes:[]}')"
  [ "$(field '.requests[0].text')" = "leaked <redacted:pulumi-api-token>" ]
}

# unjudged_row — the stored row is the mechanical envelope with no model output.
assert_unjudged_row() {
  [ "$(wc -l < "$WORKLOG_JSONL")" -eq 1 ]
  [ "$(field '.requests|length')" -eq 0 ]
  [ "$(field '.outcomes|length')" -eq 0 ]
  [ "$(field '.mistakes|length')" -eq 0 ]
}

# note_count <why> — how many times the fail-open log carries <why>.
note_count() { { grep -c -- "\"why\":\"$1\"" "$GATE_FAILOPEN_LOG" 2>/dev/null || true; } | head -1; }

# require_real_gitleaks — skip locally when the binary is missing, FAIL on CI so
# a runner without it cannot silently turn the real-binary tests into skips.
require_real_gitleaks() {
  if real_gitleaks >/dev/null; then return 0; fi
  if [ -n "${CI:-}" ]; then
    echo "gitleaks is required on CI but is not on PATH" >&2
    return 1
  fi
  skip "gitleaks is not on PATH"
}

@test "a malformed model reply still writes the row" {
  fixture_full
  drive '{"requests":5}'
  [ "$(wc -l < "$WORKLOG_JSONL")" -eq 1 ]
}

@test "a malformed model reply is stored unjudged" {
  fixture_full
  drive '{"requests":5}'
  assert_unjudged_row
}

@test "a malformed model reply is logged as judgment-unavailable" {
  fixture_full
  drive '{"requests":5}'
  [ "$(why)" = "judgment-unavailable" ]
}

@test "a gitleaks failure still writes exactly one row" {
  fixture_full
  drive_with "GITLEAKS_STUB=fail" -- "$CLEAN"
  [ "$(wc -l < "$WORKLOG_JSONL")" -eq 1 ]
}

@test "a gitleaks failure is logged as gitleaks-failed exactly once" {
  fixture_full
  drive_with "GITLEAKS_STUB=fail" -- "$CLEAN"
  [ "$(note_count gitleaks-failed)" -eq 1 ]
}

@test "a gitleaks failure stores the row unjudged" {
  fixture_full
  drive_with "GITLEAKS_STUB=fail" -- "$CLEAN"
  assert_unjudged_row
}

@test "a gitleaks failure leaves no raw key in the stored row" {
  KEY="$(fake_ant)"
  fixture_secret_prompt "$KEY"
  drive_with "GITLEAKS_STUB=fail" -- "$(redacted_reply sk-ant)"
  assert_unjudged_row
  ! grep -qF -- "$KEY" "$WORKLOG_JSONL"
}

@test "a gitleaks failure in the slice pass never invokes the model" {
  KEY="$(fake_ant)"
  fixture_secret_prompt "$KEY"
  drive_with "GITLEAKS_STUB=fail" -- "$CLEAN"
  [ ! -e "$CLAUDE_ARGV_LOG" ]
}

@test "a gitleaks failure in the entries pass only stores the row unjudged" {
  fixture_full
  drive_with "GITLEAKS_STUB=fail-after:1" -- "$CLEAN"
  assert_unjudged_row
}

@test "a gitleaks failure in the entries pass only is logged as gitleaks-failed once" {
  fixture_full
  drive_with "GITLEAKS_STUB=fail-after:1" -- "$CLEAN"
  [ "$(note_count gitleaks-failed)" -eq 1 ]
}

@test "the entries-pass gitleaks stub is reached after the slice pass succeeds" {
  # Guards the fail-after premise: two calls means the model WAS invoked.
  fixture_full
  drive_with "GITLEAKS_STUB=fail-after:1" -- "$CLEAN"
  [ "$(cat "$GITLEAKS_COUNT_FILE")" -eq 2 ]
}

@test "a hanging gitleaks times out and stores the row unjudged" {
  fixture_full
  drive_with "GITLEAKS_STUB=hang" "WORKLOG_GITLEAKS_TIMEOUT=1" -- "$CLEAN"
  assert_unjudged_row
}

@test "a hanging gitleaks is logged as gitleaks-failed exactly once" {
  fixture_full
  drive_with "GITLEAKS_STUB=hang" "WORKLOG_GITLEAKS_TIMEOUT=1" -- "$CLEAN"
  [ "$(note_count gitleaks-failed)" -eq 1 ]
}

@test "a hanging gitleaks finishes well under the stub's 30s sleep" {
  fixture_full
  local t0 t1
  t0="$(date +%s)"
  drive_with "GITLEAKS_STUB=hang" "WORKLOG_GITLEAKS_TIMEOUT=1" -- "$CLEAN"
  t1="$(date +%s)"
  [ $((t1 - t0)) -lt 15 ]
}

@test "gitleaks is invoked with the stdin report flags" {
  KEY="$(fake_lw)"
  fixture_secret_prompt "$KEY"
  drive "$CLEAN"
  grep -qxF -- "stdin --no-banner --exit-code 0 --report-format json --report-path - --log-level error" "$GITLEAKS_CALL_LOG"
}

@test "an unreadable redact lib writes no row" {
  mkdir -p "$SCRATCH/empty-lib"
  fixture_full
  drive_with "WL_REDACT_LIB=$SCRATCH/empty-lib" -- "$CLEAN"
  no_row
}

@test "an unreadable redact lib is logged as lib-unreadable:redact" {
  mkdir -p "$SCRATCH/empty-lib"
  fixture_full
  drive_with "WL_REDACT_LIB=$SCRATCH/empty-lib" -- "$CLEAN"
  [ "$(why)" = "lib-unreadable:redact" ]
}

@test "an unreadable redact lib never invokes the model" {
  mkdir -p "$SCRATCH/empty-lib"
  fixture_full
  drive_with "WL_REDACT_LIB=$SCRATCH/empty-lib" -- "$CLEAN"
  [ ! -s "$CLAUDE_STDIN_LOG" ]
}

@test "a key straddling the 200-char truncation boundary leaks no partial prefix" {
  KEY="$(fake_lw)"
  # The fixture prefix "my token is " is 12 chars; 167 filler + a space put
  # the key's first char at offset 180, so a truncate-then-redact order would
  # keep "sk-lw-" plus ~14 chars of key, which no full-key pattern matches.
  PAD="$(printf 'x%.0s' $(seq 1 167))"
  fixture_secret_prompt "$PAD $KEY"
  drive "$CLEAN"
  grep -qF -- "<redacted:sk-lw>" "$CLAUDE_STDIN_LOG"
  ! grep -Eq 'sk-lw-[A-Za-z0-9]' "$CLAUDE_STDIN_LOG"
}

# gitleaks_findings <file> — findings JSON the REAL gitleaks reports for a file.
# --exit-code 0 so a finding is data here, not a failed command.
gitleaks_findings() {
  "$(real_gitleaks)" stdin --no-banner --exit-code 0 --report-format json --report-path - < "$1" 2>/dev/null
}

@test "the worklog file from the sk-lw turn passes a real gitleaks scan" {
  require_real_gitleaks
  KEY="$(fake_lw)"
  fixture_secret_prompt "$KEY"
  drive_with "GITLEAKS_STUB=passthrough" -- "$(redacted_reply sk-lw)"
  grep -qF -- "<redacted:sk-lw>" "$WORKLOG_JSONL"
  [ "$(gitleaks_findings "$WORKLOG_JSONL" | jq -c .)" = "[]" ]
}

@test "the real gitleaks flags the pulumi token shape no built-in rule covers" {
  require_real_gitleaks
  assert_gitleaks_only "$(fake_pulumi)" pulumi-api-token
}

@test "a password= value with no known prefix is redacted as generic-secret by the built-ins" {
  # The default stub reports no findings, so only the built-in keyword rule
  # can be responsible.
  SECRET="$(fake_key "" "Hq7Lm2Zp9Wx4Rt6Yb3Nc8Vd" 24)"
  user_line "$U1" "set password=$SECRET in the env" > "$TX"
  drive "$(jq -nc --arg u "$U1" \
    '{requests:[{text:"shared a password",quote:"set <redacted:generic-secret> in the env",uuid:$u}],outcomes:[],mistakes:[]}')"
  grep -qF -- "<redacted:generic-secret>" "$WORKLOG_JSONL"
  ! grep -qF -- "$SECRET" "$WORKLOG_JSONL"
}

@test "a bare auth word before a file path is not redacted" {
  user_line "$U1" "run auth /usr/local/some/long/path/name.py now" > "$TX"
  drive "$CLEAN"
  grep -qF -- "auth /usr/local/some/long/path/name.py" "$CLAUDE_STDIN_LOG"
}

@test "a key beginning inside the 100-char text cap leaves no partial prefix" {
  KEY="$(fake_lw)"
  # Key starts at char 90 of the text; truncating first would keep a partial
  # "sk-lw-aB3dE5gH7j" that no full-key pattern matches.
  PAD="$(printf 'x%.0s' $(seq 1 89))"
  fixture_full
  drive "$(jq -nc --arg u "$U1" --arg t "$PAD $KEY" \
    '{requests:[{text:$t,quote:"do the thing",uuid:$u}],outcomes:[],mistakes:[]}')"
  [ "$(field '.requests|length')" -eq 1 ]
  ! grep -Eq 'sk-lw-[A-Za-z0-9]' "$WORKLOG_JSONL"
}

# --- redact-failed: redaction dies at runtime -----------------------------

# redact_lib_raising_on <n> — a scratch lib dir holding the real redact.py with
# redact_texts overridden to raise on its <n>th call (counted in a file, since
# each call is a separate python process).
redact_lib_raising_on() {
  mkdir -p "$SCRATCH/raising-lib"
  cp "$HOOKS/lib/redact.py" "$SCRATCH/raising-lib/redact.py"
  cat >> "$SCRATCH/raising-lib/redact.py" <<PY

_real_redact_texts = redact_texts
def redact_texts(texts):
    p = "$SCRATCH/redact-count.txt"
    try:
        c = int(open(p).read())
    except Exception:
        c = 0
    c += 1
    open(p, "w").write(str(c))
    if c == $1:
        raise RuntimeError("boom")
    return _real_redact_texts(texts)
PY
}

@test "a redaction that dies in the slice pass writes no row" {
  redact_lib_raising_on 1
  fixture_full
  drive_with "WL_REDACT_LIB=$SCRATCH/raising-lib" -- "$CLEAN"
  no_row
}

@test "a redaction that dies in the slice pass is logged as redact-failed" {
  redact_lib_raising_on 1
  fixture_full
  drive_with "WL_REDACT_LIB=$SCRATCH/raising-lib" -- "$CLEAN"
  [ "$(why)" = "redact-failed" ]
}

@test "a redaction that dies in the slice pass never invokes the model" {
  redact_lib_raising_on 1
  fixture_full
  drive_with "WL_REDACT_LIB=$SCRATCH/raising-lib" -- "$CLEAN"
  [ ! -e "$CLAUDE_ARGV_LOG" ]
}

@test "a redaction that dies in the entries pass writes no row" {
  redact_lib_raising_on 2
  fixture_full
  drive_with "WL_REDACT_LIB=$SCRATCH/raising-lib" -- "$CLEAN"
  no_row
}

@test "a redaction that dies in the entries pass is logged as redact-failed" {
  redact_lib_raising_on 2
  fixture_full
  drive_with "WL_REDACT_LIB=$SCRATCH/raising-lib" -- "$CLEAN"
  [ "$(why)" = "redact-failed" ]
}

@test "a redaction that dies in the entries pass releases the claim" {
  # The raise is on call 2 only, so the retry (calls 3 and 4) succeeds; it can
  # write a row only if the first fire did not leave its marker behind.
  redact_lib_raising_on 2
  fixture_full
  drive_with "WL_REDACT_LIB=$SCRATCH/raising-lib" -- "$CLEAN"
  rm -f "$GATE_FAILOPEN_LOG"
  drive_with "WL_REDACT_LIB=$SCRATCH/raising-lib" -- "$CLEAN"
  [ "$(field '.requests|length')" -eq 1 ]
}

# --- real binary, end to end ----------------------------------------------

@test "the real gitleaks redacts a pulumi token from prompt to stored row" {
  require_real_gitleaks
  KEY="$(fake_pulumi)"
  fixture_secret_prompt "$KEY"
  drive_with "GITLEAKS_STUB=passthrough" -- "$(redacted_reply pulumi-api-token)"
  assert_redacted_in_worklog pulumi-api-token "$KEY"
}

# --- truncation never leaves half a marker ---------------------------------

@test "a redaction marker straddling the 100-char text cut leaves no unclosed marker" {
  # 90 filler chars then a 16-char marker: the cut at 100 lands inside it.
  PAD="$(printf 'x%.0s' $(seq 1 90))"
  fixture_full
  drive "$(jq -nc --arg u "$U1" --arg t "$PAD<redacted:sk-lw> tail" \
    '{requests:[{text:$t,quote:"do the thing",uuid:$u}],outcomes:[],mistakes:[]}')"
  [ "$(field '.requests|length')" -eq 1 ]
  [ "$(field '.requests[0].text | test("<redacted:[^>]*$")')" = "false" ]
}

# --- gitleaks absent -------------------------------------------------------

# path_without_gitleaks — a PATH dir with the tools the hook needs, the claude
# stub, and no gitleaks at all.
path_without_gitleaks() {
  local d="$SCRATCH/nogl" b p
  mkdir -p "$d"
  for b in bash sh env date cat rm mktemp sed grep tr timeout python3 jq setsid \
           head tail wc sort mkdir ls find stat sleep cut awk perl dirname \
           basename tee mv cp printf uniq xargs readlink cmp diff; do
    if p="$(command -v "$b" 2>/dev/null)" && [ -x "$p" ]; then ln -sf "$p" "$d/$b"; fi
  done
  ln -sf "$STUB/claude" "$d/claude"
  printf '%s' "$d"
}

@test "with gitleaks absent the built-in rules still redact the stored row" {
  KEY="$(fake_ant)"
  fixture_secret_prompt "$KEY"
  drive_with "PATH=$(path_without_gitleaks)" -- "$(redacted_reply sk-ant)"
  assert_redacted_in_worklog sk-ant "$KEY"
}

@test "with gitleaks absent the row is judged" {
  fixture_full
  drive_with "PATH=$(path_without_gitleaks)" -- "$CLEAN"
  [ "$(field '.requests|length')" -eq 1 ]
}

# gitleaks_absent_lines — fail-open lines for this writer carrying the
# gitleaks-absent why, verbatim.
gitleaks_absent_lines() { grep -F -- '"why":"gitleaks-absent"' "$GATE_FAILOPEN_LOG" 2>/dev/null || true; }

# payload_for_session <sid> <transcript> — a Stop payload for another session.
payload_for_session() {
  jq -nc --arg s "$1" --arg tp "$2" \
    '{session_id:$s, hook_event_name:"Stop", transcript_path:$tp, cwd:"/tmp"}'
}

@test "with gitleaks absent one gitleaks-absent note is logged, stored literally" {
  fixture_full
  drive_with "PATH=$(path_without_gitleaks)" -- "$CLEAN"
  [ "$(why)" = "gitleaks-absent" ]
}

@test "the gitleaks-absent note is attributed to this writer and this session" {
  fixture_full
  drive_with "PATH=$(path_without_gitleaks)" -- "$CLEAN"
  [ "$(jq -r '.gate + " " + .session_id' "$GATE_FAILOPEN_LOG")" = "worklog-record $SID" ]
}

@test "a second turn of the same session adds no gitleaks-absent note" {
  fixture_full
  drive_with "PATH=$(path_without_gitleaks)" -- "$CLEAN"
  fixture_next_turn
  drive_with "PATH=$(path_without_gitleaks)" -- "$CLEAN"
  [ "$(wc -l < "$WORKLOG_JSONL")" -eq 2 ]          # turn 2 reached the store
  [ "$(gitleaks_absent_lines | wc -l)" -eq 1 ]
}

@test "the first turn of a different session adds one more gitleaks-absent note" {
  fixture_full
  drive_with "PATH=$(path_without_gitleaks)" -- "$CLEAN"
  # Its own transcript and turn: the store dedups on the turn, so a repeat of
  # the first turn would store no row and never reach the note.
  user_line "$U7" "do another thing" > "$TXDIR/other.jsonl"
  PAYLOAD="$(payload_for_session "$SID-other" "$TXDIR/other.jsonl")" \
    drive_with "PATH=$(path_without_gitleaks)" -- "$CLEAN"
  [ "$(wc -l < "$WORKLOG_JSONL")" -eq 2 ]          # session 2 stored its row
  [ "$(gitleaks_absent_lines | jq -r .session_id | sort | tr '\n' ' ')" = "$SID $SID-other " ]
}

@test "a gitleaks file without the execute bit gives the same note as no file" {
  d="$(path_without_gitleaks)"
  printf '#!/bin/sh\nexit 0\n' > "$d/gitleaks"
  chmod -x "$d/gitleaks"
  fixture_full
  drive_with "PATH=$d" -- "$CLEAN"
  [ "$(gitleaks_absent_lines | wc -l)" -eq 1 ]
}

@test "with gitleaks absent and the fail-open log unwritable the row is still stored" {
  fixture_full
  run drive_with "PATH=$(path_without_gitleaks)" "GATE_FAILOPEN_LOG=$SCRATCH/no-such-dir/gate-failopen.jsonl" -- "$CLEAN"
  [ "$status" -eq 0 ]
  [ "$(field '.requests|length')" -eq 1 ]
}

@test "with gitleaks absent and the model unavailable exactly one gitleaks-absent is logged" {
  fixture_full
  drive_with "PATH=$(path_without_gitleaks)" -- ""
  [ "$(gitleaks_absent_lines | wc -l)" -eq 1 ]
}

@test "with gitleaks absent and the model unavailable exactly one judgment-unavailable is logged" {
  fixture_full
  drive_with "PATH=$(path_without_gitleaks)" -- ""
  [ "$(note_count judgment-unavailable)" -eq 1 ]
}

@test "with a working gitleaks no gitleaks-absent note is logged" {
  fixture_full
  drive "$CLEAN"
  [ "$(gitleaks_absent_lines | wc -l)" -eq 0 ]
}

@test "the gitleaks-absent PATH really has no gitleaks" {
  run env PATH="$(path_without_gitleaks)" bash -c 'command -v gitleaks'
  [ "$status" -ne 0 ]
}

# --- built-in rule shapes: provider keys with unusual bodies ---------------

# builtin_out <text> — redact.builtin(<text>) as the hook's lib computes it.
builtin_out() {
  python3 -c "import sys; sys.path.insert(0, sys.argv[1]); import redact; sys.stdout.write(redact.builtin(sys.argv[2]))" "$HOOKS/lib" "$1"
}

@test "an sk-lw key with a dot in the middle never lands in the worklog file" {
  KEY="$(fake_key "sk-""lw-" "aB3dE5gH7j" 10).$(fake_key "" "kL7mN9pQ1sT3vX5zA7cD9fG1hJ3" 30)"
  fixture_secret_prompt "$KEY"
  drive "$(redacted_reply sk-lw)"
  assert_redacted_in_worklog sk-lw "$KEY"
}

@test "an sk-lw key with a dot in the middle redacts to the bare marker" {
  KEY="$(fake_key "sk-""lw-" "aB3dE5gH7j" 10).$(fake_key "" "kL7mN9pQ1sT3vX5zA7cD9fG1hJ3" 30)"
  [ "$(builtin_out "k $KEY k")" = "k <redacted:sk-lw> k" ]
}

@test "a short sk-lw key of 19 characters redacts to the bare marker" {
  KEY="$(fake_key "sk-""lw-" "aB3dE5gH7jK9mN1pQ3s" 19)"
  [ "$(builtin_out "k $KEY k")" = "k <redacted:sk-lw> k" ]
}

@test "an sk-lw key with a plus in the middle redacts to the bare marker" {
  KEY="$(fake_key "sk-""lw-" "aB3dE5gH7jK9" 12)+$(fake_key "" "mN1pQ3sT5vX7zA9cD1fG" 20)"
  [ "$(builtin_out "k $KEY k")" = "k <redacted:sk-lw> k" ]
}

@test "an sk-ant key with a dot in the middle redacts to the bare marker" {
  KEY="$(fake_key "sk-""ant-" "aB3dE5gH7j" 10).$(fake_key "" "kL7mN9pQ1sT3vX5zA7cD9fG1hJ3" 30)"
  [ "$(builtin_out "k $KEY k")" = "k <redacted:sk-ant> k" ]
}

@test "a marker followed by a long lowercase word stays intact" {
  [ "$(builtin_out "$(fake_slack) abcdefghijklmnopqrstuvwx")" = "<redacted:slack-token> abcdefghijklmnopqrstuvwx" ]
}

@test "a marker followed by a long lowercase word is not re-matched by the keyword rule" {
  run builtin_out "$(fake_slack) abcdefghijklmnopqrstuvwx"
  [[ "$output" != *"slack-<redacted"* ]]
}

# --- keyword rule: separators and marker boundaries -------------------------

# builtin_twice <text> — redact.builtin applied to its own output.
builtin_twice() {
  python3 -c "import sys; sys.path.insert(0, sys.argv[1]); import redact; sys.stdout.write(redact.builtin(redact.builtin(sys.argv[2])))" "$HOOKS/lib" "$1"
}

@test "a keyword wrapped in xml tags redacts the value to the generic marker" {
  run builtin_out "<token>abcdefghijklmnopqrstuvwx</token>"
  [[ "$output" == *"<redacted:generic-secret>"* ]]
}

@test "a keyword wrapped in xml tags never keeps the value" {
  run builtin_out "<token>abcdefghijklmnopqrstuvwx</token>"
  [[ "$output" != *"abcdefghijklmnopqrstuvwx"* ]]
}

@test "a keyword with an arrow separator never keeps the value" {
  run builtin_out "secret=> abcdefghijklmnopqrstuvwx"
  [[ "$output" != *"abcdefghijklmnopqrstuvwx"* ]]
}

@test "a keyword value right after a marker is still redacted" {
  [ "$(builtin_out "$(fake_slack) password=abcdefghijklmnopqrstuvwx")" = "<redacted:slack-token> <redacted:generic-secret>" ]
}

@test "running the built-in rules twice gives the same text as running them once" {
  IN="$(fake_slack) abcdefghijklmnopqrstuvwx password=abcdefghijklmnopqrstuvwx"
  [ "$(builtin_twice "$IN")" = "$(builtin_out "$IN")" ]
}

# --- built-in coverage of shapes that were gitleaks-only ---------------------
#
# With gitleaks absent the built-in rules are the only layer, so the common
# gitleaks-only shapes need a built-in each. Widths follow gitleaks 8.30.1: the
# short-prefix rules are strict so ordinary code text is not eaten.

ALNUM="aB3dE5gH7jK9mN1pQ3sT5vX7zA9cD1fG3hJ5kL7mN9pQ1sT3vX5zA7cD9fG1hJ3kL5mN7pQ9sT1vX3zA5cD7fG9hJ1kL3mN5pQ7sT9vX1zA3cD5fG7hJ9kL1mN3pQ5sT7vX9zA1cD3fG5hJ7kL9mN1pQ3sT5vX7zA9cD1fG3hJ5kL7mN9pQ1sT3vX5zA7cD9fG1hJ3kL5mN7pQ9sT1vX3zA5cD7fG9hJ1kL3"
HEX="a1b2c3d4e5f60718293a4b5c6d7e8f9012345678a1b2c3d4e5f60718293a4b5c6d7e8f90"

fake_gitlab()   { fake_key "glp""at-" "$ALNUM" 20; }
fake_hf()       { fake_key "h""f_" "kQmZpXvRtYwNcBdLfHgJsAeUoI" 34; }
fake_sendgrid() { printf '%s.%s' "$(fake_key "S""G." "$ALNUM" 22)" "$(fake_key "" "$ALNUM" 43)"; }
fake_xapp()     { printf '%s%s-%s-%s' "xa""pp-1-A" "$(fake_key "" "A1B2C3D4E5" 10)" "$(fake_key "" "1234567890123" 13)" "$(fake_key "" "$HEX" 64)"; }
fake_xoxe()     { fake_key "xo""xe-1-" "A1B2C3D4E5F6G7H8I9J0" 146; }
fake_whook()    { printf '%s%s' "https://ho""oks.slack.com/services/" "T01ABCDEF/B01ABCDEF/$(fake_key "" "$ALNUM" 24)"; }
fake_stripe()   { fake_key "sk_""test_" "$ALNUM" 24; }
fake_jwt()      { printf '%s.%s.%s' "ey""JhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9" "ey""JzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4ifQ" "SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"; }
fake_op()       { fake_key "ops_""eyJ" "$ALNUM" 250; }
fake_do()       { fake_key "do""p_v1_" "$HEX" 64; }
fake_pypi()     { fake_key "py""pi-AgEIcHlwaS5vcmc" "$ALNUM" 70; }
fake_shopify()  { fake_key "shp""at_" "$HEX" 32; }
fake_linear()   { fake_key "lin""_api_" "$ALNUM" 40; }
fake_vault()    { fake_key "hv""s." "$ALNUM" 95; }
fake_doppler()  { fake_key "dp.""pt." "$ALNUM" 43; }
fake_atlassian() { fake_key "AT""ATT3" "$ALNUM" 186; }
fake_grafana()  { printf '%s_%s' "$(fake_key "gl""sa_" "$ALNUM" 32)" "$(fake_key "" "a1b2c3d4" 8)"; }

# The rows of the planning marker table: <builder> <marker>.
BUILTIN_TABLE="fake_npm:npm-token fake_gitlab:gitlab-pat fake_hf:huggingface-token
fake_sendgrid:sendgrid-key fake_xapp:slack-token fake_xoxe:slack-token
fake_whook:slack-webhook fake_stripe:stripe-key fake_jwt:jwt
fake_op:1password-token fake_do:digitalocean-token fake_pypi:pypi-token
fake_shopify:shopify-token fake_linear:linear-key fake_vault:vault-token
fake_doppler:doppler-token fake_atlassian:atlassian-token fake_grafana:grafana-token"

@test "every listed token shape redacts to exactly its own marker" {
  bad=""
  for row in $BUILTIN_TABLE; do
    t="$("${row%%:*}")"
    [ "$(builtin_out "before $t after")" = "before <redacted:${row#*:}> after" ] || bad="$bad ${row%%:*}"
  done
  [ -z "$bad" ] || { echo "wrong or missing marker for:$bad" >&2; return 1; }
}

# fake_hf's alphabet is letters only, so its suffix must be letters too.
@test "a longer token of every listed shape leaves no raw tail" {
  bad=""
  for row in $BUILTIN_TABLE; do
    sfx=0a1b2c3d4e5f
    [ "${row%%:*}" = fake_hf ] && sfx=kQmZwXyT
    t="$("${row%%:*}")$sfx"
    [ "$(builtin_out "before $t after")" = "before <redacted:${row#*:}> after" ] || bad="$bad ${row%%:*}"
  done
  [ -z "$bad" ] || { echo "tail left for:$bad" >&2; return 1; }
}

@test "running the built-ins twice on every listed token gives the same text as once" {
  IN=""
  for row in $BUILTIN_TABLE; do IN="$IN $("${row%%:*}")"; done
  [ "$(builtin_twice "$IN")" = "$(builtin_out "$IN")" ]
}

@test "the real gitleaks flags every fake in the table, so the fakes are realistic" {
  require_real_gitleaks
  bad=""
  for row in $BUILTIN_TABLE; do
    t="$("${row%%:*}")"
    n="$(printf 'key = "%s"\n' "$t" | "$(real_gitleaks)" stdin --no-banner --exit-code 0 --report-format json --report-path - 2>/dev/null | jq 'length')"
    [ "${n:-0}" -ge 1 ] || bad="$bad ${row%%:*}"
  done
  [ -z "$bad" ] || { echo "gitleaks did not flag:$bad" >&2; return 1; }
}

@test "ordinary code text that resembles a short prefix comes back unchanged" {
  bad=""
  for s in npm_config_registry 'hf_hub_download(repo_id)' SG.fields \
           "ey""Jabcdefghijklmn.ey""Jabcdefghijklmn.abcdefghij" \
           lin_api_version dp.pt.x glpat-short hvs.short \
           risk_test_handlesemptystringinput \
           '\task_test_ConfigurationSettings'; do
    [ "$(builtin_out "$s")" = "$s" ] || bad="$bad [$s]"
  done
  [ -z "$bad" ] || { echo "changed:$bad" >&2; return 1; }
}

# A JSON escape is a backslash + letter in the text, not a newline.
@test "a stripe key right after a literal backslash-n still redacts" {
  t="$(fake_key "sk_""live_" "$ALNUM" 24)"
  [ "$(builtin_out "x\\n$t")" = 'x\n<redacted:stripe-key>' ]
}

@test "a stripe live key right after KEY_ or a literal equals sign still redacts" {
  t="$(fake_key "sk_""live_" "$ALNUM" 24)"
  for pre in 'KEY_' '\u003d'; do
    out="$(builtin_out "$pre$t")"
    [[ "$out" == *'<redacted:stripe-key>'* ]] || { echo "kept: $out" >&2; return 1; }
    [[ "$out" != *"${t#sk_live_}"* ]] || { echo "raw body: $out" >&2; return 1; }
  done
}

# Each row: a lead token glued straight to a live key (or, for the AIza row, to
# a google key). The lead's own rule must not stop the later one from firing.
@test "a live key glued to another token leaves no raw key body" {
  live="$(fake_key "sk_""live_" "$ALNUM" 24)"
  rk12="$(fake_key "rk_""live_" "$ALNUM" 12)"
  rk24="$(fake_key "rk_""live_" "$ALNUM" 24)"
  gk="$(fake_key "AI""za" "$ALNUM" 35)"
  wh="https://ho""oks.slack.com/services/$(fake_key "" "A" 43)"
  for row in "$(fake_key "sk_""test_" "$ALNUM" 24)$live|$live" \
             "$rk12$rk24|$rk24" \
             "xo""xe-1-abcdefghij-$live|$live" \
             "xo""xe-1-abcdefghij$gk|google" \
             "$wh$live|$live" \
             "xa""pp-1-abcde-123-abcdefgh$live|$live"; do
    out="$(builtin_out "${row%|*}")"
    if [ "${row#*|}" = google ]; then
      [[ "$out" == *'<redacted:google-api-key>'* ]] || { echo "kept: $out" >&2; return 1; }
    else
      key="${row#*|}"
      [[ "$out" != *"${key#*_live_}"* ]] || { echo "raw body: $out" >&2; return 1; }
    fi
  done
}

# The keyword rule must see a run before an added rule can split it at a marker.
@test "a short keyword value before a new token shape is not left raw" {
  out="$(builtin_out "password=hunter2.$(fake_gitlab)")"
  [[ "$out" != *hunter2* ]] || { echo "raw: $out" >&2; return 1; }
  out="$(builtin_out "token=abc.xo""xe-1-abcdefghij")"
  [[ "$out" != *token=abc* ]] || { echo "raw: $out" >&2; return 1; }
}

# One glued token can match only once its neighbour is a marker, so the
# built-ins repeat until both are markers.
@test "a token glued after another token leaves no raw token body" {
  aws="$(fake_aws)"
  goog="$(fake_key "AI""za" "$ALNUM" 35)"
  for row in "$(fake_shopify)$(fake_npm)|<redacted:shopify-token><redacted:npm-token>" \
             "$(fake_do)$(fake_npm)|<redacted:digitalocean-token><redacted:npm-token>" \
             "$(fake_do)$(fake_gitlab)|<redacted:digitalocean-token><redacted:gitlab-pat>" \
             "$(fake_shopify)$(fake_hf)|<redacted:shopify-token><redacted:huggingface-token>" \
             "$(fake_shopify)$(fake_shopify)|<redacted:shopify-token><redacted:shopify-token>" \
             "$aws$goog|<redacted:aws-access-key><redacted:google-api-key>"; do
    out="$(builtin_out "${row%|*}")"
    [ "$out" = "${row#*|}" ] || { echo "got: $out want: ${row#*|}" >&2; return 1; }
  done
}

# One python process walks every ordered pair and triple of fakes and fragments.
@test "running the built-ins twice on any two or three glued tokens gives the same text as once" {
  fakes=""
  for row in $BUILTIN_TABLE; do fakes="$fakes $("${row%%:*}")"; done
  fakes="$fakes $(fake_lw) $(fake_ant) $(fake_ghp) $(fake_slack) $(fake_aws)"
  fakes="$fakes $(fake_key "sk-" "$ALNUM" 48) $(fake_key "AI""za" "$ALNUM" 35) $(fake_key "sk_""live_" "$ALNUM" 24)"
  # shellcheck disable=SC2086
  run python3 -c '
import itertools, sys
sys.path.insert(0, sys.argv[1])
import redact
parts = sys.argv[2:] + ["token=", "password: hunter2", "secret=", "hunter2", "word", "_", "-", "."]
bad = []
for n in (2, 3):
    for combo in itertools.product(parts, repeat=n):
        s = "".join(combo)
        once = redact.builtin(s)
        if redact.builtin(once) != once:
            bad.append(s)
if bad:
    sys.stderr.write("%d unstable inputs; first 3 (fakes):\n" % len(bad))
    for s in bad[:3]:
        sys.stderr.write("  %s\n" % s)
    sys.exit(1)
' "$HOOKS/lib" $fakes
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

# A chain still changing on the 8th pass fails closed.
@test "a chain of glued tokens that needs more than 8 passes fails closed to one marker" {
  # 7 pairs is the shortest chain still changing on the 8th pass.
  chain="$(python3 -c 'import sys; sys.stdout.write((sys.argv[1] + sys.argv[2]) * 7)' "$(fake_grafana)" "$(fake_shopify)")"
  out="$(builtin_out "$chain")"
  [ "$out" = "<redacted:glued-secrets>" ] || { echo "got: ${out:0:200}" >&2; return 1; }
}

@test "a chain of glued tokens that settles within the cap is redacted token by token" {
  # 6 pairs is the longest chain that settles within the cap.
  chain="$(python3 -c 'import sys; sys.stdout.write((sys.argv[1] + sys.argv[2]) * 6)' "$(fake_grafana)" "$(fake_shopify)")"
  out="$(builtin_out "$chain")"
  want="$(python3 -c 'import sys; sys.stdout.write("<redacted:grafana-token><redacted:shopify-token>" * 6)')"
  [ "$out" = "$want" ] || { echo "got: ${out:0:200}" >&2; return 1; }
}

@test "a 200000 character chain of glued tokens uses under 10 seconds of CPU time" {
  run python3 -c '
import sys, time
sys.path.insert(0, sys.argv[1])
import redact
pair = sys.argv[2] + sys.argv[3]
s = pair * (200000 // len(pair) + 1)
# CPU time, so machine load does not fail the test.
t = time.process_time()
redact.builtin(s)
dt = time.process_time() - t
if dt >= 10:
    sys.stderr.write("used %.1f seconds of CPU time\n" % dt)
    sys.exit(1)
' "$HOOKS/lib" "$(fake_grafana)" "$(fake_shopify)"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

# body_free <out> <body>... — fails on an empty output (a dropped or failed
# redaction must not read as clean) or when any 8-character window of a body
# is still in the output.
body_free() {
  python3 -c '
import sys
out = sys.argv[1]
if not out:
    sys.stderr.write("empty output\n"); sys.exit(1)
for b in sys.argv[2:]:
    for i in range(len(b) - 7):
        if b[i:i + 8] in out:
            sys.stderr.write("raw body window %d of a body in: %s\n" % (i, out[:200])); sys.exit(1)
' "$@"
}

# Two different bodies per type, so a rule cannot pass by matching one fixed string.
fake_ghp2() { fake_key "gh""p_" "Zx9Cv8Bn7Mq6Wr5Et4Yu3Io2Pa1Sd0Fg" 36; }
fake_gho()  { fake_key "gh""o_" "Mn4Bv5Cx6Zl7Ka8Js9Hd1Gf2Ep3Wo4Ui" 36; }
fake_aws2() { fake_key "AK""IA" "MJHGFDSALKPOIUYT2345672W" 16; }
fake_asia() { fake_key "AS""IA" "ZXCVBNMLKJHGFDSA765432QW" 16; }
fake_aws3() { fake_key "AK""IA" "QZXRT5NBKDWP2367" 16; }

# glued_rows <tokA> <tokB> — wraps the pair at the string start, after a space
# and after "=", and checks the lead and trail are kept, a marker is present
# and neither body (the token minus its 4-character prefix) survives.
glued_rows() {
  local pair="$1$2" lead out
  for lead in "" "pre " "pre="; do
    out="$(builtin_out "$lead$pair post")"
    [[ "$out" == "$lead"* ]] || { echo "lead lost: $out" >&2; return 1; }
    [[ "$out" == *' post' ]] || { echo "trail lost: $out" >&2; return 1; }
    [[ "$out" == *'<redacted:'* ]] || { echo "no marker: $out" >&2; return 1; }
    body_free "$out" "${1:4}" "${2:4}" || return 1
  done
}

@test "two glued ghp tokens leave no raw token body" {
  glued_rows "$(fake_ghp)" "$(fake_ghp2)"
  glued_rows "$(fake_ghp)" "$(fake_gho)"
}

@test "two glued aws key ids leave no raw key body" {
  glued_rows "$(fake_aws2)" "$(fake_aws3)"
  glued_rows "$(fake_aws3)" "$(fake_asia)"
}

@test "three glued ghp tokens leave no raw token body" {
  out="$(builtin_out "pre $(fake_ghp)$(fake_ghp2)$(fake_gho) post")"
  [[ "$out" == 'pre '*' post' ]] || { echo "got: $out" >&2; return 1; }
  body_free "$out" "$(fake_ghp | cut -c5-)" "$(fake_ghp2 | cut -c5-)" "$(fake_gho | cut -c5-)"
}

@test "three glued aws key ids leave no raw key body" {
  out="$(builtin_out "pre $(fake_aws2)$(fake_asia)$(fake_aws2) post")"
  [[ "$out" == 'pre '*' post' ]] || { echo "got: $out" >&2; return 1; }
  body_free "$out" "$(fake_aws2 | cut -c5-)" "$(fake_asia | cut -c5-)"
}

# Ordinary text next to a marker or an uppercase run must stay as written.
@test "forty uppercase letters and digits with no key id prefix are kept" {
  in="Q3XZ7RT5NB2KD8WPQ3XZ7RT5NB2KD8WPQ3XZ7RT5"
  [ "$(builtin_out "$in")" = "$in" ]
}

@test "a token then a space then a long word redacts only the token" {
  word="abcdefghijklmnopqrst"
  [ "$(builtin_out "$(fake_ghp) $word")" = "<redacted:github-pat> $word" ]
}

@test "a token then a git remote path keeps the path" {
  suffix="@github.com/owner/repository-name.git"
  [ "$(builtin_out "$(fake_ghp)$suffix")" = "<redacted:github-pat>$suffix" ]
}

@test "known limit: a token then a 7 character tail keeps the tail" {
  [ "$(builtin_out "$(fake_ghp)_abcdef")" = "<redacted:github-pat>_abcdef" ]
}

@test "a token then an 8 character tail sweeps the tail" {
  [ "$(builtin_out "$(fake_ghp)_abcdefg")" = "<redacted:github-pat><redacted:glued-secrets>" ]
}

@test "known limit: a word character glued in front of a token keeps the token raw" {
  input="x$(fake_npm)
_$(fake_do)"
  [ "$(builtin_out "$input")" = "$input" ]
  input="1$(fake_npm)"
  [ "$(builtin_out "$input")" = "$input" ]
}

@test "known limit: an uppercase letter glued in front of an aws key id keeps the id raw" {
  input="A$(fake_aws)"
  [ "$(builtin_out "$input")" = "$input" ]
  input="9$(fake_aws)"
  [ "$(builtin_out "$input")" = "$input" ]
}

@test "six grafana shopify pairs then a glued ghp pair fail closed to one marker" {
  chain="$(python3 -c 'import sys; sys.stdout.write((sys.argv[1] + sys.argv[2]) * 6 + sys.argv[3] + sys.argv[4])' \
    "$(fake_grafana)" "$(fake_shopify)" "$(fake_ghp)" "$(fake_ghp2)")"
  [ "$(builtin_out "$chain")" = "<redacted:glued-secrets>" ]
}

@test "a 200000 character run of glued ghp tokens, glued aws key ids or uppercase letters uses under 10 seconds of CPU time each" {
  run python3 -c '
import sys, time
sys.path.insert(0, sys.argv[1])
import redact
ghp = sys.argv[2] + sys.argv[3]
aws = sys.argv[4] + sys.argv[5]
for s in (ghp * (200000 // len(ghp) + 1),
          aws * (200000 // len(aws) + 1),
          "BCDEFGHJKLMNPQRSTUVWXYZ" * (200000 // 23 + 1)):
    # CPU time, so machine load does not fail the test.
    t = time.process_time()
    redact.builtin(s)
    dt = time.process_time() - t
    if dt >= 10:
        sys.stderr.write("used %.1f seconds of CPU time\n" % dt)
        sys.exit(1)
' "$HOOKS/lib" "$(fake_ghp)" "$(fake_ghp2)" "$(fake_aws2)" "$(fake_asia)"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

# An open-ended body takes the start of the next token; the tail sweep removes
# what is left of it.
@test "a token directly after an open-ended body leaves no raw token body" {
  # row: first|second|marker the output starts with|chars cut from first|from second
  for row in "$(fake_npm)|$(fake_key "sk_""test_" "$ALNUM" 24)|<redacted:npm-token>|4|8" \
             "$(fake_hf)|$(fake_npm)|<redacted:huggingface-token>|3|4" \
             "$(fake_ghp)|$(fake_ghp2)|<redacted:github-pat>|4|4" \
             "$(fake_shopify)|$(fake_do)|<redacted:shopify-token>|6|7"; do
    IFS='|' read -r first second marker n1 n2 <<<"$row"
    out="$(builtin_out "$first$second")"
    [[ "$out" == "$marker"* ]] || { echo "got: $out want prefix: $marker" >&2; return 1; }
    body_free "$out" "${first:$n1}" "${second:$n2}" || return 1
  done
}

# An AWS-shaped run inside a longer token must not cut it in two.
@test "an aws-shaped run inside a longer token does not split the token" {
  local lower="abcdefghijklmnopqrst" aws
  aws="$(fake_key "AK""IA" "QZXRT5NBKDWP2367AB" 18)"
  [ "$(builtin_out "$(fake_key "np""m_" "$lower" 20)$aws$lower")" = "<redacted:npm-token>" ]
  [ "$(builtin_out "$(fake_key "glpat-" "$lower" 10)${aws}ccc")" = "<redacted:gitlab-pat>" ]
}

@test "an aws-shaped run inside a blocked token does not split the token" {
  local aws shp
  aws="$(fake_key "AK""IA" "QZXRT5NBKDWP2367AB" 22)"
  shp="$(fake_key "shp""at_" "0123456789abcdef" 38)"
  [ "$(builtin_out "$shp$(fake_key "glpat-" "$aws" 26)tail")" = "<redacted:shopify-token><redacted:gitlab-pat>" ]
  [ "$(builtin_out "$shp$(fake_key "np""m_" "${aws}abcdefghijklmnopqrstuvwx" 46)tail")" = "<redacted:shopify-token><redacted:npm-token>" ]
}

@test "swept and collapsed outputs are stable under a second run" {
  local pair chain i
  pair="$(fake_ghp)$(fake_ghp2)"
  chain="$(fake_key "gls""a_" "aB3dE5gH7jK9mN1pQ3sT5vX7zA9cD1fG" 37)_ab12cd34$(fake_key "shp""at_" "0123456789abcdef" 38)"
  for i in 1 2 3 4 5; do chain="$chain$chain"; done
  chain="$chain$pair"
  for IN in "$pair" "$(fake_aws2)$(fake_asia)" "$chain"; do
    [ "$(builtin_twice "$IN")" = "$(builtin_out "$IN")" ]
  done
}

@test "a long uppercase word that starts like an aws key id is redacted" {
  [ "$(builtin_out "ASIAPACIFICHEADQUARTERSOFFICE")" = "<redacted:aws-access-key>" ]
}

# --- glued pairs end to end -------------------------------------------------

# glued_turn <pair> — one turn whose prompt holds the pair in a plain sentence
# (no keyword near it). The stub reply quotes the sentence as the model is
# shown it: the built-in output of the sentence; body_free is the independent
# check.
glued_turn() {
  local sentence="we saw $1 in the logs yesterday"
  user_line "$U1" "$sentence" > "$TX"
  GLUED_REPLY="$(jq -nc --arg u "$U1" --arg q "$(builtin_out "$sentence")" \
    '{requests:[{text:"user saw a pair",quote:$q,uuid:$u}],outcomes:[],mistakes:[]}')"
}

# assert_glued_stored <body>... — one request is stored, its quote holds a
# marker, the row and the model stdin are body-free, and the words around the
# pair reach the model.
assert_glued_stored() {
  [ "$(field '.requests|length')" -eq 1 ] || { echo "not one request stored" >&2; return 1; }
  [[ "$(field '.requests[0].quote')" == *'<redacted:'* ]] || { echo "quote has no marker" >&2; return 1; }
  body_free "$(cat "$WORKLOG_JSONL")" "$@" || { echo "raw body in the row" >&2; return 1; }
  body_free "$(cat "$CLAUDE_STDIN_LOG")" "$@" || { echo "raw body in the model stdin" >&2; return 1; }
  grep -qF -- "we saw " "$CLAUDE_STDIN_LOG" || { echo "lead words missing from the model stdin" >&2; return 1; }
  grep -qF -- " in the logs yesterday" "$CLAUDE_STDIN_LOG" || { echo "trail words missing from the model stdin" >&2; return 1; }
}

@test "with gitleaks absent a glued ghp pair in the prompt is stored redacted" {
  glued_turn "$(fake_ghp)$(fake_ghp2)"
  drive_with "PATH=$(path_without_gitleaks)" -- "$GLUED_REPLY"
  assert_glued_stored "$(fake_ghp | cut -c5-)" "$(fake_ghp2 | cut -c5-)"
}

@test "with gitleaks absent a glued aws key id pair in the prompt is stored redacted" {
  glued_turn "$(fake_aws2)$(fake_asia)"
  drive_with "PATH=$(path_without_gitleaks)" -- "$GLUED_REPLY"
  assert_glued_stored "$(fake_aws2 | cut -c5-)" "$(fake_asia | cut -c5-)"
}

@test "with the real gitleaks a glued ghp pair in the prompt is stored redacted" {
  require_real_gitleaks
  glued_turn "$(fake_ghp)$(fake_ghp2)"
  drive_with "GITLEAKS_STUB=passthrough" -- "$GLUED_REPLY"
  assert_glued_stored "$(fake_ghp | cut -c5-)" "$(fake_ghp2 | cut -c5-)"
}

@test "with the real gitleaks a glued aws key id pair in the prompt is stored redacted" {
  require_real_gitleaks
  glued_turn "$(fake_aws2)$(fake_asia)"
  drive_with "GITLEAKS_STUB=passthrough" -- "$GLUED_REPLY"
  assert_glued_stored "$(fake_aws2 | cut -c5-)" "$(fake_asia | cut -c5-)"
}

# gitleaks flags the Pulumi token in the first position of this sentence only;
# no built-in rule matches it. Its marker then lands directly before the URL
# path, so the built-ins must run again after the gitleaks replacement or the
# quote and the body redact differently and the entry is dropped.
@test "a gitleaks marker directly before a URL path is swept in the quote and the body alike" {
  require_real_gitleaks
  KEY="$(fake_pulumi)"
  sentence="set the access token var to $KEY then open https://app.example.com/$KEY/stacks/production to check"
  printf '%s\n' "$sentence" | "$(real_gitleaks)" stdin --no-banner --exit-code 0 --report-format json --report-path - 2>/dev/null \
    | jq -e 'map(.RuleID) | index("pulumi-api-token")' >/dev/null
  [ "$(builtin_out "$sentence")" = "$sentence" ]
  user_line "$U1" "$sentence" > "$TX"
  drive_with "GITLEAKS_STUB=passthrough" -- \
    "$(jq -nc --arg u "$U1" --arg q 'https://app.example.com/<redacted:pulumi-api-token><redacted:glued-secrets> to check' \
      '{requests:[{text:"user opened a stack",quote:$q,uuid:$u}],outcomes:[],mistakes:[]}')"
  [ "$(field '.requests|length')" -eq 1 ]
  [[ "$(field '.requests[0].quote')" == *'<redacted:glued-secrets>'* ]]
}

# Stub twin of the real-gitleaks test above: the stub flags the same secret, so
# the path is covered with no gitleaks binary.
@test "a stubbed gitleaks marker directly before a URL path is swept in the quote and the body alike" {
  KEY="$(fake_pulumi)"
  sentence="set the access token var to $KEY then open https://app.example.com/$KEY/stacks/production to check"
  user_line "$U1" "$sentence" > "$TX"
  drive_with "GITLEAKS_STUB=find:pulumi-api-token:$KEY" -- \
    "$(jq -nc --arg u "$U1" --arg q 'https://app.example.com/<redacted:pulumi-api-token><redacted:glued-secrets> to check' \
      '{requests:[{text:"user opened a stack",quote:$q,uuid:$u}],outcomes:[],mistakes:[]}')"
  [ "$(field '.requests|length')" -eq 1 ]
  [[ "$(field '.requests[0].quote')" == *'<redacted:glued-secrets>'* ]]
}

# --- end to end with gitleaks absent ----------------------------------------

@test "with gitleaks absent an npm token in the prompt is stored as its marker" {
  KEY="$(fake_npm)"
  fixture_secret_prompt "$KEY"
  drive_with "PATH=$(path_without_gitleaks)" -- "$(redacted_reply npm-token)"
  assert_redacted_in_worklog npm-token "$KEY"
}

@test "with gitleaks absent an npm token in the prompt is not in the stdin the model receives" {
  KEY="$(fake_npm)"
  fixture_secret_prompt "$KEY"
  drive_with "PATH=$(path_without_gitleaks)" -- "$CLEAN"
  ! grep -qF -- "$KEY" "$CLAUDE_STDIN_LOG"
}

@test "with gitleaks absent a model-written text holding an npm token is stored redacted" {
  KEY="$(fake_npm)"
  fixture_full
  drive_with "PATH=$(path_without_gitleaks)" -- \
    "$(jq -nc --arg u "$U1" --arg t "leaked $KEY" \
      '{requests:[{text:$t,quote:"do the thing",uuid:$u}],outcomes:[],mistakes:[]}')"
  [ "$(field '.requests[0].text')" = "leaked <redacted:npm-token>" ]
}

# real_redact_texts <text> — the text through redact_texts with the REAL
# gitleaks first on PATH (the stub dir otherwise leads it).
real_redact_texts() {
  PATH="$(dirname "$(real_gitleaks)"):$PATH" python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
import redact
texts, failed = redact.redact_texts([sys.argv[2]])
if failed:
    sys.exit(3)
sys.stdout.write(texts[0])
' "$HOOKS/lib" "$1"
}

# The key id run step must not hide a value from gitleaks: its generic rule
# redacts the whole value, so no short mixed-case piece stays raw below the
# glued-text sweep size.
@test "with gitleaks, a short tail after a glued aws key id run is not left raw" {
  require_real_gitleaks
  tail_piece="aB3dE5g"
  value="pul-$(fake_aws)$(fake_asia)$tail_piece"
  run real_redact_texts "key = \"$value\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"<redacted:"* ]]
  [[ "$output" != *"$tail_piece"* ]]
}

@test "with gitleaks, a short piece in front of an aws key id run is not left raw" {
  require_real_gitleaks
  front_piece="uodm"
  value="$(fake_key "sk_""live_" "aB3dE5gH7jK9mN1pQ3s" 19)$(fake_key "glp""at-" "$front_piece" 4)$(fake_key "AS""IA" "ZXCVBNMLKJHGFDSA765432QW" 20)"
  run real_redact_texts "$value"
  [ "$status" -eq 0 ]
  [[ "$output" == *"<redacted:"* ]]
  [[ "$output" != *"$front_piece"* ]]
}

# ==========================================================================
# 11. the judge call saves no transcript; a channel wrapper is not the quote
# ==========================================================================
# claude#41: the judge's own `claude -p` run left a session transcript behind
# for the librarian to read as if it were a real session, and a Discord turn's
# <channel ...> wrapper ate the 200-char candidate cap so the owner's words
# never reached the model or the stored quote.

@test "the judge call is made with --no-session-persistence" {
  fixture_full
  drive "$CLEAN"
  tr '\0' '\n' < "$CLAUDE_ARGV_LOG" | grep -qx -- '--no-session-persistence'
}

# chan_text <text> [pad-len] — the real Discord wrapper around <text>; pad-len
# sets the opening tag to exactly that many characters.
chan_text() {
  local head='<channel source="plugin:discord:discord" chat_id="1522000000000000000" message_id="1556000000000000000" user="drewdrewthis" user_id="805900000000000000"'
  local tail='>' tag
  if [ -n "${2:-}" ]; then
    tag="$head pad=\"$(printf 'p%.0s' $(seq 1 $(( $2 - ${#head} - ${#tail} - 7 ))))\"$tail"
  else
    tag="$head ts=\"2026-10-06T10:22:41.310Z\"$tail"
  fi
  printf '%s\n%s\n</channel>' "$tag" "$1"
}
chan_line() { user_line "$1" "$(chan_text "$2" "${3:-}")"; }
wl_reply() {  # <quote>
  jq -nc --arg u "$U1" --arg q "$1" \
    '{requests:[{text:"asked",quote:$q,uuid:$u}],outcomes:[],mistakes:[]}'
}
long_text() { printf 'Q%s' "$(printf 'a%.0s' $(seq 1 "$(( $1 - 1 ))"))"; }

@test "a wrapped 300-char message reaches the model starting at the owner's first character" {
  chan_line "$U1" "$(long_text 300)" > "$TX"
  drive "$(wl_reply "$(long_text 150)")"
  grep -qF -- "$(printf 'user\tQaaa')" "$CLAUDE_STDIN_LOG"
}

@test "a wrapped 300-char message with a 150-char quote span stores a 120-char quote" {
  chan_line "$U1" "$(long_text 300)" > "$TX"
  drive "$(wl_reply "$(long_text 150)")"
  [ "$(field '.requests[0].quote|length')" -eq 120 ]
}

@test "a stored quote from a wrapped message holds no channel tag" {
  chan_line "$U1" "$(long_text 300)" > "$TX"
  drive "$(wl_reply "$(long_text 150)")"
  [ "$(field '.requests|length')" -eq 1 ]
  local q; q="$(field '.requests[0].quote')"
  [[ "$q" != *'<channel'* ]]
}

@test "a wrapped 60-char message stores exactly those 60 chars" {
  chan_line "$U1" "$(long_text 60)" > "$TX"
  drive "$(wl_reply "$(long_text 60)")"
  [ "$(field '.requests[0].quote')" = "$(long_text 60)" ]
}

@test "a stored quote from a wrapped message holds no closing channel tag" {
  chan_line "$U1" "$(long_text 60)" > "$TX"
  drive "$(wl_reply "$(long_text 60)")"
  [ "$(field '.requests|length')" -eq 1 ]
  local q; q="$(field '.requests[0].quote')"
  [[ "$q" != *'</channel>'* ]]
}

@test "a 256-char opening tag gives the same stored quote" {
  chan_line "$U1" "$(long_text 60)" 256 > "$TX"
  drive "$(wl_reply "$(long_text 60)")"
  [ "$(field '.requests[0].quote')" = "$(long_text 60)" ]
}

@test "a secret inside the wrapped text is stored redacted" {
  KEY="$(fake_ant)"
  chan_line "$U1" "my token is $KEY please keep it" > "$TX"
  drive "$(wl_reply "my token is <redacted:sk-ant> please keep it")"
  [ "$(field '.requests[0].quote')" = "my token is <redacted:sk-ant> please keep it" ]
}

@test "no tag attribute reaches the stored row" {
  chan_line "$U1" "$(long_text 60)" > "$TX"
  drive "$(wl_reply "$(long_text 60)")"
  [ "$(field '.requests|length')" -eq 1 ]
  ! grep -qE 'chat_id=|user_id=' "$WORKLOG_JSONL"
}

@test "a wrapper with empty text gives no request entry" {
  chan_line "$U1" "" > "$TX"
  drive "$(wl_reply "x")"
  [ "$(field '.requests|length')" -eq 0 ]
}

@test "a wrapper with empty text logs no error" {
  chan_line "$U1" "" > "$TX"
  drive "$(wl_reply "x")"
  no_log
}

@test "a wrapper with empty text shows the model no tag attribute" {
  chan_line "$U1" "" > "$TX"
  drive "$(wl_reply "x")"
  ! grep -qF -- 'chat_id=' "$CLAUDE_STDIN_LOG"
}

@test "a channel tag in the middle of the text is left unchanged" {
  user_line "$U1" 'look at <channel source="x"> in the log' > "$TX"
  drive "$(wl_reply 'look at <channel source="x"> in the log')"
  [ "$(field '.requests[0].quote')" = 'look at <channel source="x"> in the log' ]
}

@test "a record of two wrapped text blocks shows the model both texts and no channel tag" {
  jq -nc --arg u "$U1" --arg a "$(chan_text 'first message here')" --arg b "$(chan_text 'second message here')" \
    '{type:"user",uuid:$u,message:{role:"user",content:[{type:"text",text:$a},{type:"text",text:$b}]}}' > "$TX"
  drive "$(wl_reply 'first message here')"
  grep -qF -- 'first message here' "$CLAUDE_STDIN_LOG"
  grep -qF -- 'second message here' "$CLAUDE_STDIN_LOG"
  ! grep -qF -- '<channel' "$CLAUDE_STDIN_LOG"
  ! grep -qF -- '</channel>' "$CLAUDE_STDIN_LOG"
}

@test "an opening tag with no closing tag is still removed from the candidate body" {
  user_line "$U1" "$(printf '<channel source="x" chat_id="1">\nhello there friend')" > "$TX"
  drive "$(wl_reply 'hello there friend')"
  grep -qF -- "$(printf 'user\thello there friend')" "$CLAUDE_STDIN_LOG"
}

@test "a plain user line stores the same quote as before" {
  user_line "$U1" "do the thing please" > "$TX"
  drive "$(wl_reply 'do the thing please')"
  [ "$(field '.requests[0].quote')" = 'do the thing please' ]
}

# A whitespace-run regex around the closing tag was quadratic: 200,000 spaces took 120 s.
@test "a wrapped body with a 200000-space run is unwrapped fast and the row is written" {
  # Built inside jq: 200,000 chars exceed the shell's single-argument limit.
  jq -nc --arg u "$U1" '{type:"user",uuid:$u,message:{role:"user",
    content:("<channel source=\"x\">\nx" + (" " * 200000) + "y\n</channel>")}}' > "$TX"
  drive "$(wl_reply "x")"
  [ "$(field '.requests|length')" -eq 1 ]
}

# ---------------------------------------------------------------------------
# UUID-CHECK: the ask/end uuid check against the transcript (issue #218)
#
# The check lists every uuid in the transcript and asks whether the slicer's
# ask_uuid / end_uuid is in that list. Two properties are pinned here:
#   - a VALID uuid survives however long the list is (no pipe race), and
#   - the list is the only judge: a slicer uuid the list does not hold is
#     written null, whatever the other records look like (same match rule).
# ---------------------------------------------------------------------------

# fill_records <count> <uuid|zero> — append <count> small non-prompt records,
# each with a distinct uuid ("uuid") or with the number 0 as its uuid ("zero").
# Written by python3 in one pass: a jq call per record would take minutes. The
# type is one the slicer ignores, so the slice is unchanged by the bulk.
fill_records() {
  python3 - "$1" "$2" >> "$TX" <<'PY'
import sys
n, mode = int(sys.argv[1]), sys.argv[2]
for i in range(n):
    u = '"%08x-0000-4000-8000-%012x"' % (i, i) if mode == "uuid" else '0'
    sys.stdout.write('{"type":"progress","uuid":%s}\n' % u)
PY
}

# glued_line <record> — the record, a BARE carriage return, then a filler
# record, on ONE physical line. The slicer reads in text mode, where a bare \r
# ends a line, so it sees both records. `jq -R` splits on \n only, gets one
# line it cannot parse, and lists neither. That is how a uuid the slicer
# reports can be absent from the uuid list.
glued_line() { printf '%s\r{"type":"queue-operation"}\n' "$1"; }

@test "UUID-CHECK: a valid ask_uuid survives a 1 MB uuid list" {
  # The asked prompt is the FIRST uuid in the file, so a matcher that stops at
  # the first hit exits while the writer still has megabytes to send.
  user_line "$U1" "do the thing" > "$TX"
  fill_records 16000 uuid
  [ "$(wc -c < "$TX")" -ge 1000000 ]
  local t0=$SECONDS elapsed
  drive "$CLEAN"
  elapsed=$((SECONDS - t0))
  [ "$(field .ask_uuid)" = "$U1" ]
  # A wide bound on purpose: it only catches a match that goes quadratic or
  # hangs.
  echo "# hook run: ${elapsed}s" >&3
  [ "$elapsed" -le 60 ]
}

@test "UUID-CHECK: a valid end_uuid survives a long uuid list" {
  # end_uuid is the LAST uuid of the turn, so it is never early in the list.
  # Records whose uuid is the number 0 come after it: the slicer treats them
  # as uuid-less (falsy, so end_uuid stays put), jq lists each as a "0" line
  # (an empty line would not do: $(...) strips a trailing run of them), and
  # 70k of them leave the writer far more than a pipe buffer to send after the
  # match.
  user_line "$U1" "do the thing" > "$TX"
  text_line "$U2" "done" >> "$TX"
  fill_records 70000 zero
  local t0=$SECONDS elapsed
  drive "$CLEAN"
  elapsed=$((SECONDS - t0))
  [ "$(field .end_uuid)" = "$U2" ]
  # A wide bound on purpose: it only catches a match that goes quadratic or
  # hangs.
  echo "# hook run: ${elapsed}s" >&3
  [ "$elapsed" -le 60 ]
}

@test "UUID-CHECK: a uuid held by the transcript is written unchanged" {
  fixture_full
  drive "$CLEAN"
  [ "$(field .ask_uuid)" = "$U1" ]
}

@test "UUID-CHECK: given an ask_uuid no jq-listed record holds, it is written null" {
  user_line "$U0" "an earlier prompt" > "$TX"
  glued_line "$(user_line "$U1" "do the thing")" >> "$TX"
  drive "$CLEAN"
  [ "$(jq -c .ask_uuid "$WORKLOG_JSONL")" = "null" ]
}

@test "UUID-CHECK: given an ask_uuid that is a strict prefix of another record's uuid, it is written null" {
  longer="${U1}-extra"
  text_line "$longer" "a record with a longer uuid" > "$TX"
  glued_line "$(user_line "$U1" "do the thing")" >> "$TX"
  drive "$CLEAN"
  [ "$(jq -c .ask_uuid "$WORKLOG_JSONL")" = "null" ]
}

@test "UUID-CHECK: given an ask_uuid that is another uuid with its last 4 chars starred, it is written null" {
  starred="${U1%????}****"
  text_line "$U1" "a record with the full uuid" > "$TX"
  glued_line "$(user_line "$starred" "do the thing")" >> "$TX"
  drive "$CLEAN"
  [ "$(jq -c .ask_uuid "$WORKLOG_JSONL")" = "null" ]
}

@test "UUID-CHECK: given an end_uuid no jq-listed record holds, it is written null" {
  user_line "$U1" "do the thing" > "$TX"
  glued_line "$(text_line "$U2" "done")" >> "$TX"
  drive "$CLEAN"
  [ "$(jq -c .end_uuid "$WORKLOG_JSONL")" = "null" ]
}

@test "UUID-CHECK: given an end_uuid that is a strict prefix of another record's uuid, it is written null" {
  text_line "${U2}-extra" "a record with a longer uuid" > "$TX"
  user_line "$U1" "do the thing" >> "$TX"
  glued_line "$(text_line "$U2" "done")" >> "$TX"
  drive "$CLEAN"
  [ "$(jq -c .end_uuid "$WORKLOG_JSONL")" = "null" ]
}

@test "UUID-CHECK: given an end_uuid that is another uuid with its last 4 chars starred, it is written null" {
  text_line "$U2" "a record with the full uuid" > "$TX"
  user_line "$U1" "do the thing" >> "$TX"
  glued_line "$(text_line "${U2%????}****" "done")" >> "$TX"
  drive "$CLEAN"
  [ "$(jq -c .end_uuid "$WORKLOG_JSONL")" = "null" ]
}

# A tripwire, not the proof: under pipefail any pipe into an early-exit grep
# (grep -q, -Fxq, ...) can null valid uuids (SIGPIPE, 141). The two
# long-list tests above are the behaviour proof.
@test "UUID-CHECK: the hook checks uuids without a grep pipe" {
  run grep -cE '\|[[:space:]]*grep[^|]*[[:space:]]-[a-zA-Z]*q' "$HOOK"
  [ "$output" = "0" ]
}

# A uuid value holding a newline would match two neighbouring lines of the list
# (jq prints it as two lines). Both records are real: the slicer keeps the
# newline, jq -r prints it intact.
@test "UUID-CHECK: given an ask_uuid that holds a newline spanning two listed uuids, it is written null" {
  text_line "$U0" "first listed" > "$TX"
  text_line "$U2" "second listed" >> "$TX"
  user_line "$U0"$'\n'"$U2" "do the thing" >> "$TX"
  drive "$CLEAN"
  [ "$(jq -c .ask_uuid "$WORKLOG_JSONL")" = "null" ]
}

@test "UUID-CHECK: given an end_uuid that holds a newline spanning two listed uuids, it is written null" {
  text_line "$U0" "first listed" > "$TX"
  user_line "$U1" "do the thing" >> "$TX"
  text_line "$U2" "second listed" >> "$TX"
  text_line "$U0"$'\n'"$U2" "done" >> "$TX"
  drive "$CLEAN"
  [ "$(jq -c .end_uuid "$WORKLOG_JSONL")" = "null" ]
}
