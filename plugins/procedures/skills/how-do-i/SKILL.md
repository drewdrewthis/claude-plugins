---
name: how-do-i
description: Route a "how do I X / have we decided X / is there a way we do X" question to what already answers it — your own procedures, solutions, decisions log, shipped docs, or conversation history — BEFORE answering from memory or improvising. Also fires before performing any operation you've documented a procedure for.
user-invocable: true
argument-hint: "<the question, verbatim>"
allowed-tools:
  - Bash(bash ${CLAUDE_SKILL_DIR}/scripts/route-question.sh *)
  - Read
  - Grep
---

# /how-do-i — check what already answers this

Your durable knowledge lives in five places (root = `$KNOWLEDGE_REFS`, default
`~/.claude/references`). This skill searches them best-first so you act from
what's written rather than what you half-remember:

1. **Your procedures** — `<root>/procedures/*.md` — repeatable
   operations you've written down.
2. **Your solutions** — `<root>/solutions/*.md` — reusable fixes.
3. **Your decisions** — `<root>/decisions.jsonl` — settled choices.
4. **Shipped docs** — `$HOW_DO_I_EXTRA_DOCS`, if set — docs your operator
   ships to you.
5. **History** — the `/recall` index (`$RECALL_SCRIPT`), as fuzzy fallback.

## Steps

1. Run the router on the question verbatim:
   ```bash
   bash ${CLAUDE_SKILL_DIR}/scripts/route-question.sh <question words...>
   ```
2. **Read the top match's document before answering** — the router gives you
   a path and a snippet, not the content. Answer from the document.
3. **No match anywhere:** say so plainly, answer from judgment, and — if the
   answer turns out to be a repeatable way of doing something — write it down
   via `/log procedure` so next time there IS a match.

An imperative counts too: before *performing* something you've documented
("book it the usual way", "do the weekly summary"), route first and follow
your own procedure — that's what it's for.
