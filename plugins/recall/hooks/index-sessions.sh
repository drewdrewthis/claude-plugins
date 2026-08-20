#!/bin/bash
# SessionEnd hook, sole responsibility: incrementally refresh the session search
# index so /recall's first search is warm. <0.1s when nothing changed (mtime
# check), a few seconds on a cold rebuild.
#
# PLUGIN ADAPTATION: script path resolves via ${CLAUDE_PLUGIN_ROOT} instead of
# the codex-absolute ~/.claude/scripts/, so the bundled indexer is the one that
# runs. Backgrounded and fully silenced — a hook that blocks or fails loudly at
# session end would surface an error the user cannot act on (ADR-001: hooks fail
# open). The index is rebuilt on demand by /recall anyway, so a miss here costs
# latency, never correctness.
setsid python3 "${CLAUDE_PLUGIN_ROOT}/scripts/session-index.py" build >/dev/null 2>&1 &
