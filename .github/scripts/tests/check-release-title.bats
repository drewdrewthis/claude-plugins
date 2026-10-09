#!/usr/bin/env bats

SCRIPT="$BATS_TEST_DIRNAME/../check-release-title.sh"
REAL="$BATS_TEST_DIRNAME/../../../release-please-config.json"

setup() {
  CFG="$BATS_TEST_TMPDIR/config.json"
  cat > "$CFG" <<'JSON'
{
  "changelog-sections": [
    { "type": "feat", "section": "Features" },
    { "type": "fix", "section": "Bug Fixes" },
    { "type": "docs", "section": "Documentation" },
    { "type": "chore", "section": "Chores", "hidden": true }
  ],
  "packages": { "plugins/alpha": {} }
}
JSON
}

run_check() { # <title> <config> <files...>
  local title="$1" cfg="$2"; shift 2
  export PR_TITLE="$title"
  run bash -c 'printf "%s\n" "${@:2}" | "$0" "$1"' "$SCRIPT" "$cfg" "$@"
}

@test "fix on managed plugin passes" {
  run_check "fix(alpha): x" "$CFG" plugins/alpha/x
  [ "$status" -eq 0 ]
}

@test "chore on managed plugin fails and names it" {
  run_check "chore(alpha): x" "$CFG" plugins/alpha/x
  [ "$status" -eq 1 ]
  [[ "$output" == *alpha* ]]
}

@test "breaking chore passes" {
  run_check "chore!: x" "$CFG" plugins/alpha/x
  [ "$status" -eq 0 ]
}

@test "ci touching no plugin passes" {
  run_check "ci: x" "$CFG" .github/x
  [ "$status" -eq 0 ]
}

@test "docs passes because type list comes from config" {
  run_check "docs(alpha): x" "$CFG" plugins/alpha/x
  [ "$status" -eq 0 ]
}

@test "unmanaged plugin fails and names it" {
  run_check "fix(beta): x" "$CFG" plugins/beta/x
  [ "$status" -eq 1 ]
  [[ "$output" == *beta* ]]
}

@test "non-conventional title with plugin change fails" {
  run_check "update stuff" "$CFG" plugins/alpha/x
  [ "$status" -eq 1 ]
}

@test "missing PR_TITLE exits 2" {
  unset PR_TITLE
  run bash -c 'echo plugins/alpha/x | "$0" "$1"' "$SCRIPT" "$CFG"
  [ "$status" -eq 2 ]
}

# These three read the live release-please-config.json on purpose, so a config edit
# that drops procedures or the fix type breaks them loudly.
@test "real config: chore on procedures fails" {
  run_check "chore(procedures): x" "$REAL" plugins/procedures/a
  [ "$status" -eq 1 ]
}

@test "real config: fix on procedures passes" {
  run_check "fix(procedures): x" "$REAL" plugins/procedures/a
  [ "$status" -eq 0 ]
}

@test "perf on managed plugin passes" {
  run_check "perf(procedures): x" "$REAL" plugins/procedures/a
  [ "$status" -eq 0 ]
}

@test "empty stdin exits 2" {
  export PR_TITLE="fix(alpha): x"
  run bash -c 'printf "" | "$0" "$1"' "$SCRIPT" "$CFG"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no changed files"* ]]
}

@test "feat with breaking bang passes" {
  run_check "feat(alpha)!: x" "$CFG" plugins/alpha/x
  [ "$status" -eq 0 ]
}

@test "two plugins, one unmanaged: fails and names only the unmanaged one" {
  run_check "fix(alpha): x" "$CFG" plugins/alpha/x plugins/beta/y
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not manage plugins/beta"* ]]
  [[ "$output" != *"does not manage plugins/alpha"* ]]
}
