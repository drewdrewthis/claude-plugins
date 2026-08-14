#!/usr/bin/env bats
# Tests for the per-session /how-do-i digest store — the warm-start payload.
#
# THE DESIGN CONSTRAINT UNDER TEST: append-only, one file per digest, every
# write a fresh file. turn-state.sh chose one-file-per-fact precisely to remove
# read-modify-write, and a digest counter would put it straight back: read the
# highest n, add one, write — two concurrent writers pick the same n and one
# digest is lost. The store therefore names files by timestamp + a
# kernel-unique suffix, never by a counter it has to read first.
#
# THE OTHER INVARIANT: digests persist ACROSS turns while the per-turn gate
# flags do not. Both live under $TURN_STATE_DIR, so the tests below pin that
# ts_reset() cannot reach them and that the gate still fires on turn two.
#
# Run: bats hooks/tests/session-digest.bats

setup() {
  PLUGIN="$BATS_TEST_DIRNAME/../.."
  HOOKS="$PLUGIN/hooks"
  LIB="$HOOKS/lib/session-digest.sh"
  READER="$PLUGIN/scripts/session-digest-read.sh"
  export TURN_STATE_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/sd.XXXXXX")"
  export HOME="$(mktemp -d "${BATS_TMPDIR:-/tmp}/sd-home.XXXXXX")"
  mkdir -p "$HOME/.claude"
  export GATE_FAILOPEN_LOG="$TURN_STATE_DIR/gate-failopen.jsonl"
  SID="bats-sd-$$-$BATS_TEST_NUMBER"
}

teardown() {
  rm -rf "$TURN_STATE_DIR" "$HOME" 2>/dev/null || true
}

digest_dir() { printf '%s/digests' "$TURN_STATE_DIR"; }
count_digests() { find "$(digest_dir)" -name "$SID.digest.*" -type f 2>/dev/null | wc -l | tr -d ' '; }

# Feed a PostToolUse(Skill) payload to the writer hook, wrapping the body the
# way the harness really does (measured over 260 how-do-i Skill results).
record_digest() {
  local skill="${1:-how-do-i}" text="$2"
  raw_result "$skill" "Skill \"$skill\" completed (forked execution).

Result:
$text"
}

# raw_result <skill> <tool_response verbatim> — for the shapes that are NOT a
# wrapped digest.
raw_result() {
  local skill="$1" text="$2"
  jq -nc --arg s "$SID" --arg k "$skill" --arg t "$text" \
    '{session_id:$s, tool_name:"Skill", tool_input:{skill:$k}, tool_response:$t}' \
    | bash "$HOOKS/digest-record.sh"
}

# ---------- the write path (AC-2) ----------

@test "a how-do-i digest is written as its own file under the session key" {
  record_digest how-do-i "GOAL: first thing"
  [ "$(count_digests)" -eq 1 ]
}

@test "a second digest adds a file rather than replacing the first" {
  record_digest how-do-i "GOAL: first thing"
  record_digest how-do-i "GOAL: second thing"
  [ "$(count_digests)" -eq 2 ]
  run bash "$READER" --read "$SID"
  [[ "$output" == *"first thing"* ]]
  [[ "$output" == *"second thing"* ]]
}

@test "no digest file is ever rewritten (append-only: every write is a fresh file)" {
  record_digest how-do-i "one"
  local first; first="$(find "$(digest_dir)" -name "$SID.digest.*" -type f)"
  local before; before="$(cat "$first")"
  record_digest how-do-i "two"
  # the original file is untouched, byte for byte
  [ "$(cat "$first")" = "$before" ]
}

@test "concurrent writes lose nothing — racing writers produce N digests" {
  # The lost-update test the design constraint exists for. A counter-named
  # file (.digest.1, .digest.2) has to READ the highest n before writing;
  # racing writers read the same n and one write clobbers the other.
  #
  # THE RACE HAS TO BE REAL. Backgrounding N copies of the hook does NOT
  # produce one: each is a fresh bash + jq startup, and the jitter spreads the
  # writes far enough apart that every writer sees a distinct count. Verified
  # by mutation — a counter-based sd_write passes that version of this test.
  # So: source the lib in-process (no startup jitter) and hold every writer on
  # a barrier, releasing them into the critical section together.
  local n=25 i GO="$TURN_STATE_DIR/go"
  mkdir -p "$(digest_dir)"
  for i in $(seq 1 $n); do
    (
      # shellcheck source=../lib/session-digest.sh
      . "$LIB"
      while [ ! -e "$GO" ]; do :; done
      printf 'concurrent-payload-%s' "$i" | sd_write "$SID"
    ) &
  done
  sleep 1          # every subshell reaches the barrier
  : > "$GO"        # ...and is released at once
  wait

  [ "$(count_digests)" -eq "$n" ] || {
    echo "expected $n digests, found $(count_digests) — a write was lost"; false
  }
  local body; body="$(cat "$(digest_dir)"/$SID.digest.* 2>/dev/null)"
  for i in $(seq 1 $n); do
    [[ "$body" == *"concurrent-payload-$i"* ]] || {
      echo "lost update: concurrent-payload-$i is missing"; false
    }
  done
}

@test "digests are keyed by session — another session's digests are not returned" {
  record_digest how-do-i "mine"
  # The other session's payload must be a REAL wrapped digest, or it would be
  # rejected for the wrong reason and this test would pass without ever
  # exercising the session key.
  jq -nc --arg t "Skill \"how-do-i\" completed (forked execution).

Result:
theirs" \
    '{session_id:"some-other-session", tool_name:"Skill", tool_input:{skill:"how-do-i"}, tool_response:$t}' \
    | bash "$HOOKS/digest-record.sh"
  # it landed, just under a different key
  [ "$(find "$(digest_dir)" -maxdepth 1 -type f | wc -l | tr -d ' ')" -eq 2 ]
  run bash "$READER" --read "$SID"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mine"* ]]
  [[ "$output" != *"theirs"* ]]
}

@test "a session id containing path separators cannot escape the digest dir" {
  # Wrapped payload on purpose: an unwrapped one is rejected before the key is
  # ever used, so the test would pass without exercising the sanitizer at all.
  jq -nc --arg t "Skill \"how-do-i\" completed (forked execution).

Result:
escape" \
    '{session_id:"../../evil", tool_name:"Skill", tool_input:{skill:"how-do-i"}, tool_response:$t}' \
    | bash "$HOOKS/digest-record.sh"
  [ ! -e "$TURN_STATE_DIR/../../evil.digest" ]
  # it may exist, but only INSIDE the digest dir under a sanitized name
  run bash -c "find '$(digest_dir)' -maxdepth 1 -type f | wc -l | tr -d ' '"
  [ "$output" = "1" ]
}

@test "writer and reader derive the SAME key from an id needing sanitizing" {
  # The write key comes from the hook payload's .session_id; the read key comes
  # from whatever the fork prompt passes in. They are only one bucket if both
  # sanitize identically — so derive the read side from the RECORDED payload
  # rather than restating a pre-sanitized literal, which would pass even if the
  # two rules had drifted apart.
  local raw='sess/../weird id.42'
  jq -nc --arg s "$raw" --arg t "Skill \"how-do-i\" completed (forked execution).

Result:
keyed by a messy id" \
    '{session_id:$s, tool_name:"Skill", tool_input:{skill:"how-do-i"}, tool_response:$t}' \
    | bash "$HOOKS/digest-record.sh"
  run bash "$READER" --read "$raw"
  [ "$status" -eq 0 ]
  [[ "$output" == *"keyed by a messy id"* ]]
}

@test "the PRODUCTION key shape round-trips: hook payload id in, fork prompt id out" {
  # The whole feature turns on one identity: the WRITE key (hook payload
  # .session_id) and the READ key (${CLAUDE_SESSION_ID} interpolated into the
  # fork prompt) must name the same bucket, or digests are written and never
  # read and the feature is inert rather than broken.
  #
  # Measured on this machine before relying on it:
  #   - hook payload .session_id == the canonical session UUID (it matches the
  #     transcript filename: 2/2 sampled from a real gate-failopen.jsonl);
  #   - a forked subagent transcript carries its PARENT's sessionId, resolving
  #     to a real parent transcript in 25/25 sampled agent-*.jsonl sidechains.
  # So both sides name the parent session UUID. This test pins that shape.
  local uuid='cd95eb6f-408f-4c02-80af-46f48bb7eef4'
  jq -nc --arg s "$uuid" --arg t "Skill \"procedures:how-do-i\" completed (forked execution).

Result:
established by the first pass" \
    '{session_id:$s, tool_name:"Skill", tool_input:{skill:"procedures:how-do-i"}, tool_response:$t}' \
    | bash "$HOOKS/digest-record.sh"

  run bash "$READER" --read "$uuid"
  [ "$status" -eq 0 ]
  [[ "$output" == *"established by the first pass"* ]] \
    || { echo "write key and read key did not meet for a real session UUID"; false; }
}

@test "a DIFFERENT session's id reads nothing — no shared bucket, no cross-session bleed" {
  # The tolerant-read temptation (replay whatever digests are newest in the
  # dir when the key misses) is refused deliberately: it would hand one
  # session's findings to another as established fact. A miss must stay a cold
  # start.
  local mine='cd95eb6f-408f-4c02-80af-46f48bb7eef4'
  local theirs='11111111-2222-3333-4444-555555555555'
  jq -nc --arg s "$mine" --arg t "Skill \"how-do-i\" completed (forked execution).

Result:
secret to session one" \
    '{session_id:$s, tool_name:"Skill", tool_input:{skill:"how-do-i"}, tool_response:$t}' \
    | bash "$HOOKS/digest-record.sh"

  run bash "$READER" --read "$theirs"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "another session's digest leaked into this one: $output"; false; }
}

# ---------- which skills produce a digest ----------

@test "the namespaced procedures:how-do-i invocation also produces a digest" {
  record_digest "procedures:how-do-i" "namespaced payload"
  [ "$(count_digests)" -eq 1 ]
}

@test "an unrelated skill produces no digest" {
  record_digest "take-note" "not a scout digest"
  [ "$(count_digests)" -eq 0 ]
}

@test "an evil:how-do-i look-alike produces no digest" {
  record_digest "evil:how-do-i" "spoofed"
  [ "$(count_digests)" -eq 0 ]
}

@test "a non-Skill tool produces no digest" {
  jq -nc --arg s "$SID" '{session_id:$s, tool_name:"Edit", tool_input:{}}' \
    | bash "$HOOKS/digest-record.sh"
  [ "$(count_digests)" -eq 0 ]
}

@test "an empty digest body is not stored (nothing to warm-start from)" {
  record_digest how-do-i ""
  [ "$(count_digests)" -eq 0 ]
}

# ---------- tool_response shapes, as actually observed ----------
#
# Measured over 260 how-do-i Skill tool_results in this machine's transcripts:
# every one a string; 247 carried the "completed (forked execution)" wrapper,
# 7 were a user rejection, 6 were a "Launching skill" notice. The wrapper is
# the thing that separates a digest from the other two.

@test "the harness wrapper is stripped, so the replay is the digest alone" {
  record_digest how-do-i "GOAL: the real thing"
  run bash "$READER" --read "$SID"
  [[ "$output" == *"GOAL: the real thing"* ]]
  [[ "$output" != *"completed (forked execution)"* ]]
  [[ "$output" != *"Result:"* ]]
}

@test "a user-rejected skill is NOT stored as a digest" {
  # Observed 7 times. Replaying "the user doesn't want to proceed" to the next
  # scout would present a refusal as an established finding.
  raw_result how-do-i "The user doesn't want to proceed with this tool use. The tool use was rejected."
  [ "$(count_digests)" -eq 0 ]
}

@test "a bare 'Launching skill' notice is NOT stored as a digest" {
  raw_result how-do-i "Launching skill: how-do-i"
  [ "$(count_digests)" -eq 0 ]
}

@test "an unwrapped STRING is NOT stored (on the string path the wrapper is still required)" {
  # Scoped to the string path. This test predates the dogfood round and its old
  # name read as a general contract; it is not one. The live payload is an
  # OBJECT and carries no wrapper — see the block below. A bare string with no
  # wrapper remains unidentifiable, so it is still refused, and now also lands
  # in the fail-open log as an unrecognised shape rather than vanishing.
  raw_result how-do-i "GOAL: looks like a digest but arrived unwrapped"
  [ "$(count_digests)" -eq 0 ]
}

# ---------- the REAL payload shape (dogfood round) ----------
#
# Everything above this block was written against the shape a TRANSCRIPT renders
# for a Skill result. Hook stdin carries a different serialization, so the
# extractor matched nothing in production and no digest was ever written while
# these tests were green. The fixture below is a payload captured live off this
# hook's stdin with tee, committed verbatim, and is now the authority on shape.

@test "the REAL captured PostToolUse payload writes a digest" {
  local fx="$BATS_TEST_DIRNAME/fixtures/posttooluse-skill-forked.live.json"
  [ -f "$fx" ] || { echo "live payload fixture missing: $fx"; false; }

  # Guard the fixture itself: if it is ever replaced by a hand-written stand-in
  # of the OLD shape, this test would quietly go back to proving nothing.
  jq -e '.tool_response | type == "object"' "$fx" >/dev/null \
    || { echo "fixture is not the live object shape — it proves nothing"; false; }
  jq -e '.tool_response.result | type == "string"' "$fx" >/dev/null \
    || { echo "fixture has no string .tool_response.result"; false; }
  jq -e '.tool_response.result | test("completed \\(forked execution\\)") | not' "$fx" >/dev/null \
    || { echo "fixture result is wrapped; the live payload is not"; false; }

  local sid expected
  sid="$(jq -r '.session_id' "$fx")"
  expected="$(jq -r '.tool_response.result' "$fx")"

  run bash -c "bash '$HOOKS/digest-record.sh' < '$fx'"
  [ "$status" -eq 0 ]

  # Keyed by the payload's OWN session id, and readable back through the reader.
  local n
  n="$(find "$(digest_dir)" -name "$sid.digest.*" -type f 2>/dev/null | wc -l | tr -d ' ')"
  [ "$n" -eq 1 ] || { echo "expected 1 digest under $sid, found $n"; false; }

  run bash "$READER" --read "$sid"
  [ "$status" -eq 0 ]
  # The body is the result verbatim — not a wrapper fragment, not a truncation.
  [[ "$output" == *"$(printf '%s' "$expected" | head -c 120)"* ]] \
    || { echo "stored body does not match .tool_response.result"; false; }
  [[ "$output" != *"completed (forked execution)"* ]] \
    || { echo "a wrapper leaked into the stored digest"; false; }
}

@test "the live payload is stored WITHOUT tripping the fail-open recorder" {
  # Both halves on purpose. Asserting only "nothing was logged" passes against
  # the pre-fix extractor too — which stored nothing and logged nothing — so it
  # would be a vacuous guard. Pairing it with "a digest exists" makes the test
  # red before the fix while still catching the opposite failure: a recorder
  # that fires on the healthy path would poison the fail-open rate.
  local fx="$BATS_TEST_DIRNAME/fixtures/posttooluse-skill-forked.live.json"
  run bash -c "bash '$HOOKS/digest-record.sh' < '$fx'"
  [ "$status" -eq 0 ]
  # count_digests() is scoped to $SID; the fixture carries its OWN session id,
  # so count under that instead.
  local sid n
  sid="$(jq -r '.session_id' "$fx")"
  n="$(find "$(digest_dir)" -name "$sid.digest.*" -type f 2>/dev/null | wc -l | tr -d ' ')"
  [ "$n" -eq 1 ] \
    || { echo "the healthy path stored no digest (found $n under $sid)"; false; }
  [ ! -s "$GATE_FAILOPEN_LOG" ] \
    || { echo "the healthy path logged a fail-open: $(cat "$GATE_FAILOPEN_LOG")"; false; }
}

# obj_result <skill> <success> <status> <result> — the LIVE object shape.
obj_result() {
  jq -nc --arg s "$SID" --arg k "$1" --argjson ok "$2" --arg st "$3" --arg r "$4" \
    '{session_id:$s, tool_name:"Skill", tool_input:{skill:$k},
      tool_response:{success:$ok, status:$st, commandName:$k, agentId:"a1", result:$r}}' \
    | bash "$HOOKS/digest-record.sh"
}

@test "a forked result that did NOT succeed is not stored" {
  obj_result how-do-i false forked "half a digest"
  [ "$(count_digests)" -eq 0 ]
}

@test "a background run is not stored, and is not a fail-open" {
  # The wrapper used to make this impossible to confuse with a digest. On the
  # object path it must be refused by name.
  obj_result how-do-i true forked "Scout is running in the background"
  [ "$(count_digests)" -eq 0 ]
  [ ! -s "$GATE_FAILOPEN_LOG" ] \
    || { echo "a recognised benign shape was logged as blind: $(cat "$GATE_FAILOPEN_LOG")"; false; }
}

@test "a user refusal inside the object shape is not stored, and is not a fail-open" {
  obj_result how-do-i true forked "The user doesn't want to proceed with this tool use."
  [ "$(count_digests)" -eq 0 ]
  [ ! -s "$GATE_FAILOPEN_LOG" ] \
    || { echo "a recognised refusal was logged as blind: $(cat "$GATE_FAILOPEN_LOG")"; false; }
}

@test "an UNRECOGNISED tool_response shape is RECORDED, not silently dropped" {
  # The whole point of this round: the previous shape change was silent. Our own
  # skill completing in a shape we cannot read is a blind condition and must be
  # loud on its first occurrence.
  jq -nc --arg s "$SID" \
    '{session_id:$s, tool_name:"Skill", tool_input:{skill:"how-do-i"},
      tool_response:{some_future_key:"digest moved somewhere new"}}' \
    | bash "$HOOKS/digest-record.sh"
  [ "$(count_digests)" -eq 0 ]
  grep -q '"why":"payload-shape-unrecognized"' "$GATE_FAILOPEN_LOG" \
    || { echo "a shape we cannot read was not recorded: $(cat "$GATE_FAILOPEN_LOG" 2>/dev/null)"; false; }
  grep -q '"gate":"digest-record"' "$GATE_FAILOPEN_LOG"
}

# ---------- fail-open (a digest is an optimisation, never a blocker) ----------

@test "the writer stays silent and exits 0 on every path" {
  run record_digest how-do-i "quiet please"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a jq-less machine writes no digest, silently, exit 0" {
  EMPTY="$(mktemp -d)"
  run env PATH="$EMPTY" TURN_STATE_DIR="$TURN_STATE_DIR" \
    /bin/bash -c "echo '{}' | /bin/bash '$HOOKS/digest-record.sh'"
  rm -rf "$EMPTY"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an unwritable digest dir does not fail the hook, and is RECORDED" {
  # Lock the PARENT, not the digest dir. sd_write runs `chmod 700` on the digest
  # dir itself, and the test user owns it, so chmod 500 there is undone by the
  # code under test and the digest lands normally — this test asserted only
  # `status -eq 0` and so passed without ever reaching the unwritable path.
  # The recorder must land OUTSIDE the directory under test — the default log
  # path sits inside $TURN_STATE_DIR, so locking that dir would also gag the
  # recorder and this test would "prove" the silence it exists to forbid.
  export GATE_FAILOPEN_LOG="$HOME/failopen-outside.jsonl"
  chmod 500 "$TURN_STATE_DIR"
  run record_digest how-do-i "cannot land"
  chmod 700 "$TURN_STATE_DIR"

  [ "$status" -eq 0 ]                    # fail-open: never costs the turn
  [ -z "$output" ]                       # and never speaks to the user
  [ "$(count_digests)" -eq 0 ] || { echo "digest landed despite an unwritable store"; false; }
  # ADR-001: fail open AND record. A permanently unwritable store must not
  # remove warm starts for every session in silence.
  [ -s "$GATE_FAILOPEN_LOG" ] || { echo "blind fail-open recorded nothing"; false; }
  grep -q '"gate":"digest-record"' "$GATE_FAILOPEN_LOG" \
    || { echo "not recorded under its own gate name: $(cat "$GATE_FAILOPEN_LOG")"; false; }
  grep -q '"why":"store-unwritable"' "$GATE_FAILOPEN_LOG" \
    || { echo "wrong or quarantined reason: $(cat "$GATE_FAILOPEN_LOG")"; false; }
}

@test "a missing jq is recorded, not silently swallowed" {
  local EMPTY
  EMPTY="$(mktemp -d)"
  run env PATH="$EMPTY" TURN_STATE_DIR="$TURN_STATE_DIR" \
    GATE_FAILOPEN_LOG="$GATE_FAILOPEN_LOG" \
    /bin/bash -c "echo '{}' | /bin/bash '$HOOKS/digest-record.sh'"
  rm -rf "$EMPTY"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -q '"gate":"digest-record"' "$GATE_FAILOPEN_LOG" \
    || { echo "no-jq not recorded: $(cat "$GATE_FAILOPEN_LOG" 2>/dev/null)"; false; }
  grep -q '"why":"no-jq"' "$GATE_FAILOPEN_LOG" \
    || { echo "no-jq not recorded: $(cat "$GATE_FAILOPEN_LOG")"; false; }
}

@test "declining a payload is NOT recorded as a fail-open" {
  # The BLIND/LEGITIMATE line: these are the hook evaluating correctly and
  # declining. Recording them would make the log useless as a rate numerator.
  run record_digest some-other-skill "not ours"
  [ "$status" -eq 0 ]
  run bash -c "echo '{\"tool_name\":\"Bash\"}' | bash '$HOOKS/digest-record.sh'"
  [ "$status" -eq 0 ]
  [ ! -s "$GATE_FAILOPEN_LOG" ] \
    || { echo "a legitimate decline was logged as a blind fail-open: $(cat "$GATE_FAILOPEN_LOG")"; false; }
}

# ---------- the read path (AC-3) ----------

@test "the reader is silent for a session with no prior digests" {
  run bash "$READER" --read "$SID"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the reader returns digests oldest-first behind a numbered delimiter" {
  record_digest how-do-i "oldest payload"
  sleep 1
  record_digest how-do-i "newest payload"
  run bash "$READER" --read "$SID"
  [ "$status" -eq 0 ]
  [[ "$output" == *"==> prior /how-do-i digest 1"* ]]
  [[ "$output" == *"==> prior /how-do-i digest 2"* ]]
  local first_line
  first_line="$(printf '%s\n' "$output" | grep -A1 -m1 '^==> prior' | tail -1)"
  [[ "$first_line" == *"oldest payload"* ]]
}

@test "the reader caps how many digests it returns, and says so out loud" {
  # ~1,700 tokens per digest: an uncapped replay of a long session is a bigger
  # context bill than the cold start it was meant to save. A cap is allowed; a
  # SILENT one is not.
  local i
  for i in $(seq 1 6); do record_digest how-do-i "payload-$i"; sleep 1; done
  run bash "$READER" --read "$SID"
  [ "$status" -eq 0 ]
  local blocks
  blocks="$(printf '%s\n' "$output" | grep -c '^==> prior')"
  [ "$blocks" -eq 3 ]
  # the most recent survive, the oldest are the ones dropped
  [[ "$output" == *"payload-6"* ]]
  [[ "$output" != *"payload-1"* ]]
  [[ "$output" == *"6 prior digests"* ]]
}

@test "SESSION_DIGEST_KEEP tunes the cap" {
  local i
  for i in $(seq 1 4); do record_digest how-do-i "tuned-$i"; sleep 1; done
  run bash -c "SESSION_DIGEST_KEEP=1 bash '$READER' --read '$SID'"
  [ "$status" -eq 0 ]
  local blocks
  blocks="$(printf '%s\n' "$output" | grep -c '^==> prior')"
  [ "$blocks" -eq 1 ]
  [[ "$output" == *"tuned-4"* ]]
}

@test "the reader is read-only — it cannot be used to forge a digest" {
  # The scout holds Bash and is handed this script. It must not be a write
  # surface, or a warm start becomes self-authored context.
  # Exit 2 specifically, not merely non-zero: a missing script exits 127 and
  # would satisfy a `-ne 0` check while proving nothing.
  run bash "$READER" --write "$SID" <<< "forged"
  [ "$status" -eq 2 ]
  [ "$(count_digests)" -eq 0 ]
}

@test "the reader degrades to silence when the session id never interpolated" {
  # ${CLAUDE_SESSION_ID} is substituted into the fork prompt by the harness. If
  # that ever stops happening the scout would pass the literal placeholder
  # through; a warm start must then simply not happen — never an error in the
  # scout's face, and never another session's digests.
  record_digest how-do-i "should not leak"
  run bash "$READER" --read '${CLAUDE_SESSION_ID}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the reader with no session id argument is silent, exit 0" {
  record_digest how-do-i "should not leak"
  run bash "$READER" --read
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------- AC-4: the gate still fires every turn ----------

@test "AC-4: a second turn is still gated even though a digest is carried forward" {
  # The anti-goal of the whole feature. Digest-forwarding changes what the fork
  # STARTS WITH; it must never change whether the gate fires.
  local PAYLOAD_EDIT="{\"session_id\":\"$SID\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/tmp/x\"}}"

  # --- turn 1: gate fires, skill runs, digest recorded, gate releases ---
  printf '{"session_id":"%s"}' "$SID" | bash "$HOOKS/turn-state-reset.sh"
  run env CLAUDE_CODE_AGENT=technician bash -c "echo '$PAYLOAD_EDIT' | bash '$HOOKS/how-do-i-gate.sh'"
  [[ "$output" == *"HOW-DO-I-GATE"* ]]
  printf '{"session_id":"%s","tool_name":"Skill","tool_input":{"skill":"how-do-i"}}' "$SID" \
    | bash "$HOOKS/turn-state-record.sh"
  record_digest how-do-i "turn one digest"
  run env CLAUDE_CODE_AGENT=technician bash -c "echo '$PAYLOAD_EDIT' | bash '$HOOKS/how-do-i-gate.sh'"
  [ -z "$output" ]

  # --- turn 2: the digest survives, and the gate fires again anyway ---
  printf '{"session_id":"%s"}' "$SID" | bash "$HOOKS/turn-state-reset.sh"
  run env CLAUDE_CODE_AGENT=technician bash -c "echo '$PAYLOAD_EDIT' | bash '$HOOKS/how-do-i-gate.sh'"
  [[ "$output" == *"HOW-DO-I-GATE"* ]]
  [[ "$output" == *"deny"* ]]
}

@test "AC-2/AC-4 together: the turn reset clears flags but never the digests" {
  record_digest how-do-i "must survive the turn boundary"
  printf '{"session_id":"%s","tool_name":"Skill","tool_input":{"skill":"how-do-i"}}' "$SID" \
    | bash "$HOOKS/turn-state-record.sh"
  [ -f "$TURN_STATE_DIR/$SID.how_do_i" ]

  printf '{"session_id":"%s"}' "$SID" | bash "$HOOKS/turn-state-reset.sh"

  # the per-turn flag is gone...
  [ ! -f "$TURN_STATE_DIR/$SID.how_do_i" ]
  # ...and the digest is not
  [ "$(count_digests)" -eq 1 ]
  run bash "$READER" --read "$SID"
  [[ "$output" == *"must survive the turn boundary"* ]]
}

@test "the digest store is not readable by other local accounts" {
  # mktemp already gives each digest 0600, but a umask-default 0755 directory
  # still lets any local user enumerate session keys and write times.
  record_digest how-do-i "private"
  run bash -c "ls -ld '$(digest_dir)' | cut -c1-10"
  [ "$output" = "drwx------" ] || { echo "digest dir mode is $output, expected drwx------"; false; }
  run bash -c "ls -l \"\$(find '$(digest_dir)' -type f | head -1)\" | cut -c1-10"
  [ "$output" = "-rw-------" ] || { echo "digest file mode is $output, expected -rw-------"; false; }
}

# ---------- housekeeping ----------

@test "stale digests are reaped so the store cannot grow without bound" {
  mkdir -p "$(digest_dir)"
  printf 'ancient\n' > "$(digest_dir)/$SID.digest.0000000001.aaaaaa"
  touch -t 200001010000 "$(digest_dir)/$SID.digest.0000000001.aaaaaa"
  record_digest how-do-i "fresh"
  run bash "$READER" --read "$SID"
  [[ "$output" != *"ancient"* ]]
  [[ "$output" == *"fresh"* ]]
}

# ---------- the warm-start contract in the fork prompt (AC-3, AC-6) ----------

@test "the how-do-i skill hands the scout its prior digests" {
  SKILL="$PLUGIN/skills/how-do-i/SKILL.md"
  grep -qF 'session-digest-read.sh' "$SKILL"
  grep -qF 'CLAUDE_SESSION_ID' "$SKILL"
}

@test "AC-6: the fork prompt forbids treating a prior digest as coverage" {
  # The anti-goal: a warm-started scout must not skip a governing record
  # because a previous digest 'covered it'. The prompt has to say so, and has
  # to ask for the already-established / newly-found split.
  SKILL="$PLUGIN/skills/how-do-i/SKILL.md"
  grep -qi 'already established' "$SKILL"
  grep -qi 'newly found' "$SKILL"
  grep -qiE 'never a search you can skip|not a substitute for|query pass regardless' "$SKILL"
}
