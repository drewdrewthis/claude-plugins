---
type: llm
focus: { source: file, path: justfile }
---

PASS if the justfile has a recipe for TODOs whose body counts TODO comments under src/ (for example with grep or rg), or calls a script or command that does.
FAIL if that recipe is empty, only echoes text, or does not look under src/.
