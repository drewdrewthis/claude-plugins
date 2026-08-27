<!-- Frontmatter mirrors templates/_frontmatter.partial.md (schema SSOT, itself mirroring specs/RECORD_FRONTMATTER.md) — edit there first, then here. -->
---
id: std.<slug>
kind: standard
date: YYYY-MM-DD
keywords: [<named entities only — tools, commands, repos this standard measures — never empty>]
links: { standards: [], policies: [], procedures: [], decisions: [] }
enforced_by: <path to the lint / reviewer / CI check that measures the bar, or `none-aspirational`>
mitigates: [<fm.id of any failure-mode this bar treats — omit if none>]
status: active
description: <One line, ~120 chars: what class of work item this measures, and what the bar is.>
title: <Title Case Name>
---

# <Title>

<One paragraph: what must be true of the artifact, stated as a property of the finished thing rather than as steps to produce it.>

## The bar

| Requirement | Met when |
|---|---|
| <Property the artifact must have> | <The observable test. A stranger with no context must be able to run it and get the same answer.> |

## Done-test

<One line a stranger can execute against a finished artifact to return pass or fail. If the test needs the author present to interpret it, it is not a done-test.>

## Out of scope

- <What this standard deliberately does not measure, and what governs that instead.>

<!--
HOW TO USE THIS TEMPLATE — delete this block.

A standard is a CONTROL OBJECTIVE: the measurable minimum a work item must meet. It says WHAT
GOOD LOOKS LIKE, never how to get there.

  - a standard states the BAR        — "every card names an owner and a done-test"
  - a procedure states the STEPS     — "open the board, click new, fill these fields"

One standard is usually met by several procedures, and that is the point: swapping the
procedure must not silently move the bar. If your draft contains an ordered list of actions,
it is a procedure and belongs in the procedures store.

THE DONE-TEST IS THE RECORD. A bar that cannot be checked by someone who was not involved is
a preference wearing a kind. Write it so the check returns pass or fail without judgment —
"description is at least 4 lines and names a next action", not "description is clear".

`enforced_by` should name whatever actually measures the bar. If nothing does, the standard is
aspirational and will drift the moment attention moves elsewhere — say `none-aspirational`
honestly rather than naming a reviewer who has never been asked to check it.

Standards are act-docs. The rationale for choosing this particular bar belongs in a decision
record, linked from `links.decisions`.
-->
