---
id: std.record-frontmatter
kind: standard
date: 2026-08-23
keywords: [frontmatter, okf, lint-frontmatter, stores.sh, record-match]
links: { standards: [], principles: [], adrs: [] }
status: active
title: Record Frontmatter
description: The authoritative seven-key frontmatter schema every knowledge-record store must emit.
---

# Record Frontmatter

This file lives at `plugins/procedures/specs/`, outside the store tree, so its
`kind` is authored here rather than derived (rule 3 below applies only inside
a store directory).

## The seven keys

| Key | Req | Type | Purpose | Example |
|---|---|---|---|---|
| `id` | required | string | Corpus-unique join key, kind-prefixed. | `dec.2026-08-06-okf-adoption` |
| `kind` | required | enum | Record class. **Derived**, not authored — see below. | `decision` |
| `date` | required | `YYYY-MM-DD` | Authoring date. | `2026-08-23` |
| `keywords` | required | list | Named-entity match surface (projects, tools, commands, repos). Never empty. | `[langwatch, tmux, pr-ready-check]` |
| `links` | required | typed map | Edges to other records, by store. `{}` if none. | `{ decisions: [dec.2026-08-06-okf-adoption] }` |
| `status` | required | enum | Per-kind lifecycle value — see table below. | `active` |
| `description` | required | string, ~120 chars | Neutral one-line statement of what this record *says*. The retrieval match surface for the question-matching index. | `Adopts OKF as an additive mirror; kind/status stay canonical, type/tags/okf_status derive from them.` |

## Authored vs derived

| Field | Source |
|---|---|
| `id`, `date`, `links`, `status`, `description` | authored |
| `keywords` | authored, but scope-restricted to named entities (see Rejected alternatives) |
| `kind` | **derived** from the containing store directory — one directory = one store = one kind, singular of the dir name (`decisions/` → `decision`) |
| `type` (OKF mirror) | derived, `= kind` |
| `tags` (OKF mirror) | derived, `= keywords` |
| `okf_status` (OKF mirror) | derived from `status` per the ADR-017 mapping (below) |

Deriving `kind`/`type`/`tags`/`okf_status` removes them as a place authors can
diverge. Measured this session: `~/.claude/references/` holds 154 decision,
157 solution, 84 failure-mode, 22 principle, 17 adr, and 279 procedure
records (nested), plus 62 research records under `research/` (2 levels) and
71 in `plans/` — every one of these `kind` values is already 1:1 with its
containing directory, so authoring it by hand only ever repeats a fact the
path already states.

## Command frontmatter — not records

Files carrying `user-invocable:` in their frontmatter block are Claude Code
slash-command definitions, not knowledge records. Their `description:` serves
as an invocation trigger for the CLI, not a retrieval description for question
matching. These files are exempt from this standard: they need no `id`, `kind`,
`date`, `keywords`, `links`, or `status`. The linter (`lint-frontmatter.sh`)
skips them entirely.

## Per-kind `id` prefix and status values

Harvested verbatim from `references/principles/file-directory.md` (lines
51–73); not extended here.

| kind | id prefix | status values |
|---|---|---|
| failure-mode | `fm.` | `active \| superseded-by:<id>` |
| decision | `dec.` | `active \| pending \| resolved \| superseded-by:<id>` |
| solution | `sol.` | `active \| resolved \| superseded-by:<id>` |
| procedure | `proc.` | `active \| superseded-by:<id>` |
| research | `res.` | `active \| superseded-by:<id>` |
| plan | `plan.` | `active \| done \| abandoned` |
| principle | `prin.` | `active \| superseded-by:<id>` |

**Gap, not invented here:** `plugins/procedures/scripts/lib/stores.sh` in
this repo already lints four more stores — `references/adrs`,
`references/invariants`, `references/policies`, `references/standards` — and
`skills/update-records/templates/` already ships templates (`invariant`,
`policy`, `standard`) for three of them, none of which appear in
`file-directory.md`'s table. `file-directory.md` is the SSOT this standard
was told to harvest from and is stale relative to the code; extending the
prefix/status table for those four kinds is a separate ratification, not
assumed here.

## The `description` field

Neutral, third-person, states the record's *content* — not its topic, not
its use. Every kind must be able to answer it, including a decision ("you
don't use a decision, you're bound by it" — see Rejected alternatives).

| Good | Bad | Why |
|---|---|---|
| `Adopts OKF as an additive mirror; kind/status stay canonical, type/tags/okf_status derive from them.` | `Frontmatter compatibility decision.` | Bad restates the topic word (frontmatter) and the kind (decision), says nothing the reader didn't already know from the filename. |
| `walkFiles skips leftover temp files from a crashed atomic write during directory traversal.` | `Fix for walkFiles bug.` | Bad has no content to match a question against — "bug" and "fix" match everything and nothing. |
| `The gc env guard refuses to run when CODEX_ROOT is unset, to avoid collecting the wrong tree.` | `GC env var fix.` | Bad drops the mechanism (what it guards against); a question like "why does gc skip when env is unset" cannot match it. |

## Rejected alternatives

| Alternative | Why not |
|---|---|
| `when_to_use` field | Procedure-shaped — presumes the record is an action to invoke. Breaks for decision (154 records, measured this session — you're bound by a decision, not "using" it), research (62), adr (17), principle (22): none of these are invoked. Do not re-propose without a kind-conditional shape, which defeats a uniform schema. |
| `keywords` as the retrieval/topic-match surface | Measured this session: 4002 keyword tokens, 2677 distinct, 2134 (80%) appear exactly once. The rarity gate (`--k-floor 2`) drops singletons, so 80% of authored keywords are structurally excluded from ranking. The frequent survivors are all proper nouns — `keywords` is a named-entity index, not a topic-match surface. `description` is the surface built for matching questions; `keywords` stays narrowed to what it actually does well. |
| Hardcoded store list (status quo) | `~/.claude/scripts/lib/stores.sh` hardcodes 7 stores; `references/` already has 17 subdirectories (measured this session) and this repo's own `stores.sh` already lints 11. A store is any directory under the records root — no enumeration to keep in sync. |

## OKF mirror mapping

Per ADR-017 (`references/adrs/017-okf-base-frontmatter-compatibility.md`,
status Proposed). Mirrors are additive and **derived, never authored** —
duplicated-and-authored data drifts (ADR-017 consequence 4); derivation
removes the risk category entirely rather than lint-guarding it.

| Codex key | OKF key | Derivation |
|---|---|---|
| `kind` | `type` | `type := kind` |
| `keywords` | `tags` | `tags := keywords` (same list, same order) |
| `status` | `okf_status` | `active → stable`, `superseded-by:<id> → deprecated`, `draft → draft`; richer values (`pending`, `resolved`, `done`, `abandoned`, and the `<id>` on a superseded record) stay only in `status` — `okf_status` takes the nearest of the three OKF lifecycle states |
| — | `description` | ADR-017 clause 4 already names `description` "adopt-where-cheap"; this standard promotes it to required and gives it a defined purpose (retrieval surface) rather than leaving it optional prose |
