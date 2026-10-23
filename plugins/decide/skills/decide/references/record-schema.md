# /decide — decision record schema

Filename: `~/.knowledge/modules/shared/records/decisions/<YYYY-MM-DD>-<slug>.md` (always global — see Decision-record store above). No catalog file to update: the frontmatter `keywords` are the index (see `~/.knowledge/modules/shared/records/principles/file-directory.md`). Carry the uniform six-key frontmatter so the record passes the frontmatter lint and is discoverable by the router:

```
---
id: dec.<YYYY-MM-DD>-<slug>
kind: decision
date: <YYYY-MM-DD>
keywords: [tag, tag]          # the router's match surface — never empty
links: {}                     # e.g. { failure-modes: [fm.<id>] } when relevant
status: pending | resolved
resolve_after: <YYYY-MM-DD>   # decide-specific: when Phase 0 should revisit
---
# <decision title>

## Goal
Stated / Real (if they differed)

## Values protocol
risk tolerance · time horizon · reversibility weight · whose welfare

## Chosen path

## Autonomy verdict
decided-and-acted | escalated (reason)

## Consequences foreseen
- ...

## Consequences that materialized
[pending]

## Outcome
[pending]

## Process-soundness
[pending — was the procedure sound, separate from whether the outcome was good?]

## Regrets
[pending — tag each: process-regret (changes future behavior) / outcome-regret (don't)]
```

Discovery is via the frontmatter `keywords` (`scripts/query-records.sh --keyword <term>`, or `Skill(procedures:how-do-i)`; Phase 0 greps `status: pending` to find records to resolve) — there is no catalog table to append to.

Load-bearing: **process-soundness recorded separately from outcome** (resulting fallacy — a good decision can yield a bad outcome; don't let the store teach superstition), and **consequences foreseen vs. materialized** (the gap teaches the skill what it tends to miss).


