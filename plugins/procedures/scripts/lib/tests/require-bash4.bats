#!/usr/bin/env bats
# require-bash4.sh tests.
#
# Proves the interpreter search and the guard/no-op/re-exec logic WITHOUT
# needing an actual bash<4 host or the real /opt/homebrew filesystem. The
# search is driven entirely through `command -v` against a controlled PATH and
# the documented test seams (REQUIRE_BASH4_CANDIDATE_PATHS,
# REQUIRE_BASH4_PATH_PREPEND, _REQUIRE_BASH4_FORCE_MAJOR), so every branch is
# exercised against temp `bash`/`brew` shims rather than literal path checks.
#
# The finder is bash-3.2-safe, so the outer interpreter running each probe can
# be anything; PATH and $BASH are set INSIDE the `-c` script (never via `env
# PATH=...`, which would strip the ability to locate the outer `bash` itself).
#
# Run: bats scripts/lib/tests/require-bash4.bats

setup() {
  LIB="$BATS_TEST_DIRNAME/../require-bash4.sh"
  BIN="$(mktemp -d "${BATS_TMPDIR:-/tmp}/rb4.XXXXXX")"
  # Outer interpreter for the probes — the bats-invoking bash, which exists by
  # absolute path. The finder itself is bash-3.2-safe, so its version is moot.
  RUNBASH="${BASH:-/bin/bash}"

  # A fake bash reporting an arbitrary major version: it ignores its args and
  # prints the number, exactly as `bash -c 'printf %s "${BASH_VERSINFO[0]}"'`
  # would. version_ok invokes the candidate and reads this.
  make_fake_bash() { # <path> <major>
    cat > "$1" <<EOF
#!/bin/sh
printf %s $2
EOF
    chmod +x "$1"
  }
  make_fake_bash "$BIN/fakebash5" 5
  make_fake_bash "$BIN/fakebash3" 3

  # Resolve a genuine bash >=4 for the no-op test — the invoking `bash` on PATH
  # may be macOS's 3.2. Empty if none exists (that test then skips).
  BASH4=""
  local c m
  for c in "${BASH:-}" /opt/homebrew/bin/bash /usr/local/bin/bash \
           "$(command -v bash5 2>/dev/null || true)" \
           "$(command -v bash 2>/dev/null || true)"; do
    [ -n "$c" ] && [ -x "$c" ] || continue
    m="$("$c" -c 'printf %s "${BASH_VERSINFO[0]:-0}"' 2>/dev/null)" || continue
    case "$m" in '' | *[!0-9]*) continue ;; esac
    if [ "$m" -ge 4 ]; then BASH4="$c"; break; fi
  done
}

teardown() { rm -rf "$BIN" 2>/dev/null || true; }

# find_interp <bash-for-branch-a> <PATH> <candidate-paths> <path-prepend>
# Runs the pure finder with every seam controlled inside the subshell.
find_interp() {
  run "$RUNBASH" -c '
    BASH="$2"
    export PATH="$3"
    export REQUIRE_BASH4_CANDIDATE_PATHS="$4"
    export REQUIRE_BASH4_PATH_PREPEND="$5"
    source "$1"
    _require_bash4_find_interpreter
  ' _ "$LIB" "$1" "$2" "$3" "$4"
}

@test "finder returns the \$BASH candidate when it reports >=4" {
  find_interp "$BIN/fakebash5" "$BIN" "" ""
  [ "$status" -eq 0 ]
  [ "$output" = "$BIN/fakebash5" ]
}

@test "finder finds a fixed-path candidate (REQUIRE_BASH4_CANDIDATE_PATHS)" {
  # $BASH is a bash3 shim (branch a rejects); first fixed path is absent, the
  # second is our bash5 shim — proving the fixed-path branch, injected.
  find_interp "$BIN/fakebash3" "$BIN" "$BIN/absent:$BIN/fakebash5" ""
  [ "$status" -eq 0 ]
  [ "$output" = "$BIN/fakebash5" ]
}

@test "finder finds via 'brew --prefix bash'" {
  # brew shim answers `--prefix bash` with a dir holding bin/bash = bash5.
  mkdir -p "$BIN/brewbash/bin"
  make_fake_bash "$BIN/brewbash/bin/bash" 5
  cat > "$BIN/brew" <<EOF
#!/bin/sh
[ "\$1" = "--prefix" ] && [ "\$2" = "bash" ] && printf %s "$BIN/brewbash"
EOF
  chmod +x "$BIN/brew"
  find_interp "$BIN/fakebash3" "$BIN" "" ""
  [ "$status" -eq 0 ]
  [ "$output" = "$BIN/brewbash/bin/bash" ]
}

@test "finder returns nonzero/empty when no bash4+ candidate exists anywhere" {
  # bash3 everywhere: $BASH, the on-PATH `bash`, and the PATH-prepend lookup;
  # no fixed paths, no brew, no bash5.
  cp "$BIN/fakebash3" "$BIN/bash"
  find_interp "$BIN/fakebash3" "$BIN" "" ""
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "require_bash4 is a no-op (returns 0, no exec) when current bash is >=4" {
  [ -n "$BASH4" ] || skip "no bash >=4 available on this host"
  # Runs under a real bash >=4. If it exec'd, the marker after the call would
  # never print (exec replaces the process image).
  run "$BASH4" -c 'source "$1"; require_bash4 "prog"; echo MARKER' _ "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "MARKER" ]
}

@test "re-exec loop guard: sentinel set + bash<4 goes straight to error, no exec" {
  # Force a <4 running version and pre-set the sentinel. Even though a real
  # bash5 exists on this machine, require_bash4 must NOT search/exec — it must
  # hit the error path directly. Reaching the error message proves no exec
  # happened (an exec would have replaced this process).
  run "$RUNBASH" -c '
    export _REQUIRE_BASH4_FORCE_MAJOR=3
    export _REQUIRE_BASH4_REEXEC=1
    source "$1"
    require_bash4 "/some/compile-records.sh"
  ' _ "$LIB"
  [ "$status" -eq 1 ]
  [[ "$output" == *"compile-records.sh: requires bash 4 or newer (found bash 3)"* ]]
}
