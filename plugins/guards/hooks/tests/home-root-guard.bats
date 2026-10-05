#!/usr/bin/env bats
# Tests for hooks/home-root-guard.sh — the PreToolUse guard against creating
# new files directly in $HOME.
#
# HOME is a throwaway dir per test, so every path the hook resolves is
# synthetic. A deny is asserted on permissionDecision; an allow is asserted as
# exit 0 with EMPTY output (the hook stays silent when it has no objection).

setup() {
  HOOK="$BATS_TEST_DIRNAME/../home-root-guard.sh"
  FAKE_HOME="$(mktemp -d "${BATS_TMPDIR:-/tmp}/hrg-home.XXXXXX")"
  FAKE_HOME="$(cd -P "$FAKE_HOME" && pwd -P)"
  OUTSIDE="$(mktemp -d "${BATS_TMPDIR:-/tmp}/hrg-out.XXXXXX")"
  mkdir -p "$FAKE_HOME/proj" "$FAKE_HOME/notes"
  : > "$FAKE_HOME/existing.md"
  : > "$FAKE_HOME/.bashrc"
}

teardown() {
  rm -rf "$FAKE_HOME" "$OUTSIDE" 2>/dev/null || true
}

# bash_hook <command> [cwd]
bash_hook() {
  jq -nc --arg c "$1" --arg cwd "${2:-$FAKE_HOME/proj}" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' \
    | env -u HOME_ROOT_GUARD -u HOME_ROOT_GUARD_ALLOW HOME="$FAKE_HOME" bash "$HOOK"
}

# file_hook <tool> <path> [cwd]
file_hook() {
  local key=file_path
  [ "$1" = NotebookEdit ] && key=notebook_path
  jq -nc --arg t "$1" --arg k "$key" --arg p "$2" --arg cwd "${3:-$FAKE_HOME/proj}" \
    '{tool_name:$t,tool_input:{($k):$p},cwd:$cwd}' \
    | env -u HOME_ROOT_GUARD -u HOME_ROOT_GUARD_ALLOW HOME="$FAKE_HOME" bash "$HOOK"
}

decision() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null; }
reason()   { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null; }

assert_deny()  { [ "$status" -eq 0 ]; [ "$(decision "$output")" = "deny" ]; }
assert_allow() { [ "$status" -eq 0 ]; [ -z "$output" ]; }

# --- file tools: deny -------------------------------------------------------

@test "Write of a new file in the home root is denied with the documented reason" {
  run file_hook Write "$FAKE_HOME/CUTOVER-2026-10-05.md"
  assert_deny
  reason "$output" | grep -qF "Don't create files in the home root — put records in your workspace notes, scratch in /tmp or your scratchpad."
  reason "$output" | grep -qF "CUTOVER-2026-10-05.md"
}

@test "Write of a new non-allowlisted dotfile in the home root is denied" {
  run file_hook Write "$FAKE_HOME/.cutover-timers.txt"
  assert_deny
}

@test "Write with a ~/ path is resolved and denied" {
  run file_hook Write "~/foo.md"
  assert_deny
}

@test "Write with a relative path resolving to the home root is denied" {
  run file_hook Write "../foo.md" "$FAKE_HOME/proj"
  assert_deny
}

@test "Write through a dir symlink that points at HOME is denied" {
  ln -s "$FAKE_HOME" "$OUTSIDE/homelink"
  run file_hook Write "$OUTSIDE/homelink/foo.md"
  assert_deny
}

@test "Edit creating a new file in the home root is denied" {
  run file_hook Edit "$FAKE_HOME/new.log"
  assert_deny
}

@test "MultiEdit creating a new file in the home root is denied" {
  run file_hook MultiEdit "$FAKE_HOME/new.txt"
  assert_deny
}

@test "NotebookEdit creating a new notebook in the home root is denied" {
  run file_hook NotebookEdit "$FAKE_HOME/scratch.ipynb"
  assert_deny
}

# --- file tools: allow ------------------------------------------------------

@test "Write into a subdirectory of HOME is allowed" {
  run file_hook Write "$FAKE_HOME/notes/2026-10-05.md"
  assert_allow
}

@test "Write outside HOME is allowed" {
  run file_hook Write "$OUTSIDE/x.md"
  assert_allow
}

@test "Edit of an existing home-root file is allowed" {
  run file_hook Edit "$FAKE_HOME/existing.md"
  assert_allow
}

@test "Write overwriting an existing home-root file is allowed" {
  run file_hook Write "$FAKE_HOME/existing.md"
  assert_allow
}

@test "Write creating an allowlisted dotfile in the home root is allowed" {
  run file_hook Write "$FAKE_HOME/.zshrc"
  assert_allow
  run file_hook Write "$FAKE_HOME/.gitconfig"
  assert_allow
}

@test "HOME_ROOT_GUARD_ALLOW extends the allowlist (space or colon separated)" {
  run bash -c "jq -nc --arg p '$FAKE_HOME/.foorc' '{tool_name:\"Write\",tool_input:{file_path:\$p}}' | HOME='$FAKE_HOME' HOME_ROOT_GUARD_ALLOW='.barrc:.foorc' bash '$HOOK'"
  assert_allow
}

@test "HOME_ROOT_GUARD=off is a kill switch" {
  run bash -c "jq -nc --arg p '$FAKE_HOME/x.md' '{tool_name:\"Write\",tool_input:{file_path:\$p}}' | HOME='$FAKE_HOME' HOME_ROOT_GUARD=off bash '$HOOK'"
  assert_allow
}

@test "other tools are ignored" {
  run bash -c "jq -nc --arg p '$FAKE_HOME/x.md' '{tool_name:\"Read\",tool_input:{file_path:\$p}}' | HOME='$FAKE_HOME' bash '$HOOK'"
  assert_allow
}

# --- Bash: deny -------------------------------------------------------------

@test "Bash: > ~/foo.md is denied" {
  run bash_hook 'echo hi > ~/foo.md'
  assert_deny
}

@test "Bash: >> \$HOME/x.log is denied" {
  run bash_hook 'echo hi >> $HOME/x.log'
  assert_deny
}

@test "Bash: quoted \"\${HOME}/a b.txt\" is denied" {
  run bash_hook 'echo x > "${HOME}/a b.txt"'
  assert_deny
}

@test "Bash: redirect glued to the path (>~/x) is denied" {
  run bash_hook 'echo x >~/glued.md'
  assert_deny
}

@test "Bash: &> and >| redirects are denied" {
  run bash_hook 'ls &> ~/out.txt'
  assert_deny
  run bash_hook 'echo x >| ~/c'
  assert_deny
}

@test "Bash: tee ~/y is denied" {
  run bash_hook 'echo hi | tee -a ~/y'
  assert_deny
}

@test "Bash: touch of a new home-root file is denied" {
  run bash_hook 'touch ~/.cutover-timers.txt'
  assert_deny
}

@test "Bash: cp into ~/ uses the source basename and is denied" {
  run bash_hook 'cp /etc/hostname ~/'
  assert_deny
  reason "$output" | grep -qF "hostname"
}

@test "Bash: cp -t ~ is denied" {
  run bash_hook 'cp -t ~ a b'
  assert_deny
}

@test "Bash: mv x ~/z is denied" {
  run bash_hook 'mv x ~/z'
  assert_deny
}

@test "Bash: backup copy next to a dotfile in the home root is denied" {
  run bash_hook 'cp ~/.bashrc ~/.bashrc.bak'
  assert_deny
}

@test "Bash: cd ~ then a relative redirect is denied" {
  run bash_hook 'cd ~ && echo x > notes.md'
  assert_deny
}

@test "Bash: relative ../ redirect from a HOME subdir is denied" {
  run bash_hook 'echo x > ../root.md' "$FAKE_HOME/proj"
  assert_deny
}

@test "Bash: a static target behind a command substitution is still denied" {
  run bash_hook 'echo "$(date)" > ~/d.log'
  assert_deny
}

@test "Bash: a write after a heredoc body is still seen" {
  run bash_hook "cat > $OUTSIDE/x <<'EOF'
body
EOF
echo done > ~/after.md"
  assert_deny
}

@test "Bash: sudo tee is denied" {
  run bash_hook 'echo x | sudo tee ~/s.conf'
  assert_deny
}

# --- Bash: allow ------------------------------------------------------------

@test "Bash: reads are never blocked" {
  run bash_hook 'cat ~/foo.md'
  assert_allow
  run bash_hook 'cat < ~/in.txt'
  assert_allow
  run bash_hook 'ls ~ > /dev/null'
  assert_allow
}

@test "Bash: writing an existing home-root file is allowed" {
  run bash_hook 'echo hi >> ~/existing.md'
  assert_allow
}

@test "Bash: writing an allowlisted dotfile is allowed" {
  run bash_hook 'echo "alias x=y" >> ~/.bashrc'
  assert_allow
  run bash_hook 'touch ~/.zshrc'
  assert_allow
}

@test "Bash: writing into a HOME subdirectory is allowed" {
  run bash_hook 'echo x > ~/notes/today.md'
  assert_allow
}

@test "Bash: moving home-root files OUT to a subdir is allowed" {
  run bash_hook 'mkdir -p ~/.local/state/x && mv ~/existing.md ~/.local/state/x/'
  assert_allow
}

@test "Bash: heredoc body text is not parsed as commands" {
  run bash_hook "cat > $OUTSIDE/x <<'EOF'
echo > ~/inside.md
EOF"
  assert_allow
}

@test "Bash: quoted redirect text is not a redirect" {
  run bash_hook "echo '> ~/q.md'"
  assert_allow
  run bash_hook 'git commit -m "x > ~/y"'
  assert_allow
}

@test "Bash: a comment is not a redirect" {
  run bash_hook 'echo hi # > ~/comment.md'
  assert_allow
}

@test "Bash: fd duplication is not a file target" {
  run bash_hook 'echo x 2>&1 >/dev/null'
  assert_allow
}

@test "Bash: unresolvable targets are skipped (false negative over false positive)" {
  run bash_hook 'echo x > ~/$NAME'
  assert_allow
  run bash_hook 'echo x > ~/*.md'
  assert_allow
  run bash_hook 'echo x > ~someone/f'
  assert_allow
}

@test "Bash: cd to an unknown dir makes later relative targets unknown" {
  run bash_hook 'cd - && echo > rel.md' "$FAKE_HOME"
  assert_allow
}

@test "Bash: cd elsewhere then a relative write is allowed" {
  run bash_hook "cd $OUTSIDE && echo x > rel.md" "$FAKE_HOME"
  assert_allow
}

@test "Bash: commands with no write syntax exit before parsing" {
  run bash_hook 'git status'
  assert_allow
}

# --- fail-open --------------------------------------------------------------

@test "malformed stdin JSON -> exit 0, empty output" {
  run bash -c "printf 'not json' | HOME='$FAKE_HOME' bash '$HOOK'"
  assert_allow
}

@test "jq missing from PATH -> exit 0, empty output" {
  mkdir -p "$OUTSIDE/bin"
  ln -s "$(command -v cat)" "$OUTSIDE/bin/cat"
  run bash -c "printf '%s' '{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$FAKE_HOME/x.md\"}}' | PATH='$OUTSIDE/bin' HOME='$FAKE_HOME' '$BASH' '$HOOK'"
  assert_allow
}

@test "a 1500-command chain finishes well inside the hook timeout" {
  local c="" n
  for n in $(seq 1 1500); do c="${c}echo $n > $OUTSIDE/f$n && "; done
  c="${c}echo end > ~/late.md"
  SECONDS=0
  run bash_hook "$c"
  assert_deny
  [ "$SECONDS" -lt 8 ]
}
