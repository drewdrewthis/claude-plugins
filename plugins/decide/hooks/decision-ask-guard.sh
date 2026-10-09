#!/usr/bin/env bash
# An agent must make reversible calls itself and bring the owner only one-way-door
# or values-laden decisions, each with a recommendation. Deny a Discord reply that
# asks the owner to decide and has an item lacking either.
# Never echoes the text; always exits 0 so it can never wedge the agent.
# Fails open (bad JSON, no jq, no python3); a missing tool is a blind release, so it
# is logged to stderr. No PATH pin: jq/python3 live in /opt/homebrew/bin on macOS.
# Bash 3.2 safe (macOS /bin/bash).
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "decision-ask-guard: jq missing, failing open" >&2; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "decision-ask-guard: python3 missing, failing open" >&2; exit 0; }

input="$(cat 2>/dev/null || true)"
field() { jq -r "$1 // empty" <<<"$input" 2>/dev/null || true; }

[[ "$(field .hook_event_name)" == PreToolUse ]] || exit 0
[[ "$(field .tool_name)" == mcp__plugin_discord_discord__reply ]] || exit 0
text="$(field .tool_input.text)"
[[ -n "$text" ]] || exit 0

# Prints the number of items that miss a marker or a recommendation, or "noask".
verdict="$(python3 -I -c '
import re, sys
t = sys.stdin.read()
# Phrases that are an ask on their own, and phrases that are an ask only as a question.
always = r"decisions? for you|for you to decide|needs? your (?:approval|decision|call|input|ok|go|nod|sign-off)" \
  r"|needs? from you\b|pending (?:on|from) you\b|waiting on you\b|let me know (?:if|whether) (?:i|we) should" \
  r"|let me know if you want|tell me which|\bthoughts\?|\((?:your|owner|owner\x27s) (?:call|decision|pick)\)|\(y/n\)|\(yes/no\)"
quest = r"(?:do you )?want me to|should (?:i|we)\b|shall (?:i|we)\b|which (?:option|one) do you" \
  r"|your (?:call|decision|approval|pick)|can you approve|what do you think|(?:do )?you prefer|which do you" \
  r"|would you like me to|ok to \w+|can (?:i|we) (?!help\b)\w+"
ask = re.compile(always + "|(?:" + quest + r")[^.!?\n]*\?", re.I)
m = ask.search(t)
if not m:
    print("noask"); sys.exit()
t = t[t.rfind("\n", 0, m.start()) + 1:]  # a status list before the ask is not scored; start at line start so a bullet holding the ask is item 1
end = re.search(r"\n[ \t]*\n(?![ \t]*(?:[-*•]|\d+[.)]))", t)
if end:
    t = t[:end.start()]  # prose after a blank line is a footer, not part of the ask
split = re.compile(r"(?:^[ \t]*(?:[-*•]|\d+[.)])[ \t]+)|(?:(?<=\s)\d+\)[ \t]+)", re.M)
parts = split.split(t)
items = parts[1:] if len(parts) > 1 else [t]
if len(parts) > 1 and "?" in parts[0]:
    items.append(parts[0])  # a question in the header is an item too
items = [re.split(r"\n[ \t]*\n", i)[0] for i in items]  # footer text is not part of the last item
marker = re.compile(r"(?<!not )(?<!not a )(?<!n\x27t )(one[- ]way[- ]door|values[- ]laden)", re.I)
rec = re.compile(r"recommend|rec:|my rec", re.I)
print(sum(1 for i in items if not (marker.search(i) and rec.search(i))))
' <<<"$text" 2>/dev/null || true)"

[[ "$verdict" =~ ^[0-9]+$ && "$verdict" -gt 0 ]] || exit 0

msg='This reply asks the owner to decide or approve items that are not each marked one-way-door or values-laden with a recommendation. Make every reversible call yourself, act, and report what you did. Bring the owner only one-way-door or values-laden items, each marked as such and each with your recommendation. Procedure: proc.research-think.decide (the /decide:decide skill). Records: fm.ask-permission-on-reversible, fm.ask-when-rules-decide. If nothing here is for the owner to decide, report what you did instead of asking.'
jq -n --arg m "$msg" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$m}}' 2>/dev/null
exit 0
