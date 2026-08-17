<!-- TEMPLATE — the shape `/update-records decision` writes: one markdown file at
     <knowledge-root>/references/decisions/<YYYY-MM-DD>-<slug>.md
     (default root ~/.claude). Written by the log-record.sh writer script; use
     this template when hand-editing an existing record, or to know what to
     expect back.

     Rules:
     - The slug names the QUESTION resolved, kebab-case, <=7 words.
     - `status: active` at creation; flip to `resolved` only once the outcome is
       known. A reversal is a NEW record referencing this one in `links` —
       never rewrite a decision's history.
     - Leave `[pending]` in any section that needs future evidence; that is
       correct on creation. -->
---
id: dec.<YYYY-MM-DD>-<slug>
kind: decision
date: <YYYY-MM-DD>
keywords: [<lowercase — domain, options considered, key actors>]
links: {}
status: active
---

# <Title — the takeaway as a sentence, not the topic>

## Goal
Stated: <what was asked>
Real: <what was actually being solved, if different>

## Chosen path
<what was decided, concretely, and the reasoning that makes it stick>

## Consequences
<what this commits us to, and what it forecloses>

## Outcome
[pending]
