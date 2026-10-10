#!/usr/bin/env bats
# Tests for hooks/enforce-just.sh — the PreToolUse Bash nudge/block hook.
#
# No real `just` is installed for the suite. A stub first on PATH must honour
# --justfile and -d as passed, because the hook resolves the global library
# through both; the "no project justfile" path is exercised by pointing at an
# empty dir, where the stub exits nonzero exactly as real just does.

setup() {
  HOOK="$BATS_TEST_DIRNAME/../enforce-just.sh"

  SCRATCH="$(mktemp -d "${BATS_TMPDIR:-/tmp}/ej.XXXXXX")"
  FAKE_HOME="$(mktemp -d "${BATS_TMPDIR:-/tmp}/ej-home.XXXXXX")"
  CODEX_ROOT="$SCRATCH/codex"
  WRAPLOG="$CODEX_ROOT/state/wrap.log"

  # Project dir WITH a justfile.
  JUSTDIR="$SCRATCH/proj"
  mkdir -p "$JUSTDIR"
  cat > "$JUSTDIR/justfile" <<'JF'
# Build the project
build:
    @echo building

# rsync files to the remote server
sync-files:
    @echo syncing
JF

  # Project dir WITHOUT a justfile.
  EMPTYDIR="$SCRATCH/empty"
  mkdir -p "$EMPTYDIR"

  # The GLOBAL recipe library under the fake HOME — the fallback listing the
  # hook uses in any repo that has no justfile of its own.
  mkdir -p "$FAKE_HOME/.claude/just"
  cat > "$FAKE_HOME/.claude/just/justfile" <<'JF'
# Send a message to a tmux worker session
send:
    @echo sending

# Report PR readiness
pr-ready:
    @echo checking
JF

  # `just` stub: parses the justfile in cwd. Exits nonzero when absent.
  STUB="$SCRATCH/bin"
  mkdir -p "$STUB"
  cat > "$STUB/just" <<'SH'
#!/usr/bin/env bash
# Honors --justfile <path> and -d/--working-directory <dir> the way real just
# does, so the hook's global-library probe is exercised for real.
jf=""; wd=""; args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --justfile) jf="$2"; shift 2 ;;
    -d|--working-directory) wd="$2"; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
[ -n "$wd" ] && cd "$wd" 2>/dev/null
if [ -z "$jf" ]; then
  for f in justfile Justfile .justfile; do [ -f "$f" ] && { jf="$f"; break; }; done
fi
[ -f "$jf" ] || { echo "error: No justfile found." >&2; exit 1; }
case "${args[0]:-}" in
  --summary)
    awk '/^[A-Za-z0-9_-]+[^=]*:/{n=$1; sub(/:.*/,"",n); printf "%s ", n} END{print ""}' "$jf"
    ;;
  --list)
    echo "Available recipes:"
    awk '
      /^#/ {doc=substr($0,2); sub(/^ */,"",doc); next}
      /^[A-Za-z0-9_-]+[^=]*:/ {n=$0; sub(/:.*/,"",n); sub(/ .*/,"",n);
        if(doc!="") printf "    %s # %s\n", n, doc; else printf "    %s\n", n; doc=""; next}
      /^[[:space:]]/ {next}
      {doc=""}
    ' "$jf"
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$STUB/just"
}

teardown() {
  rm -rf "$SCRATCH" "$FAKE_HOME" 2>/dev/null || true
}

payload() { jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'; }

# run_hook <command> [mode] [projdir]
# mode "" -> unset (nudge default); projdir defaults to the justfile dir.
run_hook() {
  local cmd="$1" mode="${2:-}" proj="${3:-$JUSTDIR}"
  local -a envv=(
    PATH="$STUB:$PATH"
    HOME="$FAKE_HOME"
    CODEX_ROOT="$CODEX_ROOT"
    CLAUDE_PROJECT_DIR="$proj"
  )
  [ -n "$mode" ] && envv+=( JUST_RECIPES_ENFORCE="$mode" )
  payload "$cmd" | env -u JUST_RECIPES_ENFORCE "${envv[@]}" bash "$HOOK"
}

decision() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null; }
context()  { printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null; }
reason()   { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null; }

# has <text> <literal>   -> 0 when the literal is in the text
# lacks <text> <literal> -> 0 when it is not. Functions (not `!`) so a failure
# trips bats errexit anywhere in a test.
has()   { printf '%s' "$1" | grep -qF -- "$2"; }
lacks() { ! printf '%s' "$1" | grep -qF -- "$2"; }

# hook_env <cmd> [mode] [projdir] [bindir] [VAR=val ...]
# Like run_hook, but picks the `just` stub dir and passes extra env. Always
# unsets JUST_GLOBAL_JUSTFILE so only an explicit VAR=val sets it.
hook_env() {
  local cmd="$1" mode="${2:-}" proj="${3:-$JUSTDIR}" bin="${4:-$STUB}"
  shift $(( $# < 4 ? $# : 4 ))
  local -a envv=(
    PATH="$bin:$PATH"
    HOME="$FAKE_HOME"
    CODEX_ROOT="$CODEX_ROOT"
    CLAUDE_PROJECT_DIR="$proj"
  )
  [ -n "$mode" ] && envv+=( JUST_RECIPES_ENFORCE="$mode" )
  [ $# -gt 0 ] && envv+=( "$@" )
  payload "$cmd" | env -u JUST_RECIPES_ENFORCE -u JUST_GLOBAL_JUSTFILE "${envv[@]}" bash "$HOOK"
}

# hook_text <same args as hook_env> -> the nudge context, or the strict reason.
hook_text() {
  hook_env "$@" | jq -r '.hookSpecificOutput | (.additionalContext // .permissionDecisionReason // empty)' 2>/dev/null
}

# add_wrap <justfile> -> append a `wrap` recipe (the stub's summary prints "wrap").
add_wrap() { printf '\n# run a command through the logger\nwrap +cmd:\n    @echo wrapped\n' >> "$1"; }


# init_canned -> a `just` stub that answers from files, for output the line-based
# stub cannot express (modules, broken files). Reads $CANNED_DIR/<src>.<mode>
# where src is "global" when --justfile is passed, else "project"; mode is
# "summary" or "list". Missing file -> exit 1, like a just that cannot read it.
init_canned() {
  CANNED="$SCRATCH/canned"; CBIN="$SCRATCH/cbin"
  mkdir -p "$CANNED" "$CBIN"
  cat > "$CBIN/just" <<'SH'
#!/usr/bin/env bash
src=project; mode=""
while [ $# -gt 0 ]; do
  case "$1" in
    --justfile) src=global; shift 2 ;;
    -d|--working-directory) shift 2 ;;
    --summary) mode=summary; shift ;;
    --list|--list-submodules) mode=list; shift ;;
    *) shift ;;
  esac
done
f="$CANNED_DIR/$src.$mode"
[ -f "$f" ] && { cat "$f"; exit 0; }
exit 1
SH
  chmod +x "$CBIN/just"
}
# canned_put <src.mode> <text>
canned_put() { printf '%s\n' "$2" > "$CANNED/$1"; }
# canned_text <cmd> [mode] [projdir] -> hook_text through the canned stub
canned_text() { hook_text "$1" "${2:-}" "${3:-$EMPTYDIR}" "$CBIN" CANNED_DIR="$CANNED"; }

# --- modes ----------------------------------------------------------------

@test "off is a silent kill switch — no output, no wrap.log" {
  run run_hook "wget http://x" off
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f "$WRAPLOG" ]
}

@test "0 is also a kill switch" {
  run run_hook "wget http://x" 0
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f "$WRAPLOG" ]
}

@test "strict denies a non-allowlisted command regardless of any recipe match" {
  run run_hook "wget http://x" strict
  [ "$status" -eq 0 ]
  [ "$(decision "$output")" = "deny" ]
}

@test "strict deny reason carries the resolved escape hatch" {
  add_wrap "$FAKE_HOME/.claude/just/justfile"
  t="$(hook_text "wget http://x" strict)"
  has "$t" "just --justfile \"$FAKE_HOME/.claude/just/justfile\" -d . wrap \"<your command>\""
}

# --- passthrough / fail-open ---------------------------------------------

@test "no project justfile and no global library -> generic nudge, still allows" {
  rm -rf "$FAKE_HOME/.claude"
  run run_hook "wget http://x" "" "$EMPTYDIR"
  [ "$status" -eq 0 ]
  [ "$(decision "$output")" = "allow" ]
  context "$output" | grep -q "No recipe covers this yet"
}

@test "allowlisted 'just build' -> silent passthrough" {
  run run_hook "just build"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f "$WRAPLOG" ]
}

# --- nudge match-gating ---------------------------------------------------

@test "nudge when the leading word matches a summary recipe name" {
  run run_hook "build --release"
  [ "$status" -eq 0 ]
  [ "$(decision "$output")" = "allow" ]
  context "$output" | grep -q "build"
}

@test "nudge when the leading word appears in a recipe doc comment" {
  run run_hook "rsync -a src dst"
  [ "$status" -eq 0 ]
  [ "$(decision "$output")" = "allow" ]
  context "$output" | grep -q "sync-files"
}

@test "generic nudge when no recipe plausibly matches" {
  run run_hook "wget http://x"
  [ "$status" -eq 0 ]
  [ "$(decision "$output")" = "allow" ]
  context "$output" | grep -q "No recipe covers this yet"
}

# --- wrap.log backlog -----------------------------------------------------

@test "wrap.log line appended in nudge mode" {
  run run_hook "build --release"
  [ -f "$WRAPLOG" ]
  [ "$(wc -l < "$WRAPLOG" | tr -d ' ')" = "1" ]
  # fields: ts <tab> hook <tab> dir <tab> command
  awk -F'\t' -v d="$JUSTDIR" '{ if ($2!="hook" || $3!=d) exit 1; if (index($4,"build --release")==0) exit 1 }' "$WRAPLOG"
}

@test "wrap.log line appended when no recipe matches" {
  run run_hook "wget http://x"
  [ -f "$WRAPLOG" ]
  grep -q "$(printf '\thook\t')" "$WRAPLOG"
  grep -q "wget http://x" "$WRAPLOG"
}

@test "wrap.log line appended in strict mode" {
  run run_hook "wget http://x" strict
  [ -f "$WRAPLOG" ]
  grep -q "wget http://x" "$WRAPLOG"
}

@test "no wrap.log line in off mode" {
  run run_hook "wget http://x" off
  [ ! -f "$WRAPLOG" ]
}

@test "a multiline command is collapsed to one wrap.log line" {
  run run_hook "$(printf 'wget a\ncurl b')" strict
  [ "$(wc -l < "$WRAPLOG" | tr -d ' ')" = "1" ]
}

# --- state-dir precedence (knowledge-home > CODEX_ROOT > XDG) --------------

@test "tier a: ~/.knowledge/state wins even when CODEX_ROOT is also set" {
  mkdir -p "$FAKE_HOME/.knowledge"
  run run_hook "wget http://x" strict
  [ -f "$FAKE_HOME/.knowledge/state/wrap.log" ]
  grep -q "wget http://x" "$FAKE_HOME/.knowledge/state/wrap.log"
  [ ! -f "$WRAPLOG" ]   # CODEX_ROOT/state must NOT be used
}

@test "tier b: CODEX_ROOT/state used when no ~/.knowledge dir exists" {
  run run_hook "wget http://x" strict
  [ -f "$WRAPLOG" ]
  grep -q "wget http://x" "$WRAPLOG"
}

@test "tier c: XDG_STATE_HOME/just-recipes when neither CODEX_ROOT nor ~/.knowledge" {
  XDG="$SCRATCH/xdg"
  payload "wget http://x" | env -u JUST_RECIPES_ENFORCE -u CODEX_ROOT \
    PATH="$STUB:$PATH" HOME="$FAKE_HOME" XDG_STATE_HOME="$XDG" \
    CLAUDE_PROJECT_DIR="$JUSTDIR" JUST_RECIPES_ENFORCE=strict bash "$HOOK"
  [ -f "$XDG/just-recipes/wrap.log" ]
  grep -q "wget http://x" "$XDG/just-recipes/wrap.log"
}

# --- glob safety in match_recipes ------------------------------------------

@test "a glob-shaped doc-comment word does not match a same-named cwd file" {
  # A doc comment word like `deploy*` must be treated LITERALLY, never
  # expanded against files sitting in cwd (here `deploy-notes`), or an
  # unrelated command sharing that filename would wrongly get nudged.
  GLOBDIR="$SCRATCH/globproj"
  mkdir -p "$GLOBDIR"
  cat > "$GLOBDIR/justfile" <<'JF'
# deploy* things
build:
    @echo building
JF
  : > "$GLOBDIR/deploy-notes"

  run bash -c '
    cd "$1" || exit 1
    jq -nc --arg c "deploy-notes cat" --arg name Bash "{tool_name:\$name,tool_input:{command:\$c}}" \
      | env -u JUST_RECIPES_ENFORCE \
        PATH="$2:$PATH" HOME="$3" CODEX_ROOT="$4" CLAUDE_PROJECT_DIR="$1" \
        bash "$5"
  ' _ "$GLOBDIR" "$STUB" "$FAKE_HOME" "$CODEX_ROOT" "$HOOK"

  [ "$status" -eq 0 ]
  context "$output" | grep -qv "build"
  context "$output" | grep -q "No recipe covers this yet"
}

@test "wrap.log is created with owner-only 0600 permissions" {
  run run_hook "build --release"
  [ -f "$WRAPLOG" ]
  if [[ "$(uname)" == "Darwin" ]]; then
    mode=$(stat -f %Lp "$WRAPLOG")
  else
    mode=$(stat -c %a "$WRAPLOG")
  fi
  [ "$mode" = "600" ]
}

# --- command substitution -------------------------------------------------

@test "strict denies a command substitution even behind an allowlisted 'just'" {
  run run_hook "just build \$(git rev-parse HEAD)" strict
  [ "$status" -eq 0 ]
  [ "$(decision "$output")" = "deny" ]
}

@test "nudge fires on a command substitution matching a doc comment" {
  run run_hook "rsync \$(cat x) y"
  [ "$status" -eq 0 ]
  [ "$(decision "$output")" = "allow" ]
  context "$output" | grep -q "sync-files"
}

# --- doc-comment word splitting -------------------------------------------

@test "a punctuation-wrapped doc word still matches (no first-char truncation)" {
  PDIR="$SCRATCH/parenproj"
  mkdir -p "$PDIR"
  cat > "$PDIR/justfile" <<'JF'
# Deploy (staging) via rsync
ship:
    @echo shipping
JF
  run run_hook "rsync -a src dst" "" "$PDIR"
  [ "$status" -eq 0 ]
  [ "$(decision "$output")" = "allow" ]
  context "$output" | grep -q "ship"
}

# --- first-word skipping (sudo / env / VAR=value) -------------------------

@test "nudge sees past sudo and a leading assignment to the real command" {
  run run_hook "FOO=1 sudo rsync a b"
  [ "$status" -eq 0 ]
  [ "$(decision "$output")" = "allow" ]
  context "$output" | grep -q "sync-files"
}

# --- fail-open guarantees --------------------------------------------------

@test "jq missing from PATH -> exit 0, empty output" {
  NOJQ="$SCRATCH/nojq"
  mkdir -p "$NOJQ"
  ln -s "$STUB/just" "$NOJQ/just"
  for b in bash cat; do ln -s "$(command -v "$b")" "$NOJQ/$b"; done
  run bash -c '
    printf "%s" "$1" | env -u JUST_RECIPES_ENFORCE \
      PATH="$2" HOME="$3" CODEX_ROOT="$4" CLAUDE_PROJECT_DIR="$5" bash "$6"
  ' _ "$(payload "build --release")" "$NOJQ" "$FAKE_HOME" "$CODEX_ROOT" "$JUSTDIR" "$HOOK"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "malformed stdin JSON -> exit 0, empty output" {
  run bash -c '
    printf "%s" "not json {" | env -u JUST_RECIPES_ENFORCE \
      PATH="$1:$PATH" HOME="$2" CODEX_ROOT="$3" CLAUDE_PROJECT_DIR="$4" bash "$5"
  ' _ "$STUB" "$FAKE_HOME" "$CODEX_ROOT" "$JUSTDIR" "$HOOK"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "just --list erroring (stub exits 2) -> exit 0, generic nudge, never a deny" {
  ERRBIN="$SCRATCH/errbin"
  mkdir -p "$ERRBIN"
  cat > "$ERRBIN/just" <<'SH'
#!/usr/bin/env bash
# --list always errors; the resolve probe must fail open.
exit 2
SH
  chmod +x "$ERRBIN/just"
  run bash -c '
    printf "%s" "$1" | env -u JUST_RECIPES_ENFORCE \
      PATH="$2:$PATH" HOME="$3" CODEX_ROOT="$4" CLAUDE_PROJECT_DIR="$5" bash "$6"
  ' _ "$(payload "rsync -a src dst")" "$ERRBIN" "$FAKE_HOME" "$CODEX_ROOT" "$JUSTDIR" "$HOOK"
  [ "$status" -eq 0 ]
  [ "$(decision "$output")" = "allow" ]
  context "$output" | grep -q "No recipe covers this yet"
}

@test "strict + just --list erroring -> exit 0 but deny (fail-open is exit-code only)" {
  ERRBIN="$SCRATCH/errbin-strict"
  mkdir -p "$ERRBIN"
  cat > "$ERRBIN/just" <<'SH'
#!/usr/bin/env bash
# --list (and --list-submodules, and the global-library --justfile probe)
# always error; strict must still deny even though the listing never resolves.
exit 2
SH
  chmod +x "$ERRBIN/just"
  run bash -c '
    printf "%s" "$1" | env -u JUST_RECIPES_ENFORCE \
      PATH="$2:$PATH" HOME="$3" CODEX_ROOT="$4" CLAUDE_PROJECT_DIR="$5" \
      JUST_RECIPES_ENFORCE=strict bash "$6"
  ' _ "$(payload "rsync -a src dst")" "$ERRBIN" "$FAKE_HOME" "$CODEX_ROOT" "$JUSTDIR" "$HOOK"
  [ "$status" -eq 0 ]
  [ "$(decision "$output")" = "deny" ]
}

# --- global library fallback (no project justfile) -------------------------

@test "no project justfile: a global recipe doc match names the recipe" {
  run run_hook "tmux send-keys -t x hi" "" "$EMPTYDIR"
  [ "$status" -eq 0 ]
  [ "$(decision "$output")" = "allow" ]
  context "$output" | grep -q "send"
}

@test "no project justfile: the wrap.log dir column is tagged global" {
  run run_hook "tmux send-keys -t x hi" "" "$EMPTYDIR"
  [ -f "$WRAPLOG" ]
  [ "$(wc -l < "$WRAPLOG" | tr -d ' ')" = "1" ]
  awk -F'\t' '{ if ($2!="hook" || $3!="global") exit 1; if (index($4,"tmux send-keys")==0) exit 1 }' "$WRAPLOG"
}

@test "no project justfile: an unmatched command still nudges and logs" {
  run run_hook "bash some-script.sh" "" "$EMPTYDIR"
  [ "$status" -eq 0 ]
  [ "$(decision "$output")" = "allow" ]
  context "$output" | grep -q "No recipe covers this yet"
  [ -f "$WRAPLOG" ]
  grep -q "bash some-script.sh" "$WRAPLOG"
}

@test "no project justfile: off stays silent with no log line" {
  run run_hook "tmux send-keys -t x hi" off "$EMPTYDIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f "$WRAPLOG" ]
}

@test "no project justfile: allowlisted verbs and just calls stay silent" {
  run run_hook "ls -la" "" "$EMPTYDIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f "$WRAPLOG" ]

  run run_hook "just send" "" "$EMPTYDIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f "$WRAPLOG" ]
}

@test "JUST_GLOBAL_JUSTFILE overrides the default global library path" {
  ALT="$SCRATCH/altlib"
  mkdir -p "$ALT"
  cat > "$ALT/justfile" <<'JF'
# curl the health endpoint
health-check:
    @echo ok
JF
  payload "curl http://x" | env -u JUST_RECIPES_ENFORCE \
    PATH="$STUB:$PATH" HOME="$FAKE_HOME" CODEX_ROOT="$CODEX_ROOT" \
    CLAUDE_PROJECT_DIR="$EMPTYDIR" JUST_GLOBAL_JUSTFILE="$ALT/justfile" \
    bash "$HOOK" > "$SCRATCH/out.json"
  [ "$(decision "$(cat "$SCRATCH/out.json")")" = "allow" ]
  grep -q "health-check" "$SCRATCH/out.json"
}

@test "no project justfile: strict still denies" {
  run run_hook "tmux send-keys -t x hi" strict "$EMPTYDIR"
  [ "$status" -eq 0 ]
  [ "$(decision "$output")" = "deny" ]
}

# --- project justfile takes precedence over the global library ------------

@test "a project justfile wins: global recipes are not consulted" {
  run run_hook "tmux send-keys -t x hi"
  [ "$status" -eq 0 ]
  [ "$(decision "$output")" = "allow" ]
  context "$output" | grep -q "No recipe covers this yet"
}

@test "submodule recipes are listed when just supports --list-submodules" {
  MODDIR="$SCRATCH/modproj"
  mkdir -p "$MODDIR"
  cat > "$MODDIR/justfile" <<'JF'
# Build the project
build:
    @echo building
JF
  # Stub that only answers when --list-submodules is present, proving the hook
  # asks for submodules first.
  SUBBIN="$SCRATCH/subbin"
  mkdir -p "$SUBBIN"
  cat > "$SUBBIN/just" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = "--list-submodules" ] && { printf 'Available recipes:\n    global::send # Send a message to a tmux worker session\n'; exit 0; }; done
exit 1
SH
  chmod +x "$SUBBIN/just"
  payload "tmux send-keys -t x hi" | env -u JUST_RECIPES_ENFORCE \
    PATH="$SUBBIN:$PATH" HOME="$FAKE_HOME" CODEX_ROOT="$CODEX_ROOT" \
    CLAUDE_PROJECT_DIR="$MODDIR" bash "$HOOK" > "$SCRATCH/sub.json"
  grep -q "global::send" "$SCRATCH/sub.json"
}

@test "older just: --list-submodules fails, the hook retries plain --list" {
  OLDDIR="$SCRATCH/oldproj"
  mkdir -p "$OLDDIR"
  : > "$OLDDIR/justfile"
  # Stub for a just too old to know --list-submodules: it fails on that flag
  # and answers only the plain listing.
  OLDBIN="$SCRATCH/oldbin"
  mkdir -p "$OLDBIN"
  cat > "$OLDBIN/just" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do
  if [ "$a" = "--list-submodules" ]; then
    echo "error: Found argument '--list-submodules' which wasn't expected" >&2
    exit 2
  fi
done
for a in "$@"; do
  [ "$a" = "--list" ] && { printf 'Available recipes:\n    deploy # Deploy the service\n'; exit 0; }
done
exit 1
SH
  chmod +x "$OLDBIN/just"
  payload "deploy the thing" | env -u JUST_RECIPES_ENFORCE \
    PATH="$OLDBIN:$PATH" HOME="$FAKE_HOME" CODEX_ROOT="$CODEX_ROOT" \
    CLAUDE_PROJECT_DIR="$OLDDIR" bash "$HOOK" > "$SCRATCH/old.json"
  grep -q '"permissionDecision": *"allow"' "$SCRATCH/old.json"
  grep -q "deploy" "$SCRATCH/old.json"
}

# --- escape hatch resolves at run time (#223) -----------------------------
# The hook names a `wrap` form only when `just --summary` shows a recipe that
# really is `wrap`. Nothing resolves -> it names no hatch and no global path.

# no_global_refs <text> -> 0 when the text names no global-library path or form.
no_global_refs() { ! printf '%s' "$1" | grep -qE -- '--justfile|\.claude/just/justfile|just --list'; }

CMD='wget http://x'
HATCH_GLOBAL() { printf 'just --justfile "%s" -d . wrap "<your command>"' "$1"; }

@test "no hatch: no project justfile and no global file -> the nudge names no global path" {
  rm -rf "$FAKE_HOME/.claude"
  t="$(hook_text "$CMD" "" "$EMPTYDIR")"
  no_global_refs "$t"
}

@test "no hatch: no project justfile and no global file -> the nudge names no wrap" {
  rm -rf "$FAKE_HOME/.claude"
  t="$(hook_text "$CMD" "" "$EMPTYDIR")"
  lacks "$t" "wrap"
}

@test "no hatch: strict with no global file -> the reason names no global path" {
  rm -rf "$FAKE_HOME/.claude"
  t="$(hook_text "$CMD" strict "$EMPTYDIR")"
  no_global_refs "$t"
}

@test "no hatch: a dangling-symlink global file -> the nudge names no global path" {
  rm "$FAKE_HOME/.claude/just/justfile"
  ln -s "$SCRATCH/nope" "$FAKE_HOME/.claude/just/justfile"
  t="$(hook_text "$CMD" "" "$EMPTYDIR")"
  no_global_refs "$t"
}

@test "no hatch: a dangling-symlink global file -> the nudge names no wrap" {
  rm "$FAKE_HOME/.claude/just/justfile"
  ln -s "$SCRATCH/nope" "$FAKE_HOME/.claude/just/justfile"
  t="$(hook_text "$CMD" "" "$EMPTYDIR")"
  lacks "$t" "wrap"
}

@test "global hatch: a global wrap recipe and an empty project dir -> the global form is named" {
  add_wrap "$FAKE_HOME/.claude/just/justfile"
  t="$(hook_text "$CMD" "" "$EMPTYDIR")"
  has "$t" "$(HATCH_GLOBAL "$FAKE_HOME/.claude/just/justfile")"
}

@test "global hatch: JUST_GLOBAL_JUSTFILE with a space in the path -> that path is named, quoted" {
  ALT="$SCRATCH/my lib"
  mkdir -p "$ALT"
  printf 'wrap +cmd:\n    @echo w\n' > "$ALT/justfile"
  t="$(hook_text "$CMD" "" "$EMPTYDIR" "$STUB" JUST_GLOBAL_JUSTFILE="$ALT/justfile")"
  has "$t" "$(HATCH_GLOBAL "$ALT/justfile")"
}

@test "global hatch: a project justfile without wrap and a global with wrap -> the global form is named" {
  add_wrap "$FAKE_HOME/.claude/just/justfile"
  t="$(hook_text "$CMD")"
  has "$t" "$(HATCH_GLOBAL "$FAKE_HOME/.claude/just/justfile")"
}

@test "project hatch: a project wrap recipe -> 'just wrap' is named" {
  add_wrap "$JUSTDIR/justfile"
  t="$(hook_text "$CMD")"
  has "$t" 'just wrap "<your command>"'
}

@test "project hatch: project and global both have wrap -> the global form is not named" {
  add_wrap "$JUSTDIR/justfile"
  add_wrap "$FAKE_HOME/.claude/just/justfile"
  t="$(hook_text "$CMD")"
  lacks "$t" "--justfile"
}

@test "project hatch: a module recipe tools::wrap -> 'just tools::wrap' is named" {
  init_canned
  canned_put project.summary "build tools::wrap"
  canned_put project.list "$(printf 'Available recipes:\n    build\n    tools::wrap')"
  t="$(canned_text "$CMD" "" "$JUSTDIR")"
  has "$t" 'just tools::wrap "<your command>"'
}

@test "project hatch: a bare wrap beats a module tools::wrap" {
  init_canned
  canned_put project.summary "tools::wrap build wrap"
  canned_put project.list "$(printf 'Available recipes:\n    build\n    wrap')"
  t="$(canned_text "$CMD" "" "$JUSTDIR")"
  has "$t" 'just wrap "<your command>"'
}

@test "near miss: global recipes wrap-report, unwrap and tools::rewrap -> no wrap form" {
  init_canned
  canned_put global.summary "send wrap-report unwrap tools::rewrap"
  t="$(canned_text "$CMD")"
  lacks "$t" 'wrap "'
}

@test "near miss: project recipes wrap-report, unwrap and tools::rewrap -> no wrap form" {
  init_canned
  canned_put project.summary "build wrap-report unwrap tools::rewrap"
  canned_put project.list "$(printf 'Available recipes:\n    build')"
  t="$(canned_text "$CMD" "" "$JUSTDIR")"
  lacks "$t" 'wrap "'
}

@test "broken justfiles: every just probe fails -> no wrap form" {
  init_canned
  t="$(canned_text "$CMD" "" "$JUSTDIR")"
  lacks "$t" 'wrap "'
}

@test "broken justfiles: every just probe fails -> the hook exits 0" {
  init_canned
  run hook_env "$CMD" "" "$JUSTDIR" "$CBIN" CANNED_DIR="$CANNED"
  [ "$status" -eq 0 ]
}

@test "broken project justfile and a good global with wrap -> the global form is named" {
  init_canned
  canned_put global.summary "send wrap"
  t="$(canned_text "$CMD" "" "$JUSTDIR")"
  has "$t" "$(HATCH_GLOBAL "$FAKE_HOME/.claude/just/justfile")"
}

@test "list hint: a resolving project justfile -> 'just --list' is named" {
  t="$(hook_text "$CMD")"
  has "$t" "just --list"
}

@test "list hint: only the global file resolves -> 'just --justfile <path> --list' is named" {
  t="$(hook_text "$CMD" "" "$EMPTYDIR")"
  has "$t" "just --justfile \"$FAKE_HOME/.claude/just/justfile\" --list"
}

@test "list hint: nothing resolves -> 'just --list' is not named" {
  rm -rf "$FAKE_HOME/.claude"
  t="$(hook_text "$CMD" "" "$EMPTYDIR")"
  lacks "$t" "just --list"
}

@test "strict with no hatch -> deny" {
  run hook_env "$CMD" strict
  [ "$(decision "$output")" = "deny" ]
}

@test "strict with no hatch -> the reason names JUST_RECIPES_ENFORCE=off" {
  run hook_env "$CMD" strict
  has "$(reason "$output")" "JUST_RECIPES_ENFORCE=off"
}

@test "strict with no hatch -> the reason names no wrap command" {
  t="$(hook_text "$CMD" strict)"
  lacks "$t" 'wrap "<your command>"'
}

# --- cost: probes per hook run (#223) --------------------------------------

# count_stub -> a `just` that logs its args to $JLOG, then runs the normal stub.
count_stub() {
  JLOG="$SCRATCH/just-calls.log"
  CNT="$SCRATCH/cnt"
  mkdir -p "$CNT"
  cat > "$CNT/just" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$JLOG"
exec "$STUB/just" "\$@"
SH
  chmod +x "$CNT/just"
}
# calls [pattern] -> number of logged just invocations (matching pattern)
calls() {
  [ -f "$JLOG" ] || { echo 0; return; }
  if [ -n "${1:-}" ]; then grep -c -- "$1" "$JLOG" || true; else wc -l < "$JLOG" | tr -d ' '; fi
}

@test "cost: a non-allowlisted command runs at most 4 just invocations" {
  count_stub
  hook_env "$CMD" "" "$JUSTDIR" "$CNT" >/dev/null
  [ "$(calls)" -le 4 ]
}

@test "cost: a non-allowlisted command runs at most 2 just --summary" {
  count_stub
  hook_env "$CMD" "" "$JUSTDIR" "$CNT" >/dev/null
  [ "$(calls --summary)" -le 2 ]
}

@test "cost: an allowlisted command runs no just at all" {
  count_stub
  hook_env "ls -la" "" "$JUSTDIR" "$CNT" >/dev/null
  [ "$(calls)" -eq 0 ]
}
