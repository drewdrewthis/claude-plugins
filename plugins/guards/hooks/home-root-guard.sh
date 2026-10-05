#!/bin/bash
# home-root-guard.sh — PreToolUse hook (Write|Edit|MultiEdit|NotebookEdit, Bash).
#
# SINGLE RESPONSIBILITY: deny creating a NEW file directly in the home-directory
# root ($HOME/<name>). Agents drop run records, logs, scripts and backups there
# (CUTOVER-*.md, *.log, .cutover-*.txt, crontab.bak-*) where nobody owns or
# finds them; records belong in workspace notes, scratch in /tmp or the
# session scratchpad.
#
# RULE (one predicate, both surfaces): a path is blocked when ALL hold —
#   - its parent directory resolves (tilde, $HOME, relative-to-cwd, symlinks,
#     `..`) to the physical $HOME;
#   - nothing exists at the path yet (editing or overwriting an existing file
#     is never blocked — the guard is about litter, not dotfile maintenance);
#   - its basename is not on the allowlist of legit dotfiles below (+ any
#     names in HOME_ROOT_GUARD_ALLOW, space- or colon-separated).
#
# SURFACES:
#   Write/Edit/MultiEdit/NotebookEdit — tool_input.file_path / notebook_path.
#   Bash — BEST EFFORT: a quote-aware tokenizer finds output redirections
#   (> >> >| &> N>), tee, touch, cp/mv/install destinations (incl. -t DIR and a
#   bare `~`/`~/` dir destination), tracking `cd` within the command. Anything
#   it cannot resolve statically ($VAR other than HOME, $(...), globs, ~user)
#   is skipped, as is an absolute path reaching $HOME only through a symlinked
#   dir. False negatives are preferred to false positives; reads (<, cat, ls,
#   heredoc bodies) are never examined as destinations.
#
# KILL SWITCH: HOME_ROOT_GUARD=off (or 0).
# FAIL-OPEN: missing jq, unreadable payload, unresolvable $HOME => exit 0 with
# no output. Never `set -e`: a hook that exits nonzero on its own bug would
# deny every guarded tool call.

export LC_ALL=C   # byte-indexed substring ops: the tokenizer walks chars

REASON="Don't create files in the home root — put records in your workspace notes, scratch in /tmp or your scratchpad."

DEFAULT_ALLOW=".bashrc .bash_profile .bash_login .bash_logout .bash_aliases .profile
.zshrc .zshenv .zprofile .zlogin .zlogout .inputrc .gitconfig .gitignore_global
.tmux.conf .vimrc .npmrc .yarnrc .editorconfig .claude.json .curlrc .wgetrc
.hushlogin .screenrc .nanorc .psqlrc .sqliterc .Xresources .xprofile .xsession"

case "${HOME_ROOT_GUARD:-}" in off|0) exit 0 ;; esac

command -v jq >/dev/null 2>&1 || exit 0
input=$(cat 2>/dev/null) || exit 0
[ -n "$input" ] || exit 0

[ -n "${HOME:-}" ] || exit 0
HOME_PHYS=$(cd -P -- "$HOME" 2>/dev/null && pwd -P) || exit 0
[ -n "$HOME_PHYS" ] && [ "$HOME_PHYS" != "/" ] || exit 0

tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
CWD=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null) || CWD=""
[ -n "$CWD" ] || CWD="$PWD"

deny() {
  jq -nc --arg r "$REASON (blocked: $1)" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' 2>/dev/null
  exit 0
}

is_allowed_name() {
  local n="$1" a
  for a in $DEFAULT_ALLOW $(printf '%s' "${HOME_ROOT_GUARD_ALLOW:-}" | tr ':' ' '); do
    [ "$n" = "$a" ] && return 0
  done
  return 1
}

# Physical dir for $1 (absolute or relative to $2), or nonzero when it does not
# exist — a missing parent means the write fails on its own, nothing to guard.
phys_dir() {
  local d="$1"
  case "$d" in /*) ;; *) d="$2/$d" ;; esac
  (cd -P -- "$d" 2>/dev/null && pwd -P)
}

# Sets ABS to the absolute form of $1 against cwd $2 (lexical only). A global
# rather than $(...) because a long `&&` chain calls this per redirect and a
# fork each time blows the hook timeout.
abspath() {
  case "$1" in
    /*) ABS="$1" ;;
    *)  ABS="$2/$1" ;;
  esac
}

# The predicate. $1 = path (already tilde/$HOME-expanded), $2 = cwd.
# Returns 0 when $1 would be a NEW non-allowlisted file in the home root.
is_new_home_root_file() {
  local p base parent pd
  abspath "$1" "$2"; p="$ABS"
  # Bash-only fork-free fast path (FASTPATH=1): a path that neither starts
  # under $HOME nor climbs with `..` cannot land in the home root, short of a
  # symlinked dir pointing into it — an accepted Bash-surface false negative.
  # The file tools resolve every path fully; they check one path per call.
  if [ "${FASTPATH:-0}" -eq 1 ]; then
    case "$p" in
      "$HOME"/*|"$HOME_PHYS"/*|*/..|*/../*) ;;
      *) return 1 ;;
    esac
  fi
  case "$p" in */) return 1 ;; esac          # names a directory, not a file
  [ -e "$p" ] || [ -L "$p" ] && return 1     # existing: edit/overwrite is fine
  base="${p##*/}"
  case "$base" in ''|.|..) return 1 ;; esac
  parent="${p%/*}"
  [ -n "$parent" ] || parent="/"
  pd=$(phys_dir "$parent" "$2") || return 1
  [ "$pd" = "$HOME_PHYS" ] || return 1
  is_allowed_name "$base" && return 1
  return 0
}

# Expand a leading ~ for the file-tool surface (the harness passes paths
# verbatim; a model occasionally sends ~/x).
# shellcheck disable=SC2088  # matching a literal "~" sent by the model
expand_tilde() {
  case "$1" in
    "~")   printf '%s' "$HOME" ;;
    "~/"*) printf '%s/%s' "$HOME" "${1#\~/}" ;;
    *)     printf '%s' "$1" ;;
  esac
}

# ---------------------------------------------------------------- file tools
case "$tool" in
  Write|Edit|MultiEdit|NotebookEdit)
    path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null) || exit 0
    [ -n "$path" ] || exit 0
    path=$(expand_tilde "$path")
    is_new_home_root_file "$path" "$CWD" && deny "$path"
    exit 0
    ;;
  Bash) ;;
  *) exit 0 ;;
esac

# ---------------------------------------------------------------------- Bash
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
FASTPATH=1
[ -n "$cmd" ] || exit 0

# Cheap prefilter: no write-shaped syntax at all -> nothing to check.
case "$cmd" in
  *'>'*|*tee*|*touch*|*cp*|*mv*|*install*) ;;
  *) exit 0 ;;
esac

# --- tokenizer --------------------------------------------------------------
# Emits parallel arrays TOK (text, quotes removed, ~ / $HOME expanded) and TYP:
#   W word   D dynamic word (unresolvable expansion)   G glob word
#   O command separator   R output redirect   I input redirect (next word read)
TOK=(); TYP=()
word=""; inword=0; dyn=0; glob=0
hd_pending=()      # heredoc delimiters awaiting their body ("-" prefix = <<-)
hd_expect=""       # "" | "<<" | "<<-": the next word is a heredoc delimiter

emit_word() {
  if [ "$inword" -eq 1 ]; then
    if [ -n "$hd_expect" ]; then
      if [ "$hd_expect" = "<<-" ]; then hd_pending+=("-$word"); else hd_pending+=("+$word"); fi
      hd_expect=""
    else
      TOK+=("$word")
      if [ "$dyn" -eq 1 ]; then TYP+=(D); elif [ "$glob" -eq 1 ]; then TYP+=(G); else TYP+=(W); fi
    fi
  fi
  word=""; inword=0; dyn=0; glob=0
}
emit_op() { emit_word; TOK+=("$1"); TYP+=("$2"); }

len=${#cmd}
i=0

# Character access goes through a sliding window: bash's ${s:i:1} costs O(i),
# so indexing the whole command per char is quadratic and a long `&&` chain
# blew the hook timeout. PK = char at i+$1; UPTO sets LIT to the run from i+$1
# up to (not including) the first char matching glob $2.
WINSZ=2048
base=0
win=${cmd:0:WINSZ}
pk() {
  local o=$((i + $1 - base))
  if [ "$o" -lt 0 ] || [ "$o" -ge $((WINSZ / 2)) ]; then
    base=$i; win=${cmd:base:WINSZ}; o=$1
  fi
  PK=${win:o:1}
}
# shellcheck disable=SC2295  # $2 is deliberately a glob pattern
upto() {
  local o r
  pk "$1"; o=$((i + $1 - base))
  r=${win:o}
  LIT=${r%%$2*}
  if [ "${#LIT}" -eq "${#r}" ] && [ $((base + ${#win})) -lt "$len" ]; then
    r=${cmd:i+$1}; LIT=${r%%$2*}
  fi
}

# Skip a balanced $( ... ) / <( ... ) starting at the "(" index $1; sets i to
# the closing paren. Quotes inside are skipped naively — good enough to find
# the end; the word is dynamic regardless.
skip_parens() {
  local depth=0 q=""
  i=$1
  while [ "$i" -lt "$len" ]; do
    pk 0
    if [ -n "$q" ]; then
      [ "$PK" = "$q" ] && q=""
    else
      case "$PK" in
        "'"|'"') q="$PK" ;;
        '(') depth=$((depth + 1)) ;;
        ')') depth=$((depth - 1)); [ "$depth" -eq 0 ] && return 0 ;;
      esac
    fi
    i=$((i + 1))
  done
}

# Unquoted / double-quoted `$` at index i. Appends to word, advances i to the
# last consumed char.
dollar() {
  local head
  pk 1; head=${win:i + 1 - base:6}
  case "$head" in
    '{HOME}'*) word="$word$HOME"; i=$((i + 6)) ;;
    '('*)      dyn=1; skip_parens $((i + 1)) ;;
    HOME*)
      case "${head:4:1}" in
        [A-Za-z0-9_]) dyn=1; i=$((i + 4)) ;;
        *) word="$word$HOME"; i=$((i + 4)) ;;
      esac ;;
    '{'*)      dyn=1; upto 1 '\}'; i=$((i + 1 + ${#LIT})) ;;
    [A-Za-z_]*) dyn=1; upto 1 '[!A-Za-z0-9_]'; i=$((i + ${#LIT})) ;;
    [0-9\#\?\$\!\*@-]*) dyn=1; i=$((i + 1)) ;;
    *) word="$word\$" ;;
  esac
  inword=1
}

# After an unquoted newline at i: consume pending heredoc bodies, leaving i on
# the newline that ends each delimiter line. One pattern search per plain
# heredoc; <<- (tab-stripped delimiter) walks lines.
skip_heredocs() {
  local d delim rest pre line
  for d in "${hd_pending[@]}"; do
    delim=${d:1}
    rest=${cmd:i+1}
    if [ "${d:0:1}" = "+" ]; then
      if [ "$rest" = "$delim" ] || [ "${rest#"$delim"$'\n'}" != "$rest" ]; then
        i=$((i + 1 + ${#delim}))
      else
        pre=${rest%%$'\n'"$delim"$'\n'*}
        if [ "$pre" != "$rest" ]; then
          i=$((i + 1 + ${#pre} + 1 + ${#delim}))
        else
          i=$len                      # last line or unterminated: body runs to end
        fi
      fi
    else
      while [ "$i" -lt "$len" ]; do
        upto 1 $'\n'; line=$LIT
        i=$((i + 1 + ${#line}))
        line="${line#"${line%%[!$'\t']*}"}"
        [ "$line" = "$delim" ] && break
      done
    fi
  done
  hd_pending=()
}

# fd number glued to a redirect (2>file): a pure-digit static word is dropped.
drop_fd_word() {
  case "$word" in
    ''|*[!0-9]*) ;;
    *) [ "$dyn" -eq 0 ] && { word=""; inword=0; } ;;
  esac
  emit_word
}

# shellcheck disable=SC1003  # '\' below is a literal backslash pattern
while [ "$i" -lt "$len" ]; do
  pk 0; c=$PK
  case "$c" in
    ' '|$'\t') emit_word ;;
    $'\n')
      emit_op ";" O
      [ "${#hd_pending[@]}" -gt 0 ] && skip_heredocs ;;
    ';') emit_op ";" O ;;
    '&')
      pk 1
      if [ "$PK" = ">" ]; then
        emit_word; i=$((i + 1))
        pk 1; [ "$PK" = ">" ] && i=$((i + 1))
        emit_op ">" R
      else
        [ "$PK" = "&" ] && i=$((i + 1))
        emit_op ";" O
      fi ;;
    '|')
      pk 1; case "$PK" in '|'|'&') i=$((i + 1)) ;; esac
      emit_op ";" O ;;
    '('|')') emit_op ";" O ;;
    '>')
      drop_fd_word
      pk 1; case "$PK" in '>'|'|'|'&') i=$((i + 1)) ;; esac
      emit_op ">" R ;;
    '<')
      drop_fd_word
      pk 1
      if [ "$PK" = "<" ]; then
        pk 2
        if [ "$PK" = "<" ]; then
          i=$((i + 2)); emit_op "<" I              # here-string: next word is data
        elif [ "$PK" = "-" ]; then
          i=$((i + 2)); hd_expect="<<-"
        else
          i=$((i + 1)); hd_expect="<<"
        fi
      elif [ "$PK" = "(" ]; then
        skip_parens $((i + 1)); dyn=1; inword=1   # process substitution
      else
        [ "$PK" = "&" ] && i=$((i + 1))
        emit_op "<" I
      fi ;;
    "'")
      upto 1 "\\'"
      word="$word$LIT"; inword=1
      i=$((i + 1 + ${#LIT})) ;;
    '"')
      inword=1; i=$((i + 1))
      while [ "$i" -lt "$len" ]; do
        pk 0; c=$PK
        case "$c" in
          '"') break ;;
          '\') i=$((i + 1)); pk 0; word="$word$PK" ;;
          '$') dollar ;;
          '`') dyn=1; upto 1 '\`'; i=$((i + 1 + ${#LIT})) ;;
          *) word="$word$c" ;;
        esac
        i=$((i + 1))
      done ;;
    '\')
      i=$((i + 1)); pk 0
      if [ "$PK" != $'\n' ]; then word="$word$PK"; inword=1; fi ;;
    '$') dollar ;;
    '`') dyn=1; inword=1; upto 1 '\`'; i=$((i + 1 + ${#LIT})) ;;
    '~')
      if [ "$inword" -eq 0 ]; then
        pk 1
        case "$PK" in
          ''|/|' '|$'\t'|$'\n'|';'|'|'|'&'|')'|'>'|'<') word="$HOME" ;;
          *) word="~"; dyn=1 ;;                      # ~user: not resolved
        esac
      else
        word="$word~"
      fi
      inword=1 ;;
    '#')
      if [ "$inword" -eq 0 ]; then
        upto 0 $'\n'
        i=$((i + ${#LIT} - 1))
      else
        word="$word#"
      fi ;;
    '*'|'?'|'[') glob=1; word="$word$c"; inword=1 ;;
    *) word="$word$c"; inword=1 ;;
  esac
  i=$((i + 1))
done
emit_word

# --- command walk -----------------------------------------------------------
cwd="$CWD"        # tracks static `cd` within the command; "" = unknown
offender=""

check() {   # $1 path, $2 type
  [ -n "$offender" ] && return 0
  [ "$2" = W ] || return 0
  case "$1" in /*) ;; *) [ -n "$cwd" ] || return 0 ;; esac
  is_new_home_root_file "$1" "$cwd" && offender="$1"
  return 0
}

# Destination of cp/mv/install. $1 dest, $2 dest type, rest: "type:source"...
check_copy_dest() {
  local dest="$1" dtype="$2" s st sp dabs
  shift 2
  [ "$dtype" = W ] || return 0
  case "$dest" in /*) ;; *) [ -n "$cwd" ] || return 0 ;; esac
  abspath "$dest" "$cwd"; dabs="$ABS"
  [ "$dabs" = / ] || dabs="${dabs%/}"
  if [ -d "$dabs" ]; then
    [ "$(phys_dir "$dabs" "$cwd")" = "$HOME_PHYS" ] || return 0
    for s in "$@"; do
      st=${s%%:*}; sp=${s#*:}
      [ "$st" = W ] || continue
      sp="${sp%/}"
      check "$dabs/${sp##*/}" W
    done
  else
    check "$dest" W
  fi
}

run_cmd() {   # words in CW/CT
  local n=${#CW[@]} k=0 name a t
  # Skip prefix words: keywords, assignments, transparent wrappers.
  while [ "$k" -lt "$n" ]; do
    a=${CW[k]}
    case "$a" in
      '!'|'{'|'}'|then|do|else|elif|if|while|until|time|nohup|command|builtin|exec|env) k=$((k + 1)); continue ;;
      sudo) [ "${CW[k+1]:0:1}" = "-" ] && return 0; k=$((k + 1)); continue ;;
      *=*) case "${a%%=*}" in ''|*[!A-Za-z0-9_]*) ;; *) k=$((k + 1)); continue ;; esac ;;
    esac
    break
  done
  [ "$k" -lt "$n" ] || return 0
  [ "${CT[k]}" = W ] || return 0
  name=${CW[k]##*/}
  k=$((k + 1))

  local -a args=() atyp=()
  local opts=1 tdir="" ttyp="" skipnext=0 dirmode=0
  case "$name" in
    cd)
      # Unresolvable target (cd -, $VAR, relative from an unknown cwd) makes
      # every later relative path unknown, so those are skipped, not guessed.
      if [ "$k" -ge "$n" ]; then
        cwd="$HOME"
      elif [ "${CT[k]}" != W ] || [ "${CW[k]}" = "-" ]; then
        cwd=""
      elif [ "${CW[k]:0:1}" = / ] || [ -n "$cwd" ]; then
        cwd=$(phys_dir "${CW[k]}" "$cwd") || cwd=""
      fi
      return 0 ;;
    tee|touch|cp|mv|install) ;;
    *) return 0 ;;
  esac

  while [ "$k" -lt "$n" ]; do
    a=${CW[k]}; t=${CT[k]}
    if [ "$skipnext" -eq 1 ]; then
      skipnext=0
    elif [ "$skipnext" -eq 2 ]; then
      skipnext=0; tdir="$a"; ttyp="$t"
    elif [ "$opts" -eq 1 ] && [ "$a" = "--" ]; then
      opts=0
    elif [ "$opts" -eq 1 ] && [ "${a:0:1}" = "-" ] && [ "$a" != "-" ]; then
      case "$name:$a" in
        cp:-t|mv:-t|install:-t) skipnext=2 ;;
        cp:--target-directory=*|mv:--target-directory=*|install:--target-directory=*)
          tdir="${a#*=}"; ttyp="$t" ;;
        touch:-t|touch:-d|touch:-r|cp:-S|mv:-S|install:-S|install:-m|install:-o|install:-g) skipnext=1 ;;
        install:-d|install:--directory) dirmode=1 ;;
      esac
    else
      args+=("$a"); atyp+=("$t")
    fi
    k=$((k + 1))
  done

  local m=${#args[@]} j srcs=()
  case "$name" in
    tee|touch)
      for ((j = 0; j < m; j++)); do check "${args[j]}" "${atyp[j]}"; done ;;
    cp|mv|install)
      [ "$dirmode" -eq 1 ] && return 0
      if [ -n "$tdir" ]; then
        for ((j = 0; j < m; j++)); do srcs+=("${atyp[j]}:${args[j]}"); done
        check_copy_dest "$tdir" "$ttyp" "${srcs[@]}"
      else
        [ "$m" -ge 2 ] || return 0
        for ((j = 0; j < m - 1; j++)); do srcs+=("${atyp[j]}:${args[j]}"); done
        check_copy_dest "${args[m-1]}" "${atyp[m-1]}" "${srcs[@]}"
      fi ;;
  esac
  return 0
}

CW=(); CT=()
ntok=${#TOK[@]}
p=0
while [ "$p" -lt "$ntok" ]; do
  t=${TYP[p]}
  case "$t" in
    O) run_cmd; CW=(); CT=() ;;
    R) p=$((p + 1)); [ "$p" -lt "$ntok" ] && case "${TOK[p]}" in -|*[!0-9]*) [ "${TOK[p]}" = - ] || check "${TOK[p]}" "${TYP[p]}" ;; esac ;;
    I) p=$((p + 1)) ;;
    *) CW+=("${TOK[p]}"); CT+=("$t") ;;
  esac
  [ -n "$offender" ] && break
  p=$((p + 1))
done
[ -z "$offender" ] && run_cmd

[ -n "$offender" ] && deny "$offender"
exit 0
