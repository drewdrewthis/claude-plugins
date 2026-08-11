#!/usr/bin/env bash
# readonly-shape.sh — is a shell command line a pure LOOK, or does it ACT?
#
# SINGLE RESPONSIBILITY: classify one Bash command line as read-only or not.
# Policy about which gate honours that answer lives in gate-allowlist.sh.
#
# WHY A CLASSIFIER AND NOT A PATH TEST: the gates promise that read-only
# inspection stays available, so the question a gate needs answered is "does
# this MUTATE?" — not "which directory does it name?". Keying on a discovery
# path denied `tmux capture-pane | grep | tail` and `wc -l < f`, which are
# looks, while a path substring is no evidence of read-onlyness at all
# (`rm -rf references/procedures/` contains one).
#
# THE SHAPE OF THE ANSWER: separators (`;` `&&` `||` `|` `&`) are not the
# danger — what they RUN is. So every separator is split on and EVERY resulting
# segment must be a known-read-only invocation. A separator that is really
# inside quotes splits a segment badly, which yields an unrecognised command
# and a deny: quoting can only ever cost an allow, never buy one.
#
# FAILS CLOSED. A shape this cannot judge confidently is NOT read-only. The
# cost of a false deny is one `Skill(how-do-i)` call; the cost of a false allow
# is an unenforced invariant. Hence an ALLOWLIST of commands with no write
# mode, guarded by an up-front rejection of the constructs that hide a command
# from the segment scan entirely: command substitution (`$(…)`, backticks),
# process substitution (`<(…)`), and output redirection to a file. Interpreters
# — python, perl, node, awk, sh — are deliberately absent: an arbitrary program
# is precisely the thing that cannot be judged without running it.

set -uo pipefail

# ros__nth_nonflag <n> <words…> — prints the Nth argument not starting with `-`.
# Used to reach a subcommand past global flags (`git -C x status`, `systemctl
# --user status`). A flag taking a SEPARATE value (`tmux -f FILE cmd`) yields
# the value instead of the subcommand and therefore fails closed.
ros__nth_nonflag() {
    local want="${1:-1}" seen=0 w
    shift
    for w in "$@"; do
        case "$w" in
            -*) ;;
            *)
                seen=$((seen + 1))
                if [ "$seen" -eq "$want" ]; then printf '%s' "$w"; return 0; fi
                ;;
        esac
    done
    return 1
}

# ros__git_is_read_only <args-after-git…>
ros__git_is_read_only() {
    local sub a
    # Options that make an otherwise-read-only subcommand execute an external
    # program: `grep -O<pager>`/`--open-files-in-pager`, `diff --ext-diff`,
    # and `--config-env` (injects config such as core.pager from env). Rejected
    # before the subcommand allowlist. Attached `-c<k>=<v>` is invalid git
    # syntax, and separate `-c <k>=<v>` already fails closed: its value word
    # becomes the "subcommand" and misses the allowlist.
    for a in "$@"; do
        case "$a" in
            -O*|--open-files-in-pager*|--ext-diff|--config-env*) return 1 ;;
        esac
    done
    sub="$(ros__nth_nonflag 1 "$@")"
    case "$sub" in
        status|log|show|diff|blame|describe|shortlog|rev-parse|rev-list|\
        ls-files|ls-tree|cat-file|show-ref|whatchanged|grep)
            return 0 ;;
        worktree)
            # `worktree add/remove/prune` all mutate; only `list` reports.
            [ "$(ros__nth_nonflag 2 "$@")" = "list" ] && return 0
            return 1 ;;
        branch|remote|tag|config|stash)
            # Bare, these list. Given an operand they create, delete, rename or
            # set — so any second non-flag word, or any write flag, is an act.
            # (`git stash` with no operand PUSHES a stash, so it is excluded
            # from the bare-listing allowance below by the flag scan alone —
            # it is listed here only to reach that scan, and `stash list` is
            # caught by the second-operand rule. Both end in a deny.)
            case "$sub" in stash) return 1 ;; esac
            ros__nth_nonflag 2 "$@" >/dev/null 2>&1 && return 1
            for a in "$@"; do
                case "$a" in
                    -d|-D|-m|-M|-c|-C|-f|-u|--delete*|--move*|--copy*|--force|\
                    --set-upstream*|--unset*|--add|--prune|--edit-description|\
                    --replace-all|--rename-section|--remove-section)
                        return 1 ;;
                esac
            done
            return 0 ;;
    esac
    return 1
}

# ros__stage_is_read_only <segment> — 0 when this single invocation cannot write.
ros__stage_is_read_only() {
    local stage="${1:-}"
    # `<` only ever reads its operand, so drop it and judge the words. Output
    # redirection never reaches here — ros_is_read_only rejects it up front.
    stage="${stage//</ }"

    local restore_glob=0
    case $- in *f*) : ;; *) restore_glob=1 ;; esac
    set -f
    local IFS=$' \t\n'
    # shellcheck disable=SC2086 # deliberate: split the segment into words.
    set -- $stage
    [ "$restore_glob" -eq 1 ] && set +f

    # An empty segment is a separator artefact (`ls;`), not a command.
    [ "$#" -gt 0 ] || return 0

    local bin="${1##*/}"
    shift
    # `FOO=bar cmd` — the real command is a word we have not vetted.
    case "$bin" in *=*) return 1 ;; esac

    local a
    case "$bin" in
        # No write mode, whatever the arguments. `cd` changes only this shell's
        # own working directory, which no file outlives. (`ip` is deliberately
        # absent: `ip link set`/`addr add`/`route del` mutate network state.)
        cat|head|tail|nl|wc|cut|tr|rev|column|comm|diff|cmp|\
        basename|dirname|realpath|readlink|echo|printf|pwd|cd|whoami|\
        hostname|uname|id|stat|file|du|df|free|uptime|ps|pgrep|pstree|\
        jq|grep|egrep|fgrep|rg|ls|tree|seq|md5sum|sha256sum|which|\
        hexdump|strings|lsof|ss|getent|type|true|test)
            return 0 ;;

        # Read-only unless asked to edit in place.
        sed)
            for a in "$@"; do
                case "$a" in -i*|--in-place*) return 1 ;; esac
            done
            return 0 ;;

        # Read-only unless an option or operand names an OUTPUT file / sets
        # system state.
        sort)
            for a in "$@"; do
                case "$a" in -o*|--output*) return 1 ;; esac
            done
            return 0 ;;
        yq)
            for a in "$@"; do
                case "$a" in -i|--in-place*) return 1 ;; esac
            done
            return 0 ;;
        date)
            for a in "$@"; do
                case "$a" in -s*|--set*) return 1 ;; esac
            done
            return 0 ;;
        uniq|xxd)
            # A second file operand is an output file (`uniq in out`,
            # `xxd -r in out`).
            ros__nth_nonflag 2 "$@" >/dev/null 2>&1 && return 1
            return 0 ;;

        # A reader until an action primary turns it into a writer.
        find)
            for a in "$@"; do
                case "$a" in
                    -delete|-exec|-execdir|-ok|-okdir|-fprintf|-fprint|-fprint0|-fls)
                        return 1 ;;
                esac
            done
            return 0 ;;

        git)
            # Explicit returns: a bare call would only set the case's status,
            # and execution would fall through to the deny below.
            ros__git_is_read_only "$@" && return 0
            return 1 ;;

        # Multiplexers: only their reporting subcommands.
        tmux)
            case "$(ros__nth_nonflag 1 "$@")" in
                capture-pane|list-sessions|list-panes|list-windows|\
                list-clients|list-buffers|ls|display-message|show-options|\
                show-environment|has-session)
                    return 0 ;;
            esac
            return 1 ;;
        docker)
            case "$(ros__nth_nonflag 1 "$@")" in
                ps|logs|inspect|images|stats|top|version|info|port|diff)
                    return 0 ;;
            esac
            return 1 ;;
        systemctl)
            case "$(ros__nth_nonflag 1 "$@")" in
                status|show|cat|list-units|list-timers|list-unit-files|\
                is-active|is-enabled|is-failed)
                    return 0 ;;
            esac
            return 1 ;;
        journalctl)
            for a in "$@"; do
                case "$a" in --vacuum*|--rotate|--flush|--sync) return 1 ;; esac
            done
            return 0 ;;
    esac

    return 1
}

# ros_is_read_only <command-line> — 0 when the WHOLE line only reads. Judged as
# a whole because `cat x | tee y` writes even though its first stage does not.
ros_is_read_only() {
    local cmd="${1:-}"
    [ -n "$cmd" ] || return 1

    # Discarding output is not writing. Stripped BEFORE the redirection check so
    # the overwhelmingly common `2>/dev/null` / `2>&1` do not cost an allow.
    local scan="$cmd"
    scan="${scan//2>&1/ }"
    scan="${scan//>&2/ }"
    scan="${scan//&>\/dev\/null/ }"
    scan="${scan//2>\/dev\/null/ }"
    scan="${scan//>\/dev\/null/ }"

    # Constructs that hide a command from the segment scan below.
    case "$scan" in
        *'$('*|*'`'*|*'<('*|*'>'*|*$'\n'*) return 1 ;;
    esac

    # Normalise every separator to a single `|`, then require each segment to
    # be read-only. `&&` and `||` collapse first so the doubled form does not
    # leave an empty field that IFS splitting would silently drop.
    scan="${scan//&&/|}"
    scan="${scan//||/|}"
    scan="${scan//;/|}"
    scan="${scan//&/|}"

    local restore_glob=0
    case $- in *f*) : ;; *) restore_glob=1 ;; esac
    set -f
    local IFS='|'
    # shellcheck disable=SC2086 # deliberate: split the line into segments.
    set -- $scan
    [ "$#" -gt 0 ] || { [ "$restore_glob" -eq 1 ] && set +f; return 1; }
    [ "$restore_glob" -eq 1 ] && set +f

    local stage
    for stage in "$@"; do
        ros__stage_is_read_only "$stage" || return 1
    done
    return 0
}
