#!/usr/bin/env bats
# stores.sh resolver tests.
#
# Proves procedures_state_dir's precedence: PROCEDURES_STATE_DIR (explicit
# override) > XDG_STATE_HOME/procedures/librarian > $HOME/.local/state/...
# — the per-machine runtime-state dir the librarian keeps OUT of the corpus.
#
# Run: bats scripts/lib/tests/stores.bats

setup() {
  STORES_SH="$BATS_TEST_DIRNAME/../stores.sh"
  export HOME="$(mktemp -d "${BATS_TMPDIR:-/tmp}/stores-home.XXXXXX")"
  unset PROCEDURES_STATE_DIR XDG_STATE_HOME
}

teardown() { rm -rf "$HOME" 2>/dev/null || true; }

# Source stores.sh in a clean subshell and print the resolved state dir.
resolve() { bash -c 'source "$1"; procedures_state_dir' _ "$STORES_SH"; }

@test "procedures_state_dir defaults to \$HOME/.local/state/procedures/librarian" {
  run resolve
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/.local/state/procedures/librarian" ]
}

@test "XDG_STATE_HOME overrides the hardcoded default" {
  export XDG_STATE_HOME="$HOME/xdgstate"
  run resolve
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/xdgstate/procedures/librarian" ]
}

@test "PROCEDURES_STATE_DIR overrides XDG_STATE_HOME and the default" {
  export PROCEDURES_STATE_DIR="$HOME/custom/place"
  export XDG_STATE_HOME="$HOME/xdgstate"
  run resolve
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/custom/place" ]
}
