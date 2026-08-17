---
id: prin.<slug>
kind: principle
date: YYYY-MM-DD
keywords: [<grep surface — never empty>]
links: { principles: [], procedures: [], decisions: [] }
enforced_by: <path to the hook / lint / reviewer that makes this real, or `none-aspirational`>
control_type: <preventive | detective | corrective — omit only with none-aspirational>
mitigates: [<fm.id of any failure-mode this rule treats — omit if none>]
status: active
title: <Title Case Name>
purpose: <One line: what this principle decides, stated so the reader knows if it applies to them.>
---

# <Title>

<One paragraph, maximum. The load-bearing idea, stated so an agent can act on it.>

## Rules

1. **<Imperative rule.>** <One clause of consequence, only if the rule is wrong without it.>
2. **<Imperative rule.>**

## Carve-outs

- <Where this deliberately does NOT apply, and what governs instead.>

<!--
HOW TO USE THIS TEMPLATE — delete this block.

A principle binds BEHAVIOUR across many tasks. If it is steps for one task, it is a
procedure. If it is a one-time call with a rationale, it is a decision record.

`enforced_by` is the field that matters. A principle nothing enforces is a wish: it will be
violated and nobody will notice. Name the hook, lint, or reviewer agent that catches the
violation — and if none exists, that is the work, not the frontmatter. A missing
`enforced_by` is a lint WARNING for exactly this reason.

`control_type` says HOW it is caught: preventive (a hook/gate blocks the act), detective (a
lint/reviewer finds it afterwards), corrective (it feeds `/log` → failure-mode → evolution).
A domain that is all-detective ships the defect and catches it later — visible only if the
field is filled in. Run `scripts/grc-coverage.sh` before adding a principle: it reports which
existing rules are actually machine-enforced versus aspirational.

Being loaded is not the same as being enforced. Universally-binding principles are imported
into the root `CLAUDE.md`; role-scoped ones are imported by the agent that needs them. If a
new principle is neither imported nor enforced, no agent will ever apply it.

Principles are act-docs (prin.agent-facing-docs): rules, not essays. The reasoning behind a
principle belongs in a decision record, linked from `links.decisions`.
-->
