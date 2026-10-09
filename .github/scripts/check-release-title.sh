#!/usr/bin/env bash
# Fail a PR that changes plugins/<name>/ when its title will not make
# release-please release that plugin.
#
# WHY: release-please reads the squashed PR title and maps commits to packages
# by file path. A non-releasing title (chore:, ci:, ...) merges fine but never
# bumps the version, so installed boxes keep the old cached copy.
#
# Usage: PR_TITLE="fix(x): y" check-release-title.sh <release-please-config.json>
#        changed file paths, one per line, on stdin.
set -euo pipefail

usage() {
  echo "usage: PR_TITLE=<title> $0 <release-please-config.json> < changed-files" >&2
  exit 2
}

config="${1:-}"
[[ -r "$config" && -n "${PR_TITLE:-}" ]] || usage

releasing_types=$(jq -r '[.["changelog-sections"][] | select(.hidden != true) | .type] | join(", ")' "$config")

plugins=$(sed -n 's#^plugins/\([^/]\{1,\}\)/.*#\1#p' | sort -u)
if [[ -z "$plugins" ]]; then
  echo "no plugin changes; nothing to release"
  exit 0
fi

failures=()

while IFS= read -r plugin; do
  if ! jq -e --arg k "plugins/$plugin" '.packages | has($k)' "$config" >/dev/null; then
    failures+=("release-please does not manage plugins/$plugin, so its version never bumps. Add it to release-please-config.json and .release-please-manifest.json.")
  fi
done <<< "$plugins"

type=""
breaking=""
re='^([a-z]+)(\([^)]*\))?(!)?: .+'
if [[ "$PR_TITLE" =~ $re ]]; then
  type="${BASH_REMATCH[1]}"
  breaking="${BASH_REMATCH[3]}"
fi

releasing=false
if [[ -n "$breaking" ]]; then
  releasing=true
elif [[ -n "$type" ]] && jq -e --arg t "$type" \
  '[.["changelog-sections"][] | select(.hidden != true) | .type] | index($t) != null' "$config" >/dev/null; then
  releasing=true
fi

if [[ "$releasing" == false ]]; then
  names=$(echo "$plugins" | paste -sd, - | sed 's/,/, /g')
  failures+=("PR changes plugin(s) [$names] but title type \"${type:-none}\" releases nothing. Releasing types: $releasing_types (or any type with !). Retitle as fix(<plugin>): ... or feat(<plugin>): ... Otherwise installed boxes keep the old cached copy.")
fi

if ((${#failures[@]} > 0)); then
  for f in "${failures[@]}"; do echo "::error::$f" >&2; done
  exit 1
fi

echo "will release: $(echo "$plugins" | paste -sd, - | sed 's/,/, /g')"
