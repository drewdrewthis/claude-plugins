#!/usr/bin/env bash
# turn-activity.sh — did THIS turn call any tool?
#
# SINGLE RESPONSIBILITY: answer that one question from the session transcript.
# The gate decides what to do about the answer; this file only reports it.
#
# ANY tool_use counts — research, reads, and greps as much as edits. Owner
# decision 2026-08-02: "it should always gate after any tool calls. This skips a
# direct respond, but encourages a second thought about everything else from
# research to actual work." A turn that only produced words is answerable by the
# human reading them; a turn that touched the world gets a second look.
#
# This deliberately replaces an earlier WORK-set allowlist (Edit/Write/
# NotebookEdit/Agent). That predicate exempted exactly the turns that CHECK
# work — a pure-Bash verification turn ending "all green" got no review — and
# it silently missed `sed -i` mutations, which are Bash.
#
# FAIL-CLOSED-TO-QUIET: transcript unreadable / python missing / parse error =>
# the caller releases. Never block on our own blindness — but say so: exit 2
# means "could not tell", distinct from exit 1 "genuinely no tools". Collapsing
# the two makes a permanently broken gate look like a permanently clean session.

set -uo pipefail

# ta_turn_used_tools <session_id>
#   0 — a tool_use occurred since the last genuine user prompt
#   1 — no tool_use this turn (a clean, conversational turn)
#   2 — could not determine (no session, no transcript, no python, parse error)
ta_turn_used_tools() {
    local sid="${1:-}"
    [ -n "$sid" ] || return 2

    local jsonl=""
    for cand in "$HOME"/.claude/projects/*/"$sid".jsonl; do
        [ -f "$cand" ] && { jsonl="$cand"; break; }
    done
    [ -n "$jsonl" ] || return 2

    command -v python3 >/dev/null 2>&1 || return 2

    python3 - "$jsonl" <<'PY' 2>/dev/null
import json, sys

def blocks(msg):
    c = msg.get("content")
    return c if isinstance(c, list) else []

def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(b.get("text", "") for b in content
                        if isinstance(b, dict) and b.get("type") == "text")
    return ""

saw_tool = False
try:
    with open(sys.argv[1], "r", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except Exception:
                continue
            rtype = r.get("type")
            msg = r.get("message", {}) if isinstance(r.get("message"), dict) else {}
            content = msg.get("content")

            # A genuine user prompt starts a new turn: real typed input, in
            # either transcript shape, and not a hook-feedback record. Reset.
            if rtype == "user":
                t = text_of(content).lstrip()
                if t.startswith("Stop hook feedback:"):
                    continue
                is_tool_result = isinstance(content, list) and any(
                    isinstance(b, dict) and b.get("type") == "tool_result"
                    for b in content
                )
                if not is_tool_result and t.strip():
                    saw_tool = False
                continue

            if rtype == "assistant":
                for b in blocks(msg):
                    if isinstance(b, dict) and b.get("type") == "tool_use":
                        saw_tool = True
except Exception:
    sys.exit(2)

sys.exit(0 if saw_tool else 1)
PY
}
