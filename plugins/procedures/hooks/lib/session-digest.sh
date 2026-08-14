#!/usr/bin/env bash
# session-digest.sh — storage for the per-session /how-do-i digest carry-forward.
#
# SINGLE RESPONSIBILITY: own where digests live and how they are written, read,
# and reaped. The hook decides WHEN to record one; the skill decides what to do
# with them. Nothing else belongs here.
#
# STATE MODEL — one file per digest, keyed by session:
#   $SESSION_DIGEST_DIR/<key>.digest.<epoch>.<unique>
#
# WHY NOT <key>.digest.<n>: a counter has to be READ before it can be
# incremented, which is the read-modify-write turn-state.sh removed on purpose
# (see its "WHY MARKER FILES" note). Two forks returning together would read the
# same highest n and one digest would be lost. `mktemp` makes the kernel supply
# the unique part, so a write never consults another writer's state; the epoch
# prefix keeps the set chronologically sortable, which the counter was only
# ever there to provide.
#
# ORDERING IS TO THE SECOND. `date +%s` is the coarsest portable clock (BSD
# date has no %N), so two digests written inside one second replay in
# arbitrary order relative to each other. A fork takes tens of seconds, so
# real invocations never collide; nothing here depends on finer resolution.
#
# WHY A SUBDIRECTORY of $TURN_STATE_DIR: ts_reset() clears `<sid>.*` at
# -maxdepth 1 on every turn. Digests must survive the turn boundary that flags
# must NOT survive, and nesting them one level down puts them out of that
# find's reach without touching the reset path at all.
#
# FAIL-OPEN: a digest is an optimisation. Every failure here degrades to "no
# warm start", never to an error in the caller's face. sd_write still RETURNS
# nonzero on the blind paths so its caller can record the fail-open; degrading
# silently and degrading unobservably are different things (ADR-001).
#
# PLUGIN ADAPTATION: this whole file has no upstream counterpart. /how-do-i runs
# as a forked skill in the plugin, and a fork gets no turn-state continuity, so
# carrying a digest across invocations is a plugin-only problem — the codex
# never needed it. Vendoring from orchard-codex@develop-sweatshop must not treat
# this file's absence upstream as drift to be reconciled away. Class:
# "Fork-path session state" in the root README.

set -uo pipefail

# Digest store. Defaults under the turn-state dir but is separately
# overridable, so a test can isolate one without relocating the other.
SESSION_DIGEST_DIR="${SESSION_DIGEST_DIR:-${TURN_STATE_DIR:-/tmp/claude-turn-state}/digests}"
# How many prior digests a warm start replays, most recent first. ~1,700 tokens
# each: replaying a long session uncapped costs more than the cold start it
# saves.
SESSION_DIGEST_KEEP="${SESSION_DIGEST_KEEP:-3}"
# Days a digest survives. Nothing else ever removes them.
SESSION_DIGEST_TTL_DAYS="${SESSION_DIGEST_TTL_DAYS:-2}"
# Both feed `[ -gt ]` and `find -mtime`, which treat a non-numeric value as an
# error rather than a default — an uncapped replay plus stderr noise. Fall back
# instead: a typo'd env var must not change the contract.
case "$SESSION_DIGEST_KEEP" in ''|*[!0-9]*) SESSION_DIGEST_KEEP=3 ;; esac
case "$SESSION_DIGEST_TTL_DAYS" in ''|*[!0-9]*) SESSION_DIGEST_TTL_DAYS=2 ;; esac

# sd_key <raw> — the session bucket name.
# Same character class as ts_session_id() in turn-state.sh, and for the same
# reason: a crafted session_id must never escape the store via `..` or `/`.
# The two must agree so one session maps to one bucket on both paths.
sd_key() {
    local raw="${1:-}" key=""
    # An un-substituted ${CLAUDE_SESSION_ID} means the harness did not
    # interpolate the fork prompt. Sanitizing it would mint a real-looking
    # bucket shared by every such caller; refuse instead, and let the caller
    # degrade to a cold start.
    case "$raw" in *'$'*|*'{'*) return 1 ;; esac
    key="$(printf '%s' "$raw" | tr -c 'a-zA-Z0-9_-' '_' 2>/dev/null || true)"
    [ -n "$key" ] || return 1
    printf '%s' "$key"
}

# sd_reap — drop digests past their TTL, wherever they came from.
sd_reap() {
    [ -d "$SESSION_DIGEST_DIR" ] || return 0
    find "$SESSION_DIGEST_DIR" -maxdepth 1 -type f -name '*.digest.*' \
         -mtime "+$SESSION_DIGEST_TTL_DAYS" -delete 2>/dev/null || true
}

# sd_write <key> — store one digest, body on stdin. Always a NEW file.
sd_write() {
    local key="${1:-}" body=""
    [ -n "$key" ] || return 0
    body="$(cat 2>/dev/null || true)"
    # Nothing to warm-start from; storing it would only cost the next fork a
    # delimiter to read past.
    [ -n "${body//[[:space:]]/}" ] || return 0
    mkdir -p "$SESSION_DIGEST_DIR" 2>/dev/null || return 1
    # 0700, not the umask default: mktemp gives each digest 0600, but a 0755
    # directory still lets any other local account enumerate session keys and
    # write times by listing it. Separate chmod rather than `mkdir -p -m`,
    # which applies the mode to the deepest directory only (SC2174) — the
    # parent $TURN_STATE_DIR is left at whatever it already is, since the
    # gates share it and its permissions are not this file's to set.
    chmod 700 "$SESSION_DIGEST_DIR" 2>/dev/null || true
    sd_reap
    local f
    f="$(mktemp "$SESSION_DIGEST_DIR/$key.digest.$(date +%s).XXXXXX" 2>/dev/null)" || return 1
    # mktemp CREATED the file before printf ran. A failed body write (full disk,
    # EIO) would otherwise leave a zero-byte digest behind — and an empty digest
    # is worse than none: sd_read prints its "==> prior digest N <==" header
    # with nothing under it, and it still counts against SESSION_DIGEST_KEEP, so
    # it evicts a real digest from the replay. Remove the carcass.
    printf '%s\n' "$body" > "$f" 2>/dev/null || { rm -f "$f" 2>/dev/null; return 1; }
}

# sd_read <key> — replay this session's prior digests, oldest first, capped.
sd_read() {
    local key="${1:-}"
    [ -n "$key" ] || return 0
    [ -d "$SESSION_DIGEST_DIR" ] || return 0
    local files total shown
    files="$(find "$SESSION_DIGEST_DIR" -maxdepth 1 -type f -name "$key.digest.*" 2>/dev/null | sort)"
    [ -n "$files" ] || return 0
    total="$(printf '%s\n' "$files" | grep -c .)"
    if [ "$SESSION_DIGEST_KEEP" -gt 0 ] && [ "$total" -gt "$SESSION_DIGEST_KEEP" ]; then
        shown="$SESSION_DIGEST_KEEP"
        # A cap is allowed; a SILENT one is not — the scout cannot weigh what it
        # was not told was withheld.
        printf '(%d prior digests this session — replaying the %d most recent)\n' \
            "$total" "$shown"
        files="$(printf '%s\n' "$files" | tail -n "$shown")"
    fi
    local n=0 f
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        n=$((n + 1))
        printf '==> prior /how-do-i digest %d <==\n' "$n"
        cat "$f" 2>/dev/null || true
    done <<< "$files"
}
