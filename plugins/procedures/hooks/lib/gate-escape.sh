#!/usr/bin/env bash
# gate-escape.sh — one question: is this gate still on? Plus the record that
# says when one was switched off.
#
# PLUGIN ADAPTATION: no upstream counterpart in orchard-codex. An installed
# plugin cannot be edited to silence a gate the way a checkout can, so the
# off-switch has to be configuration. Upstreams via orchard-codex#268 phase 2.
#
# SINGLE RESPONSIBILITY: answer "is this gate on", observably. It does not
# release the gate, read turn state, or decide anything else — the caller does.
#
# ONE NAMED SWITCH PER GATE — no list grammar, no wildcard, and deliberately no
# central registry of the switches: each hook passes its own key and nothing
# enumerates the set. An enumerated list is the ts_reset bug in ADR-016 (the
# enumerated version omitted a key and read as correct in source), and a parsed
# spec would make one typo disarm every gate at once.
#
# Each key is declared as a userConfig option in .claude-plugin/plugin.json and
# reaches this process two ways:
#   CLAUDE_PLUGIN_OPTION_ENABLE_<KEY>  — the harness exports every userConfig
#     option to hook processes under this name, read from USER settings only
#     (~/.claude/settings.json pluginConfigs[...]). Project-level
#     .claude/settings.json is ignored for pluginConfigs as of Claude Code
#     v2.1.207, and that floor is unenforced here — on an older CLI a repo's
#     own settings.json could set the option.
#   PROCEDURES_ENABLE_<KEY>            — plain env, for one-off invocations.
#     UNTRUSTED AMBIENT CONFIG. It carries no isolation property at all: a
#     project's .claude/settings.json `env` block reaches hook subprocesses on
#     EVERY version, and so do .envrc, a Makefile, an npm script, or a wrapper
#     launcher. A cloned repo CAN disarm a gate through this channel. It exists
#     because there is no per-invocation override for a userConfig option —
#     options resolve from settings only — not because it is safe. Anything
#     relying on "a repo cannot switch my gates off" must say
#     CLAUDE_PLUGIN_OPTION_* specifically; the claim is false of this channel.
#
# EITHER saying false turns the gate off; neither is authoritative over the
# other. Precedence would make the plain var dead on an installed plugin: the
# option carries `"default": true`, so the harness exports it on every hook
# invocation, and a `PROCEDURES_ENABLE_<KEY>=false` losing to it could never be
# observed — the one-off override would work only in a bare checkout, which is
# the case that does not need it.
#
# DEFAULT ON. Only an explicit `false` or `0` turns a gate off; unset, empty, or
# unrecognised keeps it armed — the fail-safe direction for an off-switch is off.
#
# NOT TAMPER-EVIDENT. GATE_ESCAPE_LOG is a plain env var and the append is
# best-effort, so whoever can set a switch can also send the record to
# /dev/null. This log exists to show you a gate you left off months ago — not
# to catch an adversary, which it cannot do.
#
# RECORDED, in its OWN log. A switched-off gate is not a fail-open and must
# never enter gate-failopen.jsonl — that log means "a gate released without
# deciding", and blurring it destroys the fail-open rate it exists to carry. But
# an unrecorded off-switch is invisible: nothing distinguishes an owner
# debugging for an hour from a session spawned as
# `PROCEDURES_ENABLE_AM_I_DONE_GATE=false claude -p …` to dodge review. Both
# reviewers of this change flagged that gap independently. So: a separate
# gate-escape.jsonl, never merged with the other.
#
# NO EXTERNAL COMMANDS on the decision path: how-do-i-gate sources this with
# PATH emptied on the no-jq path (gate-failopen.bats "no-jq ordering").
# Indirect expansion and `case` are builtins. Only the record touches `date`,
# and it degrades to "unknown" exactly as gate_failopen does.

set -uo pipefail

GATE_ESCAPE_LOG="${GATE_ESCAPE_LOG:-$HOME/.claude/gate-escape.jsonl}"

# ge__off <value> — 0 if this value is an explicit off.
ge__off() {
    case "$1" in
        0 | [Ff][Aa][Ll][Ss][Ee] ) return 0 ;;
        * ) return 1 ;;
    esac
}

# ge__record <gate-key> <source> — append one line, best effort. Fields are
# sanitized before they reach printf: the record is built without jq, so an
# unescaped %s is one forgetful caller away from a forged key that still parses
# (same class of defect as gate_failopen's, same defence).
ge__record() {
    local gate="${1:-unknown}" src="${2:-unknown}"
    gate="${gate//[^A-Za-z0-9_.:-]/_}"
    src="${src//[^A-Za-z0-9_.:-]/_}"
    printf '{"ts":"%s","gate":"%s","released_by":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)" "$gate" "$src" \
        >> "$GATE_ESCAPE_LOG" 2>/dev/null || true
}

# ge_enabled <GATE_KEY> — 0 if the gate is on (the default), 1 if either switch
# turned it off. GATE_KEY is the uppercased option suffix, e.g. HOW_DO_I_GATE.
# Recording lives here, at the single site that can answer "off", so no caller
# can forget it.
ge_enabled() {
    local opt="CLAUDE_PLUGIN_OPTION_ENABLE_$1" plain="PROCEDURES_ENABLE_$1"
    if ge__off "${!opt:-}"; then ge__record "$1" "$opt"; return 1; fi
    if ge__off "${!plain:-}"; then ge__record "$1" "$plain"; return 1; fi
    return 0
}
