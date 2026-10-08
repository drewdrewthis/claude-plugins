#!/usr/bin/env bash
# Ported from drewdrewthis/orchard-codex guard-general-purpose.sh:
# the general-purpose subagent inherits the session's model tier, so work sent to it
# burns that tier on tasks a cheaper specialist does faster. Deny it and point at the
# router. The Agent tool uses general-purpose when subagent_type is omitted, so an
# omitted type is denied too.
#
# deny, not ask: the tmux/Discord agents and ship workers run unattended, and an
# ask prompt would stall them with nobody there to answer.
# bypassPermissions does not override a hook deny.
#
# Only general-purpose is gated: fork also runs at the session tier, but it carries the
# parent context, so the tier buys continuity, not a cold re-read.
#
# Fails open (bad JSON, no jq) and always exits 0, so it can never wedge a session.
# A missing jq is a blind release, so it is logged to stderr (CONTRIBUTING ADR-001).
set -u
# PLUGIN ADAPTATION: upstream pins PATH=/usr/bin:/bin; the plugin also runs on macOS
# where jq lives in /opt/homebrew/bin, so pinning would silently fail open there.

command -v jq >/dev/null 2>&1 || { echo "guard-general-purpose: jq missing, failing open" >&2; exit 0; }

input="$(cat 2>/dev/null || true)"
field() { jq -r "$1 // empty" <<<"$input" 2>/dev/null || true; }

jq -e . >/dev/null 2>&1 <<<"$input" || { echo "guard-general-purpose: unparseable input, failing open" >&2; exit 0; }

tool="$(field .tool_name)"
[[ "$tool" == Agent || "$tool" == Task ]] || exit 0

# PLUGIN ADAPTATION: lowercase in jq, not ${type,,} — that is bash 4+ and macOS
# /bin/bash is 3.2, where it is a "bad substitution" that kills the guard.
type="$(field '(.tool_input.subagent_type // "") | ascii_downcase')"
[[ -z "$type" || "$type" == general-purpose ]] || exit 0

# PLUGIN ADAPTATION: upstream names a hardcoded roster and a box-specific issue; this
# plugin ships no agents (the roster is the host's), so the reason points at the router.
root="$(cd "$(dirname "$0")/.." && pwd)"
msg="general-purpose is blocked by the delegation plugin: it inherits the session model tier and a specialist does the job cheaper. Route by task shape with /delegation:delegate, or list the routes with: bash \"$root/scripts/route-delegation.sh\" --list
No roster yet? Built-in types still work: Explore (search), Plan (design), fork (inherits this context).
No route fits: mint a specialist with /delegation:create-new-sub-agent. Name a subagent_type; an omitted one means general-purpose."

jq -n --arg m "$msg" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$m}}' 2>/dev/null
exit 0
