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
# The rule assumes one release branch changes one manifest line (no linked-versions
# or workspace plugin in the config).
#
# Fix: one normal commit on the release branch (never a force push, never a
# write to any other path).
#
# Usage: GH_TOKEN=... GITHUB_REPOSITORY=owner/repo [BASE_BRANCH=main] [DRY_RUN=1] \
#          repair-release-manifests.sh <release-please-config.json> <manifest-path>
# Exit 1 if any release PR could not be checked or repaired. Other PRs still run.
# Exit 2 on a bad invocation (arguments, config file, GITHUB_REPOSITORY).
# Annotations go to stdout so they stay in order with the ok:/repaired: lines
# (check-release-title.sh uses stderr).
# Needs jq 1.6+.
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

# Slurping makes empty content, trailing text and a second value fail: the content
# must be exactly one JSON object. Key order of the merge base is kept so the commit
# only touches the broken lines.
decode() {
  jq -er '.content | gsub("\n"; "") | @base64d' |
    jq -ces 'if length == 1 and (.[0] | type) == "object" then .[0] else error("not one object") end'
}

repair_one() {
  local ref=$1 head_sha=$2 foreign=$3 pending=$4 component key mb head_resp base_json head_json expected same changes blob now content

  if [[ $foreign == true ]]; then
    echo "skip: $ref (head is not in $repo)"
    # The ref is chosen by the outsider, so it stays out of the annotation.
    echo "::warning::skipped a pull request from another repository that uses the release-please branch prefix"
    return
  fi

  # Strict pattern before the ref reaches any URL or write.
  component=${ref#"$prefix"}
  [[ $component =~ ^[A-Za-z0-9._-]+$ ]] || { bad "$ref" "branch name does not match the release-please pattern"; return; }
  [[ $pending == true ]] || { bad "$ref" "no 'autorelease: pending' label"; return; }
  # Every read of the branch uses this one commit, so a branch that moves mid-run cannot mix two states.
  [[ $head_sha =~ ^[0-9a-f]{40}$ ]] || { bad "$ref" "head sha is not a commit sha"; return; }

  key=$(jq -r --arg c "$component" '[.packages | to_entries[] | select(.value.component == $c) | .key] | first // empty' "$config") ||
    { bad "$ref" "cannot read $config"; return; }
  [[ -n $key ]] || { bad "$ref" "component '$component' is not in $config"; return; }

  mb=$(gh api "repos/$repo/compare/$base...$head_sha" | jq -er '.merge_base_commit.sha') &&
    [[ $mb =~ ^[0-9a-f]{40}$ ]] || { bad "$ref" "cannot find the merge base with $base"; return; }
  base_json=$(gh api "repos/$repo/contents/$manifest?ref=$mb" | decode) ||
    { bad "$ref" "cannot read $manifest at merge base $mb"; return; }
  head_resp=$(gh api "repos/$repo/contents/$manifest?ref=$head_sha") ||
    { bad "$ref" "cannot read $manifest on the branch"; return; }
  head_json=$(decode <<< "$head_resp") || { bad "$ref" "$manifest on the branch is not valid JSON"; return; }
  blob=$(jq -er '.sha' <<< "$head_resp") || { bad "$ref" "no blob sha for $manifest on the branch"; return; }
  expected=$(jq -ce --arg k "$key" --argjson h "$head_json" \
    'if ($h[$k] | type) != "string" then error("own line") else .[$k] = $h[$k] end' <<< "$base_json") ||
    { bad "$ref" "own line $key is missing or not a string in $manifest on the branch"; return; }

  same=$(jq -n --argjson a "$expected" --argjson b "$head_json" '$a == $b') ||
    { bad "$ref" "cannot compare the manifests"; return; }
  if [[ $same == true ]]; then
    echo "ok: $ref"
    return
  fi

  changes=$(jq -nr --argjson a "$head_json" --argjson b "$expected" \
    '[($a + $b | keys[]) as $k | select($a[$k] != $b[$k]) | "\($k) \($a[$k] // "absent") -> \($b[$k] // "absent")"] | join(", ")' |
    tr -d '\000-\037\177' | cut -c1-300) || { bad "$ref" "cannot describe the difference"; return; }

  if [[ ${DRY_RUN:-} == 1 ]]; then
    echo "would repair: $ref ($changes)"
    return
  fi

  now=$(gh api "repos/$repo/git/ref/heads/$ref" | jq -er '.object.sha') && [[ $now == "$head_sha" ]] ||
    { bad "$ref" "branch moved during the check"; return; }

  content=$(jq --indent 2 . <<< "$expected" | base64 | tr -d '\n') || { bad "$ref" "cannot encode the repair"; return; }
  # The tip was re-read just before this write; the blob sha makes the write fail (409)
  # if the manifest file changed after that. One attempt, the next run re-checks.
  gh api -X PUT "repos/$repo/contents/$manifest" \
    -f "message=chore(release): restore manifest lines set back by release-please" \
    -f "content=$content" -f "sha=$blob" -f "branch=$ref" > /dev/null ||
    { bad "$ref" "could not write the repair commit"; return; }
  echo "repaired: $ref ($changes)"
  echo "::warning::$ref: restored manifest lines set back by release-please ($changes)"
}

pulls=$(gh api --paginate "repos/$repo/pulls?state=open&base=$base&per_page=100") ||
  { echo "::error::cannot list open pull requests"; exit 1; }

# --paginate may concatenate arrays; jq reads each as its own value.
list=$(jq -r --arg p "$prefix" --arg repo "$repo" '.[] | select(.head.ref | startswith($p)) |
  [.head.ref, (.head.sha | if type == "string" and . != "" then . else "none" end), (((.head.repo.full_name // "") | ascii_downcase) != ($repo | ascii_downcase)), any(.labels[]; .name == "autorelease: pending")] | @tsv' <<< "$pulls") ||
  { echo "::error::cannot parse the pull request list"; exit 1; }

if [[ -n $list ]]; then
  # fd 3, so nothing inside the loop can consume the list.
  while IFS=$'\t' read -r -u 3 ref head_sha foreign pending; do
    checked=$((checked + 1))
    repair_one "$ref" "$head_sha" "$foreign" "$pending"
  done 3<<< "$list"
fi

echo "checked: $checked release PR(s)"
exit "$failed"
