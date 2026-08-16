#!/usr/bin/env bash
# turn-state.sh — shared turn-state helpers for the per-turn invariant gates.
#
# SINGLE RESPONSIBILITY: own where turn state lives and how it is read/written.
# The gates decide policy; this file decides storage. Nothing else belongs here.
#
# STATE MODEL — one marker file per invariant, keyed by session:
#   $STATE_DIR/<session_id>.turn       created by the reset hook each turn
#   $STATE_DIR/<session_id>.how_do_i   created when Skill(how-do-i) runs
#   $STATE_DIR/<session_id>.am_i_done  created when Skill(am-i-done) runs
#
# WHY MARKER FILES, NOT ONE JSON OBJECT:
# the JSON form required a read-modify-write per flag, which is a lost-update
# race when two Skill PostToolUse hooks land together (orchard-codex#77). With
# one file per fact, setting a flag is a `touch` — atomic by construction, no
# read, no merge, no jq dependency. The race cannot occur because no writer ever
# reads another writer's value.
#
# FAIL-OPEN CONTRACT: every helper returns "satisfied" / allows when state is
# missing or unreadable. A gate that blocks on its own bug bricks a session.

set -uo pipefail

# Where turn state lives. Overridable for tests.
TURN_STATE_DIR="${TURN_STATE_DIR:-/tmp/claude-turn-state}"

# ts_session_id <payload> — the session key. Falls back to a single stable
# "unknown" bucket rather than scattering state across per-process keys.
ts_session_id() {
    local payload="${1:-}" sid=""
    sid="$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null || true)"
    # Strip anything that is not filename-safe; a crafted session_id must never
    # escape STATE_DIR via `..` or `/`.
    sid="$(printf '%s' "$sid" | tr -c 'a-zA-Z0-9_-' '_' 2>/dev/null || true)"
    [ -n "$sid" ] || sid="unknown"
    printf '%s' "$sid"
}

# ts_reset <sid> — clear every flag for a new turn, then stamp .turn.
# The .turn marker is what distinguishes "new turn, nothing satisfied yet" from
# "reset hook never ran" — the latter must fail OPEN (see ts_turn_started).
ts_reset() {
    local sid="${1:-unknown}"
    mkdir -p "$TURN_STATE_DIR" 2>/dev/null || return 0
    # Clear EVERY flag for this session. Enumerating keys here drifts from the
    # gates that write them — am_i_done_asked was missed exactly that way, which
    # silently demoted am-i-done from once-per-TURN to once-per-SESSION.
    # ⚠ -maxdepth 1 is load-bearing beyond performance: the session digests in
    # digests/ (lib/session-digest.sh) are per-SESSION and must survive the turn
    # boundary. Deepening this find would silently delete them every turn.
    # PLUGIN ADAPTATION: that constraint is plugin-local — the digests it
    # protects have no upstream counterpart. The find itself is UNCHANGED from
    # orchard-codex@develop-sweatshop; only this comment diverges. Class:
    # "Fork-path session state" in the root README.
    find "$TURN_STATE_DIR" -maxdepth 1 -name "$sid.*" ! -name "$sid.turn" \
         -delete 2>/dev/null || true
    : > "$TURN_STATE_DIR/$sid.turn" 2>/dev/null || true
    # Reap abandoned sessions' markers; nothing else ever removes them.
    find "$TURN_STATE_DIR" -maxdepth 1 -type f -mtime +1 -delete 2>/dev/null || true
}

# ts_mark <sid> <key> — record that an invariant was satisfied this turn.
ts_mark() {
    local sid="${1:-unknown}" key="${2:-}"
    [ -n "$key" ] || return 0
    mkdir -p "$TURN_STATE_DIR" 2>/dev/null || return 0
    : > "$TURN_STATE_DIR/$sid.$key" 2>/dev/null || true
}

# ts_is_marked <sid> <key> — 0 if satisfied this turn, 1 otherwise.
ts_is_marked() {
    local sid="${1:-unknown}" key="${2:-}"
    [ -n "$key" ] || return 0
    [ -f "$TURN_STATE_DIR/$sid.$key" ]
}

# ts_turn_started <sid> — 0 if the reset hook has run for this session.
# When it has NOT, callers must fail open: the gate cannot distinguish an
# unsatisfied invariant from an unwired reset hook, and blocking on the latter
# is unrecoverable.
ts_turn_started() {
    local sid="${1:-unknown}"
    [ -f "$TURN_STATE_DIR/$sid.turn" ]
}
