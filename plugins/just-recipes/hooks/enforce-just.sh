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

# Resolve the state dir that holds wrap.log. Mirrors
# procedures_state_dir (plugins/procedures/scripts/lib/stores.sh) minus the
# config.json tier. Highest precedence first:
#   1. ${KNOWLEDGE_HOME:-$HOME/.knowledge}/state — but only if that ~/.knowledge
#      dir EXISTS (a box that never opted into the knowledge home is not
#      silently relocated under a directory that isn't there).
#   2. $CODEX_ROOT/state — when CODEX_ROOT is set (parity with `just wrap`).
#   3. ${XDG_STATE_HOME:-$HOME/.local/state}/just-recipes — the XDG fallback.
log_dir() {
  local khome="${KNOWLEDGE_HOME:-$HOME/.knowledge}"
  if [ -d "$khome" ]; then
    printf '%s' "$khome/state"
  elif [ -n "${CODEX_ROOT:-}" ]; then
    printf '%s' "$CODEX_ROOT/state"
  else
    printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}/just-recipes"
  fi
}

# Append one line to the wrap.log backlog. Best-effort: every failure is silent
# and returns 0 so it can never break the hook's exit-0 fail-open guarantee.
log_wrap() {
  local d="$1" raw="$2" logdir logfile ts oneline
  logdir=$(log_dir)
  logfile="$logdir/wrap.log"
  # chmod 700 only when the hook itself creates the dir — never tighten a
  # pre-existing dir (e.g. a shared ~/.knowledge/state) out from under its owner.
  if [ ! -d "$logdir" ]; then
    mkdir -p "$logdir" 2>/dev/null || return 0
    chmod 700 "$logdir" 2>/dev/null
  fi
  [ -e "$logfile" ] || (umask 077; : >>"$logfile") 2>/dev/null
  chmod 600 "$logfile" 2>/dev/null
  ts=$(date +%Y-%m-%dT%H:%M:%S%z 2>/dev/null) || return 0
  [ -n "$ts" ] || return 0
  oneline=$(printf '%s' "$raw" | tr '\r\n' '  ')
  printf '%s\t%s\t%s\t%s\n' "$ts" "hook" "$d" "$oneline" >>"$logfile" 2>/dev/null || return 0
  return 0
}

# First real command word of a segment: skips leading `sudo`, `env`, and
# NAME=value assignment prefixes, then strips a leading path (./ or /usr/bin/).
# bash 3.2 safe (no arrays/regex).
first_cmd_word() {
  local rest="$1" w name
  while :; do
    rest="${rest#"${rest%%[![:space:]]*}"}"   # strip leading whitespace
    w="${rest%%[[:space:]]*}"
    [ -n "$w" ] || break
    case "$w" in
      sudo|env) rest="${rest#"$w"}"; continue ;;
      *=*)
        name="${w%%=*}"
        case "$name" in
          ''|*[!A-Za-z0-9_]*) break ;;   # not a valid var name -> real command
        esac
        rest="${rest#"$w"}"; continue ;;
    esac
    break
  done
  w="${w##*/}"
  printf '%s' "$w"
}

# Recipe name(s) that plausibly match a leading command word, case-insensitively:
# a recipe whose name equals the word, or a recipe whose doc comment contains the
# word as a whole word. Both names and docs come from a single `just --list`
# capture (passed in as $1) — no extra `just` fork. Prints a deduped,
# space-separated list (possibly empty).
match_recipes() {
  local listing="$1" word="$2" lcword name doc line lcname lcdoc dw matched="" restore_f=0
  lcword=$(printf '%s' "$word" | tr '[:upper:]' '[:lower:]')

  # Doc-comment words below are word-split via unquoted expansion; disable
  # pathname expansion so a word cannot glob against files in cwd. Restore the
  # prior state (rather than always re-enabling) so a caller that already had
  # -f set is not affected.
  case $- in *f*) restore_f=1 ;; esac
  set -f

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
      # Lowercase, then replace every non-word char with a space so
      # punctuation-wrapped words like `(staging)` or `rsync.` split cleanly
      # into whole words to compare — the prior trailing-trim truncated
      # `(build)` to the empty string.
      lcdoc=$(printf '%s' "$doc" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' ' ')
      for dw in $lcdoc; do
        [ "$dw" = "$lcword" ] && { matched="$matched $name"; break; }
      done
    fi
  done <<EOF
$listing
EOF

  [ "$restore_f" -eq 0 ] && set +f

  printf '%s' "$matched" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ *$//;s/^ *//'
}

# Allowlist check for one command segment.
#   $1 = segment, $2 = just-only (1: composite chain, must be a `just` call;
#   0: lone segment, `just` or a read-only verb passes).
seg_is_allowed() {
  local seg="$1" just_only="$2"
  if [ "$just_only" -eq 1 ]; then
    case $seg in
      just|just\ *|just$'\t'*) return 0 ;;
      *) return 1 ;;
    esac
  fi
  printf '%s' "$seg" | grep -Eq '^(just|cd|pwd|echo|ls|cat|command[[:space:]]+-v|which)([[:space:]]|$)'
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
  seg_is_allowed "${segments[0]}" 0 || { all_ok=0; bad_seg="${segments[0]}"; }
elif [ "$n" -gt 1 ]; then
  for s in "${segments[@]}"; do
    seg_is_allowed "$s" 1 || { all_ok=0; bad_seg="$s"; break; }
  done
fi

# Fully allowed -> allow early, whether or not a justfile resolves
if [ "$all_ok" -eq 1 ] && [ "$subshell" -eq 0 ]; then
  exit 0
fi

# Enforcement applies only where a justfile resolves from the project dir (or
# cwd). A single `just --list` capture doubles as the resolve probe (nonzero
# exit -> no justfile, or --list itself errored -> fail-open allow) AND the
# recipe/doc source reused by the nudge match below — one fork, not three.
dir="${CLAUDE_PROJECT_DIR:-$PWD}"
listing=$( cd "$dir" 2>/dev/null && just --list 2>/dev/null ) || exit 0

# Justfile resolves and the command is not allowlisted: record it in the
# wrap.log backlog (nudge + strict; the kill switch already exited above).
log_wrap "$dir" "$cmd"

# Strict mode: hard block regardless of whether a recipe matches.
case "$mode" in
  strict) deny ;;
esac

# Nudge (default): only surface guidance when a recipe plausibly matches the
# command's leading word. No match -> silent allow.
# The lexer breaks on command substitution before flushing a full segment, so
# bad_seg is unreliable when subshell=1; match against the whole command's
# first real word instead.
if [ "$subshell" -eq 1 ]; then
  word=$(first_cmd_word "$cmd")
else
  match_seg="$bad_seg"
  [ -n "$match_seg" ] || match_seg="${segments[0]:-$cmd}"
  word=$(first_cmd_word "$match_seg")
fi
[ -n "$word" ] || exit 0
matched=$(match_recipes "$listing" "$word") || exit 0
[ -n "$matched" ] || exit 0
nudge "$matched"
