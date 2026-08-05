---
name: take-note
description: Jot a note on your daily scratchpad (default ~/workspace/notes/YYYY-MM-DD.md; override with NOTES_DIR). Use for in-flight plans, agreements with your person, open threads, working context worth surviving the day — the yellow legal pad, NOT durable memory. New day = new file with still-relevant items carried forward.
user-invocable: true
argument-hint: "[the note — or leave empty to review/tidy today's note]"
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash(bash ${CLAUDE_SKILL_DIR}/scripts/note-file.sh)
---

# /take-note — daily working notes

One markdown file per day at `~/workspace/notes/YYYY-MM-DD.md` by default
(override the workspace with `KNOWLEDGE_WS` or the notes dir directly with
`NOTES_DIR`). This is the
scratchpad of what's live *today* — plans in motion, things agreed with your
person, open threads, gotchas of the moment. It is NOT memory (durable facts
about your person → `/about-my-person`; ambient facts → auto-memory) and NOT
history (that's `/recall`). Rule of thumb: matters in a month → elsewhere;
matters this week → here.

## Steps

1. **Resolve today's file:**
   ```bash
   bash ${CLAUDE_SKILL_DIR}/scripts/note-file.sh
   ```
   Prints `TODAY=`, `PREV=`, `NEW=`.

2. **If `NEW=yes` (first note of the day): roll over.** Read `PREV` (if not
   `none`). Create `TODAY` as:
   ```markdown
   # YYYY-MM-DD — daily notes

   ## Carried over
   - <still-relevant items from PREV, condensed — drop anything done, stale,
     or promoted to ABOUT_MY_PERSON/memory>
   ```
   Durable facts you notice while rolling over get promoted to
   `/about-my-person` right then, not re-carried forever.

3. **Append the note** under a `## HH:MM` heading (or fold into an existing
   section if it's the same thread). Keep entries short — a line or three.

4. **Called with no note:** read today's file, tidy it — collapse resolved
   threads, promote durable facts, delete noise.

Your SessionStart hook loads today's + yesterday's notes automatically, so
whatever you write here is what future-you wakes up knowing.
