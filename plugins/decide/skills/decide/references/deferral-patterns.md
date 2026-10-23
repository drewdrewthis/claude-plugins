# /decide — deferral patterns to catch

The moments when /decide should run, and the subtle ways an agent hands a decision back without noticing.

## The deferral reflex

Trigger: the deferral reflex. The moment you're about to:
- ask "what should I do?" / "which do you prefer?" / "should I proceed?"
- present a menu of options for the human to pick from
- caveat your way out of committing to a non-trivial call
- reach for a downstream skill or procedure (the `ship` skill's PR+MONITOR mode, the launch procedure `~/.knowledge/modules/shared/records/procedures/fleet-session/lifecycle/PROCEDURE.md#launch`, the `coder` agent, `/implement`, ...) without first checking that its *target* is correct — `routine-skill-skips-decide`. The skill being the right tool is not the same as the goal being the right goal; if you haven't decided what to apply the skill to, you haven't decided.

— stop, and run /decide instead. Resolve it, then act.

(Genuinely trivial decisions don't need the full procedure — Phase 0 fast-paths them. And genuinely irreversible/high-stakes ones the procedure will route to the human deliberately — that's different from the reflexive deferral this skill replaces.)


## Subtler deferral patterns (the squeeze-the-balloon failures)

The front-of-turn deferrals are easy to catch. These aren't:

- **Ranked-options as deferral.** "Here are three approaches, I recommend (a)" — still deferral if you're waiting for an OK. If (a) is reversible and you'd act on it, just do it; report after.
- **Preemptive-concerns deferral.** Listing risks the user might object to so they can veto without you having to commit. State concerns inside the decision record, not as an invitation to override.
- **End-of-turn permission-seeking.** "Want me to commit?" / "Should I proceed?" / "Apply this?" *after* doing reversible work. Bookending autonomous work with a permission ask undoes it. Report what you did, not whether to do it.
- **Hedge-stacking.** "I'll do X, but tell me if you want Y instead" — same pattern, friendlier costume.
- **Ratification-shaped procedure** — `confirmation-shaped-decide`. The inverse failure of deferral, same root: running /decide to *ratify* a path you've already chosen instead of to investigate the choice. Tell: every phase's output points the same direction; alternatives in Phase 4 are strawmen; the record reads like a defense, not an audit. If you can't name what would have made you choose differently, you weren't deciding — you were performing. Restart from Phase 1 with the chosen path treated as one candidate among others, not the answer.
- **Analysis-as-license-to-ask** — a thorough decomposition followed by "which should we do?" / "should I proceed?" / "happy to do X if you confirm" is still a deferral. The careful analysis can make the post-analysis ask feel earned — it isn't. **The quality of your reasoning predicts permission-asking BACKWARD**: if you reasoned through it cleanly and the chosen path is reversible, you've earned the right to act, not the right to defer. Tell: the post-analysis sentence ends in a question mark or "your call" or "let me know"; the reversibility check would have cleared if you'd run it.  ⚠ fm.ask-permission-on-reversible — reversible? Act and report; the ask is reflex.

If you catch any of these, you were running /decide implicitly without writing the record. Either commit and write the record, or surface the genuine escalation reason.
