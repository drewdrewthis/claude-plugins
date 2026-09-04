#!/usr/bin/env bats
# Tests for hooks/enforce-just.sh — the PreToolUse Bash nudge/block hook.
#
# WHAT THIS FILE PROVES:
#   1. THE THREE MODES ARE DISTINCT. off/0 is fully silent (no output, no log);
#      strict denies; unset/default nudges.
#   2. NUDGE IS MATCH-GATED. It fires only when the command's leading word
#      plausibly maps to a recipe — by summary name OR by a doc comment — and
#      is a SILENT allow otherwise. Strict denies regardless of any match.
#   3. THE wrap.log BACKLOG ACCRUES in nudge AND strict where a justfile
#      resolves and the command is not allowlisted, and NEVER in off.
#   4. FAIL-OPEN HOLDS: no justfile / allowlisted `just` -> silent passthrough.
#
# NO REAL `just` IS INSTALLED FOR THE SUITE. A stub first on PATH parses the
# fixture justfile in cwd, so --summary / --list are deterministic and the
# "no justfile" path is exercised by pointing at an empty dir (the stub exits
# nonzero when no justfile is present, exactly as real just does).

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

  # `just` stub: parses the justfile in cwd. Exits nonzero when absent.
  STUB="$SCRATCH/bin"
  mkdir -p "$STUB"
  cat > "$STUB/just" <<'SH'
#!/usr/bin/env bash
jf=""
for f in justfile Justfile .justfile; do [ -f "$f" ] && { jf="$f"; break; }; done
[ -n "$jf" ] || { echo "error: No justfile found." >&2; exit 1; }
case "${1:-}" in
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

@test "strict deny reason carries the escape-hatch guidance" {
  run run_hook "wget http://x" strict
  printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -q "just --list"
  printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -q 'global::wrap'
}

# --- passthrough / fail-open ---------------------------------------------

@test "no justfile -> silent passthrough (nudge mode)" {
  run run_hook "wget http://x" "" "$EMPTYDIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f "$WRAPLOG" ]
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

@test "silent allow when no recipe plausibly matches" {
  run run_hook "wget http://x"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- wrap.log backlog -----------------------------------------------------

@test "wrap.log line appended in nudge mode" {
  run run_hook "build --release"
  [ -f "$WRAPLOG" ]
  [ "$(wc -l < "$WRAPLOG" | tr -d ' ')" = "1" ]
  # fields: ts <tab> hook <tab> dir <tab> command
  awk -F'\t' -v d="$JUSTDIR" '{ if ($2!="hook" || $3!=d) exit 1; if (index($4,"build --release")==0) exit 1 }' "$WRAPLOG"
}

@test "wrap.log line appended even when nudge stays silent (no match)" {
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
  [ -z "$output" ]
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

@test "just --list erroring (stub exits 2) -> exit 0" {
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
  [ -z "$output" ]
}
