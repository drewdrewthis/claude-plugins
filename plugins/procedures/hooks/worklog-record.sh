#!/usr/bin/env bash
# worklog-record.sh — Stop hook.
#
# SINGLE RESPONSIBILITY: append ONE line per turn to a worklog JSONL describing
# what the agent did. Nothing else. It records a turn; it never decides anything
# about the turn, and it never blocks one.
#
# THE LINE:
#   {"ts","session","ask_uuid","end_uuid",
#    "requests":[{"text","quote","uuid"}],
#    "outcomes":[{"text","quote","uuid"}],
#    "mistakes":[{"text","quote","uuids"}]}
#
# THE STORY THE ROW TELLS: what was asked, what came of it, and what went
# wrong. Three arrays rather than three scalars because one turn routinely
# carries several asks and several results, and collapsing them to one line
# each forces the model to choose which to drop.
#
# EVERY ENTRY CARRIES ITS OWN EVIDENCE — `text` is the model's summary, `quote`
# is the span it rests on, and the uuid says where that span lives. A claim
# with no checkable evidence is the failure this shape exists to prevent, so an
# entry whose quote cannot be located in a candidate body is DROPPED WHOLE
# rather than stored with the quote blanked.
#
# MECHANICAL / JUDGMENT SPLIT, the same one scripts/log-record.sh draws. This
# script owns every field a machine can settle — ts, session, ask_uuid,
# end_uuid — and it owns the VERIFICATION of everything the model returns. The
# model owns only the `text` summaries and the SELECTION of quotes and uuids.
# It never authors a quote: it names a span, and what is stored is the run
# SLICED OUT of the candidate body it was shown (wl_entries). So `quote` has
# exactly the provenance the uuids do — transcript-derived by construction, and
# unable to drift from what was verified.
#
# THE MODEL NEVER TYPES A UUID. It is handed a CANDIDATES block the slicer
# built, and may only copy from it. Every uuid it returns is then re-checked
# against that set before it is written. A uuid is 36 characters; one
# transposition yields a pointer that resolves to nothing and fails silently
# forever, so "the model was careful" is not an acceptable guarantee here —
# the check is.
#
# NOT A GATE, AND NOT A MISTAKE LOG.
#   * It never emits a `decision` — am-i-done-gate.sh is the Stop hook that
#     blocks, and it must stay the only one. Two blocking Stop hooks make an
#     unclearable turn.
#   * It never writes $HOME/.claude/mistakes.jsonl. That file feeds the
#     promotion path into references/failure-modes/ and thence into the
#     @-imported common-mistakes.md, where one bad row becomes a fleet-wide
#     rule. `mistakes` here is deliberately INERT: a marker for a later human
#     or analysis pass, carrying no severity, no category and no failure-mode
#     name, because each of those is a corpus-relative join this hook has no
#     standing to make.
#   * It never writes the harness-owned session transcript. The worklog is a
#     SIBLING file, and the write path refuses outright if it ever resolves
#     onto the transcript or onto a mistakes.jsonl (wl_store_ok).
#
# DETACHED, ALWAYS. The judgment call takes seconds; several workers land at
# once; a synchronous Stop hook would serialize them and stall every one. So
# the parent does the cheap envelope checks and returns, and the real work runs
# in a `setsid` child with stdin/stdout/stderr off the inherited pipes —
# redirecting those is the load-bearing half, since a harness reading the
# hook's pipe blocks until it closes no matter that the process is detached.
# WORKLOG_SYNC=1 runs it inline instead, for tests.
#
# THE SETTLE SLEEP IS NOT PADDING. Measured on 2.1.237: at the instant Stop
# fires, the turn's final assistant record is NOT yet in the flat jsonl (6
# lines at t=0, 10 lines at t=1s and stable thereafter). Reading immediately
# yields a turn missing its own conclusion and an end_uuid pointing at the
# second-to-last record. Detachment is what makes waiting free.
#
# TRANSCRIPT RESOLUTION: the Stop payload carries `.transcript_path` outright —
# no slugging needed. The realpath-slug glob under $HOME/.claude/projects/ is
# kept as a fallback for payload shapes that omit it, and it must slug the
# REALPATH of cwd (sol.2026-06-12-claude-2.1.175-no-flat-jsonl), which the glob
# sidesteps by matching on the session id alone.
#
# FAIL-OPEN, BUT OBSERVABLY (ADR-001). No jq, an unreadable lib, an unreadable
# transcript, an unavailable judgment, an unwritable store => exit 0, and
# append one line to GATE_FAILOPEN_LOG first. These are BLIND paths: the hook
# could not do its job and cannot tell whether it should have.
#
# A LEGITIMATE DECLINE IS NOT A FAIL-OPEN and is never recorded — a non-Stop
# event, sdk-cli, a subagent, a re-entrant call from our own judgment child, a
# transcript that parses but holds no user prompt to bracket a turn with.
# Recording those makes the log useless as a fail-open rate numerator, which is
# the same line gate-failopen.sh draws.
#
# ONE LINE PER TURN, AND STOP CAN FIRE TWICE FOR ONE TURN. am-i-done-gate.sh
# BLOCKS the first Stop and releases the next, so a turn firing Stop twice is
# the normal path in this fleet, not an edge case — and both fires bracket the
# SAME turn, so both slice to the same ask_uuid.
#
# BOTH FIRES RUN CONCURRENTLY, so a store scan alone cannot key the append. The
# default dispatch is wl_detach, so fire 2 does not queue behind fire 1: it
# starts while fire 1 is still inside a judgment call bounded by
# WORKLOG_MODEL_TIMEOUT (120s) that has written NOTHING yet. A scan-then-write
# therefore reads "not seen", buys a second model answer, and appends a
# duplicate — on the common path, not a rare one. The turn is claimed
# ATOMICALLY instead, before the model call, with `mkdir` (atomic on POSIX, and
# needing no flock this hook does not otherwise depend on):
#
#   wl_claim — the CONCURRENCY claim. One marker directory per ask_uuid beside
#     the store. Whoever creates it owns the turn; a concurrent fire declines.
#     Released once the row is on disk, so the markers do not accumulate.
#   wl_seen  — the DURABLE record. Survives marker loss across a reboot, and
#     covers every fire arriving after the marker was released.
#
# A fire proceeds only when BOTH say unseen. Either check failing for an
# ENVIRONMENTAL reason (the claim directory cannot be made) fails OPEN — a
# possible duplicate row beats a dropped turn (ADR-001).
#
# A CLAIM THAT DIES MID-TURN MUST NOT SUPPRESS ITS TURN FOREVER. A fire that
# claims and is then killed before appending leaves a marker nobody will
# release. Markers are therefore STEALABLE once older than
# WORKLOG_CLAIM_TTL_SECS, which defaults to longer than any live fire can run
# (settle + model timeout + margin) so a steal cannot race a working fire.
# The tradeoff, deliberately: the crashed turn's row is lost until the next
# Stop fire for it, and a steal on a badly skewed clock could duplicate one row.
# Both beat the alternative — a permanent silent hole. Markers are keyed PER
# ask_uuid, so a stuck one can never suppress any turn but its own.
#
# STORE LOCATION IS A COMPATIBILITY CONSTRAINT, not a preference. The worklog
# does NOT live beside the transcript under ~/.claude/projects/, because
# consumers in the codex repo glob that directory for session files —
# hourly-self-eval.sh takes `ls -t .../*.jsonl | head -1` as THE transcript, and
# a file rewritten every turn is always the newest; night-watch-run.sh sweeps
# `find projects -name '*.jsonl'` into corpus, recursively, so a subdirectory
# would not escape it either. It lives under $HOME/.claude/worklog/ keyed by
# project slug instead: outside every one of those globs, present and future.
#
# PLUGIN ADAPTATION: no upstream counterpart. Class: "Turn worklog" in the root
# README — like digest-record.sh this is a WRITER, not a gate, so group by
# <gate> before computing any fail-open rate over the log.

set -uo pipefail

# Resolved with ${BASH_SOURCE[0]%/*} rather than `dirname`, and sourced BEFORE
# the jq check, on gate-failopen.sh's own constraint: a missing jq is one of the
# conditions this must record, and that path can run with PATH emptied, so
# anything shelling out to locate the recorder is unreachable exactly when it is
# needed.
SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[ "$SCRIPT_DIR" = "${BASH_SOURCE[0]}" ] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "$SCRIPT_DIR" 2>/dev/null && pwd 2>/dev/null)" || exit 0
SELF="$SCRIPT_DIR/${BASH_SOURCE[0]##*/}"

# The recorder cannot record its own absence — with no gate_failopen to call,
# exit 0 rather than brick the turn.
# shellcheck source=lib/gate-failopen.sh
. "$SCRIPT_DIR/lib/gate-failopen.sh" 2>/dev/null || exit 0

# --- tunables -------------------------------------------------------------
# Seconds to let the transcript tail settle before reading. See the header:
# 1s sufficed in measurement; 3 is that with margin, and it costs nothing
# because the reader is detached.
WORKLOG_SETTLE_SECS="${WORKLOG_SETTLE_SECS:-3}"
# Prior conversation records offered to the model as uuid candidates. Must
# exceed one turn: a mistake anchors to an offense AND a correction, and those
# routinely sit in different turns, which is why a mistake carries a uuid ARRAY
# and needs at least two entries to be recorded at all.
WORKLOG_WINDOW="${WORKLOG_WINDOW:-60}"
# Hard ceiling on the judgment call. A hung child must not linger.
WORKLOG_MODEL_TIMEOUT="${WORKLOG_MODEL_TIMEOUT:-120}"
WORKLOG_MODEL="${WORKLOG_MODEL:-claude-haiku-4-5-20251001}"
# Rows of the store scanned for the dedup key. See wl_seen.
WORKLOG_DEDUP_SCAN="${WORKLOG_DEDUP_SCAN:-500}"
# Non-numeric values feed `sleep`/`timeout`/`tail`, which error rather than
# default — a typo'd env var must not change the contract (same guard as
# lib/session-digest.sh).
case "$WORKLOG_SETTLE_SECS"   in ''|*[!0-9]*) WORKLOG_SETTLE_SECS=3 ;; esac
case "$WORKLOG_WINDOW"        in ''|*[!0-9]*|0) WORKLOG_WINDOW=60 ;; esac
case "$WORKLOG_MODEL_TIMEOUT" in ''|*[!0-9]*|0) WORKLOG_MODEL_TIMEOUT=120 ;; esac
# 0 is rejected, not honoured: `tail -n 0` is not an error, it prints nothing,
# so wl_seen would report "not seen" for every turn and the second Stop fire
# would write a duplicate row — silently disabling the one-row-per-turn key
# with no failure anywhere to notice.
case "$WORKLOG_DEDUP_SCAN"    in ''|*[!0-9]*|0) WORKLOG_DEDUP_SCAN=500 ;; esac
# Age at which a claim marker is stealable. Derived from the other two rather
# than fixed, so raising the model timeout cannot make a live fire's own claim
# stealable out from under it. 0 is rejected like the counts above and for the
# same class of reason: a zero TTL makes every marker instantly stealable,
# which is the race with an extra step.
WORKLOG_CLAIM_TTL_SECS="${WORKLOG_CLAIM_TTL_SECS:-$(( WORKLOG_SETTLE_SECS + WORKLOG_MODEL_TIMEOUT + 60 ))}"
case "$WORKLOG_CLAIM_TTL_SECS" in
    ''|*[!0-9]*|0) WORKLOG_CLAIM_TTL_SECS=$(( WORKLOG_SETTLE_SECS + WORKLOG_MODEL_TIMEOUT + 60 )) ;;
esac

INPUT=""
# The marker this process holds, or empty when it holds none — either because
# the turn had no key, or because claiming failed environmentally and the fire
# proceeded unclaimed. wl_unclaim releases exactly what was taken.
WL_MARKER=""

# wl_sid — the session id, sanitized to the same character class
# turn-state.sh's ts_session_id uses, AND falling back to the same single
# "unknown" bucket, so one session names one thing across every hook in this
# plugin. Returning empty here instead would put a `"session":""` row in the
# worklog and an empty session_id in the fail-open log for the same payload
# turn-state files under `unknown` — one condition with two names.
wl_sid() {
    local sid=""
    sid="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"
    sid="$(printf '%s' "$sid" | tr -c 'a-zA-Z0-9_-' '_' 2>/dev/null || true)"
    [ -n "$sid" ] || sid="unknown"
    printf '%s' "$sid"
}

# wl_precheck — every condition under which this hook has nothing to do.
# Runs in BOTH the parent and the detached child, so the child cannot outlive
# a reason the parent would have declined for. Exits 0 on any decline; the
# blind ones record first.
wl_precheck() {
    # RE-ENTRANCY GUARD, and the first thing checked. The judgment call below is
    # itself a `claude` invocation, which fires this same Stop hook in the
    # child. Unguarded that is not a slow path, it is unbounded recursion.
    # Belt and braces: the child is launched with WORKLOG_DISABLE=1, and it
    # ALSO arrives as CLAUDE_CODE_ENTRYPOINT=sdk-cli (checked below) — either
    # alone stops it, and neither is left to be the only one.
    [ -n "${WORKLOG_DISABLE:-}" ] && exit 0

    command -v jq >/dev/null 2>&1 || gate_failopen worklog-record no-jq

    # Settle whether the payload is READABLE before filtering on anything
    # inside it. Every extraction below degrades to empty on a parse failure,
    # so an unparseable payload would otherwise be indistinguishable from "not
    # our event" and exit 0 silently — the shape of bug that keeps a hook inert.
    printf '%s' "$INPUT" | jq -e . >/dev/null 2>&1 \
        || gate_failopen worklog-record malformed-payload
    # Parsing is not being an envelope: `jq -e .` accepts a bare string or an
    # array, and indexing a non-object then yields empty, which reads as "a
    # different event fired". Different fault, different fix, separate record.
    printf '%s' "$INPUT" | jq -e 'type == "object"' >/dev/null 2>&1 \
        || gate_failopen worklog-record non-object-payload

    # Not a Stop event => not ours. A legitimate decline.
    [ "$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)" = "Stop" ] \
        || exit 0

    # Ephemeral one-shot (claude --print / SDK): no worklog worth keeping, and
    # this is also the arm that catches our own judgment child.
    case "${CLAUDE_CODE_ENTRYPOINT:-}" in sdk-cli) exit 0 ;; esac

    # A delegated subagent's turns belong to its own contract, not to the
    # session that spawned it. Same predicate the gates use.
    # shellcheck source=lib/gate-audience.sh
    . "$SCRIPT_DIR/lib/gate-audience.sh" 2>/dev/null \
        || gate_failopen worklog-record lib-unreadable:gate-audience "$(wl_sid)"
    ga_binds_main "$INPUT" || exit 0
}

# wl_transcript — absolute path to this session's flat jsonl, or empty.
# `.transcript_path` is authoritative and present on 2.1.237; the glob is the
# fallback for payload shapes that omit it.
wl_transcript() {
    local tp sid cand
    tp="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
    if [ -n "$tp" ] && [ -r "$tp" ]; then printf '%s' "$tp"; return 0; fi
    # Sanitized through wl_sid before it is interpolated into a path. The
    # payload is harness-controlled so this is not a live exploit, but a
    # session_id of `../../../etc/x` would otherwise reach a glob, and a
    # traversal that reaches a glob is not a thing to leave standing on the
    # grounds that today's caller is trusted.
    sid="$(wl_sid)"
    [ -n "$sid" ] && [ "$sid" != "unknown" ] || return 0
    for cand in "$HOME"/.claude/projects/*/"$sid".jsonl; do
        [ -r "$cand" ] && { printf '%s' "$cand"; return 0; }
    done
    return 0
}

# wl_store_ok <path> <transcript> — 0 when <path> is a safe worklog target.
# THE TWO NAMED HAZARDS, refused by construction rather than by convention:
# writing into the harness-owned transcript, and writing into a mistakes.jsonl
# (whose rows are promoted into fleet-wide rules by a path this hook has no
# standing to feed).
wl_store_ok() {
    local p="${1:-}" tx="${2:-}"
    [ -n "$p" ] || return 1
    case "${p##*/}" in mistakes.jsonl) return 1 ;; esac
    [ -n "$tx" ] && [ "$p" = "$tx" ] && return 1
    # Also refuse any flat session transcript, not only THIS one: the worklog
    # must never be mistaken for a session file by a reader globbing the
    # project dir.
    #
    # Matched on the ACTUAL uuid shape (8-4-4-4-12 hex), not on a loose
    # `*-*-*-*-*.jsonl`. The loose form counts dashes and nothing else, and a
    # project slug is all dashes — `-home-ubuntu--claude.jsonl` has four of
    # them, so the default store this hook now writes to would have been
    # refused by its own safety check.
    if [[ "${p##*/}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\.jsonl$ ]]; then
        return 1
    fi
    return 0
}

# wl_store <transcript> — absolute path of the worklog for this project.
#
# NOT a sibling of the transcript. See the header: ~/.claude/projects/ is
# globbed by three consumers in the codex repo, one of which takes the newest
# *.jsonl in the directory AS the transcript — and a file rewritten every turn
# is permanently the newest. Keyed by project slug (the transcript directory's
# own name, which is already the realpath slug), so per-project grouping
# survives; per-session grouping needs no separate file because every row
# carries `session`.
wl_store() {
    local tx="${1:-}" pdir slug
    if [ -n "${WORKLOG_JSONL:-}" ]; then printf '%s' "$WORKLOG_JSONL"; return 0; fi
    pdir="${tx%/*}"
    slug="${pdir##*/}"
    slug="${slug//[^A-Za-z0-9_.-]/_}"
    [ -n "$slug" ] || slug="unknown"
    printf '%s' "$HOME/.claude/worklog/$slug.jsonl"
}

# wl_seen <store> <ask_uuid> — 0 when this turn is already on the record.
#
# Stop fires TWICE for one turn on the normal path here: am-i-done-gate.sh
# blocks the first and releases the next. Both fires bracket the same turn and
# so slice to the same ask_uuid, which is what makes it a usable key.
#
# An EMPTY ask is never a key. It means the uuid did not resolve, and treating
# null as a key would collapse every such turn in the file into one row —
# turning a dedup into silent data loss on exactly the turns already degraded.
#
# Bounded scan: the two fires are adjacent, so the tail is generous already,
# and an unbounded re-read of a file that only grows is a cost paid every turn.
wl_seen() {
    local store="${1:-}" ask="${2:-}" hit=""
    [ -n "$ask" ] || return 1
    [ -r "$store" ] || return 1
    hit="$(tail -n "$WORKLOG_DEDUP_SCAN" "$store" 2>/dev/null \
        | jq -R -r --arg a "$ask" \
            'fromjson? | select(type == "object") | select(.ask_uuid == $a) | "hit"' \
            2>/dev/null | head -n 1 || true)"
    [ "$hit" = "hit" ]
}

# wl_marker <store> <ask> — path of the claim marker for one turn, or empty.
#
# Beside the store and keyed by it, so two stores in one directory (the default
# and a WORKLOG_JSONL override) cannot claim each other's turns.
#
# `ask` becomes a PATH COMPONENT, so it is sanitized to the same class wl_sid
# uses first. A uuid is unaffected by that class; a `..` is not, and a traversal
# reaching `mkdir` is not a thing to leave standing because today's caller is
# trusted.
wl_marker() {
    local store="${1:-}" ask="${2:-}" dir base
    [ -n "$store" ] || return 1
    ask="${ask//[^A-Za-z0-9_-]/_}"
    [ -n "$ask" ] || return 1
    case "$store" in */*) dir="${store%/*}" ;; *) dir="." ;; esac
    base="${store##*/}"
    base="${base//[^A-Za-z0-9_.-]/_}"
    printf '%s/.%s.claims/%s' "$dir" "$base" "$ask"
}

# wl_marker_age <marker> — seconds since the marker was created, or nonzero
# when that cannot be determined. Undeterminable age is NOT treated as old: a
# blind steal would reinstate the race the marker exists to close.
wl_marker_age() {
    local m="${1:-}" mt now
    mt="$(stat -c %Y "$m" 2>/dev/null || date -r "$m" +%s 2>/dev/null || true)"
    now="$(date +%s 2>/dev/null || true)"
    case "$mt"  in ''|*[!0-9]*) return 1 ;; esac
    case "$now" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s' "$(( now - mt ))"
}

# wl_claim <store> <ask> — 0 when this fire may do the work, 1 when a
# concurrent fire already owns this turn.
#
# `mkdir` is the whole mechanism: it is atomic on POSIX and fails when the
# directory exists, so the check and the take are one syscall and cannot be
# interleaved. Everything else here is about telling the three ways it can fail
# apart.
#
# NO KEY, NO CLAIM. An empty ask means the uuid did not resolve — the same
# condition under which wl_seen refuses to key. Claiming on a shared "empty"
# marker would let one degraded turn suppress the next, so those turns proceed
# unclaimed, exactly as they do today.
wl_claim() {
    local store="${1:-}" ask="${2:-}" marker age
    marker="$(wl_marker "$store" "$ask")" || return 0
    [ -n "$marker" ] || return 0
    mkdir -p "${marker%/*}" 2>/dev/null || return 0   # environmental => fail OPEN
    if mkdir "$marker" 2>/dev/null; then WL_MARKER="$marker"; return 0; fi
    # mkdir failed and the marker is NOT there: the failure was environmental
    # (unwritable directory, ENOSPC), not a competing fire. Fail OPEN — a
    # possible duplicate row beats a dropped turn.
    [ -d "$marker" ] || return 0
    # Held. Steal only once no live fire could still be inside it.
    age="$(wl_marker_age "$marker")" || return 1
    [ -n "$age" ] || return 1
    [ "$age" -gt "$WORKLOG_CLAIM_TTL_SECS" ] 2>/dev/null || return 1
    rmdir "$marker" 2>/dev/null || return 1
    mkdir "$marker" 2>/dev/null || return 1
    WL_MARKER="$marker"
    return 0
}

# wl_unclaim — release this process's marker, if it took one.
# Called once the row is durable (wl_seen covers every later fire from then on)
# and on the failure paths after a claim, so a fire that could not write does
# not hold its turn hostage for the whole TTL.
wl_unclaim() {
    [ -n "$WL_MARKER" ] || return 0
    rmdir "$WL_MARKER" 2>/dev/null || true
    WL_MARKER=""
}

# wl_entries <candidates> <uuids-json> <raw-json> — prints the three verified
# entry arrays as one JSON object {requests, outcomes, mistakes}, or nothing.
#
# THE VERIFICATION LOOP FOR THE ARRAY SHAPE. Same three rules the scalar row
# applied, now per entry: every uuid is intersected with the candidate set,
# every quote is SLICED FROM the candidate body rather than stored as the
# model typed it, and text is truncated to the cap the brief asks for.
#
# AN ENTRY THAT FAILS ANY RULE IS DROPPED WHOLE. Storing it with a blanked
# quote would leave a claim wearing the shape of evidence — the exact thing
# the quote field exists to prevent. Dropping is also the safe direction: a
# missing entry is visibly missing, a hollow one is not.
#
# python3 rather than jq+bash for the same reason wl_slice uses it: this is a
# per-entry loop over a substring match against a second data set, and jq
# cannot see the candidate bodies to slice from.
wl_entries() {
    python3 - "$1" "$2" "$3" <<'PY' 2>/dev/null || true
import json, re, sys

cands, uuids_json, raw = sys.argv[1], sys.argv[2], sys.argv[3]
MAXTEXT, MAXQUOTE = 100, 120
CAPS = {"requests": 6, "outcomes": 6, "mistakes": 4}

try:
    obj = json.loads(raw)
    ok = set(json.loads(uuids_json))
except Exception:
    sys.exit(1)
if not isinstance(obj, dict):
    sys.exit(1)

# Bodies keyed by uuid, normalised the same way wl_norm does it: collapse all
# whitespace runs to one space and strip. A quote is matched against the body
# it is claimed to come from, never against the whole blob — joining the lines
# would let a "quote" spanning two unrelated records match.
def norm(s):
    return re.sub(r"\s+", " ", s or "").strip()

bodies = {}
for line in cands.split("\n"):
    parts = line.split("\t", 3)
    if len(parts) == 4:
        bodies[parts[0]] = norm(parts[3])

def verified_quote(quote, uuid):
    """Return the run SLICED FROM the candidate body, or None."""
    q = norm(quote)
    if not q or uuid not in bodies:
        return None
    body = bodies[uuid]
    i = body.find(q)
    if i < 0:
        return None
    return body[i:i + len(q)][:MAXQUOTE]

def entries(key, uuid_field):
    out = []
    for e in (obj.get(key) or [])[:CAPS[key]]:
        if not isinstance(e, dict):
            continue
        text = e.get("text")
        if not isinstance(text, str) or not text.strip():
            continue
        # uuids: model-supplied, intersected with the candidate set. Order is
        # the model's, which for mistakes is asked to be chronological.
        raw_u = e.get(uuid_field)
        if uuid_field == "uuids":
            named = [u for u in (raw_u or []) if isinstance(u, str)]
            us = [u for u in named if u in ok]
            # A mistake needs the offense AND the correction; one uuid is an
            # unlocatable pair, so the entry cannot be audited.
            if len(us) < 2:
                continue
            # The anchor is the CORRECTION — the last uuid the model NAMED,
            # not merely the last one that survived the candidate filter.
            # Those differ when an interior uuid is dropped: [offense, mid,
            # correction] with the correction outside the window still leaves
            # a length-2 list whose tail is `mid`, a line that never was the
            # correction. Anchoring to the survivor would quietly audit the
            # wrong line, so a pair that lost its correction is dropped.
            anchor = named[-1]
            if anchor not in ok:
                continue
        else:
            us = [raw_u] if isinstance(raw_u, str) and raw_u in ok else []
            if not us:
                continue
            anchor = us[0]
        q = verified_quote(e.get("quote"), anchor)
        if q is None:
            continue
        ent = {"text": text.strip()[:MAXTEXT], "quote": q}
        ent["uuids" if uuid_field == "uuids" else "uuid"] = us if uuid_field == "uuids" else us[0]
        out.append(ent)
    return out

print(json.dumps({
    "requests": entries("requests", "uuid"),
    "outcomes": entries("outcomes", "uuid"),
    "mistakes": entries("mistakes", "uuids"),
}, ensure_ascii=False))
PY
}

# ---------------------------------------------------------------------------
# wl_slice <transcript> <window> — the MECHANICAL read of the transcript.
#
# Emits one JSON object: {ask_uuid, end_uuid, changed, uuids, candidates}, or
# {"decline":"<why>"} when there is nothing to log. python3 for the same reason
# lib/turn-activity.sh uses it — this is line-oriented parsing over records
# whose content is a heterogeneous block list, and jq is the wrong shape for it.
#
# TURN BOUNDARY: the same predicate turn-activity.sh applies — a genuine user
# prompt is real typed input, in either transcript shape, and is neither a
# tool_result nor hook feedback. The LAST such record starts the turn.
#
# NOT EVERY RECORD CARRIES A UUID. Measured: a real transcript interleaves
# `queue-operation`, `atis-latch`, `last-prompt` and `file-history-snapshot`
# bookkeeping lines that have none, and the final line is routinely one of
# them. So end_uuid is the last record IN THE TURN THAT HAS A UUID — "the last
# line" would resolve to nothing on most turns.
# ---------------------------------------------------------------------------
wl_slice() {
    python3 - "$1" "$2" <<'PY' 2>/dev/null
import json, re, sys

path, window = sys.argv[1], int(sys.argv[2])
MAXTEXT = 200
MAXCHANGED = 50

recs = []
try:
    with open(path, "r", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except Exception:
                continue
            if isinstance(r, dict):
                recs.append(r)
except Exception:
    sys.exit(3)

def msg(r):
    m = r.get("message")
    return m if isinstance(m, dict) else {}

def blocks(r):
    c = msg(r).get("content")
    return c if isinstance(c, list) else []

def text_of(r):
    c = msg(r).get("content")
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return " ".join(b.get("text", "") for b in c
                        if isinstance(b, dict) and b.get("type") == "text")
    return ""

def flat(s, n=MAXTEXT):
    s = re.sub(r"\s+", " ", (s or "")).strip()
    return s[:n]

def is_genuine_user(r):
    if r.get("type") != "user":
        return False
    t = text_of(r).lstrip()
    if t.startswith("Stop hook feedback:"):
        return False
    c = msg(r).get("content")
    if isinstance(c, list) and any(
            isinstance(b, dict) and b.get("type") == "tool_result" for b in c):
        return False
    return bool(t.strip())

# --- turn boundary -------------------------------------------------------
start = None
for i, r in enumerate(recs):
    if is_genuine_user(r) and r.get("uuid"):
        start = i
if start is None:
    print(json.dumps({"decline": "no-user-prompt"}))
    sys.exit(0)

turn = recs[start:]
ask_uuid = recs[start].get("uuid")
end_uuid = None
for r in turn:
    if r.get("uuid"):
        end_uuid = r.get("uuid")

# --- changed: mechanical, never from the model ---------------------------
# Write/Edit/NotebookEdit name their target outright. Bash does not, so its
# contribution is a LEXICAL guess over the command string: redirect targets
# plus the path-shaped arguments of a known-mutating command. Deliberately
# conservative and deliberately not clever — over-reporting a path is cheap,
# and a shell parser here would be a second language to maintain.
MUTATORS = {"tee", "touch", "mkdir", "rm", "mv", "cp", "install",
            "truncate", "ln", "dd"}
SPLIT = re.compile(r"[;|&\n]+|\|\||&&")
REDIR = re.compile(r"(?<![0-9<>])>>?\s*(?:\"([^\"]+)\"|'([^']+)'|([^\s;|&<>()]+))")
EXTN = re.compile(r"\.[A-Za-z0-9]{1,8}$")
NOTAFILE = {"/dev/null", "/dev/stdout", "/dev/stderr", "/dev/tty"}

def looks_path(tok):
    tok = tok.strip("\"'")
    if not tok or tok.startswith("-"):
        return False
    if tok in NOTAFILE:
        return False
    if "$" in tok or "*" in tok or "?" in tok:
        return False
    return "/" in tok or EXTN.search(tok) is not None

def bash_paths(cmd):
    out = []
    if not isinstance(cmd, str):
        return out
    for m in REDIR.finditer(cmd):
        tok = m.group(1) or m.group(2) or m.group(3) or ""
        if looks_path(tok):
            out.append(tok.strip("\"'"))
    for seg in SPLIT.split(cmd):
        toks = seg.split()
        # Step over leading VAR=value assignments and `sudo`.
        j = 0
        while j < len(toks) and (re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", toks[j])
                                 or toks[j] == "sudo"):
            j += 1
        if j >= len(toks):
            continue
        head = toks[j].split("/")[-1]
        rest = toks[j + 1:]
        if head == "sed" and any(t.startswith("-i") for t in rest):
            # `sed -i s/x/y/ file` — the SCRIPT is a bare argument and it
            # contains slashes, so looks_path() would happily record `s/x/y/`
            # as a file that changed. Consume the script (directly, or as the
            # value of -e/-f) before treating anything as a path.
            expect_script, take_next = True, False
            for t in rest:
                if take_next:
                    take_next, expect_script = False, False
                    continue
                if t in ("-e", "-f", "--expression", "--file"):
                    take_next = True
                    continue
                if t.startswith("-"):
                    continue
                if expect_script:
                    expect_script = False
                    continue
                if looks_path(t):
                    out.append(t.strip("\"'"))
            continue
        if head not in MUTATORS:
            continue
        for t in rest:
            if looks_path(t):
                out.append(t.strip("\"'"))
    return out

changed = []
def add(p):
    if p and p not in changed and len(changed) < MAXCHANGED:
        changed.append(p)

for r in turn:
    if r.get("type") != "assistant":
        continue
    for b in blocks(r):
        if not isinstance(b, dict) or b.get("type") != "tool_use":
            continue
        name = b.get("name")
        inp = b.get("input") if isinstance(b.get("input"), dict) else {}
        if name in ("Write", "Edit"):
            add(inp.get("file_path"))
        elif name == "NotebookEdit":
            add(inp.get("notebook_path") or inp.get("file_path"))
        elif name == "Bash":
            for p in bash_paths(inp.get("command")):
                add(p)

# --- candidates: the ONLY uuids the model may return ---------------------
# Conversation records only, and thinking blocks are excluded: detection is
# lexical and anchored to what was actually said, so an internal deliberation
# is neither a correction signal nor a citable anchor.
turn_uuids = {r.get("uuid") for r in turn if r.get("uuid")}
cands = []
for r in recs:
    u = r.get("uuid")
    if not u or r.get("type") not in ("user", "assistant"):
        continue
    kind, body = None, ""
    if r.get("type") == "user":
        c = msg(r).get("content")
        if isinstance(c, list) and any(isinstance(b, dict)
                                       and b.get("type") == "tool_result" for b in c):
            kind = "tool-result"
            parts = []
            for b in c:
                if isinstance(b, dict) and b.get("type") == "tool_result":
                    x = b.get("content")
                    if isinstance(x, str):
                        parts.append(x)
                    elif isinstance(x, list):
                        parts.extend(y.get("text", "") for y in x
                                     if isinstance(y, dict))
            body = " ".join(parts)
        else:
            kind, body = "user", text_of(r)
    else:
        tools = [b.get("name") for b in blocks(r)
                 if isinstance(b, dict) and b.get("type") == "tool_use"]
        txt = text_of(r)
        if tools:
            kind, body = "assistant-tool", ",".join(t for t in tools if t)
        elif txt.strip():
            kind, body = "assistant", txt
        else:
            continue
    if not kind:
        continue
    cands.append((u, kind, flat(body)))

cands = cands[-window:]
lines = []
for u, kind, body in cands:
    where = "THIS-TURN" if u in turn_uuids else "earlier"
    lines.append("%s\t%s\t%s\t%s" % (u, where, kind, body))

print(json.dumps({
    "ask_uuid": ask_uuid,
    "end_uuid": end_uuid,
    "changed": changed,
    "uuids": [u for u, _, _ in cands],
    "candidates": "\n".join(lines),
}))
PY
}

# ---------------------------------------------------------------------------
# wl_prompt — the judgment brief. Deliberately narrow.
#
# SHALLOW AND LEXICAL BY DESIGN. It asks what was asked, what came of it, and
# for an explicit correction signal, and for nothing else. No severity, no
# category, no failure-mode name: each of those is a judgment relative to a
# corpus this reader has never seen, and a confident wrong one is worse than a
# blank. Over-flagging is tolerable — the flag is inert — so the instruction
# that actually matters is the one FORBIDDING inference from tone.
#
# EVERY ENTRY CARRIES ITS OWN EVIDENCE. text says what happened; quote is the
# span that made the reader believe it; uuid says where that span lives. The
# pair is the point: a summary with no quote cannot be audited, and a quote
# with no uuid cannot be located. A missing quote is also the one thing that
# cannot be backfilled later, because the judgment that selected it is gone.
#
# THE MODEL DOES NOT AUTHOR quote. It names a span; wl_quote_verified locates
# that span in a candidate body and the row stores the characters SLICED FROM
# THE BODY. So quote has the same provenance as the uuids: transcript-derived
# by construction. An entry whose quote cannot be located is DROPPED, not
# stored quote-less — an unevidenced entry reads as evidence.
#
# CAPS 100/120 are asked for here and enforced at the row site. They are a
# readability bound, not a measured one; documented as unratified so a later
# reader does not mistake them for a finding.
# ---------------------------------------------------------------------------
wl_prompt() {
    cat <<EOF
You are reading one turn of an agent transcript and writing a single worklog row.

Reply with ONE JSON object and nothing else. No prose, no markdown fence.

{"requests": [], "outcomes": [], "mistakes": []}

Every entry in all three arrays has the same two evidence fields:

  "text"  — YOUR OWN words. What happened. At most 100 characters. Plain past
            tense. No ellipsis, no quotation marks: this is a summary you write,
            not something you copy.
  "quote" — VERBATIM characters from ONE candidate line. At most 120. Copy, do
            not paraphrase, do not fix spelling or punctuation. Cut the middle
            with "..." if it is too long: "...the part that matters...".

The pair is the point. "text" is your claim; "quote" is the evidence a reader
checks it against. Never write a "text" that the "quote" does not support.

An entry whose quote cannot be found verbatim in a candidate line is DISCARDED
in full. A confident entry with unusable evidence is worse than no entry, so
copy the quote exactly.

"requests" — [{"text","quote","uuid"}]. What the USER asked for. One entry per
distinct ask; a turn with several asks gets several entries. The quote comes
from the user's own line. Do not include what the agent decided to do on its
own — that is not a request.

"outcomes" — [{"text","quote","uuid"}]. What CHANGED IN THE WORLD because of
this turn. The test: if the transcript were deleted, would anything remain? A
file written, a command run, a PR opened, a message sent, a decision recorded.
Talking about a plan is not an outcome. Analysis, discussion, agreement,
explanation and proposals are NOT outcomes. [] is a correct and common answer
for a turn that was only conversation.

"mistakes" — [{"text","quote","uuids"}]. Note "uuids", an ARRAY.
Add an entry ONLY on an EXPLICIT correction signal:
  - the user says the agent was wrong, told it to stop, to not do that, to
    revert or undo, or that this is not what was asked; or
  - the agent states it had ALREADY ACTED WRONGLY and reverses course.
NEVER infer a mistake from tone, terseness, impatience, a short reply, a
follow-up question, or a change of subject. If the correction is not stated in
words, there is no mistake.
VIGILANCE IS NOT ERROR. An agent checking its work, noticing a risk, flagging
uncertainty, or deciding not to do something is working correctly, not making a
mistake. A mistake needs a WRONG ACT that already happened.
A correction is STILL a mistake when the agent then fixed it.
"uuids" needs at least two, chronological: the line where the offense happened
and the line where it was corrected. These are often in DIFFERENT turns, so
earlier lines are fair to cite. The quote comes from the CORRECTION line.

"uuid" / "uuids" — COPY CHARACTER-FOR-CHARACTER from the CANDIDATES block.
Never retype one from memory, never edit one, never invent one. A uuid that is
not in that block verbatim will be discarded.

At most 6 requests, 6 outcomes, 4 mistakes. Empty arrays are valid answers.

CANDIDATES (uuid, where, kind, text) follow as the user message.
EOF
}

# ---------------------------------------------------------------------------
# wl_candidates — the DATA half, sent as the user message.
#
# Split from wl_prompt deliberately. Piping brief and data together as one
# stdin blob makes the CLI read the whole thing as USER content, so the brief
# arrives as something to react to rather than as standing instructions.
# Measured on this repo's own transcript, n=6 per arm, same model and same
# candidates: delivering the brief on stdin caught the correction in the window
# 0/6 times and emitted 0 flags; delivering it via --system-prompt caught it 5/6
# times. The wording never changed — only which channel carried it.
# ---------------------------------------------------------------------------
wl_candidates() {
    local cands="$1"
    cat <<EOF
CANDIDATES (uuid, where, kind, text):
$cands
EOF
}

# ---------------------------------------------------------------------------
# wl_run — the whole job, once the envelope is known good.
# ---------------------------------------------------------------------------
wl_run() {
    wl_precheck

    local sid; sid="$(wl_sid)"
    sleep "$WORKLOG_SETTLE_SECS" 2>/dev/null || true

    local tx; tx="$(wl_transcript)"
    [ -n "$tx" ] && [ -r "$tx" ] \
        || gate_failopen worklog-record transcript-unreadable "$sid"

    command -v python3 >/dev/null 2>&1 \
        || gate_failopen worklog-record transcript-unreadable "$sid"

    local slice; slice="$(wl_slice "$tx" "$WORKLOG_WINDOW")"
    # An empty slice means the reader itself failed (python3 exited nonzero, or
    # the file could not be opened at all) — blind. A slice carrying "decline"
    # means it read fine and there was nothing to bracket a turn with — a
    # legitimate decline, and recording it would poison the fail-open rate.
    [ -n "$slice" ] && printf '%s' "$slice" | jq -e 'type == "object"' >/dev/null 2>&1 \
        || gate_failopen worklog-record transcript-unreadable "$sid"
    printf '%s' "$slice" | jq -e 'has("decline") | not' >/dev/null 2>&1 || exit 0

    # `changed` is still computed by the slicer and deliberately NOT read here.
    # It was dropped from the row because it overlapped `outcomes`: a file
    # written is an outcome, and carrying it twice invites the two to disagree.
    # The cost is named rather than hidden — it was the one field no model
    # touched, so the row is now entirely model-authored apart from the
    # timestamps and uuids, and `outcomes` inherits the burden of naming the
    # artifact that changed.
    local ask end uuids cands
    ask="$(printf '%s' "$slice" | jq -r '.ask_uuid // empty')"
    end="$(printf '%s' "$slice" | jq -r '.end_uuid // empty')"
    uuids="$(printf '%s' "$slice" | jq -c '.uuids // []')"
    cands="$(printf '%s' "$slice" | jq -r '.candidates // ""')"

    # ask_uuid/end_uuid are OURS, not the model's — but they are still checked
    # against the transcript rather than trusted, because a scalar that
    # resolves to nothing is the same silent dead pointer whoever wrote it.
    # Re-parsed rather than grepped for the literal `"uuid":"…"`: that byte
    # sequence is a serialization detail (compact today, one added space from
    # matching nothing), and a check that silently nulls VALID uuids on a
    # formatting change is worse than no check at all. `fromjson?` also lets a
    # single malformed line pass by instead of failing the whole scan.
    # `select(type == "object")` is load-bearing, not defensive noise: `?` binds
    # to fromjson only, so a line holding a bare JSON scalar reaches `.uuid`,
    # raises "cannot index", and aborts the WHOLE scan — which empties `present`
    # and nulls two uuids that were fine.
    local present; present="$(jq -R -r 'fromjson? | select(type == "object") | .uuid // empty' "$tx" 2>/dev/null || true)"
    printf '%s\n' "$present" | grep -Fxq -- "$ask" 2>/dev/null || ask=""
    printf '%s\n' "$present" | grep -Fxq -- "$end" 2>/dev/null || end=""

    # --- store, and the one-row-per-turn key ------------------------------
    # Both halves of the key are settled BEFORE the judgment, never after. The
    # model call is the expensive part of this hook, and it is also the window
    # the two Stop fires overlap in: a check made afterwards would buy a second
    # answer on every double-Stop turn and then throw it away.
    local store; store="$(wl_store "$tx")"
    wl_store_ok "$store" "$tx" || gate_failopen worklog-record store-unwritable "$sid"
    case "$store" in
        # Only when there is a directory component to make. `mkdir -p` on a
        # bare filename would create a DIRECTORY where the store belongs.
        */*) mkdir -p "${store%/*}" 2>/dev/null \
                || gate_failopen worklog-record store-unwritable "$sid" ;;
    esac
    # Already logged => a legitimate decline, and NOT a fail-open: the hook did
    # its job the first time Stop fired. The DURABLE half of the key.
    wl_seen "$store" "$ask" && exit 0
    # ...and the CONCURRENCY half. The row above is only on disk once fire 1
    # has finished; both fires are in flight together, so the turn is claimed
    # atomically here, before anything expensive, and a fire that loses the
    # claim declines. Also a legitimate decline: another fire IS recording it.
    wl_claim "$store" "$ask" || exit 0

    # --- judgment -------------------------------------------------------
    local raw="" entries="" judged=1
    if command -v claude >/dev/null 2>&1; then
        raw="$(wl_candidates "$cands" \
            | WORKLOG_DISABLE=1 timeout "$WORKLOG_MODEL_TIMEOUT" \
              claude -p --model "$WORKLOG_MODEL" --output-format text \
                     --system-prompt "$(wl_prompt)" \
                     --allowed-tools '' 2>/dev/null || true)"
    fi
    # Take the outermost brace span: a ```json fence or a stray sentence around
    # the object must not cost us the whole row. Done with parameter expansion
    # rather than sed because sed is line-oriented and a fence puts the noise on
    # its OWN line, where a per-line pattern cannot see the braces to strip
    # relative to. Newlines go first so the object is one string to trim.
    raw="$(printf '%s' "$raw" | tr -d '\000\n')"
    raw="${raw#"${raw%%\{*}"}"   # drop everything before the first {
    raw="${raw%"${raw##*\}}"}"   # drop everything after the last }

    if [ -n "$raw" ] && printf '%s' "$raw" | jq -e 'type == "object"' >/dev/null 2>&1; then
        # Every per-entry rule — uuid intersected with the candidate set, quote
        # sliced from the candidate body, text truncated, unverifiable entry
        # dropped whole — lives in wl_entries. It returns nothing when the
        # object is unusable, and the row is then written unjudged.
        entries="$(wl_entries "$cands" "$uuids" "$raw")"
        if [ -n "$entries" ] && printf '%s' "$entries" | jq -e 'type == "object"' >/dev/null 2>&1; then
            judged=0
        else
            entries=""
        fi
    fi
    [ -n "$entries" ] || entries='{"requests":[],"outcomes":[],"mistakes":[]}'

    # --- write ----------------------------------------------------------
    # Built with `jq -n --arg`, never an echoed brace literal — the hard rule
    # in scripts/log-record.sh. An apostrophe in a `text` or a `quote` is not
    # hypothetical here; it is the common case.
    local row
    row="$(jq -nc \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)" \
        --arg session "$sid" \
        --arg ask "$ask" \
        --arg end "$end" \
        --argjson entries "$entries" \
        '{ts: $ts,
          session: $session,
          ask_uuid: (if $ask   == "" then null else $ask   end),
          end_uuid: (if $end   == "" then null else $end   end),
          requests: $entries.requests,
          outcomes: $entries.outcomes,
          mistakes: $entries.mistakes}' 2>/dev/null || true)"
    # The claim is released on BOTH exits from here. A fire that could not write
    # must not hold its turn for the whole TTL: the next Stop fire is the only
    # chance that turn has left, and it should find the turn free.
    [ -n "$row" ] || { wl_unclaim; gate_failopen worklog-record store-unwritable "$sid"; }
    printf '%s\n' "$row" >> "$store" 2>/dev/null \
        || { wl_unclaim; gate_failopen worklog-record store-unwritable "$sid"; }
    # Durable now, so wl_seen covers every later fire and the marker is spent.
    # Released rather than kept, so one directory per turn does not accumulate
    # beside the store forever.
    wl_unclaim

    # Recorded LAST, and only after the mechanical row is safely on disk: the
    # machine-settled half of the turn is the durable part, and losing it to a
    # model outage would lose the turn entirely. gate_failopen exits.
    [ "$judged" -eq 0 ] || gate_failopen worklog-record judgment-unavailable "$sid"
    exit 0
}

# wl_detach — hand the job to a child and return immediately.
# Redirecting the child's stdin/stdout/stderr is the load-bearing half, not
# `setsid`: a harness reading the hook's pipe stays blocked until that pipe
# closes, detached process or not.
wl_detach() {
    local tmp
    tmp="$(mktemp "${TMPDIR:-/tmp}/worklog-payload.XXXXXX" 2>/dev/null)" || return 1
    printf '%s' "$INPUT" > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
    if command -v setsid >/dev/null 2>&1; then
        setsid bash "$SELF" --worker "$tmp" </dev/null >/dev/null 2>&1 &
    else
        bash "$SELF" --worker "$tmp" </dev/null >/dev/null 2>&1 &
    fi
    disown 2>/dev/null || true
    return 0
}

# --- dispatch -------------------------------------------------------------
if [ "${1:-}" = "--worker" ]; then
    INPUT="$(cat "${2:-/dev/null}" 2>/dev/null || true)"
    [ -n "${2:-}" ] && rm -f "$2" 2>/dev/null
    wl_run
    exit 0
fi

INPUT="$(cat 2>/dev/null || true)"
wl_precheck
if [ "${WORKLOG_SYNC:-0}" = "1" ]; then
    wl_run
    exit 0
fi
# NOT store-unwritable. wl_detach fails when `mktemp` fails or $TMPDIR is
# unwritable — the store is never touched on this path, and naming it here
# sends whoever reads the log to the wrong directory.
wl_detach || gate_failopen worklog-record detach-failed "$(wl_sid)"
exit 0
