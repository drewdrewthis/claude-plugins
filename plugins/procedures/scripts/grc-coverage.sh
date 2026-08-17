#!/usr/bin/env bash
# grc-coverage.sh — control-coverage report over the codex.
#
# Answers the three questions a control framework exists to answer:
#   1. Which obligations (principles, policies) have no control?
#   2. Which named controls do not exist on disk / are not wired?
#   3. Which risks (failure-modes) have no treatment pointing at them?
#
# Everything is derived LIVE from the artifacts each run. No status field is
# trusted as proof of current state (fm.written-record-mistaken-for-live-state),
# and existence is asserted against the parsed artifact, never a regex over a
# doc that claims it (sol.2026-07-31-text-assertions-over-config-are-not-policy-proof).
#
# Usage:
#   scripts/grc-coverage.sh            # full report, always exit 0
#   scripts/grc-coverage.sh --strict   # exit 1 if any control is MISSING on disk
#   scripts/grc-coverage.sh --summary  # counts only

set -uo pipefail

# PLUGIN ADAPTATION (data-root defaults): upstream derives ROOT from the
# script's own location, which is the repo root there. Installed as a plugin the
# script sits in the plugin cache, not the corpus — so the corpus root becomes a
# config default instead, matching query-records.sh.
ROOT="${GRC_COVERAGE_ROOT:-${CODEX_ROOT:-$HOME/.claude}}"
cd "$ROOT" || exit 2

MODE="full"
case "${1:-}" in
    --strict) MODE="strict" ;;
    --summary) MODE="summary" ;;
    --help | -h)
        sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
esac

bold() { printf '\033[1m%s\033[0m\n' "$1"; }

# --- resolve a control reference to a real path on disk -----------------------
# Accepts:
#   scripts/pr-ready-check.sh                     -> repo-relative
#   agents/ac-reviewer.md                         -> repo-relative
#   procedures@drewdrewthis:hooks/am-i-done-gate.sh -> plugin cache lookup
# Echoes the resolved path if it exists; empty string otherwise.
resolve_control() {
    local ref="$1" plugin owner rest base
    case "$ref" in
        none-aspirational | "") return 0 ;;
        *@*:*)
            plugin="${ref%%@*}"
            owner="${ref#*@}"
            owner="${owner%%:*}"
            rest="${ref#*:}"
            base="$HOME/.claude/plugins/cache/$owner/$plugin"
            [ -d "$base" ] || return 0
            # newest installed version wins; a control in ANY installed version counts
            local v
            for v in $(ls -1 "$base" 2>/dev/null | sort -Vr); do
                [ -e "$base/$v/$rest" ] && { echo "$base/$v/$rest"; return 0; }
            done
            return 0
            ;;
        */*)
            [ -e "$ROOT/$ref" ] && echo "$ROOT/$ref"
            return 0
            ;;
        *)
            # bare name: a reviewer agent (`hygiene-reviewer`) or a script stem
            for base in "agents/$ref.md" "skills/$ref/SKILL.md" "scripts/$ref.sh" "$ref"; do
                [ -e "$ROOT/$base" ] && { echo "$ROOT/$base"; return 0; }
            done
            return 0
            ;;
    esac
}

# --- how is this control actually invoked? ------------------------------------
# AUTOMATED — named by a config the machine executes without an agent choosing to
#             (settings hooks, plugin hooks.json, pre-commit, CI workflow).
#             This is a preventive/detective control in the GRC sense.
# PROSE     — named only in an agent/skill/procedure doc: it fires when a model
#             decides to run it. Real, but discretionary — not a gate.
# SHELFWARE — on disk, nothing references it anywhere. Never fires.
invocation_of() {
    local path="$1" base
    base="$(basename "$path")"
    if grep -rqlF "$base" \
        "$ROOT"/settings.json "$ROOT"/settings.local.json \
        "$ROOT"/git-hooks/ "$ROOT"/.github/workflows/ \
        "$HOME"/.claude/plugins/cache/*/*/*/hooks/hooks.json \
        2>/dev/null; then
        echo AUTOMATED
    elif grep -rqlF "$base" \
        "$ROOT"/agents "$ROOT"/skills "$ROOT"/rules "$ROOT"/CLAUDE.md \
        "$ROOT"/references/procedures 2>/dev/null; then
        echo PROSE
    else
        echo SHELFWARE
    fi
}

fm_of() { sed -n '/^---$/,/^---$/p' "$1"; }
field() { fm_of "$1" | grep -m1 "^$2:" | sed "s/^$2:[[:space:]]*//"; }

# =============================================================================
# 1. OBLIGATIONS -> CONTROLS
# =============================================================================
declare -a NO_FIELD=() ASPIRATIONAL=() MISSING=() SHELFWARE=() PROSE=() AUTOMATED=()

scan_obligations() {
    local f id enf resolved
    for f in references/principles/*.md references/policies/*.md; do
        [ -f "$f" ] || continue
        case "$f" in */INDEX.md | */README.md) continue ;; esac
        id="$(field "$f" id)"
        [ -n "$id" ] || id="$f"
        enf="$(field "$f" enforced_by)"
        if [ -z "$enf" ]; then
            NO_FIELD+=("$id")
            continue
        fi
        if [ "$enf" = "none-aspirational" ]; then
            ASPIRATIONAL+=("$id")
            continue
        fi
        resolved="$(resolve_control "$enf")"
        if [ -z "$resolved" ]; then
            MISSING+=("$id -> $enf")
            continue
        fi
        case "$(invocation_of "$resolved")" in
            AUTOMATED) AUTOMATED+=("$id -> $enf") ;;
            PROSE) PROSE+=("$id -> $enf") ;;
            SHELFWARE) SHELFWARE+=("$id -> $enf") ;;
        esac
    done
}

# =============================================================================
# 2. RISKS -> TREATMENTS
# =============================================================================
# A failure-mode is treated when any record outside failure-modes/ names its id
# (in links.failure-modes, mitigates:, or inline prose citation).
declare -a UNTREATED=()
TREATED=0

scan_risks() {
    local f id hits
    for f in references/failure-modes/*.md; do
        [ -f "$f" ] || continue
        case "$f" in */INDEX.md | */README.md) continue ;; esac
        id="$(field "$f" id)"
        [ -n "$id" ] || continue
        hits="$(grep -rlF "$id" \
            references/procedures references/solutions references/principles \
            references/policies rules agents skills 2>/dev/null | head -1)"
        if [ -n "$hits" ]; then
            TREATED=$((TREATED + 1))
        else
            UNTREATED+=("$id")
        fi
    done
}

scan_obligations
scan_risks

TOTAL_OBL=$((${#NO_FIELD[@]} + ${#ASPIRATIONAL[@]} + ${#MISSING[@]} + ${#SHELFWARE[@]} + ${#PROSE[@]} + ${#AUTOMATED[@]}))
TOTAL_RISK=$((TREATED + ${#UNTREATED[@]}))

bold "CONTROL COVERAGE  ($TOTAL_OBL obligations, $TOTAL_RISK risks)"
printf '  AUTOMATED  (machine runs it)   %3d\n' "${#AUTOMATED[@]}"
printf '  PROSE      (agent may run it)  %3d\n' "${#PROSE[@]}"
printf '  SHELFWARE  (nothing calls it)  %3d\n' "${#SHELFWARE[@]}"
printf '  MISSING    (not on disk)       %3d\n' "${#MISSING[@]}"
printf '  ASPIRATIONAL (no mechanism)    %3d\n' "${#ASPIRATIONAL[@]}"
printf '  NO FIELD   (never declared)    %3d\n' "${#NO_FIELD[@]}"
printf '\n'
printf '  risks with a treatment       %3d\n' "$TREATED"
printf '  risks UNTREATED              %3d\n' "${#UNTREATED[@]}"

if [ "$MODE" = "summary" ]; then
    exit 0
fi

list() {
    local title="$1"
    shift
    [ "$#" -eq 0 ] && return 0
    printf '\n'
    bold "$title"
    printf '  %s\n' "$@"
}

list "MISSING — obligation names a control that is not on disk" "${MISSING[@]+"${MISSING[@]}"}"
list "SHELFWARE — control on disk, nothing anywhere calls it" "${SHELFWARE[@]+"${SHELFWARE[@]}"}"
list "PROSE-DISPATCHED — fires only if an agent chooses to run it" "${PROSE[@]+"${PROSE[@]}"}"
list "ASPIRATIONAL — rule with no mechanism (violated silently)" "${ASPIRATIONAL[@]+"${ASPIRATIONAL[@]}"}"
list "NO FIELD — obligation that never declared a control" "${NO_FIELD[@]+"${NO_FIELD[@]}"}"
list "UNTREATED RISKS — failure-mode nothing points back at" "${UNTREATED[@]+"${UNTREATED[@]}"}"

if [ "$MODE" = "strict" ] && [ "${#MISSING[@]}" -gt 0 ]; then
    printf '\n'
    bold "FAIL: ${#MISSING[@]} obligation(s) name a control that does not exist."
    exit 1
fi
exit 0
