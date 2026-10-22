# just-recipes evals

Measures whether the skill loads on natural requests, and stays off on near misses.
Run from `plugins/just-recipes` (each run is a paid model call):

    claude plugin eval . --scaffold --trust-plugin --allow-tools Edit Write

`--scaffold` builds each case's repo from its `fixture.sh`; without it the cases have no justfile.
Bash is not granted: that needs `bubblewrap` for the eval sandbox, so the suite checks what Claude
chose, not that a recipe ran.
