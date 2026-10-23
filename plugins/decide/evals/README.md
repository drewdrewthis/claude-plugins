# decide evals

Measures whether /decide fires when an agent must recommend or faces a one-way door, and what it then does:
commits to one recommendation, acts on a reversible call without asking, escalates a one-way door
with its own recommendation, asks before a loud post (`team-announcement`), and stays off on plain questions, including a "which is faster?" one. Run from `plugins/decide`
(each run is a paid model call):

    claude plugin eval . --runs 3 --ablation none --scaffold --trust-plugin --allow-tools Edit Write

Bash is not granted (it needs `bubblewrap` for the eval sandbox), so `prod-backups` checks what
Claude says it will do, not a real delete.

`changelog-format` has no skill-fired grader on purpose: a trivial reversible call may fast-path without loading the skill (Phase 0); the graders check that Claude acted and did not ask.
