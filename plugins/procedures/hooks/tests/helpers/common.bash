# Shared bats helpers. Pulled in with `load helpers/common` (bats resolves the
# path relative to the test file's directory and appends .bash). Kept in a
# subdirectory with a .bash suffix so the CI glob hooks/tests/*.bats never
# treats it as a suite. Everything here must stay bash 3.2 + BSD portable.

# Clear every ambient gate switch by prefix so a developer's shell cannot arm
# or release a gate behind the suite's back. A prefix, not a list: a list goes
# stale the day a key is added, and that is the day a leaked arm would hide.
# compgen -v lists shell variables (exported or not) and exists in bash 3.2.
clear_gate_switches() {
  local v
  for v in $(compgen -v PROCEDURES_ENABLE_) $(compgen -v CLAUDE_PLUGIN_OPTION_ENABLE_); do
    unset "$v"
  done
}

# chmod 000 does not restrict root, so the unreadable-lib tests would fail for
# the wrong reason there.
skip_if_root() {
  if [ "$(id -u)" -eq 0 ]; then skip "chmod 000 does not restrict root; unreadable-lib tests need a non-root user"; fi
}

# Epoch seconds -> touch -t stamp. GNU date takes -d @N, BSD date takes -r N;
# `touch -d` itself is GNU-only, `touch -t` is POSIX.
_stamp() { date -d "@$1" +%Y%m%d%H%M.%S 2>/dev/null || date -r "$1" +%Y%m%d%H%M.%S; }
_touch_ago() { touch -t "$(_stamp $(( $(date +%s) - $2 )))" "$1"; }

# git >= 2.47 starts `git maintenance run --auto --detach` after every commit.
# That background process locks files under .git/objects and races the
# `rm -rf` of a fixture repo in teardown ("Directory not empty", seen on macOS).
# GIT_CONFIG_COUNT env config is NOT enough: git strips it from the
# receive-pack child of a local push, which then spawns its own maintenance in
# the bare remote. GIT_CONFIG_GLOBAL survives that hop (git >= 2.32; older git
# ignores it, and is not covered: it is older than every CI runner). The file lives in
# the per-test tmp dir so bats cleans it up and the real ~/.gitconfig is untouched.
git_no_auto_maintenance() {
  local cfg="${BATS_TEST_TMPDIR:?}/no-auto-maintenance.gitconfig"
  printf '[maintenance]\n\tauto = false\n[gc]\n\tauto = 0\n[receive]\n\tautogc = false\n' > "$cfg"
  export GIT_CONFIG_GLOBAL="$cfg"
}

# A system gitconfig (/etc/gitconfig, or GIT_CONFIG_SYSTEM) can change fixture
# behaviour: measured, a system `push.default = nothing` fails three
# commit-records tests. GIT_CONFIG_NOSYSTEM wins over GIT_CONFIG_SYSTEM and,
# unlike GIT_CONFIG_SYSTEM=/dev/null, also works on git older than 2.32.
git_fixture_env() {
  git_no_auto_maintenance
  export GIT_CONFIG_NOSYSTEM=1
}

# GNU stat -c vs BSD stat -f.
_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
_inode() { stat -c %i "$1" 2>/dev/null || stat -f %i "$1"; }

# git_shim <intercept-snippet> — build a `git` shim and set GIT_SHIM_DIR; the
# caller puts it first on PATH (PATH="$GIT_SHIM_DIR:$PATH"). Prints nothing.
# The shim resolves the real git here, before PATH changes, then runs the
# snippet inline and falls through to the real git. The snippet sees:
#   $real     absolute path of the real git
#   $dir      the -C directory ("." when no -C was given)
#   ${args[@]} the arguments with a leading `-C <dir>` stripped
# and may `exit` to swallow the call. One shared body keeps each test to just
# the behaviour it fakes, so a respelled git call cannot slip past a copy.
git_shim() {
  local real; real="$(command -v git)"
  GIT_SHIM_DIR="${BATS_TEST_TMPDIR:?}/git-shim"
  mkdir -p "$GIT_SHIM_DIR"
  {
    printf '#!/usr/bin/env bash\nreal=%q\n' "$real"
    cat <<'HEAD'
args=("$@")
dir=.
if [ "${args[0]:-}" = "-C" ]; then dir="${args[1]}"; args=("${args[@]:2}"); fi
HEAD
    printf '%s\n' "$1"
    cat <<'TAIL'
exec "$real" "$@"
TAIL
  } > "$GIT_SHIM_DIR/git"
  chmod +x "$GIT_SHIM_DIR/git"
}
