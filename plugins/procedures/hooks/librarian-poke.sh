#!/usr/bin/env bash
# librarian-poke.sh — Stop hook (async).
#
# SINGLE RESPONSIBILITY: once per qualifying turn, wake the librarian agent to
# drain whatever transcript backlog has built up. This hook decides WHEN to
# poke (cooldown, load gate) and owns the per-transcript cursors (advanced
# only after a clean wake); agents/librarian.md decides WHAT is worth
# extracting, and is safe to poke more often than it has new work.
#
# DIVERGES FROM evolve-sweep.sh ON PURPOSE: no per-turn classifier call, no
# digest of the final message, no asyncRewake wake-the-caller trick. The
# child spawns `claude -p --agent procedures:librarian` directly — a
# SEPARATE session that does its own work and exits — so there is nothing to
# hand back to the turn that triggered the poke. Registered async:true, no
# asyncRewake, no timeout: the parent returns as soon as the child is
# detached, same as worklog-record.sh's own (unregistered-async) hook entry.
#
# DETACHED, ALWAYS, same load-bearing shape as worklog-record.sh's wl_detach:
# redirecting the child's stdin/stdout/stderr off the inherited pipes is what
# lets the parent return immediately — a harness reading the hook's pipe
# blocks until it closes no matter that the process is detached. `setsid` is
# used when available and plain background `&` otherwise (confirmed both
# `setsid` and `flock`, below, are absent on macOS/BSD). LIBRARIAN_SYNC=1
# runs the worker inline instead, for tests.
#
# THE SETTLE SLEEP (LIBRARIAN_SETTLE_SECS, default 3): at Stop time the
# firing turn's final assistant record is not yet in its own transcript jsonl
# (worklog-record.sh measured this on 2.1.237). This hook does not read that
# transcript itself, but the librarian it wakes might drain this very session
# moments later, so the settle buys its cursor a finished record to read
# instead of a truncated one.
#
# SINGLE WRITER: every knowledge-store commit funnels through one librarian
# invocation at a time. `flock -n` is the preferred lock — a second
# concurrent poke exits silently, which is fine, since this fires on every
# qualifying turn and is at-least-once by design. Where `flock` is
# unavailable, an atomic `mkdir` claim with a stealable TTL
# (LIBRARIAN_CLAIM_TTL_SECS, default the runtime cap + 120s) stands in, mirroring
# worklog-record.sh's wl_claim/wl_marker_age exactly. LIBRARIAN_NO_FLOCK=1
# forces this fallback in tests regardless of what the host actually has.
#
# FAIL-OPEN on the gating half, same posture as every gate in this plugin: no
# jq, an unreadable lib, or an unwired reset hook releases via
# ge_release_or_failopen. The poke itself (the detached half) is best-effort
# and UNRECORDED on failure — no claude binary or a lost claim degrade
# silently (a nonzero `claude -p` exit logs one line: its lines are re-issued).
# A background knowledge-intake poke that occasionally no-ops costs nothing;
# recording every miss would grow the fail-open log one row per turn forever
# for a condition that is not one.

set -uo pipefail

# Resolve our own directory WITHOUT the external `dirname` binary: PATH is
# emptied entirely on the no-jq test path, and `${x%/*}` is parameter
# expansion, not a command lookup.
SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[ "$SCRIPT_DIR" = "${BASH_SOURCE[0]}" ] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "$SCRIPT_DIR" 2>/dev/null && pwd 2>/dev/null)" || exit 0
SELF="$SCRIPT_DIR/${BASH_SOURCE[0]##*/}"

# --- state dir --------------------------------------------------------------
# Per-machine librarian runtime state (lock, cursors, grooming queue) lives
# OUTSIDE the git-tracked corpus, on the XDG state-dir convention — see
# scripts/lib/stores.sh procedures_state_dir for the full why. Source it for
# the resolver; if the lib is unreadable, fall open to the same formula inline
# so a missing resolver never breaks the poke (this hook fails open).
# shellcheck source=../scripts/lib/stores.sh
. "$SCRIPT_DIR/../scripts/lib/stores.sh" 2>/dev/null || true
lp_state_dir() {
    if declare -F procedures_state_dir >/dev/null 2>&1; then
        procedures_state_dir
        return
    fi
    printf '%s' "${PROCEDURES_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/procedures/librarian}"
}

# lp_log <line> — append one timestamped line to the librarian-poke log in the
# state dir. Best-effort: an unwritable log never blocks the poke. The single
# writer for every log line below (defers, invalid-env warnings, timeouts).
lp_log() {
    local logf; logf="$(lp_state_dir)/librarian-poke.log"
    mkdir -p "${logf%/*}" 2>/dev/null || true
    printf '%s %s\n' "$(date -Is 2>/dev/null || true)" "${1:-}" >>"$logf" 2>/dev/null || true
}

# lp_num_or_default <name> <value> <default> <ere> — echo <value> when it
# matches the (anchored) ERE, else log one line and echo <default>. The value
# is passed in directly (not via ${!name}) so set -u never trips on an unset
# indirect target. Fixes the old `case ...|*[!0-9.]*)` guards, which only
# rejected a value that CONTAINED a bad char and so let `...` and `1.2.3` pass
# straight into a ceiling that then defers the drain forever, silently.
lp_num_or_default() {
    local name="$1" val="$2" def="$3" re="$4"
    if [[ "$val" =~ $re ]]; then
        printf '%s' "$val"
    else
        lp_log "librarian-poke: invalid $name=$val, using $def"
        printf '%s' "$def"
    fi
}

# --- tunables --------------------------------------------------------------
LIBRARIAN_SETTLE_SECS="${LIBRARIAN_SETTLE_SECS:-3}"
case "$LIBRARIAN_SETTLE_SECS" in ''|*[!0-9]*) LIBRARIAN_SETTLE_SECS=3 ;; esac

# Wall-clock cap on one drain; see LP_TIMEOUT below.
LIBRARIAN_MAX_RUNTIME_SEC="$(lp_num_or_default LIBRARIAN_MAX_RUNTIME_SEC "${LIBRARIAN_MAX_RUNTIME_SEC:-1800}" 1800 '^[0-9]+$')"

# The claim TTL must outlive a drain at its cap plus timeout's 60s kill-after,
# or a live drain's claim is stolen and two librarians write at once.
LP_TTL_DEFAULT=$(( LIBRARIAN_MAX_RUNTIME_SEC + 120 ))
LIBRARIAN_CLAIM_TTL_SECS="${LIBRARIAN_CLAIM_TTL_SECS:-$LP_TTL_DEFAULT}"
case "$LIBRARIAN_CLAIM_TTL_SECS" in ''|*[!0-9]*|0) LIBRARIAN_CLAIM_TTL_SECS=$LP_TTL_DEFAULT ;; esac

# LIBRARIAN_MIN_INTERVAL_SECS (default 1800, 0 disables) — minimum gap between
# the STARTS of two drains that ran claude, because every wake is a fresh
# session whose prompt is a cache write. A deferred poke loses nothing: the
# cursors stay put, so the next drain issues the whole backlog in one batch.
LIBRARIAN_MIN_INTERVAL_SECS="$(lp_num_or_default LIBRARIAN_MIN_INTERVAL_SECS "${LIBRARIAN_MIN_INTERVAL_SECS:-1800}" 1800 '^[0-9]+$')"

LIBRARIAN_LOCK="${LIBRARIAN_LOCK:-$(lp_state_dir)/librarian.lock}"
LIBRARIAN_LOCK_DIR="${LIBRARIAN_LOCK_DIR:-${LIBRARIAN_LOCK}.d}"

# --- load gate -------------------------------------------------------------
# PLUGIN ADAPTATION: the vendored upstream librarian-poke drains unconditionally.
# This plugin copy diverges by pressure-gating the drain (loadavg/iowait ceilings
# below, plus ionice/nice/timeout wrappers on the run) because on this always-on
# box the ungated find+wc corpus scan storms the shared host — 18:04Z 2026-09-06
# it drove load to 24 / iowait to 58%. The gate is fail-open by design so it can
# only ever postpone a drain, never lose one; see the ceilings and lp_load_ok.
# The drain scans the WHOLE transcript corpus. Ungated it storms the box:
# 18:04Z 2026-09-06 it drove load to 24 and iowait to 58% with D-state
# find+wc over ~/.claude/projects. Two defences, both at the point of action:
#   (a) run the drain at idle I/O + lowest CPU priority (ionice -c3 nice -n19),
#       so even when it does run it yields to real work — see LP_NICE below;
#   (b) refuse to start it at all when the box is already under pressure —
#       1-min loadavg over LIBRARIAN_LOAD_CEILING (default 8 = one core-worth
#       per core on this 8-core box), or iowait over LIBRARIAN_IOWAIT_CEILING
#       (default 30%) sampled over a ~1s /proc/stat window. On a defer the
#       poke exits 0 without draining; the next qualifying turn retries, so no
#       backlog is lost, only postponed until the box can afford it.
# Load is a decimal (loadavg), iowait an integer percent. Strict-validate
# both: anything not matching the anchored pattern falls back to the default
# AND logs, so a fat-fingered ceiling can never silently coerce the drain into
# deferring forever.
LIBRARIAN_LOAD_CEILING="$(lp_num_or_default LIBRARIAN_LOAD_CEILING "${LIBRARIAN_LOAD_CEILING:-8}" 8 '^[0-9]+([.][0-9]+)?$')"
LIBRARIAN_IOWAIT_CEILING="$(lp_num_or_default LIBRARIAN_IOWAIT_CEILING "${LIBRARIAN_IOWAIT_CEILING:-30}" 30 '^[0-9]+$')"

# lp_log_defer <reason> — append one line to the librarian-poke log in the
# state dir. Best-effort: an unwritable log never blocks the poke.
lp_log_defer() {
    lp_log "librarian-poke: deferred, ${1:-}"
}

# lp_iowait_pct — iowait % over a ~1s window from /proc/stat cpu-line deltas,
# or empty when unreadable. Fields on the aggregate 'cpu ' line (awk-indexed):
# $2 user $3 nice $4 system $5 idle $6 iowait $7 irq $8 softirq $9 steal.
# PLUGIN ADAPTATION: LP_STAT_FILE (a test-injection seam, default /proc/stat)
# lets a test point both samples at a fixture instead of the real kernel
# counter; LP_STAT_SAMPLE_SLEEP lets a test swap the fixture file BETWEEN the
# two samples (e.g. `cp fixture2 "$LP_STAT_FILE"`) instead of sleeping 1s
# against a live, unrepeatable counter. Unset, both default to today's exact
# production behaviour: read /proc/stat, sleep 1, read /proc/stat again.
lp_iowait_pct() {
    local i1 t1 i2 t2 di dt
    read -r i1 t1 < <(awk '/^cpu /{print $6, ($2+$3+$4+$5+$6+$7+$8+$9); exit}' "${LP_STAT_FILE:-/proc/stat}" 2>/dev/null)
    [ -n "${i1:-}" ] && [ -n "${t1:-}" ] || return 1
    if [ -n "${LP_STAT_SAMPLE_SLEEP:-}" ]; then
        eval "$LP_STAT_SAMPLE_SLEEP" 2>/dev/null || true
    else
        sleep 1 2>/dev/null || true
    fi
    read -r i2 t2 < <(awk '/^cpu /{print $6, ($2+$3+$4+$5+$6+$7+$8+$9); exit}' "${LP_STAT_FILE:-/proc/stat}" 2>/dev/null)
    [ -n "${i2:-}" ] && [ -n "${t2:-}" ] || return 1
    di=$(( i2 - i1 )); dt=$(( t2 - t1 ))
    [ "$dt" -gt 0 ] 2>/dev/null || return 1
    printf '%s' "$(( di * 100 / dt ))"
}

# lp_log_failopen <signal> — record a blind fail-open: a pressure signal was
# unreadable (empty /proc read), so the gate RELEASES rather than blocks — an
# unreadable /proc must never wedge the drain shut. Distinct message from
# lp_log_defer (which records an intentional over-ceiling defer) so a silently
# degraded gate is visible in the log. Best-effort: an unwritable log never
# blocks the poke.
lp_log_failopen() {
    lp_log "librarian-poke: fail-open, ${1:-} unreadable — proceeding without that signal"
}

# lp_load_ok — 0 to proceed with the drain, 1 to defer (and log the reason).
# Fail-open: an unreadable /proc never blocks the drain — but every blind
# release is logged (lp_log_failopen), so a gate degraded to always-open is
# not silent.
# PLUGIN ADAPTATION: LP_LOADAVG_FILE (a test-injection seam, default
# /proc/loadavg) lets a test point this at a fixture file instead of the real
# kernel counter. Unset, behaviour is byte-identical to today: read
# /proc/loadavg.
lp_load_ok() {
    local l iw
    l="$(awk '{print $1}' "${LP_LOADAVG_FILE:-/proc/loadavg}" 2>/dev/null)"
    if [ -n "$l" ]; then
        if awk -v x="$l" -v y="$LIBRARIAN_LOAD_CEILING" 'BEGIN{exit !(x+0>y+0)}'; then
            lp_log_defer "load=$l > ceiling=$LIBRARIAN_LOAD_CEILING"
            return 1
        fi
    else
        lp_log_failopen "loadavg"
    fi
    iw="$(lp_iowait_pct)" || iw=""
    if [ -n "$iw" ]; then
        if [ "$iw" -gt "$LIBRARIAN_IOWAIT_CEILING" ] 2>/dev/null; then
            lp_log_defer "iowait=${iw}% > ceiling=${LIBRARIAN_IOWAIT_CEILING}%"
            return 1
        fi
    else
        lp_log_failopen "iowait"
    fi
    return 0
}

# LP_NICE — idle-I/O + lowest-CPU launch prefix for the drain. Each half is
# guarded: ionice/nice are absent on macOS/BSD, so a missing binary drops out
# of the prefix rather than aborting the poke. ionice class idle (-c3) and the
# nice value are inherited by the claude child's own find/wc/grep subprocesses.
LP_NICE=""
command -v ionice >/dev/null 2>&1 && LP_NICE="ionice -c3"
command -v nice   >/dev/null 2>&1 && LP_NICE="${LP_NICE:+$LP_NICE }nice -n19"

# LP_TIMEOUT — a wall-clock cap on the drain. Under `ionice -c3` (idle I/O)
# the drain can be starved indefinitely on a busy box while it still HOLDS the
# single-writer lock, so every later poke finds the lock taken and no drain
# ever runs again. Bounding the run at LIBRARIAN_MAX_RUNTIME_SEC (default 30m)
# guarantees the lock is released: a starved drain is TERMed, KILLed 60s later
# if it ignores that, and the next qualifying turn retries. Guarded on the
# binary — `timeout` is absent on macOS/BSD, where it simply drops out of the
# prefix (the drain then runs unbounded, exactly as it does today).
LP_TIMEOUT=""
command -v timeout >/dev/null 2>&1 && \
    LP_TIMEOUT="timeout --signal=TERM --kill-after=60 $LIBRARIAN_MAX_RUNTIME_SEC"

# lp_note_timeout <rc> — log one line, and return 0, when the drain was killed
# by the runtime cap. `timeout` exits 124 on TERM, or 137 (128+SIGKILL) when
# it had to escalate. The lock is released by the caller either way; any other
# exit returns 1 and logs nothing.
lp_note_timeout() {
    [ -n "$LP_TIMEOUT" ] || return 1
    case "${1:-0}" in
        124|137)
            lp_log "librarian-poke: drain exceeded ${LIBRARIAN_MAX_RUNTIME_SEC}s cap, killed; cursors not advanced, lock released for retry"
            return 0 ;;
    esac
    return 1
}

# lp_cooled_down [quiet] — 0 when no drain started within
# LIBRARIAN_MIN_INTERVAL_SECS, 1 otherwise (logged unless quiet: the gating
# half checks every turn, and one log line per turn is noise). An absent or
# unreadable stamp never blocks a drain.
lp_cooled_down() {
    [ "$LIBRARIAN_MIN_INTERVAL_SECS" -gt 0 ] || return 0
    local last now
    last="$(tr -dc '0-9' < "$(lp_state_dir)/last-drain-start" 2>/dev/null)"
    now="$(date +%s 2>/dev/null)"
    [ -n "$last" ] && [ -n "$now" ] || return 0
    # A stamp in the future (clock change, bad write) must not block forever.
    [ "$last" -le "$now" ] || return 0
    if [ $(( now - last )) -lt "$LIBRARIAN_MIN_INTERVAL_SECS" ]; then
        [ "${1:-}" = quiet ] \
            || lp_log_defer "cooldown, last drain started $(( now - last ))s ago < ${LIBRARIAN_MIN_INTERVAL_SECS}s"
        return 1
    fi
    return 0
}

# lp_advance_issued <manifest> — move every cursor the manifest issued to its
# issued end, through librarian-advance.sh (the one place cursor rules live).
# The hook does this, not the model, because model-run advances went wrong.
lp_advance_issued() {
    local slug end out
    while IFS=$'\t' read -r slug _ end; do
        [ -n "$slug" ] || continue
        out="$(bash "$SCRIPT_DIR/../scripts/librarian-advance.sh" "$slug" "$end" 2>&1)" \
            || lp_log "librarian-poke: advance refused: $(printf '%s' "$out" | tr '\n' ' ')"
    done < "$1"
}

# lp_store_status — "<root><TAB><XY> <path><TAB><content hash>" for every
# dirty path in each configured store root (stores.sh STORE_ROOTS); nothing
# when none resolve. The hash catches a path that was already dirty and was
# written again: its status alone would not change. -z keeps paths unquoted
# (a quoted "b c" would not hash); a rename record is "XY new\0old\0".
lp_store_status() {
    declare -p STORE_ROOTS >/dev/null 2>&1 || return 0
    local r rec old p h
    for r in ${STORE_ROOTS[@]+"${STORE_ROOTS[@]}"}; do
        git -C "$r" status --porcelain -z -uall 2>/dev/null | while IFS= read -r -d '' rec; do
            case "$rec" in [RC]?\ * | ?[RC]\ *) IFS= read -r -d '' old ;; esac
            p="${rec:3}"
            h="$(git -C "$r" hash-object -- "$p" 2>/dev/null)" || h="-"
            printf '%s\t%s\t%s\n' "$r" "${rec//$'\n'/?}" "$h"
        done
    done
}

# lp_note_store_writes <before> — log one line per store root that has dirty
# paths now that it did not have in <before> (a sorted lp_store_status
# snapshot): the wake wrote there but the commit gate did not commit it.
lp_note_store_writes() {
    local n r
    lp_store_status | LC_ALL=C sort | LC_ALL=C comm -13 "$1" - | cut -f1 | uniq -c \
        | while read -r n r; do
            lp_log "librarian-poke: wake left uncommitted store writes in $r: $n paths"
        done
}

# --- the poke, and its portable claim fallback ------------------------------

# lp_marker_age <dir> — seconds since the claim dir was created, or nonzero
# (undeterminable) when it cannot be. Mirrors worklog-record.sh's
# wl_marker_age: an undeterminable age is NOT treated as old, so a blind
# steal cannot race a live holder.
lp_marker_age() {
    local m="${1:-}" mt now
    mt="$(stat -c %Y "$m" 2>/dev/null || date -r "$m" +%s 2>/dev/null || true)"
    now="$(date +%s 2>/dev/null || true)"
    case "$mt"  in ''|*[!0-9]*) return 1 ;; esac
    case "$now" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s' "$(( now - mt ))"
}

# lp_claim — 0 when this fire may run the librarian, 1 when a concurrent fire
# (or one still inside its TTL) already holds the claim. `mkdir` is atomic on
# POSIX, so the check and the take are one syscall. An environmental failure
# to create it fails OPEN, same as worklog's wl_claim — a possible duplicate
# poke beats one permanently suppressed.
lp_claim() {
    mkdir -p "${LIBRARIAN_LOCK_DIR%/*}" 2>/dev/null || return 0
    if mkdir "$LIBRARIAN_LOCK_DIR" 2>/dev/null; then return 0; fi
    [ -d "$LIBRARIAN_LOCK_DIR" ] || return 0
    local age
    age="$(lp_marker_age "$LIBRARIAN_LOCK_DIR")" || return 1
    [ -n "$age" ] || return 1
    [ "$age" -gt "$LIBRARIAN_CLAIM_TTL_SECS" ] 2>/dev/null || return 1
    rmdir "$LIBRARIAN_LOCK_DIR" 2>/dev/null || return 1
    mkdir "$LIBRARIAN_LOCK_DIR" 2>/dev/null || return 1
    return 0
}

# lp_access_args <state-dir> — print the drain's permission flags, one argv
# word per line, for lp_drain to read into an array.
# PLUGIN ADAPTATION: the vendored upstream launches with --permission-mode
# auto. Headless, auto mode is not always available (it needs a supported
# model and server-side availability; when it is missing the session starts
# in Manual), and in Manual every Bash call and every read outside the cwd is
# denied because nobody is there to approve it. dontAsk plus this allowlist
# behaves the same every time. Transcripts are untrusted input, so the list
# is scoped to the agent's own commands rather than bypassPermissions:
#   - --add-dir: reads of the state dir, this plugin, the transcripts, and each
#     store root. Without it a read outside the cwd is denied.
#   - Edit: the commit-gate tmp dir, the grooming queue, and per root only the
#     record .md files the librarian writes (agents/librarian.md step 4): one
#     level of *.md in decisions/, solutions/, failure-modes/, policies/ and
#     standards/, and procedures/**/*.md (PROCEDURE.md and its EVOLUTION.md).
#     Everything else under a root is unwritable: its scripts/ and git-hooks/
#     (the commit gate runs them), and every non-.md file, since dontAsk
#     denies whatever no allow rule matches. .git is a protected path.
#   - --disallowedTools: deny wins over allow, so these hold even if an allow
#     rule above is widened later. Per records dir: any scripts/ dir at any
#     depth (procedures ship executable helpers there), invariants/ and
#     common-mistakes.md (a user CLAUDE.md can @-import them into every
#     session), and the script and config extensions in LP_DENY_EXTS. A rule
#     cannot say "not .md" (a [!x] bracket is not a negation in these rules),
#     so other non-.md files rely on the allow list's default deny.
#   - Bash: the state-dir lookup, and log-record.sh and commit-records.sh with
#     each root's literal CODEX_ROOT= prefix; commit-records.sh also has its
#     `--root '<root>'` pinned right after the script. A rule matches the
#     command text as written, so each quoting the agent doc uses gets its own
#     rule. An allow rule does not match past an unknown variable assignment,
#     and a wildcard in place of the root would also match
#     `CODEX_ROOT=x <any program> ...`. The trailing `*` stays open, so each
#     script validates its own arguments: log-record.sh refuses a slug or date
#     that could leave the records dir, and commit-records.sh refuses a --root
#     other than $CODEX_ROOT (or a second --root).
#   - No mkdir and no rm: Write creates the tmp dir's parents itself, and the
#     poke removes <state-dir>/tmp/commit-* after the drain (lp_clean_tmp).
# Record kinds the librarian writes one level deep, and extensions denied
# under every records dir.
LP_EDIT_KINDS="decisions solutions failure-modes policies standards"
LP_DENY_EXTS="sh bash zsh py js mjs cjs ts rb pl json jsonl yml yaml toml"
lp_access_args() {
    local sd="$1" pr r q q2 e rd k roots=()
    pr="$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd)" || return 0
    declare -p STORE_ROOTS >/dev/null 2>&1 && roots=(${STORE_ROOTS[@]+"${STORE_ROOTS[@]}"})
    printf '%s\n' --permission-mode dontAsk --add-dir "$sd" --add-dir "$pr" \
        --add-dir "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
    for r in ${roots[@]+"${roots[@]}"}; do printf '%s\n' --add-dir "$r"; done
    printf '%s\n' --allowedTools \
        "Bash(bash -c 'source \"$pr/scripts/lib/stores.sh\" && procedures_state_dir')" \
        "Edit(/$sd/tmp/**)" "Edit(/$sd/grooming-queue.md)"
    for r in ${roots[@]+"${roots[@]}"}; do
        rd="$(stores_records_dir "$r")"
        case "$rd" in /*) ;; *) rd="$r/$rd" ;; esac
        for k in $LP_EDIT_KINDS; do printf '%s\n' "Edit(/$rd/$k/*.md)"; done
        printf '%s\n' "Edit(/$rd/procedures/**/*.md)"
        for q in '' "'" '"'; do
            for e in "CODEX_ROOT=$q$r$q" "CODEX_ROOT=$q$r$q MISTAKES_JSONL=$q$r/mistakes.jsonl$q"; do
                printf '%s\n' "Bash($e bash $pr/scripts/log-record.sh *)" \
                    "Bash($e bash \"$pr/scripts/log-record.sh\" *)"
                for q2 in '' "'" '"'; do
                    printf '%s\n' "Bash($e bash $pr/scripts/commit-records.sh --root $q2$r$q2 *)" \
                        "Bash($e bash \"$pr/scripts/commit-records.sh\" --root $q2$r$q2 *)"
                done
            done
        done
    done
    printf '%s\n' --disallowedTools
    for r in ${roots[@]+"${roots[@]}"}; do
        rd="$(stores_records_dir "$r")"
        case "$rd" in /*) ;; *) rd="$r/$rd" ;; esac
        printf '%s\n' "Edit(/$rd/**/scripts/**)" "Edit(/$rd/invariants/**)" \
            "Edit(/$rd/common-mistakes.md)"
        for k in $LP_DENY_EXTS; do printf '%s\n' "Edit(/$rd/**/*.$k)"; done
    done
}

# lp_clean_tmp <state-dir> — remove the commit gate's metadata dirs
# (<state-dir>/tmp/commit-*) once the drain returns, whatever its exit. The
# agent has no rm rule, so the cleanup is the poke's. Nothing outside
# <state-dir>/tmp/ is touched; a symlink is removed as a link, not followed.
lp_clean_tmp() {
    local d
    [ -n "$1" ] && [ -d "$1/tmp" ] || return 0
    for d in "$1"/tmp/commit-*; do
        [ -e "$d" ] || [ -L "$d" ] || continue
        rm -rf -- "$d" 2>/dev/null || lp_log "librarian-poke: could not remove $d"
    done
}

# lp_drain — under the claim: issue this drain's batch, then run the librarian
# only when the batch issued something. The poke, not the agent, runs
# librarian-batch.sh, so the agent cannot re-issue itself a bigger batch; an
# empty manifest (or a failed batch, which leaves none) spends no tokens.
# Exit 0 means the batch counts as read (agents/librarian.md step 7), so only
# then are the cursors advanced; a crash or timeout leaves them, and the next
# drain re-issues the same lines (at-least-once).
lp_drain() {
    local out rc=0 st manifest issued
    lp_cooled_down || return 0
    # No store roots means no write rule at all: the drain would exit 0 having
    # written nothing, the cursors would advance, and the batch would be lost.
    # Skip before issuing anything, so the lines wait for a configured root.
    if ! declare -p STORE_ROOTS >/dev/null 2>&1 || [ "${#STORE_ROOTS[@]}" -eq 0 ]; then
        lp_log "librarian-poke: no store roots resolved, drain skipped; lines kept for the next drain"
        return 0
    fi
    if ! out="$(bash "$SCRIPT_DIR/../scripts/librarian-batch.sh" 2>&1)"; then
        lp_log "librarian-poke: batch failed, drain skipped: $(printf '%s' "$out" | tr '\n' ' ')"
        return 0
    fi
    # A transcript the batch had to skip is reported even when the batch succeeded.
    local line
    while IFS= read -r line; do
        case "$line" in "librarian-batch: skipped "*) lp_log "librarian-poke: $line" ;; esac
    done <<< "$out"
    st="$(lp_state_dir)"; manifest="$st/batch.manifest"
    issued="$manifest.issued"
    [ -s "$manifest" ] || return 0
    # Advance from what was ISSUED: a manifest rewritten during the wake
    # describes lines the model was never handed.
    cp "$manifest" "$issued" 2>/dev/null \
        || { lp_log "librarian-poke: cannot snapshot the manifest, drain skipped"; return 0; }
    lp_store_status | LC_ALL=C sort > "$st/store-status.before" 2>/dev/null || true
    date +%s > "$st/last-drain-start" 2>/dev/null || true
    local access=() word roots
    # A read loop, not mapfile: macOS ships bash 3.2.
    while IFS= read -r word; do access+=("$word"); done < <(lp_access_args "$st")
    roots="$(IFS=:; printf '%s' "${STORE_ROOTS[*]-}")"
    # The roots and state dir go in the prompt and env, so the agent never
    # has to list a parent dir that is outside its allowed reads.
    # log-record.sh appends a mistake to $HOME/.claude/mistakes.jsonl when
    # MISTAKES_JSONL is unset, which is outside every store root. Default it to
    # the first root's mistakes.jsonl, the file the commit gate commits; the
    # agent doc still passes MISTAKES_JSONL=<root>/mistakes.jsonl per call, and
    # that inline value wins for any other root.
    CODEX_STORE_ROOTS="$roots" MISTAKES_JSONL="${STORE_ROOTS[0]}/mistakes.jsonl" \
        $LP_TIMEOUT $LP_NICE claude -p "${access[@]}" --agent procedures:librarian \
        "Drain the transcript queue. State dir: $st. Store roots (CODEX_STORE_ROOTS): $roots." || rc=$?
    lp_clean_tmp "$st"
    # Cursors still advance past a gate block: re-issuing would loop on a
    # persistent block, and the gate already queued its reason.
    lp_note_store_writes "$st/store-status.before"
    if [ "$rc" -ne 0 ]; then
        lp_note_timeout "$rc" \
            || lp_log "librarian-poke: drain exited $rc, cursors not advanced; lines re-issued next drain"
        return 0
    fi
    if ! cmp -s "$manifest" "$issued"; then
        lp_log "librarian-poke: manifest changed during drain, not advancing"
        return 0
    fi
    lp_advance_issued "$issued"
}

# lp_worker — settle, then run the librarian under a single-writer claim.
# Everything past the settle is best-effort: no claude binary or a lost claim
# degrade silently.
lp_worker() {
    sleep "$LIBRARIAN_SETTLE_SECS" 2>/dev/null || true
    command -v claude >/dev/null 2>&1 || return 0

    # Load gate: read pressure fresh, immediately before draining. Over the
    # ceiling => defer (logged) and exit without touching the corpus. The next
    # qualifying turn pokes again, so nothing is dropped, only postponed.
    lp_load_ok || return 0

    # LIBRARIAN_NO_FLOCK=1 forces the mkdir fallback below even when a real
    # flock is on PATH — test-only, so "second concurrent claim loses" is
    # deterministic on any host rather than depending on this machine's own
    # tool availability (mirrors LIBRARIAN_SYNC's precedent).
    if [ "${LIBRARIAN_NO_FLOCK:-0}" != "1" ] && command -v flock >/dev/null 2>&1; then
        ( flock -n 9 || exit 0; lp_drain ) 9>"$LIBRARIAN_LOCK" 2>/dev/null || true
        return 0
    fi

    # Portable fallback (flock is absent on macOS/BSD): the same atomic
    # mkdir claim worklog-record.sh uses, TTL-stealable, released on exit via
    # trap so a crash does not wedge every future poke shut.
    if lp_claim; then
        trap 'rmdir "$LIBRARIAN_LOCK_DIR" 2>/dev/null || true' EXIT
        lp_drain
        rmdir "$LIBRARIAN_LOCK_DIR" 2>/dev/null || true
        trap - EXIT
    fi
    return 0
}

# --- one-time state migration ----------------------------------------------
# Move librarian runtime state (cursors, grooming queue) out of the git-tracked
# ~/.claude repo, AND the how-do-i index cache out of ~/.cache, into the
# resolved state dir ($(lp_state_dir) — ~/.knowledge/state when the knowledge
# home exists, else the XDG state dir). Runs on EVERY invocation (both the
# gating call and the --worker re-entry) — the checks are cheap and each move
# is idempotent: once the new location is populated that block no-ops. FAIL-
# OPEN, mv-ONLY (never rm): nothing is deleted, every step is guarded so a
# failure never blocks the poke, and a marker is left in each OLD location
# pointing at the new one. It only ever touches the OLD ~/.claude/librarian/*
# and ~/.cache/how-do-i-index locations — never modules/ or anything else under
# $KNOWLEDGE_HOME, which are git clones that must not be auto-moved.
lp_migrate_legacy_state() {
    local legacy="$HOME/.claude/librarian"
    local legacy_cursors="$legacy/cursors"
    local legacy_queue="$legacy/grooming-queue.md"
    local state new_cursors
    state="$(lp_state_dir)"
    new_cursors="$state/cursors"

    # Cursors: move only when legacy has files AND the new dir is not already
    # populated (absent or empty) — so a machine already migrated is a no-op.
    if [ -d "$legacy_cursors" ] && [ -n "$(ls -A "$legacy_cursors" 2>/dev/null)" ]; then
        if [ ! -d "$new_cursors" ] || [ -z "$(ls -A "$new_cursors" 2>/dev/null)" ]; then
            if mkdir -p "$new_cursors" 2>/dev/null; then
                mv "$legacy_cursors"/* "$new_cursors"/ 2>/dev/null || true
                # Filename can't hold slashes, so the sanitized path names the
                # marker and the literal path is its contents — a human/agent
                # looking in the old dir sees exactly where the state went.
                printf 'librarian state moved to: %s\n' "$state" \
                    > "$legacy/MIGRATED-to-${state//\//-}" 2>/dev/null || true
            fi
        fi
    fi

    # Grooming queue: move only if the new one does not already exist.
    if [ -f "$legacy_queue" ] && [ ! -f "$state/grooming-queue.md" ]; then
        mkdir -p "$state" 2>/dev/null || true
        mv "$legacy_queue" "$state/grooming-queue.md" 2>/dev/null || true
    fi

    # How-do-i index cache: same guard shape as cursors above — move the
    # CONTENTS (never the dir) only when the legacy dir has files AND the new
    # one is absent-or-empty, so a machine already migrated is a no-op. The
    # index moved off ~/.cache onto the state dir so a single location holds
    # ALL per-machine librarian runtime state.
    local legacy_index new_index
    legacy_index="${XDG_CACHE_HOME:-$HOME/.cache}/how-do-i-index"
    new_index="$state/how-do-i-index"
    if [ -d "$legacy_index" ] && [ -n "$(ls -A "$legacy_index" 2>/dev/null)" ]; then
        if [ ! -d "$new_index" ] || [ -z "$(ls -A "$new_index" 2>/dev/null)" ]; then
            if mkdir -p "$new_index" 2>/dev/null; then
                mv "$legacy_index"/* "$new_index"/ 2>/dev/null || true
                printf 'how-do-i index moved to: %s\n' "$new_index" \
                    > "$legacy_index/MIGRATED-to-${new_index//\//-}" 2>/dev/null || true
            fi
        fi
    fi
    return 0
}
lp_migrate_legacy_state

# --- worker re-entry ---------------------------------------------------
# The detached child calls back into this same script with --worker, stdin
# on /dev/null. Handled first, before any Stop-event gating below — none of
# it applies to the worker, which only sleeps and pokes.
if [ "${1:-}" = "--worker" ]; then
    lp_worker
    exit 0
fi

# --- gating: same shape as evolve-sweep.sh's preamble -----------------------
INPUT="$(cat 2>/dev/null || true)"

# shellcheck source=lib/gate-escape.sh
. "$SCRIPT_DIR/lib/gate-escape.sh" 2>/dev/null || true
# shellcheck source=lib/gate-failopen.sh
. "$SCRIPT_DIR/lib/gate-failopen.sh" 2>/dev/null || exit 0

command -v jq >/dev/null 2>&1 || ge_release_or_failopen "LIBRARIAN" "librarian-poke" "no-jq"

# Not a Stop event => not ours. A legitimate release, not blindness.
[ "$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)" = "Stop" ] || exit 0

# Ephemeral one-shot (claude --print / SDK): no session to settle into.
case "${CLAUDE_CODE_ENTRYPOINT:-}" in sdk-cli) exit 0 ;; esac

# shellcheck source=lib/turn-state.sh
. "$SCRIPT_DIR/lib/turn-state.sh" 2>/dev/null || ge_release_or_failopen "LIBRARIAN" "librarian-poke" "lib-unreadable:turn-state"
# shellcheck source=lib/gate-audience.sh
. "$SCRIPT_DIR/lib/gate-audience.sh" 2>/dev/null || ge_release_or_failopen "LIBRARIAN" "librarian-poke" "lib-unreadable:gate-audience"
# shellcheck source=lib/turn-activity.sh
. "$SCRIPT_DIR/lib/turn-activity.sh" 2>/dev/null || ge_release_or_failopen "LIBRARIAN" "librarian-poke" "lib-unreadable:turn-activity"

# Not our audience (subagent, or a non-main agent) => legitimate release.
ga_binds_main "$INPUT" || exit 0

SID="$(ts_session_id "$INPUT")"
# No .turn marker => the reset hook never ran => unwired, not clear.
ts_turn_started "$SID" || ge_release_or_failopen "LIBRARIAN" "librarian-poke" "reset-hook-never-ran" "$SID"

# Already poked this turn => release. The only same-turn guard, same as
# evolve-sweep: no stop_hook_active check either.
ts_is_marked "$SID" librarian_poked && exit 0

# No tool use => nothing this turn adds to any queue. Could not tell =>
# silent release: a poke's blindness costs nothing, unlike a gate's.
ta_turn_used_tools "$SID"
case "$?" in
    0) ;;
    *) exit 0 ;;
esac

# Off-switch asked at the point of action, like the gates: an escape record
# means "a poke was released", not "a process started".
if declare -F ge_enabled >/dev/null 2>&1 && ! ge_enabled "LIBRARIAN"; then exit 0; fi

# Mark BEFORE dispatch, same reasoning as evolve-sweep's marker: it is what
# serializes overlapping Stops for this turn, not stop_hook_active.
ts_mark "$SID" librarian_poked

# Cheap pre-check of the worker's cooldown, so a deferred turn spawns nothing.
# The worker re-checks under the lock, where the answer is authoritative.
lp_cooled_down quiet || exit 0

# --- dispatch ----------------------------------------------------------
if [ "${LIBRARIAN_SYNC:-0}" = "1" ]; then
    lp_worker
    exit 0
fi
if command -v setsid >/dev/null 2>&1; then
    setsid bash "$SELF" --worker </dev/null >/dev/null 2>&1 &
else
    bash "$SELF" --worker </dev/null >/dev/null 2>&1 &
fi
disown 2>/dev/null || true
exit 0
