<!-- Frontmatter mirrors templates/_frontmatter.partial.md (schema SSOT, itself mirroring specs/RECORD_FRONTMATTER.md) — edit there first, then here. -->
---
id: fm.<kebab-name>
kind: failure-mode
date: YYYY-MM-DD
keywords: [<named entities — tools, commands, repos involved — what recurrence would grep>]
links: { procedures: [] }
status: active
description: <One line, ~120 chars: the failure and its trigger — what the agent does wrong and when it fires, not "bug in X".>
project: <owner/repo this failure-mode is scoped to — delete if corpus-wide>

<!-- TEMPLATE — `project:` is OPTIONAL (`--project` on the writer). DELETE the
     line for a corpus-wide failure-mode; an empty or placeholder value is
     unmatchable and fails the lint. -->

---

# <kebab-name — the mistake as a short noun phrase>

## Mistake

<The pattern in the abstract: what the agent does wrong and why it seems
reasonable in the moment. Then the canonical case (YYYY-MM-DD): the concrete
incident, with enough detail to recognize a recurrence.>

## Correct

<The rule going forward — what to do instead, stated as behavior, with the
check that proves you followed it.>
