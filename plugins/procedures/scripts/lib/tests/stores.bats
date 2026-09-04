#!/usr/bin/env bats
# stores.sh resolver tests.
#
# Proves two resolvers, both now ~/.knowledge-aware:
#   procedures_state_dir — PROCEDURES_STATE_DIR (explicit override) >
#     ~/.knowledge/config.json `state_dir` > ~/.knowledge/state (only when that
#     dir exists) > XDG_STATE_HOME/procedures/librarian > $HOME/.local/state/...
#   STORE_ROOTS (via _stores_resolve_roots_spec) — env/settings > config.json
#     `modules` > auto-discovered ~/.knowledge/modules/* git repos > legacy.
# HOME is a fresh mktemp dir with no ~/.knowledge, so the pre-existing state-dir
# tests below still take the XDG/hardcoded fallback path unchanged.
#
# Run: bats scripts/lib/tests/stores.bats

setup() {
  STORES_SH="$BATS_TEST_DIRNAME/../stores.sh"
  export HOME="$(mktemp -d "${BATS_TMPDIR:-/tmp}/stores-home.XXXXXX")"
  # A stray CLAUDE_CONFIG_DIR/settings.json or an inherited CODEX_STORE_ROOTS in
  # the ambient env would outrank the ~/.knowledge tiers under test, so clear
  # every higher- and lower-precedence source and let HOME alone decide.
  unset PROCEDURES_STATE_DIR XDG_STATE_HOME \
        CODEX_STORE_ROOTS CODEX_ROOT KNOWLEDGE_HOME CLAUDE_CONFIG_DIR \
        CODEX_RECORDS_DIR
}

teardown() { rm -rf "$HOME" 2>/dev/null || true; }

# Source stores.sh in a clean subshell and print the resolved state dir.
resolve() { bash -c 'source "$1"; procedures_state_dir' _ "$STORES_SH"; }

# Source stores.sh in a clean subshell and print STORE_ROOTS, one per line.
# STORE_ROOTS is populated at source time by
# `_stores_split_roots "$(_stores_resolve_roots_spec)"`.
resolve_roots() {
  bash -c 'source "$1"; for r in ${STORE_ROOTS[@]+"${STORE_ROOTS[@]}"}; do printf "%s\n" "$r"; done' _ "$STORES_SH"
}

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

# --- store-root resolution -------------------------------------------------

@test "auto-discovery finds two fake ~/.knowledge/modules in alphabetical order" {
  mkdir -p "$HOME/.knowledge/modules/alpha/.git"
  mkdir -p "$HOME/.knowledge/modules/beta/.git"
  run resolve_roots
  [ "$status" -eq 0 ]
  # Exactly the two module dirs, alphabetical (bash glob order), nothing else.
  [ "${lines[0]}" = "$HOME/.knowledge/modules/alpha" ]
  [ "${lines[1]}" = "$HOME/.knowledge/modules/beta" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "config.json modules overrides auto-discovery: config order wins, unlisted module excluded" {
  # Discovery WOULD find all three if config.json were absent.
  mkdir -p "$HOME/.knowledge/modules/alpha/.git"
  mkdir -p "$HOME/.knowledge/modules/beta/.git"
  mkdir -p "$HOME/.knowledge/modules/gamma/.git"
  # Reversed order, gamma deliberately omitted.
  printf '{"modules": ["beta", "alpha"]}\n' > "$HOME/.knowledge/config.json"
  run resolve_roots
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$HOME/.knowledge/modules/beta" ]
  [ "${lines[1]}" = "$HOME/.knowledge/modules/alpha" ]
  [ "${#lines[@]}" -eq 2 ]   # gamma excluded, discovery not consulted
}

@test "resolve_roots: nothing configured resolves zero roots (spec is empty)" {
  run resolve_roots
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 0 ]
}

@test "_stores_resolve_roots_spec returns exit 1 and empty output when nothing resolves" {
  run bash -c 'source "$1"; _stores_resolve_roots_spec' _ "$STORES_SH"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "CODEX_ROOT still works as the legacy explicit override" {
  export CODEX_ROOT="$HOME/legacy-root"
  run resolve_roots
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$HOME/legacy-root" ]
  [ "${#lines[@]}" -eq 1 ]
}

@test "_stores_no_roots_message prints the canonical error text" {
  run bash -c 'source "$1"; _stores_no_roots_message' _ "$STORES_SH"
  [ "$status" -eq 0 ]
  [ "$output" = "no knowledge roots found — clone a module into ~/.knowledge/modules/<name> or set CODEX_STORE_ROOTS" ]
}

# --- state-dir ~/.knowledge precedence (three-way) -------------------------
# The pre-existing tests above cover the case where ~/.knowledge is absent
# entirely (XDG/hardcoded fallback); these three cover it present.

@test "state_dir: PROCEDURES_STATE_DIR wins over config.json state_dir and ~/.knowledge/state" {
  mkdir -p "$HOME/.knowledge"
  printf '{"state_dir": "%s/from-config"}\n' "$HOME" > "$HOME/.knowledge/config.json"
  export PROCEDURES_STATE_DIR="$HOME/from-env"
  run resolve
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/from-env" ]
}

@test "state_dir: config.json state_dir wins over the ~/.knowledge/state default" {
  mkdir -p "$HOME/.knowledge"
  printf '{"state_dir": "%s/from-config"}\n' "$HOME" > "$HOME/.knowledge/config.json"
  run resolve
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/from-config" ]
}

@test "state_dir: falls to ~/.knowledge/state when the dir exists and config has no state_dir" {
  mkdir -p "$HOME/.knowledge"
  printf '{"modules": ["x"]}\n' > "$HOME/.knowledge/config.json"   # no state_dir key
  run resolve
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/.knowledge/state" ]
}

# --- record-tree dirname resolution (stores_records_dir) --------------------
# The corpus record tree is being renamed per root from a legacy references/
# layout to a records/ layout; stores_records_dir resolves the bare dirname
# per root at runtime so a mixed fleet keeps working.

# Print stores_records_dir for a given root path, in a clean subshell.
records_dir() { bash -c 'source "$1"; stores_records_dir "$2"' _ "$STORES_SH" "$1"; }

# cd into a fixture root, run _stores_discover, print $RECORDS_ROOT then each
# STORES entry (one per line). CWD == root is _stores_discover's contract.
discover_in() {
  bash -c 'source "$1"; cd "$2" || exit 9; _stores_discover
    printf "RECORDS_ROOT=%s\n" "$RECORDS_ROOT"
    for s in ${STORES[@]+"${STORES[@]}"}; do printf "STORE=%s\n" "$s"; done' \
    _ "$STORES_SH" "$1"
}

@test "stores_records_dir: root with only records/ resolves to records" {
  mkdir -p "$HOME/root/records"
  run records_dir "$HOME/root"
  [ "$status" -eq 0 ]
  [ "$output" = "records" ]
}

@test "stores_records_dir: root with only references/ resolves to references" {
  mkdir -p "$HOME/root/references"
  run records_dir "$HOME/root"
  [ "$status" -eq 0 ]
  [ "$output" = "references" ]
}

@test "stores_records_dir: both records/ and references/ present — records wins" {
  mkdir -p "$HOME/root/records" "$HOME/root/references"
  run records_dir "$HOME/root"
  [ "$status" -eq 0 ]
  [ "$output" = "records" ]
}

@test "stores_records_dir: CODEX_RECORDS_DIR override wins regardless of disk" {
  mkdir -p "$HOME/root/references"   # references exists, but override must win
  export CODEX_RECORDS_DIR="custom-dir"
  run records_dir "$HOME/root"
  [ "$status" -eq 0 ]
  [ "$output" = "custom-dir" ]
}

@test "stores_records_dir: neither dir present falls back to references" {
  mkdir -p "$HOME/root"
  run records_dir "$HOME/root"
  [ "$status" -eq 0 ]
  [ "$output" = "references" ]
}

@test "_stores_discover: STORES uses the resolved records dirname end-to-end" {
  mkdir -p "$HOME/root/records/decisions"
  run discover_in "$HOME/root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RECORDS_ROOT=records"* ]]
  [[ "$output" == *"STORE=records/decisions"* ]]
  # The legacy references/ dirname must NOT appear when records/ exists.
  [[ "$output" != *"STORE=references/"* ]]
}

@test "_stores_discover: legacy references-only root behaves as before" {
  mkdir -p "$HOME/root/references/decisions"
  run discover_in "$HOME/root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RECORDS_ROOT=references"* ]]
  [[ "$output" == *"STORE=references/decisions"* ]]
  [[ "$output" == *"STORE=references/principles"* ]]
}
