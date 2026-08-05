#!/usr/bin/env bash
# gate-audience.sh — shared audience predicates for the per-turn invariant gates.
#
# SINGLE RESPONSIBILITY: answer "does this invariant bind THIS session / THIS
# turn?" and nothing else. Storage lives in turn-state.sh; policy in each gate.
#
# AUDIENCES (owner-set 2026-08-02, resolving orchard-codex#99):
#   /respond    — the assistant only, and only on a turn the owner triggered
#                 directly (owner directive 2026-08-05; see TURN TRIGGER below).
#   /how-do-i   — every MAIN agent (technician, orchardist, support, lead,
#                 default interactive, assistant, workers).
#   /am-i-done  — every MAIN agent.
#
# A SUBAGENT IS NEVER GATED, for any invariant. A delegated specialist runs
# under its own contract and cannot satisfy a per-turn invariant that belongs to
# the session that spawned it — gating it would deadlock the delegation the
# gates exist to encourage.
#
# The subagent discriminator is `.agent_id` in the tool payload, present only on
# a delegated call. It is a payload fact, not an environment guess:
# CLAUDE_CODE_AGENT is absent from /proc/<pid>/environ for some session shapes
# (sol.2026-07-29-claude-code-agent-absent-from-proc-environ), so environment
# alone cannot carry this decision.

set -uo pipefail

# ga_is_subagent <payload> — 0 when this call comes from a delegated subagent.
ga_is_subagent() {
    local payload="${1:-}" aid=""
    aid="$(printf '%s' "$payload" | jq -r '.agent_id // empty' 2>/dev/null || true)"
    [ -n "$aid" ]
}

# ga_is_assistant — 0 only when this session IS the assistant.
# Unset means the default interactive `claude`, which is how-do-i-gated but NOT
# respond-gated (owner decision, issue #197). Treating unset as the assistant
# would make "assistant" mean "unlabeled" and gate every worker and bare shell.
ga_is_assistant() {
    [ "${CLAUDE_CODE_AGENT:-}" = "assistant" ]
}

# ga_binds_respond <payload> — 0 when /respond binds this call.
ga_binds_respond() {
    ga_is_subagent "${1:-}" && return 1
    ga_is_assistant
}

# ga_binds_main <payload> — 0 when a main-agent invariant (/how-do-i,
# /am-i-done) binds this call. Every non-subagent session is a main agent.
ga_binds_main() {
    ga_is_subagent "${1:-}" && return 1
    return 0
}

# --- TURN TRIGGER -----------------------------------------------------------
#
# The predicates above scope by SESSION. /respond also scopes by TURN: owner
# directive 2026-08-05 — it binds only a DIRECT message from the owner. A cron
# wakeup, a task-notification, and another agent's channel message are turns the
# session did not solicit from him, and gating them makes the assistant run its
# say-do-report contract at nobody.
#
# The trigger is legible only in the UserPromptSubmit payload; a PreToolUse
# payload does not carry it. So this is classified once at the turn boundary
# (turn-state-reset.sh) rather than by respond-gate.sh itself.
#
# EVERY AMBIGUITY RESOLVES TOWARD DIRECT. Binding is today's behaviour, so a
# classification that cannot be made must change nothing.

# ga_tag_attr <tag-body> <attr> — print an XML-ish attribute value, or fail.
# The body must be SPACE-PREFIXED by the caller: anchoring the match on
# " name=\"" is what stops `reply_to_user="…"` being read as `user="…"`.
ga_tag_attr() {
    local body="${1:-}" attr="${2:-}" v=""
    case "$body" in
        *" $attr=\""*) ;;
        *) return 1 ;;
    esac
    v="${body#*" $attr=\""}"
    case "$v" in
        *"\""*) ;;
        *) return 1 ;;
    esac
    printf '%s' "${v%%\"*}"
}

# ga_ident_is_owner <ident> — 0 when a channel tag's user/user_id attribute
# identifies the owner. Defaults mirror the allowFrom entries in
# channels/discord/access.json; re-derive from there if his account changes.
ga_ident_is_owner() {
    local ident="${1:-}" list="" o=""
    [ -n "$ident" ] || return 1
    list="${RESPOND_DIRECT_USERS:-drewdrewthis 805967286547775489}"
    list="${list//,/ }"
    # Deliberately unquoted: the setting is a space/comma-separated list.
    for o in $list; do
        if [ "$ident" = "$o" ]; then return 0; fi
    done
    return 1
}

# ga_prompt_is_direct_owner <prompt> — 0 when this turn was triggered by a
# direct message from the owner (a terminal prompt, or his own channel message).
#
# Owner-presence is checked BEFORE the task-notification marker so that message
# text quoting a marker can only ever over-gate, never exempt.
ga_prompt_is_direct_owner() {
    local prompt="${1:-}" rest="" body="" src="" u="" uid="" foreign=0

    # Nothing to classify => bind.
    [ -n "$prompt" ] || return 0

    rest="$prompt"
    while :; do
        case "$rest" in
            *"<channel "*) ;;
            *) break ;;
        esac
        rest="${rest#*"<channel "}"
        # Unterminated tag => cannot classify => bind.
        case "$rest" in
            *">"*) ;;
            *) return 0 ;;
        esac
        body=" ${rest%%>*}"

        # Telegram is DM-locked to the owner (channels/telegram/access.json
        # allowFrom), so its sender attribute carries no extra information.
        src="$(ga_tag_attr "$body" source 2>/dev/null || true)"
        case "$src" in
            *telegram*) return 0 ;;
        esac

        u="$(ga_tag_attr "$body" user 2>/dev/null || true)"
        uid="$(ga_tag_attr "$body" user_id 2>/dev/null || true)"
        # Unattributable tag => cannot classify => bind.
        if [ -z "$u" ] && [ -z "$uid" ]; then return 0; fi
        if ga_ident_is_owner "$u"; then return 0; fi
        if ga_ident_is_owner "$uid"; then return 0; fi
        foreign=1
    done

    # Channel tags were present and every one of them was another agent's.
    if [ "$foreign" = 1 ]; then return 1; fi

    case "$prompt" in
        *"<task-notification"*) return 1 ;;
    esac

    # Plain text, no trigger tags: he typed it.
    return 0
}
