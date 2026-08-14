#!/usr/bin/env bash
# session-digest-read.sh — READ surface for this session's prior /how-do-i digests.
#
# Handed to the forked procedure-scout so it can start warm: what this session
# already established, before it searches for what it has not.
#
# READ-ONLY BY CONSTRUCTION. The scout holds Bash, and a scout that could write
# here would be authoring the "prior findings" it then cites as established —
# a warm start has to come from a completed fork, recorded by
# hooks/digest-record.sh, which is the only writer.
#
# Usage:
#   scripts/session-digest-read.sh --read <session_id>
#
# Output: prior digests oldest-first behind `==> prior /how-do-i digest N <==`
# headers, capped at SESSION_DIGEST_KEEP (3) with a loud count line when it
# truncates. No prior digests, no session id, or a session id the harness never
# interpolated: empty stdout, exit 0 — a cold start is always a valid outcome.
#
# Exit codes:
#   0  ran (empty stdout means nothing to replay)
#   2  usage error

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../hooks/lib/session-digest.sh
. "$SCRIPT_DIR/../hooks/lib/session-digest.sh" 2>/dev/null || exit 0

case "${1:-}" in
    --read)
        # A missing or un-interpolated id is a cold start, not an error: the
        # scout must never see a stack trace where it expected context.
        KEY="$(sd_key "${2:-}")" || exit 0
        sd_read "$KEY"
        exit 0
        ;;
    *)
        echo "session-digest: read-only — usage: session-digest-read.sh --read <session_id>" >&2
        exit 2
        ;;
esac
