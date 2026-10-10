#!/usr/bin/env bats
#
# Tests for ../repair-release-manifests.sh. The script talks to GitHub only through
# `gh api`; ./fake-gh stands in for it and records every call, so the suite makes
# no network call. Status, ::error:: and ::warning:: lines are read from STDOUT.

SCRIPT="$BATS_TEST_DIRNAME/../repair-release-manifests.sh"
REAL_CFG="$BATS_TEST_DIRNAME/../../../release-please-config.json"
INCIDENT="$BATS_TEST_DIRNAME/fixtures/incident"
MANIFEST=".release-please-manifest.json"
PREFIX="release-please--branches--main--components--"

# merge base: gamma first (key order is part of the contract), beta ahead of the stale branch
BASE='{"plugins/gamma":"1.0.0","plugins/alpha":"1.0.0","plugins/beta":"2.0.0"}'
# alpha bumped, beta set back: the stale-write signature
STALE='{"plugins/alpha":"1.1.0","plugins/beta":"1.0.0","plugins/gamma":"1.0.0"}'
# alpha bumped, nothing else changed (different key order on purpose)
HEALTHY='{"plugins/alpha":"1.1.0","plugins/beta":"2.0.0","plugins/gamma":"1.0.0"}'

setup() {
  FX="$BATS_TEST_TMPDIR/gh"
  mkdir -p "$FX/compare" "$FX/contents" "$BATS_TEST_TMPDIR/bin"
  : > "$FX/calls.log"; : > "$FX/prs.ndjson"
  cp "$BATS_TEST_DIRNAME/fake-gh" "$BATS_TEST_TMPDIR/bin/gh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export FAKE_GH_DIR="$FX" FAKE_GH_MANIFEST_PATH="$MANIFEST" ERR="$BATS_TEST_TMPDIR/stderr"
  export GH_TOKEN=test-token GITHUB_REPOSITORY=acme/plugins
  unset BASE_BRANCH DRY_RUN FAKE_GH_FAIL
  CFG="$BATS_TEST_TMPDIR/config.json"
  cat > "$CFG" <<'JSON'
{ "packages": {
  "plugins/alpha": { "component": "alpha" },
  "plugins/beta": { "component": "beta" },
  "plugins/gamma": { "component": "gamma" } } }
JSON
}

# A call the fake does not know is a failed test, even when the script swallowed it.
teardown() {
  [ ! -e "$FX/unknown-call" ] || { echo "fake-gh got a call it does not know:"; cat "$FX/calls.log"; return 1; }
}

# add_pr <number> <ref> [<head repo full name> | null] [<label> | none] [<head sha>]
# Default head sha: 40 hex starting with "a" (see fake-gh).
add_pr() {
  local repo="${3:-acme/plugins}" label="${4:-autorelease: pending}" sha="${5:-$(printf 'a%039x' "$1")}"
  jq -nc --argjson n "$1" --arg ref "$2" --arg repo "$repo" --arg lab "$label" --arg sha "$sha" '{
    number: $n, user: {login: "github-actions[bot]"},
    head: {ref: $ref, sha: $sha,
           repo: (if $repo == "null" then null else {full_name: $repo} end)},
    labels: (if $lab == "none" then [] else [{name: $lab}] end)}' >> "$FX/prs.ndjson"
}

# b64_json <file>: the contents API shape, base64 wrapped at 60 columns with a trailing newline
b64_json() {
  jq -nc --arg c "$(base64 < "$1" | tr -d '\n' | fold -w60)" --arg sha "$2" \
    '{sha: $sha, content: (if $c == "" then $c else $c + "\n" end)}'
}

# stage <ref> <base manifest file> <head manifest file>: serves what the PR's head sha
# and its merge base (same number, first char "b") need; blob "blob-<ref>"
stage() {
  local head mb
  head=$(jq -r --arg r "$1" 'select(.head.ref == $r) | .head.sha' "$FX/prs.ndjson")
  mb="b${head:1}"
  jq -nc --arg sha "$mb" '{merge_base_commit: {sha: $sha}}' > "$FX/compare/$head.json"
  b64_json "$2" blob-mb > "$FX/contents/$mb.json"
  b64_json "$3" "blob-$1" > "$FX/contents/$head.json"
}

# stage_json <ref> <base json> <head json>
stage_json() {
  printf '%s\n' "$2" > "$BATS_TEST_TMPDIR/base-$1.json"
  printf '%s\n' "$3" > "$BATS_TEST_TMPDIR/head-$1.json"
  stage "$1" "$BATS_TEST_TMPDIR/base-$1.json" "$BATS_TEST_TMPDIR/head-$1.json"
}

# run_repair [args...]: defaults to <config> <manifest path>
run_repair() {
  # Negative assertions (zero PUT) would pass vacuously without the script.
  [ -x "$SCRIPT" ] || { echo "script missing or not executable: $SCRIPT" >&2; return 1; }
  [ -f "$FX/pulls.json" ] || jq -s . "$FX/prs.ndjson" > "$FX/pulls.json"
  [ $# -gt 0 ] || set -- "$CFG" "$MANIFEST"
  run bash -c '"$0" "$@" 2>"$ERR"' "$SCRIPT" "$@"
}

puts() { find "$FX" -maxdepth 1 -name 'put-[0-9]*' | wc -l; }
gh_calls() { grep -c . "$FX/calls.log" || true; }

# A refused PR: non-zero exit, the ::error:: line for the ref with its specific message, and no write.
assert_refused() {
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::$1: "*"$2"* ]]
  [ "$(puts)" -eq 0 ]
}

# head_sha_of <ref>
head_sha_of() { jq -r --arg r "$1" 'select(.head.ref == $r) | .head.sha' "$FX/prs.ndjson"; }

# --- stale branch -----------------------------------------------------------

stale_pr() { REF="${PREFIX}alpha"; add_pr 7 "$REF"; stage_json "$REF" "$BASE" "$STALE"; }

@test "stale branch gives exactly one PUT" {
  stale_pr; run_repair
  [ "$(puts)" -eq 1 ]
}

@test "stale branch PUT targets the release branch" {
  stale_pr; run_repair
  [ "$(cat "$FX/put-1/branch")" = "$REF" ]
}

@test "stale branch PUT carries the blob sha read from the release branch" {
  stale_pr; run_repair
  [ "$(cat "$FX/put-1/sha")" = "blob-$REF" ]
}

@test "stale branch PUT content is the merge-base manifest with the own line from the branch" {
  stale_pr; run_repair
  printf '{\n  "plugins/gamma": "1.0.0",\n  "plugins/alpha": "1.1.0",\n  "plugins/beta": "2.0.0"\n}\n' > "$BATS_TEST_TMPDIR/expected"
  base64 -d < "$FX/put-1/content" | cmp - "$BATS_TEST_TMPDIR/expected"
}

@test "reads carry the head sha and never the branch name; the PUT carries the branch" {
  stale_pr; run_repair
  sha=$(head_sha_of "$REF")
  grep -qF "compare/main...$sha" "$FX/calls.log"
  grep -qF "ref=$sha" "$FX/calls.log"
  run bash -c 'grep -v PUT "$0" | grep -cF "$1"' "$FX/calls.log" "$REF"
  [ "$output" = "0" ]
  [ "$(cat "$FX/put-1/branch")" = "$REF" ]
}

@test "stale branch never sends a PUT without a branch field" {
  stale_pr; run_repair
  [ ! -e "$FX/put-without-branch" ]
}

@test "stale branch reports repaired, with a warning annotation" {
  stale_pr; run_repair
  [[ "$output" == *"repaired: $REF"* ]]
  [[ "$output" == *"::warning::"*"$REF"* ]]
}

@test "stale branch exits 0" {
  stale_pr; run_repair
  [ "$status" -eq 0 ]
}

@test "stale branch run ends with the checked line" {
  stale_pr; run_repair
  [ "${lines[-1]}" = "checked: 1 release PR(s)" ]
}

@test "two other lines set back are both restored" {
  REF="${PREFIX}alpha"; add_pr 7 "$REF"
  stage_json "$REF" '{"plugins/alpha":"1.0.0","plugins/beta":"2.0.0","plugins/gamma":"3.0.0"}' \
                    '{"plugins/alpha":"1.1.0","plugins/beta":"1.0.0","plugins/gamma":"1.0.0"}'
  run_repair
  [ "$(base64 -d < "$FX/put-1/content" | jq -c '[.["plugins/beta"], .["plugins/gamma"]]')" = '["2.0.0","3.0.0"]' ]
}

@test "a line present at the merge base and absent on the branch is restored" {
  REF="${PREFIX}alpha"; add_pr 7 "$REF"
  stage_json "$REF" "$BASE" '{"plugins/alpha":"1.1.0","plugins/beta":"2.0.0"}'
  run_repair
  [ "$(base64 -d < "$FX/put-1/content" | jq -r '.["plugins/gamma"]')" = "1.0.0" ]
}

@test "DRY_RUN=1 on a stale branch reports would repair" {
  stale_pr; DRY_RUN=1 run_repair
  [[ "$output" == *"would repair: $REF"* ]]
}

@test "DRY_RUN=1 on a stale branch writes nothing" {
  stale_pr; DRY_RUN=1 run_repair
  [ "$(puts)" -eq 0 ]
}

@test "DRY_RUN=1 on a stale branch exits 0" {
  stale_pr; DRY_RUN=1 run_repair
  [ "$status" -eq 0 ]
}

# --- healthy branch ---------------------------------------------------------

healthy_pr() { REF="${PREFIX}alpha"; add_pr 7 "$REF"; stage_json "$REF" "$BASE" "$HEALTHY"; }

@test "healthy branch on an older main gives zero PUT" {
  healthy_pr; run_repair
  [ "$(puts)" -eq 0 ]
}

@test "healthy branch reports ok and exits 0" {
  healthy_pr; run_repair
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok: $REF"* ]]
}

# --- skip and refuse --------------------------------------------------------

@test "fork head is skipped with a warning" {
  REF="${PREFIX}alpha"; add_pr 7 "$REF" other/plugins; run_repair
  [[ "$output" == *"skip: $REF"* ]]
  [[ "$output" == *"::warning::"* ]]
}

@test "the warning for a fork head does not contain the branch name" {
  REF="${PREFIX}alpha"; add_pr 7 "$REF" other/plugins; run_repair
  warning=$(grep '^::warning::' <<< "$output")
  [ -n "$warning" ]
  [[ "$warning" != *"$REF"* ]]
}

@test "fork head gives zero PUT, exit 0 and counts as checked" {
  REF="${PREFIX}alpha"; add_pr 7 "$REF" other/plugins; run_repair
  [ "$(puts)" -eq 0 ]
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "checked: 1 release PR(s)" ]
}

@test "head.repo null is skipped like a fork" {
  REF="${PREFIX}alpha"; add_pr 7 "$REF" null; run_repair
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip: $REF"* ]]
  [ "$(puts)" -eq 0 ]
}

@test "unknown component is an error" {
  REF="${PREFIX}zeta"; add_pr 7 "$REF"; stage_json "$REF" "$BASE" "$STALE"; run_repair
  assert_refused "$REF" "component 'zeta' is not in"
}

@test "missing own line on the branch is an error" {
  REF="${PREFIX}alpha"; add_pr 7 "$REF"
  stage_json "$REF" "$BASE" '{"plugins/beta":"1.0.0","plugins/gamma":"1.0.0"}'; run_repair
  assert_refused "$REF" "own line plugins/alpha is missing"
}

@test "missing autorelease pending label is an error" {
  REF="${PREFIX}alpha"; add_pr 7 "$REF" acme/plugins none; stage_json "$REF" "$BASE" "$STALE"; run_repair
  assert_refused "$REF" "no 'autorelease: pending' label"
}

# The config names these components, so only the pattern check can refuse them.
strict_pattern_case() {
  REF="$PREFIX$1"; add_pr 7 "$REF"
  jq -n --arg c "$1" '{packages: {"plugins/evil": {component: $c}}}' > "$CFG"
  run_repair
}

@test "branch name outside the strict pattern is an error" {
  strict_pattern_case "alpha/evil"
  assert_refused "$REF" "does not match the release-please pattern"
}

@test "branch name with a space or semicolon is an error" {
  strict_pattern_case "alpha ;evil"
  assert_refused "$REF" "does not match the release-please pattern"
}

@test "branch name outside the strict pattern triggers no call beyond the list" {
  strict_pattern_case "alpha/evil"
  [ "$(gh_calls)" -eq 1 ]
}

@test "head sha that is not 40 hex is an error before any further call" {
  REF="${PREFIX}alpha"; add_pr 7 "$REF" acme/plugins "autorelease: pending" "main"; run_repair
  assert_refused "$REF" "head sha is not a commit sha"
  [ "$(gh_calls)" -eq 1 ]
}

@test "head sha missing from the list is an error before any further call" {
  REF="${PREFIX}alpha"; add_pr 7 "$REF"
  jq -c 'del(.head.sha)' "$FX/prs.ndjson" > "$FX/x" && mv "$FX/x" "$FX/prs.ndjson"; run_repair
  assert_refused "$REF" "head sha is not a commit sha"
  [ "$(gh_calls)" -eq 1 ]
}

@test "merge base sha that is not 40 hex is an error" {
  stale_pr
  jq -nc '{merge_base_commit: {sha: "main"}}' > "$FX/compare/$(head_sha_of "$REF").json"; run_repair
  assert_refused "$REF" "cannot find the merge base"
}

@test "branch manifest that is not JSON is an error" {
  REF="${PREFIX}alpha"; add_pr 7 "$REF"; stage_json "$REF" "$BASE" "this is not json"; run_repair
  assert_refused "$REF" "is not valid JSON"
}

@test "branch manifest with empty content is an error at the read" {
  REF="${PREFIX}alpha"; add_pr 7 "$REF"; stage_json "$REF" "$BASE" "$STALE"
  : > "$BATS_TEST_TMPDIR/empty"; stage "$REF" "$BATS_TEST_TMPDIR/base-$REF.json" "$BATS_TEST_TMPDIR/empty"
  run_repair
  assert_refused "$REF" "is not valid JSON"
}

@test "pull requests without the release prefix are ignored silently" {
  add_pr 3 "feature/x"; run_repair
  [ "$output" = "checked: 0 release PR(s)" ]
}

@test "no pull requests at all ends with checked 0 and exit 0" {
  run_repair
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "checked: 0 release PR(s)" ]
}

# --- failing gh calls -------------------------------------------------------

@test "failing pulls list is an error" {
  stale_pr; FAKE_GH_FAIL=pulls run_repair
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::cannot list open pull requests"* ]]
}

@test "failing compare call is an error for that PR" {
  stale_pr; FAKE_GH_FAIL=compare run_repair
  assert_refused "$REF" "cannot find the merge base"
}

@test "failing merge-base manifest read is an error for that PR" {
  stale_pr; FAKE_GH_FAIL=contents-base run_repair
  assert_refused "$REF" "cannot read $MANIFEST at merge base"
}

@test "failing head manifest read is an error for that PR" {
  stale_pr; FAKE_GH_FAIL=contents-head run_repair
  assert_refused "$REF" "cannot read $MANIFEST on the branch"
}

@test "PUT rejected with HTTP 409 is an error and is not reported as repaired" {
  stale_pr; FAKE_GH_FAIL=put run_repair
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::$REF: could not write the repair commit"* ]]
  [[ "$output" != *"repaired: $REF"* ]]
}

@test "PUT rejected with HTTP 409 is not retried" {
  stale_pr; FAKE_GH_FAIL=put run_repair
  [ "$(puts)" -eq 1 ]
}

# --- several PRs, pagination, env -------------------------------------------

@test "an error on PR 1 does not stop the repair of PR 2" {
  add_pr 6 "${PREFIX}zeta"; stage_json "${PREFIX}zeta" "$BASE" "$STALE"
  stale_pr; run_repair
  [ "$(cat "$FX/put-1/branch")" = "$REF" ]
}

@test "an error on PR 1 makes the run exit non-zero and counts both PRs" {
  add_pr 6 "${PREFIX}zeta"; stage_json "${PREFIX}zeta" "$BASE" "$STALE"
  stale_pr; run_repair
  [ "$status" -ne 0 ]
  [ "${lines[-1]}" = "checked: 2 release PR(s)" ]
}

@test "two concatenated pages from --paginate are both read" {
  add_pr 6 "${PREFIX}beta"; stage_json "${PREFIX}beta" "$BASE" '{"plugins/alpha":"1.0.0","plugins/beta":"2.1.0","plugins/gamma":"1.0.0"}'
  stale_pr
  { jq -s '[.[0]]' "$FX/prs.ndjson"; jq -s '[.[1]]' "$FX/prs.ndjson"; } > "$FX/pulls.json"
  run_repair
  [ "${lines[-1]}" = "checked: 2 release PR(s)" ]
}

@test "BASE_BRANCH selects the list, the compare and the branch prefix" {
  export BASE_BRANCH=rel
  REF="release-please--branches--rel--components--alpha"; add_pr 7 "$REF"; stage_json "$REF" "$BASE" "$STALE"
  run_repair
  [ "$(cat "$FX/put-1/branch")" = "$REF" ]
}

# --- usage ------------------------------------------------------------------

@test "no arguments exits non-zero with usage before any gh call" {
  run bash -c '"$0" 2>&1' "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *[Uu]sage* ]]
  [ "$(gh_calls)" -eq 0 ]
}

@test "missing config file exits non-zero before any gh call" {
  run bash -c '"$0" "$@" 2>&1' "$SCRIPT" "$BATS_TEST_TMPDIR/nope.json" "$MANIFEST"
  [ "$status" -eq 2 ]
  [[ "$output" == *nope.json* ]]
  [ "$(gh_calls)" -eq 0 ]
}

@test "missing GITHUB_REPOSITORY exits non-zero before any gh call" {
  unset GITHUB_REPOSITORY
  run bash -c '"$0" "$@" 2>&1' "$SCRIPT" "$CFG" "$MANIFEST"
  [ "$status" -eq 2 ]
  [[ "$output" == *GITHUB_REPOSITORY* ]]
  [ "$(gh_calls)" -eq 0 ]
}

# --- the 2026-10-10 incident (real data) ------------------------------------
# e86b71e4 (release branch for procedures) sat on top of 284c1d7e but carried the
# manifest of a main where ship was still 0.1.0. 24eb73a8 is the manifest that
# commit should have had.

@test "incident 2026-10-10: ship set back by the procedures release branch is restored byte for byte" {
  REF="${PREFIX}procedures"; add_pr 190 "$REF"
  stage "$REF" "$INCIDENT/base.json" "$INCIDENT/head.json"
  run_repair "$REAL_CFG" "$MANIFEST"
  [ "$(puts)" -eq 1 ]
  base64 -d < "$FX/put-1/content" | cmp - "$INCIDENT/expected.json"
}
