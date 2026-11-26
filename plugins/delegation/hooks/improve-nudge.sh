#!/usr/bin/env bash
# improve-nudge.sh — UserPromptSubmit hook.
#
# SINGLE RESPONSIBILITY: when a prompt looks like a plan, proposal, design or
# PR that is about to be acted on, print ONE line suggesting
# /delegation:improve. Silent on every other prompt.
#
# A cheap regex, not a model call, by owner decision
# (dec.2026-11-26-agent-system-revamp-steps-3-6, item 9): it runs on every
# prompt, and a `prompt`/`agent` hook would hold each turn for seconds. The
# line is a suggestion the agent judges, not a decision made for it, so a
# false positive costs one ignored line.
#
# Match: an artifact word (plan, proposal, design, spec, RFC, ADR, approach,
# architecture, PR, pull request) together with an act-on-it word (implement,
# build, ship, merge, go ahead, ...), or a GitHub pull-request URL. Silent when
# the prompt already names /improve.
#
# Off-switch: DELEGATION_IMPROVE_NUDGE=0.
#
# Fails open toward silence (no jq, bad JSON, subagent prompt): print nothing,
# exit 0. Plain grep -E with explicit boundaries, no \b and no bash 4+, so it
# runs on macOS /bin/bash 3.2 and BSD grep.
set -u

[ "${DELEGATION_IMPROVE_NUDGE:-1}" = 0 ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

input="$(cat 2>/dev/null || true)"
# A subagent's prompt is a delegated brief, not the owner's plan to act on.
[ -n "$(jq -r '.agent_id // empty' <<<"$input" 2>/dev/null)" ] && exit 0
prompt="$(jq -r '.prompt // empty' <<<"$input" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
[ -n "$prompt" ] || exit 0

has() { grep -Eq "(^|[^[:alnum:]])($1)([^[:alnum:]]|$)" <<<"$prompt"; }

case "$prompt" in *"/improve"*|*"delegation:improve"*) exit 0 ;; esac

artifact='plans?|proposals?|proposed?|designs?|specs?|rfcs?|adrs?|approach|architecture|prs?|pull requests?'
act='implement(ing)?|build(ing)?|ship(ping)?|merge|execute|proceed|go ahead|kick off|roll out|deploy|apply|start on|act on|approve[ds]?|lgtm|let'"'"'?s do|do it|open (a|the) pr'

if grep -Eq 'github\.com/[^/ ]+/[^/ ]+/pull/[0-9]+' <<<"$prompt" || { has "$artifact" && has "$act"; }; then
    echo "This looks like a plan, design or PR about to be acted on: consider /delegation:improve on it first (stress-test, simplify and domain lenses in parallel)."
fi
exit 0
