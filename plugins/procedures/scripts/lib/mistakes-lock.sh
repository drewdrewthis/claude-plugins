#!/usr/bin/env bash
# mistakes-lock.sh — the one lock every writer of a root's mistakes.jsonl takes:
# log-record.sh's append and commit-records.sh's quarantine rewrite. Without it
# the rewrite (read, drop rows, write back) can lose an append made meanwhile.
#
# Source it, then:
#   mistakes_locked "$(mistakes_lock_path <dir-holding-mistakes.jsonl>)" <cmd> [args..]
#
# `flock` where it exists; else an atomic `mkdir <lock>.d`, as librarian-poke.sh
# does, for macOS/BSD. MISTAKES_NO_FLOCK=1 forces the fallback (tests).
# MISTAKES_LOCK_WAIT_SECS (default 30) bounds the wait.

# mistakes_lock_path <dir> — <git-dir>/mistakes.lock for the repo holding <dir>,
# else <dir>/.mistakes.lock outside a repo.
mistakes_lock_path() {
    local p
    if p="$(git -C "$1" rev-parse --git-path mistakes.lock 2>/dev/null)"; then
        case "$p" in /*) ;; *) p="$1/$p" ;; esac
    else
        p="$1/.mistakes.lock"
    fi
    printf '%s' "$p"
}

# mistakes_locked <lock> <cmd> [args..] — run <cmd> holding <lock>; its exit
# status, or 75 (EX_TEMPFAIL) when the lock stays held past the wait.
mistakes_locked() {
    local lock="$1" wait="${MISTAKES_LOCK_WAIT_SECS:-30}" tries=0 rc
    shift
    case "$wait" in ''|*[!0-9]*) wait=30 ;; esac
    if [ "${MISTAKES_NO_FLOCK:-0}" != "1" ] && command -v flock >/dev/null 2>&1; then
        { flock -w "$wait" 9 || return 75; "$@"; } 9>"$lock"
        return
    fi
    until mkdir "$lock.d" 2>/dev/null; do
        # The holder only appends or rewrites one small file; a dir older
        # than a minute is a crashed holder, so take it over.
        if [ -n "$(find "$lock.d" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
            rmdir "$lock.d" 2>/dev/null
            continue
        fi
        [ "$tries" -lt $(( wait * 10 )) ] || return 75
        tries=$(( tries + 1 ))
        sleep 0.1
    done
    "$@"; rc=$?
    rmdir "$lock.d" 2>/dev/null
    return "$rc"
}
