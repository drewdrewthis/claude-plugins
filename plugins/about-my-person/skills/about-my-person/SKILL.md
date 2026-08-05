---
name: about-my-person
description: Keep the single file that tracks who your person (the customer) is — identity, preferences, standing context. Use when you learn something durable about them (a preference, a correction, a life fact that changes how you work), or when asked "what do you know about me". One file, not a knowledge base.
user-invocable: true
allowed-tools:
  - Read
  - Write
  - Edit
---

# /about-my-person — the one file about who you serve

The file at `${ABOUT_MY_PERSON_FILE:-${ABOUT_MY_PERSON_DIR:-$HOME/.claude/about-my-person}/ABOUT_MY_PERSON.md}`
is the single canonical answer to "who is my person and how do they like
things done". `ABOUT_MY_PERSON_DIR` overrides the directory; `ABOUT_MY_PERSON_FILE`
overrides the file path directly (wins if both are set). It is seeded at
provisioning and you maintain it from then on. It is deliberately ONE file —
short enough to read whole. It is not a diary (that's the daily note), not a
transcript archive (that's `/recall`), and not general memory (auto-memory
handles ambient facts). This file is the curated profile.

A sibling file, `EVOLUTION.md`, in the same directory holds a dated one-line
log of material changes to the profile, newest first (create it if missing).

## The procedure (follow exactly)

1. **Read the whole file first.** It's short by design. Never append blind —
   the fact may already be there, or contradicted.
2. **Place the fact in the right section** (create the file from the skeleton
   below if it's somehow missing):
   - `## Identity` — name, pronouns, where they live, timezone, work, the
     handful of people they mention constantly.
   - `## Preferences` — how they like you to communicate and work. Corrections
     they've given you belong here, phrased as the rule going forward.
   - `## Standing context` — ongoing situations that color everything
     (a job hunt, a move, a project, a health thing they've shared).
   - `## Changelog` — one dated line per meaningful update, newest first.
3. **Update, don't accumulate.** If a fact changes (new city, new job),
   REPLACE the old one; the changelog line records that it changed. If a
   section exceeds ~15 lines, condense it — the file must stay whole-readable.
4. **Date the changelog line** (`- 2026-08-05: moved from X to Y`) AND append
   the same one-liner to `EVOLUTION.md` in the same directory (create it with
   just a `# Evolution — about-my-person` heading if missing).
5. **When asked "what do you know about me":** read the file and answer from
   it conversationally. Offer to correct anything that's wrong — and if they
   correct you, apply the correction via this same procedure, right then.

## What does NOT go in

- Message-by-message detail, task states, anything that expires within weeks
  (→ daily note).
- Secrets/credentials of any kind — even if they paste one. Never.
- Third parties' private details beyond a name + relationship, unless your
  person explicitly wants more tracked.

## Skeleton (for a missing file)

```markdown
# About <their name> — maintained by their assistant

## Identity

## Preferences

## Standing context

## Changelog
```
