---
id: pol.<slug>
kind: policy
date: YYYY-MM-DD
keywords: [<grep surface — never empty>]
links: { policies: [], principles: [], procedures: [], decisions: [] }
enforced_by: <path to the skill / reviewer / hook that applies this authority, or `none-aspirational`>
control_type: <preventive | detective | corrective — omit only with none-aspirational>
mitigates: [<fm.id of any failure-mode this authority treats — omit if none>]
status: active
title: <Title Case Name>
purpose: <One line: what authority this grants or withholds, and over what scope.>
---

# <Title>

**In force on publication. Struck lines stop applying immediately; the rest stands.**

<One paragraph: the standing authority this record establishes, and the boundary of it.>

## Scope

- **Applies to:** <who or what this binds — which agents, which repos, which class of action.>
- **Does not apply to:** <the explicit boundary. A policy with no stated edge will be read as universal.>

## Granted

1. **<Action now permitted without asking.>** <The condition under which it holds.>

## Withheld

1. **<Action that still requires explicit authorization.>** <Say plainly that merging this record does NOT grant it.>

## How to strike

<One line: how the owner revokes part of this — strike the line in review, and it stops applying without invalidating the rest of the record.>

<!--
HOW TO USE THIS TEMPLATE — delete this block.

A policy is STANDING AUTHORITY. It is in force by default from the moment it is published,
and stays in force until a line is struck. That default-on behaviour is the whole reason the
kind exists, and is what separates it from every other record:

  - a principle GUIDES judgment          — it does not grant permission
  - an invariant FORBIDS absolutely      — it never grants anything
  - a procedure gives STEPS              — it assumes the authority already exists
  - a policy GRANTS or WITHHOLDS         — it changes what may be done without asking

Because a policy is live on merge, write the Withheld section first and be generous with it.
Anything left out of Withheld, you have granted. The failure mode is not a policy that
withholds too much — it is a policy whose silence gets read as permission.

Never bundle an unresolved authority question into a policy and merge it. If a section needs
the owner's explicit word, mark it clearly as open and state in the record that merging does
not grant it. A policy that quietly widens its own scope on merge is the exact thing the kind
exists to make impossible.

Policies are act-docs. The deliberation behind the grant belongs in a decision record, linked
from `links.decisions`.
-->
