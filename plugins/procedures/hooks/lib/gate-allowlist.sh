#!/usr/bin/env bash
# gate-allowlist.sh — what a per-turn invariant gate may never deny.
#
# SINGLE RESPONSIBILITY: decide whether a tool call is part of the compliance
# path. A gate that denies the call which satisfies it deadlocks the session
# (sol.2026-07-08-hook-conflict-markers-freeze-all-tools).
#
# ALLOWLISTED:
#   Skill  — Skill(how-do-i) / Skill(am-i-done) ARE compliance.
#   Agent  — /how-do-i and /am-i-done dispatch a subagent, so the delegation
#            itself is the compliance path. Without this the gate denies the
#            Agent call that would satisfy it. Added 2026-08-02 with the
#            delegating skills; the pre-delegation gate did not need it.
#   Read   — of a file under references/procedures/ (the corpus read).
#   Bash   — read-only shapes on the discovery surface only.
#
# GATE ON ACT, NOT ON LOOK: read-only inspection is allowlisted because a good
# /how-do-i query cannot be formed before you know what the turn is about. On a
# diagnostic turn ("the box is down") the useful query depends on what you find.
# Forcing the skill before any look yields a blind query and a wrong digest.

set -uo pipefail

# gal_is_compliance_path <tool_name> <payload> — 0 when the call must be allowed
# regardless of outstanding invariants.
gal_is_compliance_path() {
    local tool="${1:-}" payload="${2:-}"

    case "$tool" in
        Skill|Agent) return 0 ;;
    esac

    if [ "$tool" = "Read" ]; then
        local fp
        fp="$(printf '%s' "$payload" | jq -r '(.tool_input.file_path // .input.file_path) // empty' 2>/dev/null || true)"
        case "$fp" in
            # Traversal is rejected BEFORE the glob: a path like
            # .../references/procedures/../../CLAUDE.md matches the glob yet
            # escapes the tree, which would leak arbitrary reads.
            *..*) return 1 ;;
            */references/procedures/*|references/procedures/*) return 0 ;;
        esac
        return 1
    fi

    if [ "$tool" = "Bash" ]; then
        local cmd
        cmd="$(printf '%s' "$payload" | jq -r '(.tool_input.command // .input.command) // empty' 2>/dev/null || true)"
        case "$cmd" in
            *..*) return 1 ;;
        esac
        # SUBSTRING MATCHING ALONE IS UNSAFE: a destructive command that merely
        # CONTAINS `references/procedures/` (e.g. as an rm argument) would pass.
        # Anchor on a known read-only invocation shape AND the discovery surface.
        case "$cmd" in
            grep\ *|ls\ *|cat\ *|rg\ *|sed\ -n\ *|bash\ scripts/query-records.sh*|scripts/query-records.sh*)
                case "$cmd" in
                    *references/procedures/*|*query-records.sh*) return 0 ;;
                esac
                ;;
        esac
        return 1
    fi

    return 1
}
