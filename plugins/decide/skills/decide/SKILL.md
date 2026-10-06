---
name: decide
description: Reach for this instead of asking the user "what should I do?", "which option do you prefer?", or "should I proceed?". A procedure to resolve a decision yourself and act on it — escalating to the human only the genuinely irreversible, high-stakes, or values-laden minority. Produces an auditable decision record so the human reviews after instead of approving before. Use whenever you catch yourself about to defer a non-trivial decision back to the user.
argument-hint: "<the decision you were about to ask about>"
---

# /decide

<!-- PLUGIN ADAPTATION (plugin-hosting context): vendored from orchard-codex@develop-sweatshop skills/decide. The decision-record store defaults to ~/.knowledge/modules/shared/records/decisions/ (host data root, not this plugin); discovery via procedures plugin's /what-do-i-know (procedures:how-do-i alias still works). query-records.sh is not shipped here — see README. -->

Trigger: the deferral reflex. The moment you're about to:
- ask "what should I do?" / "which do you prefer?" / "should I proceed?"
- present a menu of options for the human to pick from
- caveat your way out of committing to a non-trivial call
- reach for a downstream skill or procedure (the `ship` skill's PR+MONITOR mode, the launch procedure `~/.knowledge/modules/shared/records/procedures/fleet-session/lifecycle/PROCEDURE.md#launch`, the `coder` agent, `/implement`, ...) without first checking that its *target* is correct — `routine-skill-skips-decide`. The skill being the right tool is not the same as the goal being the right goal; if you haven't decided what to apply the skill to, you haven't decided.

— stop, and run /decide instead. Resolve it, then act.

(Genuinely trivial decisions don't need the full procedure — Phase 0 fast-paths them. And genuinely irreversible/high-stakes ones the procedure will route to the human deliberately — that's different from the reflexive deferral this skill replaces.)

### Subtler deferral patterns (the squeeze-the-balloon failures)

The front-of-turn deferrals are easy to catch. These aren't:

- **Ranked-options as deferral.** "Here are three approaches, I recommend (a)" — still deferral if you're waiting for an OK. If (a) is reversible and you'd act on it, just do it; report after.
- **Preemptive-concerns deferral.** Listing risks the user might object to so they can veto without you having to commit. State concerns inside the decision record, not as an invitation to override.
- **End-of-turn permission-seeking.** "Want me to commit?" / "Should I proceed?" / "Apply this?" *after* doing reversible work. Bookending autonomous work with a permission ask undoes it. Report what you did, not whether to do it.
- **Hedge-stacking.** "I'll do X, but tell me if you want Y instead" — same pattern, friendlier costume.
- **Ratification-shaped procedure** — `confirmation-shaped-decide`. The inverse failure of deferral, same root: running /decide to *ratify* a path you've already chosen instead of to investigate the choice. Tell: every phase's output points the same direction; alternatives in Phase 4 are strawmen; the record reads like a defense, not an audit. If you can't name what would have made you choose differently, you weren't deciding — you were performing. Restart from Phase 1 with the chosen path treated as one candidate among others, not the answer. See `~/.knowledge/modules/shared/records/solutions/2026-05-20-abandon-643-skip-to-v08.md`.
- **Analysis-as-license-to-ask** — a thorough decomposition followed by "which should we do?" / "should I proceed?" / "happy to do X if you confirm" is still a deferral. The careful analysis can make the post-analysis ask feel earned — it isn't. **The quality of your reasoning predicts permission-asking BACKWARD**: if you reasoned through it cleanly and the chosen path is reversible, you've earned the right to act, not the right to defer. Tell: the post-analysis sentence ends in a question mark or "your call" or "let me know"; the reversibility check would have cleared if you'd run it.  ⚠ fm.ask-permission-on-reversible — reversible? Act and report; the ask is reflex.

If you catch any of these, you were running /decide implicitly without writing the record. Either commit and write the record, or surface the genuine escalation reason.

**Bootstrap (empty store):** lean toward acting on the smallest reversible decisions. Resolve cases aggressively (`resolve_after` 1-7 days while seeding). The first uses are calibration, not authority.

## Decision-record store

- Location: `~/.knowledge/modules/shared/records/decisions/` — global, project-agnostic, git-tracked. One file per decision: `<YYYY-MM-DD>-<slug>.md`, frontmatter schema `id`/`kind`/`date`/`keywords`/`links`/`status` (see `~/.knowledge/modules/shared/records/principles/file-directory.md`). Discovery by grepping `keywords` — no catalog file. Reusable recipes go in `~/.knowledge/modules/shared/records/solutions/` instead.
- Do NOT place records inside a project worktree.
- Plain markdown, no MemPalace/embeddings/vector DB.

---

## The procedure

### Phase 0 — Triage + prior-record check

1. **Resolve stale pending records.** Find pending records by frontmatter: `grep -rl 'status: pending' ~/.knowledge/modules/shared/records/decisions/`. For any record whose plan should have concluded, resolve it now — fill in outcome / consequences-materialized / process-soundness / regrets, and flip `status:` to `resolved`. This closes the decision loop.
2. **Check for a known case.** Does this decision resemble a past case? If so, pull the file and **quote its outcome and process-soundness explicitly** — not just "a similar case exists." State whether you're fast-pathing on it or treating the new decision as a variant. **Then check `wisdom-as-confirmation-bias`:** is the case shape actually a match for the *situation*, or am I cite-matching by tag against a path I was already on? A case used as armor against a correction is not precedent — it's rationalization. Test: would I pull this same case if the chosen path were the opposite?
3. **Triage — three weights.** Pick one:
   - **Fast-path** — trivial AND instantly reversible AND matches a known-good case (or is plainly obvious). Decide in a line, act, log only if non-obvious. No record template needed.
   - **Lite path** — small but not trivial; reversible; consequences shallow; no values call. Use Phase 0.5 below. ~3 lines of record. This is the default for most decisions a working agent makes in a turn.
   - **Full procedure** — non-trivial consequences, multiple plausible paths, irreversibility risk, or a values call. Continue to Phase 1.

   If unsure which weight, default UP one level. The skill exists to bias toward action, not to bias toward deliberation; but a borderline-Full mistaken as Lite is worse than a borderline-Lite mistaken as Full.

   **Meta-check — `lite-pass-too-aggressive`.** Certainty about the triage weight is itself a decision. If you're *certain* this is Lite (not unsure), ask: am I certain because I've genuinely assessed reversibility, floor, and values — or because the lighter weight serves a path I'm already on? Confident-in-the-wrong-direction looks identical to confident-and-correct from the inside; the tell is whether the weight you picked happens to be the one that lets you skip the alternatives in Phase 4.

4. **Background tier (option at Full).** If ALL THREE triggers fire, run the Full procedure in a **background agent** (spawn via the Agent tool with `run_in_background: true` and a clean brief), then return to the deciding session to act on the record:
   - Weight = Full procedure (this option is not available at Fast or Lite — the trajectory bias is bounded enough there to skip the cost), AND
   - Self-assessed correctness confidence is **<90%**, AND
   - Trajectory-rich context: >30 turns since the last fresh boot OR a strong user-framing turn ("just do X," "obviously the right call is Y") in the last few turns.

   When the Background tier fires, **the brief must present candidate paths neutrally**, not the parent's preferred narrative. Briefing-as-framing is a known leak (white paper §10 Q14): if the brief encodes the parent's trajectory, the background agent will rationalize the same trajectory in cleaner clothes. Mitigation: list candidate paths in random or alphabetical order, do not lead with a recommendation, do not name "the right answer."

   The Background tier is also the canonical mechanism for the polar-framing convergence experiment (white paper §10 Q12): spawn TWO background agents, one with "is X correct?" framing, one with "is X wrong?" framing, see if they converge. Recommended for the first 3–5 Suggestive-tier cases to validate the methodology.

   For everything else: inline is the default and remains the default.

### Phase 0.5 — Lite path

For Lite-weight decisions, run this 3-step variant. Skip Phases 1-5; produce a 3-line record.

1. **State the goal in one line.** What outcome am I after?
2. **State the chief risk in one line.** What's the worst plausible undesirable consequence, and is it (a) reversible, (b) clears the floor test? If both yes → proceed. If either no → escalate to Full procedure.
3. **Act.** Then write the lite decision-record file `~/.knowledge/modules/shared/records/decisions/<YYYY-MM-DD>-<slug>.md` with conformant frontmatter (so it passes the lint and the router can find it) plus the 3-line body:
   ```
   ---
   id: dec.<YYYY-MM-DD>-<slug>
   kind: decision
   date: <YYYY-MM-DD>
   keywords: [tag, tag]
   links: {}
   status: resolved
   ---
   DECISION: <chosen path>
   CHIEF RISK (accepted): <one line — reversible, floor-clear>
   AUTONOMY VERDICT: decided-and-acting
   ```
   The frontmatter `keywords` make it discoverable — there is no catalog file to update. Use the full template (Phase 6) only when the case feels novel.

If the Lite path keeps catching itself escalating to Full, that's a signal to either rewrite the entry criteria or trust the procedure more, not to keep grinding both.

### Phase 1 — Goal + values protocol

4. **What is the actual goal?**
5. **Interrogate it.** Is this the correct goal, or a proxy for a deeper one? Does it need challenging? Whose goal is it? (Thread in any wisdom-file regret about goal-framing.) **`research-mode-quotes-as-commitments` check** — if you're about to cite prior user-stated direction ("they said X last week", "the user committed to Y") as a constraint, check the *mode* of the original utterance: exploratory / research / thinking-aloud text is not binding policy. Quoting tentative text back as commitment fabricates a constraint the user never made. When in doubt, ask the user whether the prior framing still holds — *that* ask is not deferral, it's calibration.
6. **State the values protocol** — the yardstick: risk tolerance, time horizon, reversibility weighting, whose welfare counts.

### Phase 2 — Consequences

7. **If we pursue the goal, what are the consequences?** Enumerate first-order. **Tag each one with a horizon:** `immediate` (this turn), `today` (this session / day), `week` (the work cycle), `structural` (load-bearing forever — always-loaded rules, infrastructure, public commits). Trajectory bias under-weights `structural` consequences because the model's attention is on the current turn; the explicit tag forces the long-horizon read. **`false-urgency-anchoring` check on each consequence** — especially urgency-shaped ones ("X is blocked!", "Y is broken!"): ask *whose* urgency. Actually-felt by a real consumer waiting now, or theoretically-felt because something is technically in a non-ideal state? Weight actually-felt urgency; discount theoretical urgency. "The daemon is blocked" with no caller waiting is not the same consequence as "the daemon is blocked and three workers are stalled." Theoretical blocks that anchor a fast decision are a known leak.
8. **Chain them** — consequences of consequences, to a depth proportionate to the stakes. Failures hide in the 2nd/3rd order. Chain depth (causal) is separate from horizon (temporal); a 1st-order consequence can be structural-horizon. Don't conflate.
9. **Sort against the protocol:** desirable vs. undesirable.

### Phase 3 — Satisficing gate + autonomy gate

10. **For each undesirable consequence, run the decomposition — don't eyeball it:**
    - **Severity × probability** — estimate the expected cost.
    - **Reversibility** — reversible → low bar; irreversible → high bar (two-way vs. one-way door).
    - **Floor test** — if it happened in full, is the resulting world survivable? A ruin-class tail is unacceptable regardless of probability.
    - **Comparative** — acceptable relative to what? A negative every path carries is a cost of the goal, not a strike against this path.

11. **The autonomy gate — this is what the decomposition is FOR.** The decomposition tells you which kind of decision this is:
    - **Decide and act yourself** if the chosen path is reversible, clears the floor, and isn't a genuine values call you can't infer. This is the large majority. Do not ask the human.  ⚠ fm.ask-when-rules-decide — if the decomposition already determines the answer, act on it; presenting the conclusion as a question is deferral.
    - **Escalate to the human** only if the path is irreversible, has a ruin-class floor, affects shared systems in a hard-to-undo way, or hinges on a values judgment the human's preference genuinely can't be inferred for. This is the minority. Escalating here is correct — it is not the reflexive deferral the skill exists to stop.

**Escalation triggers — concrete examples.** These are the canonical blast-radius cases that earn human escalation even when individually reversible, because their floor is loud or wide:

- **Slack / Discord / team-chat posts** — visible to everyone, hard to retract without drawing more attention.
- **Production deploys** — reversible by rollback, but the floor includes user-visible downtime or data corruption.
- **Customer-facing replies** — email, support response, public PR comment on an open-source repo touching a user issue.
- **Public-repo PRs that aren't `langwatch/*` or codex** — third-party signals; closing without merging carries social cost.
- **Telegram broadcasts to the @BoxdOrchardistBot channel** — fanout to every orchardist machine; not undoable in any consumer's notification feed.
- **Wide-scope refactor commits** — multi-file, multi-package edits where rollback is messy because intermediate state is hard to reproduce.

These are *reversible with loud blast radius*, escalating on the floor test, not on reversibility itself.

12. **Route each undesirable consequence:**
    - **Unacceptable** → Phase 4.
    - **Acceptable but cheaply closeable** → close it now, in this run. A hole you found and could close is not a residual.
    - **Acceptable and irreducible** → a named residual; carry it to Phase 6.

    When every consequence is closed or accepted-irreducible → Phase 5.

### Phase 4 — Alternative paths

13. **What other paths reach the goal with fewer / no unacceptable negatives?** Generate on demand. Run each through Phases 2–3. First to clear the gate → Phase 5.

### Phase 5 — Info gaps + stopping rule

14. **What information would change this decision?** For each gap ask: *would this change the decision, or only refine the how?* Only decision-changing gaps matter here — "could always know more" is not a gap.
15. **Stopping rule.** Is closing a decision-changing gap (or evaluating another path) worth it — expected value vs. cost, scaled to stakes?
    - **Wasteful** → STOP. Commit.
    - **Warranted** → gather, re-enter Phase 1.
16. **Loop guard.** If the decision keeps resolving the same way across passes, commit.

### Phase 6 — Decide, act, log

17. **Decision record — this is the skill's headline deliverable. Use this fixed template:**

    ```
    DECISION: <the chosen path>
    GOAL IT SERVES: <the interrogated goal>
    DECOMPOSITION:
      | consequence | severity×prob | reversibility | floor | verdict |
    ACCEPTED RESIDUALS: <named — what we're proceeding with>
    PROCEEDING DESPITE: <named uncertainty — separate from residuals>
    AUTONOMY VERDICT: decided-and-acting  |  escalating to human (reason)
    ```

18. **Act.** If the autonomy verdict is decide-and-act: carry out the decision. Don't stop at the record and wait. If escalating: hand the record to the human — they're approving a specific, decomposed call, not answering an open "what should I do?".
19. **Write a decision-record file** (schema below). Its frontmatter `keywords` make it discoverable — there is no catalog file to update. State plainly you are writing a *new* file this run — don't describe a file you just wrote as pre-existing.
20. **Queue the outcome update:** note `resolve_after` so a future Phase 0 fills in how it turned out.

### Phase 7 — Plan the chosen path

21. **Do the work now.** Turn the chosen path into ordered next-actions and EXECUTE them this turn. **Future work is a failure mode** — filing a tracked goal "for later" instead of finishing is the deferral reflex wearing a planning costume. A decision that stops at the record rots. If you decided it, do it.
22. **The only legitimate deferral is genuinely time-gated work** — something that physically cannot happen until an external event (a deploy that takes 8 minutes, a CI run, a teammate's reply). For those, arm a real machine wake (`CronCreate`, `ScheduleWakeup`, a Monitor) — that's a `<waiting-for>` terminal, not a tracked-for-later. Everything you COULD do now, do now.

### Phase 8 — Feed the methodology

23. **Update the white paper if this case surfaces methodology-level signal.** The white paper at `~/.knowledge/modules/shared/records/decide-whitepaper.md` is a living scientific-method document; it grows only when /decide invocations produce evidence about the methodology itself. Trigger an edit when:
    - The case reveals a new failure mode (a new entry for the anti-deferral catalog or a new threat to validity).
    - The case is a falsification or confirmation event for one of the registered hypotheses (H0–H3 or any successor).
    - A registered open question is now answerable.
    - A registered prediction has now resolved (one way or the other).

    Do NOT update the white paper after every case. Routine cases feed the decision-record store and stop there; the white paper is for *changes to the model of the methodology itself*. If unsure whether a case is white-paper-worthy, leave a note in the decision-record file and let it accumulate — multiple notes that point in the same direction will earn a paper revision when the pattern is clear.

    When you do update: bump the revision log with a short summary, keep the prior content (revisions are additive, not silent rewrites), and check whether the §10 open questions need pruning.

---

## Decision record schema

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

