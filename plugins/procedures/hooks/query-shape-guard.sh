#!/usr/bin/env bash
# query-shape-guard.sh — PreToolUse hook (all tools; no matcher).
#
# SINGLE RESPONSIBILITY: hold the two gate forks to their one-shot contracts.
#   procedures:procedure-scout  — Bash only, and every segment of that Bash is
#                                 the ONE sanctioned shape (--ask / digest
#                                 replay / the documented justfile probe); ONE
#                                 retrieval call per fork session.
#   procedures:work-reviewer    — same Bash shape and budget; at most ONE Agent
#                                 dispatch, targeting procedures:procedure-evolver.
# Both forks lose Write/Edit/Read-class tools outright: a fork inherits the
# parent toolset (fm.read-only-fork-writes-anyway), so prose boundaries are not
# the control — this guard is.
#
# AUDIENCE: keyed on `.agent_type` in the payload, falling back to the
# CLAUDE_CODE_AGENT env var. Every other session — main agents included — is
# released untouched.
#
# FAIL-OPEN: missing jq, unreadable payload => ALLOW, recorded as a blind
# fail-open (gate-failopen convention). A guard that bricks its fork on its own
# bug costs more than it enforces.
#
# BUDGET STATE: one marker file per session+key under QUERY_GUARD_STATE_DIR,
# incremented ONLY when a sanctioned call is allowed. Fork sessions carry their
# own session id, so the count is naturally per-fork. Exactly ONE retrieval
# call is granted (matching the prompts' "exactly ONE query, ever"): the grace
# lives in the SHAPE check, not the budget — a DENIED shape spends nothing, so
# a typo'd first command does not brick the fork. An ALLOWED call spends the
# budget even if the query itself later fails (a bad term set exits 2 after
# the fact); the prompts forbid a retry, so neither does the guard.

set -uo pipefail

INPUT="$(cat 2>/dev/null || true)"

SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[ "$SCRIPT_DIR" = "${BASH_SOURCE[0]}" ] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "$SCRIPT_DIR" 2>/dev/null && pwd 2>/dev/null)" || exit 0

# shellcheck source=lib/gate-escape.sh
. "$SCRIPT_DIR/lib/gate-escape.sh" 2>/dev/null || true
# shellcheck source=lib/gate-failopen.sh
. "$SCRIPT_DIR/lib/gate-failopen.sh" 2>/dev/null || exit 0

command -v jq >/dev/null 2>&1 || ge_release_or_failopen "QUERY_SHAPE_GUARD" "query-shape" "no-jq"

if declare -F ge_enabled >/dev/null 2>&1 && ! ge_enabled "QUERY_SHAPE_GUARD"; then exit 0; fi

qsg_deny() {
    jq -nc --arg r "$1" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $r
      }
    }'
    exit 0
}

AGENT="$(printf '%s' "$INPUT" | jq -r '.agent_type // empty' 2>/dev/null || true)"
[ -n "$AGENT" ] || AGENT="${CLAUDE_CODE_AGENT:-}"

case "$AGENT" in
    procedures:procedure-scout|procedures:work-reviewer) ;;
    *) exit 0 ;;
esac
REVIEWER=0
[ "$AGENT" = "procedures:work-reviewer" ] && REVIEWER=1

TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '(.tool_name // .tool) // empty' 2>/dev/null || true)"

SID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"
STATE_DIR="${QUERY_GUARD_STATE_DIR:-${TMPDIR:-/tmp}/procedures-query-guard}"

# qsg_bump <key> — append one allowance; best effort, unwritable state fails
# open (the guard degrades to shape-only enforcement).
qsg_allowance() {
    [ -n "$SID" ] || { mkdir -p "$STATE_DIR" 2>/dev/null || true; return 0; }
    mkdir -p "$STATE_DIR" 2>/dev/null || return 0
    printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo t)" \
        >> "$STATE_DIR/${SID}.${1}" 2>/dev/null || true
}

qsg_count() {
    [ -n "$SID" ] || { printf '0'; return; }
    [ -f "$STATE_DIR/${SID}.${1}" ] || { printf '0'; return; }
    wc -l < "$STATE_DIR/${SID}.${1}" 2>/dev/null | tr -d ' ' || printf '0'
}

# ---- non-Bash tools ----
case "$TOOL_NAME" in
    Bash) : ;;
    Agent)
        if [ "$REVIEWER" -eq 0 ]; then
            qsg_deny "QUERY-SHAPE-GUARD: procedure-scout is read-only — no Agent dispatches. Retrieve with --ask, report findings."
        fi
        N="$(qsg_count agent)"
        if [ "${N:-0}" -ge 1 ]; then
            qsg_deny "QUERY-SHAPE-GUARD: work-reviewer gets exactly ONE evolution dispatch per review, and it was spent. Return your findings now — remaining hygiene rows go in them."
        fi
        SUBTYPE="$(printf '%s' "$INPUT" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null || true)"
        case "$SUBTYPE" in
            procedures:procedure-evolver) qsg_allowance agent; exit 0 ;;
            *) qsg_deny "QUERY-SHAPE-GUARD: the single allowed dispatch targets procedures:procedure-evolver (got: ${SUBTYPE:-none}). Record hygiene belongs there — not to any other agent." ;;
        esac
        ;;
    Write|Edit|MultiEdit|NotebookEdit|Read|Grep|Glob)
        # The write surface belongs to procedure-evolver; reading beyond the
        # pasted report is what the review contract forbids. Deny by name so
        # the fork knows the guard did it.
        qsg_deny "QUERY-SHAPE-GUARD: $TOOL_NAME is outside the $AGENT contract — judge from the report you were handed (record WRITES belong to procedures:procedure-evolver)."
        ;;
    *) exit 0 ;;
esac

# ---- Bash: every separator-split segment must be a sanctioned shape ----
CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[ -n "$CMD" ] || qsg_deny "QUERY-SHAPE-GUARD: empty command."

# Redirection to /dev/null is discarding output, not acting; stripped first.
SCAN="$CMD"
SCAN="${SCAN//2>&1/ }"
SCAN="${SCAN//>&2/ }"
SCAN="${SCAN//&>\/dev\/null/ }"
SCAN="${SCAN//2>\/dev\/null/ }"
SCAN="${SCAN//>\/dev\/null/ }"

# Constructs that hide a segment from this scan deny outright.
case "$SCAN" in
    *'$('*|*'`'*|*'<('*|*$'\n'*) qsg_deny "QUERY-SHAPE-GUARD: command substitution hides a segment from the shape check — run the digest read, --ask, and the justfile probe as plain segments." ;;
esac
# Output redirection to a FILE is a write.
case "$SCAN" in *'>'*) qsg_deny "QUERY-SHAPE-GUARD: file redirection is a write — the forks read." ;; esac

SANCTIONED=0
# Statements are split on &&/||/;/&; each statement is then judged pipe-STAGE
# by pipe-STAGE, with each stage TRIMMED — the splitter leaves a leading
# space on every non-first segment, and the sanctioned patterns are anchored.
#
# A jq stage swallows the REST of its statement: the jq program's own '|'
# characters are indistinguishable from shell pipes, so the documented probe's
# `.recipes | to_entries[] | ...` must be judged as one unit with its producer,
# not shredded into fragments that match nothing. Corollary: a jq stage is
# sanctioned only beside a `just --dump` producer IN THE SAME STATEMENT.
while IFS= read -r stmt; do
    [ -n "$stmt" ] || continue
    stmt="${stmt#"${stmt%%[![:space:]]*}"}"; stmt="${stmt%"${stmt##*[![:space:]]}"}"
    HAS_JUST_DUMP=0
    case "$stmt" in *"just --dump"*) HAS_JUST_DUMP=1 ;; esac
    IN_JQ=0
    while IFS= read -r seg; do
        [ -n "$seg" ] || continue
        seg="${seg#"${seg%%[![:space:]]*}"}"; seg="${seg%"${seg##*[![:space:]]}"}"
        if [ "$IN_JQ" -eq 1 ]; then continue; fi   # tail of the quoted jq program
        case "$seg" in
            *"session-digest-read.sh"*" --read "*) ;;
            *"query-records.sh"*" --ask "*) ;;
            "command -v just"*) ;;
            "just "*) ;;
            "jq "*)
                if [ "$HAS_JUST_DUMP" -eq 1 ]; then IN_JQ=1; else
                    qsg_deny "QUERY-SHAPE-GUARD: jq is sanctioned only inside the justfile probe pipeline (just --dump | jq -r ...)."
                fi ;;
            *)
                qsg_deny "QUERY-SHAPE-GUARD: unsanctioned command segment in $AGENT — the contract allows exactly: session-digest-read.sh --read ..., query-records.sh --ask '<terms>', and (when the repo has one) the documented justfile probe. Offending segment: ${seg:0:120}" ;;
        esac
    done <<EOF
$(printf '%s' "$stmt" | sed -e 's/|/\n/g')
EOF
    SANCTIONED=$((SANCTIONED + 1))
done <<EOF
$(printf '%s' "$SCAN" | sed -e 's/&&/\n/g' -e 's/||/\n/g' -e 's/;/\n/g' -e 's/&/\n/g')
EOF

[ "$SANCTIONED" -gt 0 ] || qsg_deny "QUERY-SHAPE-GUARD: nothing sanctioned in the command."

N="$(qsg_count bash)"
if [ "${N:-0}" -ge 1 ]; then
    qsg_deny "QUERY-SHAPE-GUARD: $AGENT has spent its one retrieval call. Work from the answer you already have and report it — a second query is never the fix for an answer you did not like."
fi
qsg_allowance bash
exit 0
