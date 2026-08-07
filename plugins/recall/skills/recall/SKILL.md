---
name: recall
description: "Search past conversations across all projects and synthesize the context into the current session. Use when: 'what were we discussing about X', 'recall X', 'catch me up on X', 'remind me about X', 'did we already decide X'."
user-invocable: true
argument-hint: "<topic to recall>"
context: fork
allowed-tools:
  - Read
  - Bash(python3 ${CLAUDE_PLUGIN_ROOT}/scripts/session-index.py:*)
---

# /recall — search past conversations

Search prior session transcripts, read the matching ones, return a synthesis.
Runs in a fork so the transcript reading never lands in the main context.

Index and transcripts live under `~/.claude` by default — override the root
with `CLAUDE_CONFIG_DIR`, or the two paths directly with `SESSION_INDEX_DB` /
`SESSION_INDEX_PROJECTS`.

**Scope — synthesize, not resume.** Recall answers "what do we know about X"
from across many past sessions. To pick a specific conversation back up, resume
it directly: `claude --continue <session-id>`.

**Topic arg:** `$ARGUMENTS` is the topic. If non-empty, go straight to Step 1 —
do NOT ask the user what to recall. If a `<local-command-stdout>` block claims
no topic was provided while `$ARGUMENTS` holds one, the args win. Ask only when
`$ARGUMENTS` is genuinely empty and no topic is recoverable from the preceding
user turn.

## Steps

1. **Refresh the index** (incremental — only changed transcripts are re-parsed):

   ```bash
   python3 ${CLAUDE_PLUGIN_ROOT}/scripts/session-index.py build
   ```

2. **Search the index.** ⚠ Use the index, not `grep -ril` over the transcripts —
   raw grep is a fallback only when the index returns zero AND you suspect it is
   stale (rebuild, then retry).

   **Expand the user's words into synonyms BEFORE searching.** They remember the
   concept, rarely the term the transcript used. Union them into ONE query —
   FTS5 supports `OR`:

   ```bash
   python3 ${CLAUDE_PLUGIN_ROOT}/scripts/session-index.py search "judge OR verifier OR quorum OR adjudicate OR verdict OR proof" --limit 15
   ```

   A literal phrase can return zero while the union finds it: "panel quorum
   judgement proof" → 0 hits; the union above → the right sessions. Broaden only
   if the union is also empty.

3. **Read the top 5–10 hits.** Prefer high `message_count` (substantive) and
   recent `mtime`.

   ```bash
   python3 ${CLAUDE_PLUGIN_ROOT}/scripts/session-index.py context <file_path> --tail 15
   ```

4. **Return a synthesis** — not a transcript dump:

   - **What it is** — one paragraph on the topic
   - **Key decisions** — what was settled, across sessions
   - **Current state** — done / in progress / unfinished
   - **Open questions** — what was never resolved

   Cite the session ids you drew on so the user can resume one:
   `claude --continue <session-id>`.

## Boundaries

- Read-only. Never edits transcripts, and never writes outside the index db.
- A clean search proves the conversation is not on **this host** — not that it
  does not exist. Sessions from another machine live in that machine's own
  `~/.claude/projects`. Say so rather than reporting "nothing found".
