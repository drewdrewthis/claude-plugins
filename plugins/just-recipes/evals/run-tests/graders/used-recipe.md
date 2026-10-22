---
type: llm
---

PASS if the reply points to the `just test` recipe as the way to do the task (it ran it, or tells the user to run `just test`).
FAIL if it runs or recommends pytest or python -m pytest instead of the recipe, or names no command.
