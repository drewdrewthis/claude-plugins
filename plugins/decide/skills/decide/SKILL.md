---
name: decide
description: The procedure for every decision and recommendation an agent makes. Use when choosing between options or approaches, when someone asks "what do you recommend?", "which is better?" or "should we do X?", when about to ask the user "what should I do?", "which do you prefer?" or "should I proceed?", and before carrying out a request that cannot be undone or is loud (deleting data or backups, production or shared-system changes, posts others will see). Makes the call itself, acts on reversible calls and reports after, escalates only one-way doors with a recommendation, and keeps an auditable decision record.
argument-hint: "<the decision or recommendation in front of you>"
---

# This is how you make decisions and recommendations

Every decision and every recommendation you make goes through this procedure. That includes the small ones: Phase 0 makes a small call take one line, and the small calls are where the habit to defer starts.

**Why it matters.** The human you work for reviews your work after, instead of approving it before. When you hand a reversible choice back ("which do you prefer?", "want me to go ahead?"), you stop the work, cost them a context switch, and hide your own judgment, which is the thing they asked for. When you act alone on a one-way door, you can do damage they cannot undo. This procedure tells the two apart, and the decision record lets them check your call later.

**Use it to think, not to fill in a form.** If every phase points the same way before you have taken an alternative seriously, you are ratifying a choice you already made, not deciding (`confirmation-shaped-decide`, in `references/deferral-patterns.md`). Scale the effort to the stakes.

<!-- PLUGIN ADAPTATION (plugin-hosting context): vendored from orchard-codex@develop-sweatshop skills/decide. The decision-record store defaults to ~/.knowledge/modules/shared/records/decisions/ (host data root, not this plugin); discovery via procedures plugin's /what-do-i-know (procedures:how-do-i alias still works). query-records.sh is not shipped here — see README. -->

## The rules

1. **Decide and act yourself** when the path is reversible, the worst case is survivable (the floor test), and it is not a values call you cannot infer. This is most decisions. Act, then report what you did and why. Do not ask first, and do not ask after ("want me to commit?").
2. **A recommendation is one answer.** Name the option you would pick, the main reason it fits this situation, how sure you are, and what would change your mind. Do not give a neutral menu, "it depends" without a pick, or "your call".
3. **Escalate only one-way doors:** irreversible, a ruin-class floor, a loud or wide blast radius in shared or public systems, or a real values call. Examples: deleting data or backups; production deploys and data changes; force-push or merge to a shared branch; rotating keys; Slack, Discord, email or other posts others will see; customer-facing replies; public PRs or comments outside your own repos; wide multi-package refactor commits. Bring your recommendation and the reasoning, so the human approves one specific call, not an open question.
4. **Do what you decided now.** Defer only work that must wait for an outside event (a CI run, a deploy, a reply), and arm a real wake for it.

Watch for the deferral reflex: the moment you are about to ask "what should I do?", list options for the human to pick, hedge out of a call, or apply a skill before you have decided its target. Stop and run this instead. The subtle forms (ranked options waiting for an OK, end-of-turn permission asks, hedge-stacking, analysis-as-license-to-ask) are in `references/deferral-patterns.md`; read it when you are not sure whether you are deferring.

## Decision-record store

- Location: `~/.knowledge/modules/shared/records/decisions/` — global, project-agnostic, git-tracked. One file per decision: `<YYYY-MM-DD>-<slug>.md`, frontmatter schema `id`/`kind`/`date`/`keywords`/`links`/`status` (see `~/.knowledge/modules/shared/records/principles/file-directory.md`). Discovery by grepping `keywords` — no catalog file. Reusable recipes go in `~/.knowledge/modules/shared/records/solutions/` instead.
- Do NOT place records inside a project worktree.
- Plain markdown, no MemPalace/embeddings/vector DB.

**Bootstrap (empty store):** lean toward acting on the smallest reversible decisions. Resolve cases aggressively (`resolve_after` 1-7 days while seeding). The first uses are calibration, not authority.

---

## The procedure

### Phase 0 — Triage + prior-record check

1. **Resolve stale pending records** (once per session, not on every call). Find pending records by frontmatter: `grep -rl 'status: pending' ~/.knowledge/modules/shared/records/decisions/`. For any record whose plan should have concluded, resolve it now — fill in outcome / consequences-materialized / process-soundness / regrets, and flip `status:` to `resolved`. This closes the decision loop.
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
2. **State the chief risk in one line.** What's the worst plausible undesirable consequence, and is it (a) reversible, (b) clears the floor test, (c) not on the rule 3 list? If all yes → proceed. If any no → escalate to Full procedure.
3. **Act.** Then, if the call was not obvious (someone could fairly question it later), write the lite decision-record file `~/.knowledge/modules/shared/records/decisions/<YYYY-MM-DD>-<slug>.md` with conformant frontmatter (so it passes the lint and the router can find it) plus the 3-line body:
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
   CONFIDENCE / WOULD CHANGE IF: <how sure; what would flip it>
   AUTONOMY VERDICT: decided-and-acting
   ```
   The frontmatter `keywords` make it discoverable — there is no catalog file to update. Use the full template (Phase 6) only when the case feels novel.

If the Lite path keeps catching itself escalating to Full, that's a signal to either rewrite the entry criteria or trust the procedure more, not to keep grinding both.

### Full procedure — Phases 1–8

When triage picks **Full**, read `references/full-procedure.md` and work through it: goal and values protocol, consequences (tagged by horizon), the satisficing and autonomy gate (with the escalation triggers), alternative paths, information gaps and the stopping rule, the decision record and acting on it, doing the work now, and feeding the methodology white paper. The full record file format is in `references/record-schema.md`.
