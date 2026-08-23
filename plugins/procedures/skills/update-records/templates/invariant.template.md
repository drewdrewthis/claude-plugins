---
id: inv.<slug>
kind: invariant
date: YYYY-MM-DD
keywords: [<named entities only — tools, commands, repos this invariant governs — never empty>]
links: { invariants: [], principles: [], procedures: [], decisions: [] }
enforced_by: <path to the hook / gate that blocks the violating act — an invariant with no enforcer is a wish>
mitigates: [<fm.id of any failure-mode this law treats — omit if none>]
status: active
description: <One line, ~120 chars: the law, stated so a reader knows instantly whether they are about to break it.>
title: <Title Case Name>
---

# <Title>

<One paragraph, maximum. State the constraint as a law, not as advice. No hedging verbs — not "should", not "prefer", not "generally".>

## The law

**<The single imperative sentence. This is the whole record. Everything else is support.>**

## What breaking it costs

- <The concrete damage, not the abstract risk. If you cannot name a real cost, this is a principle, not an invariant.>

## How it is blocked

- <The hook, gate, or lint that prevents the act — with its path. If nothing blocks it, say so here in plain words; an unenforced invariant is the most dangerous record in the corpus, because its kind claims a certainty its wiring does not deliver.>

<!--
HOW TO USE THIS TEMPLATE — delete this block.

An invariant is an ABSOLUTE constraint binding every layer — agents, hooks, skills,
procedures, and the owner's own ad-hoc requests. "No secrets in the repo" is an invariant.
"Prefer small PRs" is not.

THE TEST THAT SEPARATES THIS FROM A PRINCIPLE: a principle is judgment guidance for
situations the rules do not cover, and it legitimately has carve-outs. An invariant has NO
carve-outs section, because the moment you write one, the record is a principle. If you find
yourself reaching for "except when", stop and use principle.template.md instead.

Do not mint an invariant to give a principle more weight. The kinds are not a severity scale.
Promoting a rule you still intend to break on occasion trains every agent to read invariants
as suggestions, which destroys the one property the kind exists to carry.

`enforced_by` must name something that BLOCKS the act, not something that notices it later.
An invariant caught only after the fact has already been violated, and the damage the record
exists to prevent has already happened. If the only thing available notices after the fact,
that gap is the work — state it in "How it is blocked" rather than hiding it behind a
filled-in field.

Invariants are act-docs: rules, not essays. The reasoning for minting one belongs in a
decision record, linked from `links.decisions`.
-->
