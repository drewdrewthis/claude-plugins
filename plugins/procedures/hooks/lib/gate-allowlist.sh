#!/usr/bin/env bash
# gate-allowlist.sh — what a per-turn invariant gate may never deny.
#
# SINGLE RESPONSIBILITY: decide whether a tool call is part of the compliance
# path. A gate that denies the call which satisfies it deadlocks the session
# (sol.2026-07-08-hook-conflict-markers-freeze-all-tools).
#
# ALLOWLISTED:
#   Skill  — Skill(how-do-i) / Skill(am-i-done) ARE compliance.
#   Agent  — ONLY when the dispatch payload names a compliance skill
#            (how-do-i / am-i-done / procedures). A blanket Agent allow let
#            any delegated write bypass the gate — delegation is the main way
#            a lead makes durable changes, so it was the widest hole in the
#            gate (clara defect report 2026-08-17). The /how-do-i and
#            /am-i-done dispatches carry the skill name in
#            subagent_type/description/prompt, so they still pass and cannot
#            deadlock; a work delegation does not.
#   WebFetch / WebSearch
#          — read-only web discovery, unconditional. No payload or URL
#            inspection: neither can mutate the local tree or the session
#            state this gate protects, and a lookup is often how the
#            turn's /how-do-i query gets formed.
#   Read   — any file read (Read / Grep / Glob / NotebookRead).
#   Bash   — any command line that only reads (see lib/readonly-shape.sh).
#
# GATE ON ACT, NOT ON LOOK: read-only inspection is allowlisted because a good
# /how-do-i query cannot be formed before you know what the turn is about. On a
# diagnostic turn ("the box is down") the useful query depends on what you find.
# Forcing the skill before any look yields a blind query and a wrong digest.
#
# WHY THE DISCOVERY-PATH CO-REQUIREMENT IS GONE: until 2026-08-09 a look also
# had to NAME `references/procedures/` — a Read anywhere else, or a
# `tmux capture-pane | grep | tail`, was denied even though the deny message
# promises read-only commands stay available. That co-requirement was never
# the safety property it looked like: `rm -rf references/procedures/` names the
# surface too. The real property is MUTATION, and it is now decided by a
# command classifier that judges the whole pipeline and fails closed.

set -uo pipefail

# readonly-shape.sh answers "does this Bash line mutate?". Sourced defensively:
# if it is unreadable, `ros_is_read_only` is undefined and every Bash call is
# denied — the pre-fix behaviour for all but a handful of shapes, and a deny
# costs one Skill(how-do-i), so degradation is safe.
# ${BASH_SOURCE[0]%/*} is the file's own name when sourced by a bare name
# (no slash) — guard with the same fallback how-do-i-gate.sh uses, so a
# future caller doesn't silently lose Bash inspection.
GAL_LIB_DIR="${BASH_SOURCE[0]%/*}"
[ "$GAL_LIB_DIR" = "${BASH_SOURCE[0]}" ] && GAL_LIB_DIR="."
# shellcheck source=readonly-shape.sh
. "$GAL_LIB_DIR/readonly-shape.sh" 2>/dev/null || true

# gal_is_compliance_path <tool_name> <payload> — 0 when the call must be allowed
# regardless of outstanding invariants.
gal_is_compliance_path() {
    local tool="${1:-}" payload="${2:-}"

    case "$tool" in
        Skill) return 0 ;;
        WebFetch|WebSearch) return 0 ;;
        Agent)
            # Compliance dispatches name their skill somewhere in the payload;
            # a work delegation does not. jq failure yields "" → deny, which
            # costs one Skill(how-do-i) — fail closed is safe here.
            local ap
            ap="$(printf '%s' "$payload" | jq -r '
                (.tool_input // .input // {})
                | [(.subagent_type // ""), (.description // ""), (.prompt // "")]
                | join(" ")' 2>/dev/null || true)"
            case "$ap" in
                *how-do-i*|*am-i-done*|*what-do-i-know*|*adherence-check*|*procedures*) return 0 ;;
            esac
            return 1 ;;
    esac

    case "$tool" in
        Read|NotebookRead|Grep|Glob)
            # Traversal fields differ per tool: Glob targets via `pattern` and
            # Grep can scope via `glob`. Grep's `pattern` is a REGEX where `..`
            # is legitimate (any-two-chars), so it is deliberately not checked.
            local fp
            fp="$(printf '%s' "$payload" | jq -r --arg tool "$tool" '
                (.tool_input // .input // {})
                | if $tool == "Grep" then [(.path // ""), (.glob // "")]
                  elif $tool == "Glob" then [(.path // ""), (.pattern // "")]
                  else [(.file_path // .notebook_path // .path // "")] end
                | join(" ")' 2>/dev/null || true)"
            # Traversal stays refused. A read is no longer scoped to a tree, so
            # this no longer guards an escape — it is kept because a `..` path
            # is nearly always an unintended read of somewhere else, and the
            # absolute form of the same read is always available.
            case "$fp" in
                *..*) return 1 ;;
            esac
            return 0 ;;
    esac

    if [ "$tool" = "Bash" ]; then
        command -v ros_is_read_only >/dev/null 2>&1 || return 1
        local cmd
        cmd="$(printf '%s' "$payload" | jq -r '(.tool_input.command // .input.command) // empty' 2>/dev/null || true)"
        ros_is_read_only "$cmd" && return 0
        return 1
    fi

    return 1
}
