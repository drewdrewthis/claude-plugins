---
id: proc.<category>.<name>
kind: procedure
date: YYYY-MM-DD
keywords: [<the words someone would grep to find this — never empty>]
links: { procedures: [], principles: [], decisions: [], solutions: [] }
status: active
---

# <name>

<One or two lines: what this does and what it operates on. No preamble, no motivation.>

**Not when:** <the nearest neighbour this gets confused with, and where to go instead.>
Delete this line only if nothing is confusable with it.

## Steps

1. **<Imperative.>** <Exact command where one exists — verbatim, copy-pasteable.>
2. **<Imperative.>**   ⚠ <one clause naming the trap at the exact step it bites>
3. **<A decision.>** <condition> → <what to do>. <other condition> → <what to do>.

## Boundaries

- Never <the thing that looks reasonable and is wrong>.
- <What this procedure does NOT cover, and who does.>

<!--
HOW TO USE THIS TEMPLATE — delete this block.

A procedure is for work with NO script. If a script does the work, write a SKILL instead —
a skill whose job is telling an agent how to use that script.

Act-doc rules (prin.agent-facing-docs, loaded in the root CLAUDE.md):
- Steps are imperative and ordered. The reader is a competent agent, not a novice.
- EXILE RATIONALE. No "why we do this" sections. Backstory goes in the sibling EVOLUTION.md.
  Keep an inline WHY clause ONLY where removing it would cause a wrong or unsafe result.
- Say each thing once. Cross-reference by record id; never restate another doc's rule.
- Fuse each warning to the step it applies to. A "Failure modes" section at the bottom is
  read after the mistake has been made.
- Never trim a constraint, boundary, step, edge, or failure mode. Only redundancy is cuttable.
- Point at discoverable sets (`ls`, an INDEX); never freeze a snapshot list that will go stale.
-->
