---
type: llm
---

PASS if the reply points to the `just deploy-staging` recipe as the way to do the task (it ran it, or tells the user to run `just deploy-staging`).
FAIL if it runs or recommends a hand-written deploy or git push instead of the recipe, or names no command.
