#!/bin/bash
# PreToolUse (Bash) hook: nudge raw bash toward just recipes where a justfile
# resolves. Default is a NUDGE (permissionDecision=allow + additionalContext);
# JUST_RECIPES_ENFORCE=strict restores the old hard block; off/0 is a kill
# switch.
# Defensive by design: ANY internal failure must result in exit 0 (allow).
# Never use `set -e` here — a hook that exits nonzero on a bug denies all Bash.

# Shared guidance text, reused verbatim by the strict deny reason and the nudge
# additionalContext. Single-quoted heredoc so $HOME and the inner quotes stay
# literal — jq JSON-escapes them at emit time.
GUIDANCE=$(cat <<'TXT'
Run 'just --list' to find a recipe. Escape hatch that always resolves: just --justfile "$HOME/.claude/just/justfile" -d . wrap "<your command>". Bare 'just wrap' needs one-time project wiring (mod global '~/.claude/just/justfile' + set fallback) and is then invoked as just global::wrap "<your command>". To add a recipe: see the just-recipes skill.
TXT
)

deny() {
  jq -nc --arg r "Raw bash is funneled through just here. $GUIDANCE" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' 2>/dev/null
  exit 0
}

nudge() {
  # $1: space-separated matched recipe name(s).
  jq -nc --arg c "A just recipe may cover this ($1). $GUIDANCE" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",additionalContext:$c}}' 2>/dev/null
  exit 0
}

# Append one line to the wrap.log backlog. Best-effort: every failure is silent
# and returns 0 so it can never break the hook's exit-0 fail-open guarantee.
log_wrap() {
  local d="$1" raw="$2" logdir logfile ts oneline
  if [ -n "${CODEX_ROOT:-}" ]; then
    logdir="$CODEX_ROOT/state"
  else
    logdir="$HOME/.knowledge/state"
  fi
  logfile="$logdir/wrap.log"
  mkdir -p "$logdir" 2>/dev/null || return 0
  ts=$(date +%Y-%m-%dT%H:%M:%S%z 2>/dev/null) || return 0
  [ -n "$ts" ] || return 0
  oneline=$(printf '%s' "$raw" | tr '\r\n' '  ')
  printf '%s\t%s\t%s\t%s\n' "$ts" "hook" "$d" "$oneline" >>"$logfile" 2>/dev/null || return 0
  return 0
}

# First word of a command segment, with a leading path (./ or /usr/bin/) stripped.
first_cmd_word() {
  local w="${1%%[[:space:]]*}"
  w="${w##*/}"
  printf '%s' "$w"
}

# Recipe name(s) that plausibly match a leading command word, case-insensitively:
# a recipe whose name equals the word (`just --summary` and `just --list`), or a
# recipe whose doc comment (`just --list`) contains the word as a whole word.
# Prints a deduped, space-separated list (possibly empty).
match_recipes() {
  local d="$1" word="$2" lcword names name doc line lcname lcdoc dw matched=""
  lcword=$(printf '%s' "$word" | tr '[:upper:]' '[:lower:]')

  names=$( cd "$d" 2>/dev/null && just --summary 2>/dev/null ) || names=""
  for name in $names; do
    [ "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')" = "$lcword" ] && matched="$matched $name"
  done

  while IFS= read -r line; do
    case "$line" in
      " "*|$'\t'*) ;;   # only indented recipe rows in `just --list` output
      *) continue ;;
    esac
    line="${line#"${line%%[![:space:]]*}"}"   # strip leading whitespace
    name="${line%%[[:space:]]*}"
    [ -n "$name" ] || continue
    doc=""
    case "$line" in
      *"#"*) doc="${line#*#}" ;;
    esac
    lcname=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
    if [ "$lcname" = "$lcword" ]; then
      matched="$matched $name"
    elif [ -n "$doc" ]; then
      lcdoc=$(printf '%s' "$doc" | tr '[:upper:]' '[:lower:]')
      for dw in $lcdoc; do
        dw="${dw%%[^a-z0-9_-]*}"   # trim trailing punctuation
        [ "$dw" = "$lcword" ] && { matched="$matched $name"; break; }
      done
    fi
  done <<EOF
$( cd "$d" 2>/dev/null && just --list 2>/dev/null )
EOF

  printf '%s' "$matched" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ *$//;s/^ *//'
}

# Mode: unset/default = nudge; strict = hard block; off/0 = kill switch.
mode="${JUST_RECIPES_ENFORCE:-}"
case "$mode" in
  off|0) exit 0 ;;
esac

# just not installed -> passthrough
command -v just >/dev/null 2>&1 || exit 0

# Read stdin (hook input JSON); any failure -> allow
input=$(cat 2>/dev/null) || exit 0
[ -n "$input" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

# Trim leading/trailing IFS whitespace so indented commands match at byte 0
cmd="${cmd#"${cmd%%[![:space:]]*}"}"
cmd="${cmd%"${cmd##*[![:space:]]}"}"
[ -n "$cmd" ] || exit 0

# Segment the command on shell control operators so EVERY segment is checked,
# honoring quote state (a quoted '|' or '&&' inside a string does not split).
# Also flags command substitution ($(...) or backticks) outside single quotes.
segments=()
subshell=0   # $( or ` seen outside single quotes -> raw execution by another name
cur=""
pc=""        # last char appended to cur; detects >& &> >| redirection dups
in_s=0       # inside single quotes
in_d=0       # inside double quotes
esc=0        # next char is backslash-escaped (outside single quotes)

flush_seg() {
  local s="${cur#"${cur%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  [ -n "$s" ] && segments+=("$s")
  return 0
}

nl=$'\n'
cr=$'\r'
len=${#cmd}
i=0
while [ "$i" -lt "$len" ]; do
  c=${cmd:i:1}
  if [ "$in_s" -eq 1 ]; then
    # single-quoted: everything literal, operators and substitution syntax included
    [ "$c" = "'" ] && in_s=0
    cur="$cur$c"; pc="$c"
  elif [ "$esc" -eq 1 ]; then
    esc=0; cur="$cur$c"; pc="$c"
  elif [ "$c" = '\' ]; then
    esc=1; cur="$cur$c"; pc="$c"
  else
    # unquoted, or inside double quotes (where $( and ` still execute)
    if [ "$c" = '`' ] || { [ "$c" = '$' ] && [ "${cmd:i+1:1}" = '(' ]; }; then
      subshell=1
      break
    fi
    if [ "$c" = '"' ]; then
      in_d=$((1 - in_d)); cur="$cur$c"; pc="$c"
    elif [ "$in_d" -eq 1 ]; then
      # inside double quotes operators (and single quotes) are literal
      cur="$cur$c"; pc="$c"
    elif [ "$c" = "'" ]; then
      in_s=1; cur="$cur$c"; pc="$c"
    elif [ "$c" = "&" ] || [ "$c" = "|" ]; then
      nxt=${cmd:i+1:1}
      if [ "$pc" = ">" ] || [ "$pc" = "<" ] || [ "$nxt" = ">" ] || [ "$nxt" = "<" ]; then
        cur="$cur$c"; pc="$c"   # >& &> 2>&1 >| : fd duplication, not a separator
      else
        flush_seg; cur=""; pc=""
        [ "$nxt" = "$c" ] && i=$((i + 1))   # consume doubled partner of && ||
      fi
    elif [ "$c" = ";" ] || [ "$c" = "$nl" ] || [ "$c" = "$cr" ]; then
      flush_seg; cur=""; pc=""
    else
      cur="$cur$c"; pc="$c"
    fi
  fi
  i=$((i + 1))
done
flush_seg

# Allowlist: every segment independently evaluated.
# Lone segment: first word is `just` or a read-only verb.
# Composite (2+ segments): every segment must be a just invocation — chained
# read-only verbs still funnel (e.g. newline-splitting 'just x\ncat y' denies).
# bad_seg records the FIRST non-allowlisted segment, whose leading word drives
# the nudge match.
all_ok=1
bad_seg=""
n=${#segments[@]}
if [ "$n" -eq 1 ]; then
  if printf '%s' "${segments[0]}" | grep -Eq '^(just|cd|pwd|echo|ls|cat|command[[:space:]]+-v|which)([[:space:]]|$)'; then
    :
  else
    all_ok=0; bad_seg="${segments[0]}"
  fi
elif [ "$n" -gt 1 ]; then
  for s in "${segments[@]}"; do
    case $s in
      just|just\ *|just$'\t'*) ;;
      *) all_ok=0; bad_seg="$s"; break ;;
    esac
  done
fi

# Fully allowed -> allow early, whether or not a justfile resolves
if [ "$all_ok" -eq 1 ] && [ "$subshell" -eq 0 ]; then
  exit 0
fi

# Enforcement applies only where a justfile resolves from the project dir (or cwd)
dir="${CLAUDE_PROJECT_DIR:-$PWD}"
( cd "$dir" 2>/dev/null && just --summary >/dev/null 2>&1 ) || exit 0

# Justfile resolves and the command is not allowlisted: record it in the
# wrap.log backlog (nudge + strict; the kill switch already exited above).
log_wrap "$dir" "$cmd"

# Strict mode: hard block regardless of whether a recipe matches.
case "$mode" in
  strict) deny ;;
esac

# Nudge (default): only surface guidance when a recipe plausibly matches the
# command's leading word. No match -> silent allow.
match_seg="$bad_seg"
[ -n "$match_seg" ] || match_seg="${segments[0]:-$cmd}"
word=$(first_cmd_word "$match_seg")
[ -n "$word" ] || exit 0
matched=$(match_recipes "$dir" "$word") || exit 0
[ -n "$matched" ] || exit 0
nudge "$matched"
