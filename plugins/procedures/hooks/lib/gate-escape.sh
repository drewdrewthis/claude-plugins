#!/usr/bin/env bash
# gate-escape.sh — one question: is this gate still on? Plus the record that
# says when one was switched off (or, for a default-off gate, switched on).
#
# PLUGIN ADAPTATION: no upstream counterpart in orchard-codex. An installed
# plugin cannot be edited to silence a gate the way a checkout can, so the
# off-switch has to be configuration. Upstreams via orchard-codex#268 phase 2.
#
# SINGLE RESPONSIBILITY: answer "is this gate on", observably. It does not
# release the gate, read turn state, or decide anything else — the caller does.
#
# ONE NAMED SWITCH PER GATE — no list grammar, no wildcard, and deliberately no
# central registry of switch VALUES: each hook passes its own key and nothing
# enumerates the set. An enumerated list is the ts_reset bug in ADR-016 (the
# enumerated version omitted a key and read as correct in source), and a parsed
# spec would make one typo disarm every gate at once. ge__default_off below is
# a narrower exception: it names which keys default off, not their values.
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
# EITHER saying the deviation value turns a gate against its own default;
# neither channel is authoritative over the other. Precedence would make the
# plain var dead on an installed plugin: a default-on option carries
# `"default": true`, so the harness exports it on every hook invocation, and a
# PROCEDURES_ENABLE_<KEY> override losing to it could never be observed — the
# one-off override would work only in a bare checkout, which is the case that
# does not need it.
#
# MIXED DEFAULT, PER KEY (see ge__default_off). FRONTMATTER_CHECK and
# EVOLVE_SWEEP default ON: unset/empty/unrecognised keeps them armed, and only
# an explicit `false`/`0` turns one off (a release, recorded as released_by).
# HOW_DO_I_GATE, AM_I_DONE_GATE, and QUERY_SHAPE_GUARD default OFF (soft: they
# remind via nudge.sh rather than deny): unset/empty/unrecognised keeps them
# off, and only an explicit `true`/`1` turns one on (an arm, recorded as
# armed_by). Either direction, the fail-safe reading of an unrecognised value
# is "stay at this key's own default".
#
# NOT TAMPER-EVIDENT. GATE_ESCAPE_LOG is a plain env var and the append is
# best-effort, so whoever can set a switch can also send the record to
# /dev/null. This log exists to show you a gate you left off (or on) months
# ago — not to catch an adversary, which it cannot do.
#
# RECORDED, in its OWN log. A gate deviating from ITS OWN default is not a
# fail-open and must never enter gate-failopen.jsonl — that log means "a gate
# released without deciding", and blurring it destroys the fail-open rate it
# exists to carry. But an unrecorded deviation is invisible: nothing
# distinguishes an owner debugging for an hour from a session spawned as
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

# ge__on <value> — 0 if this value is an explicit on.
ge__on() {
    case "$1" in
        1 | [Tt][Rr][Uu][Ee] ) return 0 ;;
        * ) return 1 ;;
    esac
}

# ge__default_off <GATE_KEY> — 0 if this gate key's own default is OFF (the
# three soft gates); 1 otherwise (default ON).
ge__default_off() {
    case "$1" in
        HOW_DO_I_GATE | AM_I_DONE_GATE | QUERY_SHAPE_GUARD ) return 0 ;;
        * ) return 1 ;;
    esac
}

# ge__record <gate-key> <source> [field] — append one line, best effort. Field
# defaults to "released_by"; a default-off gate's arm event passes "armed_by"
# so the row self-describes which direction deviated. Fields are sanitized
# before they reach printf: the record is built without jq, so an unescaped
# %s is one forgetful caller away from a forged key that still parses (same
# class of defect as gate_failopen's, same defence).
ge__record() {
    local gate="${1:-unknown}" src="${2:-unknown}" field="${3:-released_by}"
    gate="${gate//[^A-Za-z0-9_.:-]/_}"
    src="${src//[^A-Za-z0-9_.:-]/_}"
    field="${field//[^A-Za-z0-9_.:-]/_}"
    printf '{"ts":"%s","gate":"%s","%s":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)" "$gate" "$field" "$src" \
        >> "$GATE_ESCAPE_LOG" 2>/dev/null || true
}

# ge_release_or_failopen <GATE_KEY> <gate-label> <why> [sid] — classify a
# release that is about to happen anyway.
#
# Every degenerate path (no jq, unreadable lib, unwired reset hook) releases the
# gate via gate_failopen, which never returns. A gate already off by its own
# default (explicitly or not) reaching one of those paths would therefore be
# filed as a BLIND fail-open — inflating the very rate that log exists to
# measure, one row per tool call for a whole session. Ask the switch first.
# Both arms exit; neither returns.
ge_release_or_failopen() {
    if declare -F ge_enabled >/dev/null 2>&1 && ! ge_enabled "$1"; then exit 0; fi
    shift
    # enforce-frontmatter sources this lib but NOT gate-failopen.sh, so the
    # recorder can legitimately be absent. Release anyway — never return.
    declare -F gate_failopen >/dev/null 2>&1 || exit 0
    gate_failopen "$@"
}

# ge_enabled <GATE_KEY> — 0 if the gate is on, 1 if off. Polarity is per key
# (ge__default_off). A default-ON gate is on unless explicitly released
# (false/0). A default-OFF gate is off unless explicitly armed (true/1).
# Recording lives here, at the single site that can answer either question, so
# no caller can forget it.
ge_enabled() {
    local key="$1"
    local opt="CLAUDE_PLUGIN_OPTION_ENABLE_$key" plain="PROCEDURES_ENABLE_$key"
    if ge__default_off "$key"; then
        if ge__on "${!opt:-}"; then ge__record "$key" "$opt" armed_by; return 0; fi
        if ge__on "${!plain:-}"; then ge__record "$key" "$plain" armed_by; return 0; fi
        return 1
    fi
    if ge__off "${!opt:-}"; then ge__record "$key" "$opt"; return 1; fi
    if ge__off "${!plain:-}"; then ge__record "$key" "$plain"; return 1; fi
    return 0
}
