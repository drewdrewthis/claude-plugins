# /decide — full procedure (Phases 1–8)

Read this when Phase 0 triage picks **Full procedure**. Phase 0 and the Lite path are in `../SKILL.md`.

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
