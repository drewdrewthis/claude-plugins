#!/usr/bin/env bash
# Restore the other plugins' lines on a release-please branch whose
# .release-please-manifest.json set them back.
#
# WHY: release-please rewrites the whole manifest from a copy it cached at run
# start onto main's newest head, so a merge that lands during the run is undone
# on the release branch. Merging that PR would publish the stale version of an
# unrelated plugin. https://github.com/drewdrewthis/claude-plugins/issues/232
# Upstream: https://github.com/googleapis/release-please/issues/2890
#
# A release branch's manifest must equal the manifest at its MERGE BASE with the
# base branch, except for its own package line. We compare against the merge
# base and not main's head on purpose: a healthy branch cut from an older main
# differs from main's head and still merges cleanly, so a head comparison would
# "repair" healthy branches.
#
# Fix: one normal commit on the release branch (never a force push, never a
# write to any other path).
#
# Usage: GH_TOKEN=... GITHUB_REPOSITORY=owner/repo [BASE_BRANCH=main] [DRY_RUN=1] \
#          repair-release-manifests.sh <release-please-config.json> <manifest-path>
# Exit 1 if any release PR could not be checked or repaired. Other PRs still run.
set -euo pipefail

usage() {
  echo "usage: GH_TOKEN=... GITHUB_REPOSITORY=owner/repo $0 <release-please-config.json> <manifest-path>" >&2
  exit 2
}

[[ $# -eq 2 ]] || usage
config=$1
manifest=$2
[[ -r "$config" ]] || { echo "cannot read config file: $config" >&2; exit 2; }
[[ -n "${GITHUB_REPOSITORY:-}" ]] || { echo "GITHUB_REPOSITORY is not set" >&2; exit 2; }

repo=$GITHUB_REPOSITORY
base=${BASE_BRANCH:-main}
prefix="release-please--branches--$base--components--"
failed=0
checked=0

bad() { echo "::error::$1: $2"; failed=1; }

# Key order of the merge base is kept so the commit only touches the broken lines.
decode() { jq -er '.content | gsub("\n"; "") | @base64d' | jq -c .; }

repair_one() {
  local ref=$1 fork=$2 pending=$3 component key mb head_resp base_json head_json own expected diff blob content

  if [[ $fork == true ]]; then
    echo "skip: $ref (head is not in $repo)"
    echo "::warning::$ref: head is not in $repo; not touched"
    return
  fi

  # Strict pattern before the ref reaches any URL or write.
  component=${ref#"$prefix"}
  [[ $component =~ ^[A-Za-z0-9._-]+$ ]] || { bad "$ref" "branch name does not match the release-please pattern"; return; }
  [[ $pending == true ]] || { bad "$ref" "no 'autorelease: pending' label"; return; }

  key=$(jq -r --arg c "$component" '[.packages | to_entries[] | select(.value.component == $c) | .key] | first // empty' "$config") ||
    { bad "$ref" "cannot read $config"; return; }
  [[ -n $key ]] || { bad "$ref" "component '$component' is not in $config"; return; }

  mb=$(gh api "repos/$repo/compare/$base...$ref" | jq -er '.merge_base_commit.sha') ||
    { bad "$ref" "cannot find the merge base with $base"; return; }
  base_json=$(gh api "repos/$repo/contents/$manifest?ref=$mb" | decode) ||
    { bad "$ref" "cannot read $manifest at merge base $mb"; return; }
  head_resp=$(gh api "repos/$repo/contents/$manifest?ref=$ref") ||
    { bad "$ref" "cannot read $manifest on the branch"; return; }
  head_json=$(decode <<< "$head_resp") || { bad "$ref" "$manifest on the branch is not valid JSON"; return; }
  blob=$(jq -er '.sha' <<< "$head_resp") || { bad "$ref" "no blob sha for $manifest on the branch"; return; }
  own=$(jq -ec --arg k "$key" '.[$k] | select(. != null)' <<< "$head_json") ||
    { bad "$ref" "own line $key is missing from $manifest on the branch"; return; }

  expected=$(jq -c --arg k "$key" --argjson v "$own" '.[$k] = $v' <<< "$base_json") || { bad "$ref" "cannot build the expected manifest"; return; }
  if jq -en --argjson a "$expected" --argjson b "$head_json" '$a == $b' > /dev/null; then
    echo "ok: $ref"
    return
  fi

  diff=$(jq -nr --argjson a "$head_json" --argjson b "$expected" \
    '[($a + $b | keys[]) as $k | select($a[$k] != $b[$k]) | "\($k) \($a[$k] // "absent") -> \($b[$k] // "absent")"] | join(", ")' |
    tr -d '\r\n') || { bad "$ref" "cannot describe the difference"; return; }

  if [[ ${DRY_RUN:-} == 1 ]]; then
    echo "would repair: $ref ($diff)"
    return
  fi

  content=$(jq --indent 2 . <<< "$expected" | base64 -w0) || { bad "$ref" "cannot encode the repair"; return; }
  # One attempt: a 409 means the branch moved, and the next run re-checks it.
  gh api -X PUT "repos/$repo/contents/$manifest" \
    -f "message=chore(release): restore manifest lines set back by release-please" \
    -f "content=$content" -f "sha=$blob" -f "branch=$ref" > /dev/null ||
    { bad "$ref" "could not write the repair commit"; return; }
  echo "repaired: $ref ($diff)"
  echo "::warning::$ref: restored manifest lines set back by release-please ($diff)"
}

pulls=$(gh api --paginate "repos/$repo/pulls?state=open&base=$base&per_page=100") ||
  { echo "::error::cannot list open pull requests"; exit 1; }

# --paginate may concatenate arrays; jq reads each as its own value.
list=$(jq -r --arg p "$prefix" --arg repo "$repo" '.[] | select(.head.ref | startswith($p)) |
  [.head.ref, ((.head.repo.full_name // "") != $repo), ([.labels[].name] | index("autorelease: pending") != null)] | @tsv' <<< "$pulls") ||
  { echo "::error::cannot parse the pull request list"; exit 1; }

if [[ -n $list ]]; then
  while IFS=$'\t' read -r ref fork pending; do
    checked=$((checked + 1))
    repair_one "$ref" "$fork" "$pending"
  done <<< "$list"
fi

echo "checked: $checked release PR(s)"
exit "$failed"
