<!-- TEMPLATE — copy to your knowledge root's solutions/ (default ~/.claude/references/solutions/)<YYYY-MM-DD>-<kebab-name>.md.
     A solution = a reusable fix for a problem shape that will recur.
     `project:` is OPTIONAL (`--project` on the writer). DELETE the line for a
     corpus-wide solution — an empty or placeholder value is unmatchable and
     fails the lint. -->
---
id: sol.<YYYY-MM-DD>-<kebab-name>
title: <the takeaway as a sentence — the rule, not the topic>
kind: solution
date: <YYYY-MM-DD>
keywords: [<symptom words + tool names — what future-you will grep when it recurs>]
links: {}
status: resolved
project: <owner/repo this solution is scoped to — delete if corpus-wide>
situation_tags: [<lowercase situation class — daemon, gh-cli, env-config, …>]
resolve_after: <YYYY-MM-DD — ~3 months out; env/version hacks expire faster>
---

# <Title again>

## The problem shape

<1-2 sentences: what it looks like when this hits, and why the obvious
approach fails.>

## Canonical case (<YYYY-MM-DD>)

<the concrete incident that produced this — enough detail to recognize it>

## The fix

<the reusable steps/commands, with the check that proves it worked>

## See also

<links to related procedures/decisions, if any>
