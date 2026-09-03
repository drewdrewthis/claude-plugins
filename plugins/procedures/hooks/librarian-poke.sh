#!/usr/bin/env bash
# librarian-poke.sh — Stop hook (async).
#
# SINGLE RESPONSIBILITY: once per qualifying turn, wake the librarian agent to
# drain whatever transcript backlog has built up. This hook decides only WHEN
# to poke; agents/librarian.md decides WHAT is worth extracting, from its own
# per-transcript cursors, and is safe to poke more often than it has new work.
#
# DIVERGES FROM evolve-sweep.sh ON PURPOSE: no per-turn classifier call, no
# digest of the final message, no asyncRewake wake-the-caller trick. The
# child spawns `claude -p --agent procedures:librarian` directly — a
# SEPARATE session that does its own work and exits — so there is nothing to
# hand back to the turn that triggered the poke. Registered async:true, no
# asyncRewake, no timeout: the parent returns as soon as the child is
# detached, same as worklog-record.sh's own (unregistered-async) hook entry.
#
# DETACHED, ALWAYS, same load-bearing shape as worklog-record.sh's wl_detach:
# redirecting the child's stdin/stdout/stderr off the inherited pipes is what
# lets the parent return immediately — a harness reading the hook's pipe
# blocks until it closes no matter that the process is detached. `setsid` is
# used when available and plain background `&` otherwise (confirmed both
# `setsid` and `flock`, below, are absent on macOS/BSD). LIBRARIAN_SYNC=1
# runs the worker inline instead, for tests.
#
# THE SETTLE SLEEP (LIBRARIAN_SETTLE_SECS, default 3): at Stop time the
# firing turn's final assistant record is not yet in its own transcript jsonl
# (worklog-record.sh measured this on 2.1.237). This hook does not read that
# transcript itself, but the librarian it wakes might drain this very session
# moments later, so the settle buys its cursor a finished record to read
# instead of a truncated one.
#
# SINGLE WRITER: every knowledge-store commit funnels through one librarian
# invocation at a time. `flock -n` is the preferred lock — a second
# concurrent poke exits silently, which is fine, since this fires on every
# qualifying turn and is at-least-once by design. Where `flock` is
# unavailable, an atomic `mkdir` claim with a stealable TTL
# (LIBRARIAN_CLAIM_TTL_SECS, default 900) stands in, mirroring
# worklog-record.sh's wl_claim/wl_marker_age exactly. LIBRARIAN_NO_FLOCK=1
# forces this fallback in tests regardless of what the host actually has.
#
# FAIL-OPEN on the gating half, same posture as every gate in this plugin: no
# jq, an unreadable lib, or an unwired reset hook releases via
# ge_release_or_failopen. The poke itself (the detached half) is best-effort
# and UNRECORDED on failure — no claude binary, lost claim, or nonzero
# `claude -p` exit all degrade silently. A background knowledge-intake poke
# that occasionally no-ops costs nothing; recording every miss would grow the
# fail-open log one row per turn forever for a condition that is not one.

set -uo pipefail

# Resolve our own directory WITHOUT the external `dirname` binary: PATH is
# emptied entirely on the no-jq test path, and `${x%/*}` is parameter
# expansion, not a command lookup.
SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[ "$SCRIPT_DIR" = "${BASH_SOURCE[0]}" ] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "$SCRIPT_DIR" 2>/dev/null && pwd 2>/dev/null)" || exit 0
SELF="$SCRIPT_DIR/${BASH_SOURCE[0]##*/}"

# --- state dir --------------------------------------------------------------
# Per-machine librarian runtime state (lock, cursors, grooming queue) lives
# OUTSIDE the git-tracked corpus, on the XDG state-dir convention — see
# scripts/lib/stores.sh procedures_state_dir for the full why. Source it for
# the resolver; if the lib is unreadable, fall open to the same formula inline
# so a missing resolver never breaks the poke (this hook fails open).
# shellcheck source=../scripts/lib/stores.sh
. "$SCRIPT_DIR/../scripts/lib/stores.sh" 2>/dev/null || true
lp_state_dir() {
    if declare -F procedures_state_dir >/dev/null 2>&1; then
        procedures_state_dir
        return
    fi
    printf '%s' "${PROCEDURES_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/procedures/librarian}"
}

# --- tunables --------------------------------------------------------------
LIBRARIAN_SETTLE_SECS="${LIBRARIAN_SETTLE_SECS:-3}"
case "$LIBRARIAN_SETTLE_SECS" in ''|*[!0-9]*) LIBRARIAN_SETTLE_SECS=3 ;; esac

LIBRARIAN_CLAIM_TTL_SECS="${LIBRARIAN_CLAIM_TTL_SECS:-900}"
case "$LIBRARIAN_CLAIM_TTL_SECS" in ''|*[!0-9]*|0) LIBRARIAN_CLAIM_TTL_SECS=900 ;; esac

LIBRARIAN_LOCK="${LIBRARIAN_LOCK:-$(lp_state_dir)/librarian.lock}"
LIBRARIAN_LOCK_DIR="${LIBRARIAN_LOCK_DIR:-${LIBRARIAN_LOCK}.d}"

# --- the poke, and its portable claim fallback ------------------------------

# lp_marker_age <dir> — seconds since the claim dir was created, or nonzero
# (undeterminable) when it cannot be. Mirrors worklog-record.sh's
# wl_marker_age: an undeterminable age is NOT treated as old, so a blind
# steal cannot race a live holder.
lp_marker_age() {
    local m="${1:-}" mt now
    mt="$(stat -c %Y "$m" 2>/dev/null || date -r "$m" +%s 2>/dev/null || true)"
    now="$(date +%s 2>/dev/null || true)"
    case "$mt"  in ''|*[!0-9]*) return 1 ;; esac
    case "$now" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s' "$(( now - mt ))"
}

# lp_claim — 0 when this fire may run the librarian, 1 when a concurrent fire
# (or one still inside its TTL) already holds the claim. `mkdir` is atomic on
# POSIX, so the check and the take are one syscall. An environmental failure
# to create it fails OPEN, same as worklog's wl_claim — a possible duplicate
# poke beats one permanently suppressed.
lp_claim() {
    mkdir -p "${LIBRARIAN_LOCK_DIR%/*}" 2>/dev/null || return 0
    if mkdir "$LIBRARIAN_LOCK_DIR" 2>/dev/null; then return 0; fi
    [ -d "$LIBRARIAN_LOCK_DIR" ] || return 0
    local age
    age="$(lp_marker_age "$LIBRARIAN_LOCK_DIR")" || return 1
    [ -n "$age" ] || return 1
    [ "$age" -gt "$LIBRARIAN_CLAIM_TTL_SECS" ] 2>/dev/null || return 1
    rmdir "$LIBRARIAN_LOCK_DIR" 2>/dev/null || return 1
    mkdir "$LIBRARIAN_LOCK_DIR" 2>/dev/null || return 1
    return 0
}

# lp_worker — settle, then run the librarian under a single-writer claim.
# Everything past the settle is best-effort: no claude binary, a lost claim,
# or a nonzero `claude -p` exit all degrade silently.
lp_worker() {
    sleep "$LIBRARIAN_SETTLE_SECS" 2>/dev/null || true
    command -v claude >/dev/null 2>&1 || return 0

    # LIBRARIAN_NO_FLOCK=1 forces the mkdir fallback below even when a real
    # flock is on PATH — test-only, so "second concurrent claim loses" is
    # deterministic on any host rather than depending on this machine's own
    # tool availability (mirrors LIBRARIAN_SYNC's precedent).
    if [ "${LIBRARIAN_NO_FLOCK:-0}" != "1" ] && command -v flock >/dev/null 2>&1; then
        flock -n "$LIBRARIAN_LOCK" claude -p --agent procedures:librarian "Drain the transcript queue." || true
        return 0
    fi

    # Portable fallback (flock is absent on macOS/BSD): the same atomic
    # mkdir claim worklog-record.sh uses, TTL-stealable, released on exit via
    # trap so a crash does not wedge every future poke shut.
    if lp_claim; then
        trap 'rmdir "$LIBRARIAN_LOCK_DIR" 2>/dev/null || true' EXIT
        claude -p --agent procedures:librarian "Drain the transcript queue." || true
        rmdir "$LIBRARIAN_LOCK_DIR" 2>/dev/null || true
        trap - EXIT
    fi
    return 0
}

# --- one-time state migration ----------------------------------------------
# Move librarian runtime state (cursors, grooming queue) out of the git-tracked
# ~/.claude repo, AND the how-do-i index cache out of ~/.cache, into the
# resolved state dir ($(lp_state_dir) — ~/.knowledge/state when the knowledge
# home exists, else the XDG state dir). Runs on EVERY invocation (both the
# gating call and the --worker re-entry) — the checks are cheap and each move
# is idempotent: once the new location is populated that block no-ops. FAIL-
# OPEN, mv-ONLY (never rm): nothing is deleted, every step is guarded so a
# failure never blocks the poke, and a marker is left in each OLD location
# pointing at the new one. It only ever touches the OLD ~/.claude/librarian/*
# and ~/.cache/how-do-i-index locations — never modules/ or anything else under
# $KNOWLEDGE_HOME, which are git clones that must not be auto-moved.
lp_migrate_legacy_state() {
    local legacy="$HOME/.claude/librarian"
    local legacy_cursors="$legacy/cursors"
    local legacy_queue="$legacy/grooming-queue.md"
    local state new_cursors
    state="$(lp_state_dir)"
    new_cursors="$state/cursors"

    # Cursors: move only when legacy has files AND the new dir is not already
    # populated (absent or empty) — so a machine already migrated is a no-op.
    if [ -d "$legacy_cursors" ] && [ -n "$(ls -A "$legacy_cursors" 2>/dev/null)" ]; then
        if [ ! -d "$new_cursors" ] || [ -z "$(ls -A "$new_cursors" 2>/dev/null)" ]; then
            if mkdir -p "$new_cursors" 2>/dev/null; then
                mv "$legacy_cursors"/* "$new_cursors"/ 2>/dev/null || true
                # Filename can't hold slashes, so the sanitized path names the
                # marker and the literal path is its contents — a human/agent
                # looking in the old dir sees exactly where the state went.
                printf 'librarian state moved to: %s\n' "$state" \
                    > "$legacy/MIGRATED-to-${state//\//-}" 2>/dev/null || true
            fi
        fi
    fi

    # Grooming queue: move only if the new one does not already exist.
    if [ -f "$legacy_queue" ] && [ ! -f "$state/grooming-queue.md" ]; then
        mkdir -p "$state" 2>/dev/null || true
        mv "$legacy_queue" "$state/grooming-queue.md" 2>/dev/null || true
    fi

    # How-do-i index cache: same guard shape as cursors above — move the
    # CONTENTS (never the dir) only when the legacy dir has files AND the new
    # one is absent-or-empty, so a machine already migrated is a no-op. The
    # index moved off ~/.cache onto the state dir so a single location holds
    # ALL per-machine librarian runtime state.
    local legacy_index new_index
    legacy_index="${XDG_CACHE_HOME:-$HOME/.cache}/how-do-i-index"
    new_index="$state/how-do-i-index"
    if [ -d "$legacy_index" ] && [ -n "$(ls -A "$legacy_index" 2>/dev/null)" ]; then
        if [ ! -d "$new_index" ] || [ -z "$(ls -A "$new_index" 2>/dev/null)" ]; then
            if mkdir -p "$new_index" 2>/dev/null; then
                mv "$legacy_index"/* "$new_index"/ 2>/dev/null || true
                printf 'how-do-i index moved to: %s\n' "$new_index" \
                    > "$legacy_index/MIGRATED-to-${new_index//\//-}" 2>/dev/null || true
            fi
        fi
    fi
    return 0
}
lp_migrate_legacy_state

# --- worker re-entry ---------------------------------------------------
# The detached child calls back into this same script with --worker, stdin
# on /dev/null. Handled first, before any Stop-event gating below — none of
# it applies to the worker, which only sleeps and pokes.
if [ "${1:-}" = "--worker" ]; then
    lp_worker
    exit 0
fi

# --- gating: same shape as evolve-sweep.sh's preamble -----------------------
INPUT="$(cat 2>/dev/null || true)"

# shellcheck source=lib/gate-escape.sh
. "$SCRIPT_DIR/lib/gate-escape.sh" 2>/dev/null || true
# shellcheck source=lib/gate-failopen.sh
. "$SCRIPT_DIR/lib/gate-failopen.sh" 2>/dev/null || exit 0

command -v jq >/dev/null 2>&1 || ge_release_or_failopen "LIBRARIAN" "librarian-poke" "no-jq"

# Not a Stop event => not ours. A legitimate release, not blindness.
[ "$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)" = "Stop" ] || exit 0

# Ephemeral one-shot (claude --print / SDK): no session to settle into.
case "${CLAUDE_CODE_ENTRYPOINT:-}" in sdk-cli) exit 0 ;; esac

# shellcheck source=lib/turn-state.sh
. "$SCRIPT_DIR/lib/turn-state.sh" 2>/dev/null || ge_release_or_failopen "LIBRARIAN" "librarian-poke" "lib-unreadable:turn-state"
# shellcheck source=lib/gate-audience.sh
. "$SCRIPT_DIR/lib/gate-audience.sh" 2>/dev/null || ge_release_or_failopen "LIBRARIAN" "librarian-poke" "lib-unreadable:gate-audience"
# shellcheck source=lib/turn-activity.sh
. "$SCRIPT_DIR/lib/turn-activity.sh" 2>/dev/null || ge_release_or_failopen "LIBRARIAN" "librarian-poke" "lib-unreadable:turn-activity"

# Not our audience (subagent, or a non-main agent) => legitimate release.
ga_binds_main "$INPUT" || exit 0

SID="$(ts_session_id "$INPUT")"
# No .turn marker => the reset hook never ran => unwired, not clear.
ts_turn_started "$SID" || ge_release_or_failopen "LIBRARIAN" "librarian-poke" "reset-hook-never-ran" "$SID"

# Already poked this turn => release. The only same-turn guard, same as
# evolve-sweep: no stop_hook_active check either.
ts_is_marked "$SID" librarian_poked && exit 0

# No tool use => nothing this turn adds to any queue. Could not tell =>
# silent release: a poke's blindness costs nothing, unlike a gate's.
ta_turn_used_tools "$SID"
case "$?" in
    0) ;;
    *) exit 0 ;;
esac

# Off-switch asked at the point of action, like the gates: an escape record
# means "a poke was released", not "a process started".
if declare -F ge_enabled >/dev/null 2>&1 && ! ge_enabled "LIBRARIAN"; then exit 0; fi

# Mark BEFORE dispatch, same reasoning as evolve-sweep's marker: it is what
# serializes overlapping Stops for this turn, not stop_hook_active.
ts_mark "$SID" librarian_poked

# --- dispatch ----------------------------------------------------------
if [ "${LIBRARIAN_SYNC:-0}" = "1" ]; then
    lp_worker
    exit 0
fi
if command -v setsid >/dev/null 2>&1; then
    setsid bash "$SELF" --worker </dev/null >/dev/null 2>&1 &
else
    bash "$SELF" --worker </dev/null >/dev/null 2>&1 &
fi
disown 2>/dev/null || true
exit 0
