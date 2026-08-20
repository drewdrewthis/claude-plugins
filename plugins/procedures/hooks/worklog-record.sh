#!/usr/bin/env bash
# worklog-record.sh — Stop hook.
#
# SINGLE RESPONSIBILITY: append ONE line per turn to a worklog JSONL describing
# what the agent did. Nothing else. It records a turn; it never decides anything
# about the turn, and it never blocks one.
#
# THE LINE:
#   {"ts","session","ask_uuid","end_uuid","did","changed",
#    "flag","flag_uuids","flag_quote"}
#
# MECHANICAL / JUDGMENT SPLIT, the same one scripts/log-record.sh draws. This
# script owns every field a machine can settle — ts, session, ask_uuid,
# end_uuid, changed. A Haiku read of the transcript owns only `did` and the
# flag triple. Nothing crosses that line: `changed` is read out of the turn's
# Write/Edit/NotebookEdit/Bash tool_use blocks and is NEVER taken from the
# model, so a summary that misremembers a path cannot enter the record.
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
#     rule. `flag` here is deliberately INERT: a marker for a later human or
#     analysis pass, carrying no severity, no category and no failure-mode
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
# SAME turn, so both slice to the same ask_uuid. The append is therefore keyed:
# a row whose ask_uuid is already present is not written again (wl_seen).
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
# routinely sit in different turns, which is why flag_uuids is an array.
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

INPUT=""

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
# SHALLOW AND LEXICAL BY DESIGN. It asks for a summary and an explicit
# correction signal, and for nothing else. No severity, no category, no
# failure-mode name: each of those is a judgment relative to a corpus this
# reader has never seen, and a confident wrong one is worse than a blank.
# Over-flagging is tolerable — the flag is inert — so the instruction that
# actually matters is the one FORBIDDING inference from tone.
# ---------------------------------------------------------------------------
wl_prompt() {
    local cands="$1"
    cat <<EOF
You are reading one turn of an agent transcript and writing a single worklog row.

Reply with ONE JSON object and nothing else. No prose, no markdown fence.

{"did": "<one line>", "flag": null, "flag_uuids": [], "flag_quote": null}

Fields:

"did" — one line, at most 200 characters, plain past tense, describing what the
agent DID in the lines marked THIS-TURN. Concrete over vague: name the thing
acted on. Do not evaluate the work.

"flag" — null, or the exact string "mistake".
Set it to "mistake" ONLY on an EXPLICIT correction signal:
  - the user says the agent was wrong, told it to stop, to not do that, to
    revert or undo, or that this is not what was asked; or
  - the agent itself states it was wrong and visibly reverses course.
NEVER infer a mistake from tone, terseness, impatience, a short reply, a
follow-up question, or a change of subject. If the correction is not stated in
words, "flag" is null.

"flag_uuids" — [] when flag is null. Otherwise the uuids of the lines the flag
rests on, chronological. A mistake needs at least two: the line where the
offense happened and the line where it was corrected. These are often in
DIFFERENT turns, so earlier lines are fair to cite.
COPY each uuid CHARACTER-FOR-CHARACTER from the CANDIDATES block below. Never
retype one from memory, never edit one, never invent one. A uuid that is not in
that block verbatim will be discarded.

"flag_quote" — null when flag is null. Otherwise a short verbatim quote, at
most 200 characters, from the line that carries the correction.

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

    local ask end changed uuids cands
    ask="$(printf '%s' "$slice" | jq -r '.ask_uuid // empty')"
    end="$(printf '%s' "$slice" | jq -r '.end_uuid // empty')"
    changed="$(printf '%s' "$slice" | jq -c '.changed // []')"
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
    # Resolved BEFORE the judgment, not after, so a second Stop for a turn
    # already on the record costs nothing. The model call is the expensive part
    # of this hook; paying for it and then discarding the answer would make the
    # dedup a correctness fix that doubles the bill on the common path.
    local store; store="$(wl_store "$tx")"
    wl_store_ok "$store" "$tx" || gate_failopen worklog-record store-unwritable "$sid"
    case "$store" in
        # Only when there is a directory component to make. `mkdir -p` on a
        # bare filename would create a DIRECTORY where the store belongs.
        */*) mkdir -p "${store%/*}" 2>/dev/null \
                || gate_failopen worklog-record store-unwritable "$sid" ;;
    esac
    # Already logged => a legitimate decline, and NOT a fail-open: the hook did
    # its job the first time Stop fired.
    wl_seen "$store" "$ask" && exit 0

    # --- judgment -------------------------------------------------------
    local raw="" did="" flag="" quote="" fuuids="[]" judged=1
    if command -v claude >/dev/null 2>&1; then
        raw="$(wl_prompt "$cands" \
            | WORKLOG_DISABLE=1 timeout "$WORKLOG_MODEL_TIMEOUT" \
              claude -p --model "$WORKLOG_MODEL" --output-format text \
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
        judged=0
        did="$(printf '%s' "$raw" | jq -r '(.did // "") | if type == "string" then .[0:200] else "" end' 2>/dev/null || true)"
        flag="$(printf '%s' "$raw" | jq -r 'if .flag == "mistake" then "mistake" else "" end' 2>/dev/null || true)"
        # 200 for both, matching what wl_prompt ASKS for character-for-
        # character. The truncation is the backstop for a model that ignores
        # the limit, not a second, looser limit of its own: a documented bound
        # the code does not enforce teaches a reader the wrong contract, and
        # the enforced-but-undocumented one is what they discover later.
        quote="$(printf '%s' "$raw" | jq -r '(.flag_quote // "") | if type == "string" then .[0:200] else "" end' 2>/dev/null || true)"
        # EVERY returned uuid is intersected with the candidate set the slicer
        # built. This is the check the header promises; without it a
        # transposed character writes a pointer that resolves to nothing and
        # nobody ever learns.
        fuuids="$(printf '%s' "$raw" | jq -c --argjson ok "$uuids" \
            '[(.flag_uuids // []) | if type == "array" then .[] else empty end
              | select(type == "string") | select(. as $u | $ok | index($u))]' \
            2>/dev/null || printf '[]')"
        [ -n "$fuuids" ] || fuuids="[]"
    fi
    # Schema coherence: an unflagged row carries no anchors and no quote, so a
    # reader never has to ask what a quote with no flag meant.
    if [ "$flag" != "mistake" ]; then fuuids="[]"; quote=""; fi

    # --- write ----------------------------------------------------------
    # Built with `jq -n --arg`, never an echoed brace literal — the hard rule
    # in scripts/log-record.sh. An apostrophe in `did` or `flag_quote` is not
    # hypothetical here; it is the common case.
    local row
    row="$(jq -nc \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)" \
        --arg session "$sid" \
        --arg ask "$ask" \
        --arg end "$end" \
        --arg did "$did" \
        --arg flag "$flag" \
        --arg quote "$quote" \
        --argjson changed "$changed" \
        --argjson fuuids "$fuuids" \
        '{ts: $ts,
          session: $session,
          ask_uuid: (if $ask   == "" then null else $ask   end),
          end_uuid: (if $end   == "" then null else $end   end),
          did:      (if $did   == "" then null else $did   end),
          changed: $changed,
          flag:     (if $flag  == "" then null else $flag  end),
          flag_uuids: $fuuids,
          flag_quote: (if $quote == "" then null else $quote end)}' 2>/dev/null || true)"
    [ -n "$row" ] || gate_failopen worklog-record store-unwritable "$sid"
    printf '%s\n' "$row" >> "$store" 2>/dev/null \
        || gate_failopen worklog-record store-unwritable "$sid"

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
wl_detach || gate_failopen worklog-record store-unwritable "$(wl_sid)"
exit 0
