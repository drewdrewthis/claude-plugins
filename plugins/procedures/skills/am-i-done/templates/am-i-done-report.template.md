# am-i-done report template

Fill this in. Each section says what it is for; the traps are marked inline.

Delete this explanatory block from your copy. Delete any section that is
genuinely empty, except **Procedures followed**, **Not done**, and
**Assumptions** — those three are load-bearing precisely when they look empty,
because silence in them reads as coverage.

---

## The ask

<One line, in the terms the asker used — not the terms the work ended up in.>

## The premise

<What you took as true going in: the state you believed the system was in, the
constraints you assumed, the reading of the ask you committed to. A wrong
premise is invisible in a report that only shows results — this is where a
reviewer catches it.>

## What I did

<Two or three lines. The shape of the work, not a narration of every step.>

## Decisions

| Decision | Why | What I rejected |
|---|---|---|
| <the call> | <the reason> | <the alternative and why not> |

## Procedures followed

| Procedure | Followed as written? | Deviation / friction — needs /evolve-procedure? |
|---|---|---|
| <path or id of each procedure consulted this turn> | <yes / no — what you did instead> | <what was wrong, stale, or costly, and whether it warrants a patch> |

<If no procedure covered the work, say so — an uncovered success is the input
for a new draft, not an empty section.>

## Claims and evidence

```
CLAIM: <what you are asserting>
  $ <the command>
  <its actual output, trimmed but not paraphrased>
```

<One block per claim. A claim without a command and its output is not a
result — move it to Assumptions.>

⚠ Paste output, never paraphrase it — paraphrase is where a failing line
quietly becomes a passing one. Include the inconvenient results too: the
reviewer sees only this report, so omitting one makes the review worthless and
the failure yours. A disconfirmed hypothesis is a finding, not an
embarrassment.

## Assumptions

- <Anything unverified this turn. "Should still work" belongs here, not above.>

## Not done

- <Deferred work, skipped checks, paths not taken, and why.>

## What would change my mind

- <For each judgment call: the check that would falsify it, and whether you ran
  it.>
