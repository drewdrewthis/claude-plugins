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
# Env config reaches every git call, including those inside scripts under test.
git_no_auto_maintenance() {
  export GIT_CONFIG_COUNT=2
  export GIT_CONFIG_KEY_0=maintenance.auto GIT_CONFIG_VALUE_0=false
  export GIT_CONFIG_KEY_1=gc.auto GIT_CONFIG_VALUE_1=0
}
