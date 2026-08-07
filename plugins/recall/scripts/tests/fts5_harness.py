#!/usr/bin/env python3
"""Run one query through translate() against a REAL FTS5 index; print the hits.

Prints the matching doc ids, space-separated and sorted, so a bats row can
assert on which documents come back rather than on the rendered expression.
That distinction is the whole point: every defect this module has shipped
produced a *valid* expression that matched the wrong set, so an assertion on
the string is exactly the assertion that keeps passing while search is wrong.

Prints `ERROR: <message>` and exits 2 when translation refuses the query, and
`ERROR: FTS5 rejected ...` when the rendered expression is a syntax error —
distinguishable outcomes, because "refused" and "detonated" are different bugs.
"""

import os
import sqlite3
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from fts5_query import Fts5QueryError, translate  # noqa: E402

# Deliberately overlapping: `c` holds BOTH terms `a` and `b` are distinguished
# by, so an inverted or collapsed operator changes the answer instead of
# happening to agree with the correct one.
DOCS = {
    "a": "kubernetes cluster autoscaling notes",
    "b": "postgres replication lag notes",
    "c": "kubernetes postgres migration notes",
    "d": "the rate-limiter tuning pass",
    "e": "running the suite again",
    "f": 'he said "ship it" (finally) re:launch ^now',
}


def main():
    if len(sys.argv) != 2:
        print("usage: fts5_harness.py <query>", file=sys.stderr)
        return 64

    try:
        expr = translate(sys.argv[1])
    except Fts5QueryError as exc:
        print("ERROR: %s" % exc)
        return 2

    if not expr:
        print("EMPTY")
        return 0

    db = sqlite3.connect(":memory:")
    db.execute("CREATE VIRTUAL TABLE docs USING fts5(id, body, tokenize='porter unicode61')")
    db.executemany("INSERT INTO docs (id, body) VALUES (?, ?)", sorted(DOCS.items()))

    try:
        rows = db.execute(
            "SELECT id FROM docs WHERE docs MATCH ? ORDER BY id", (expr,)
        ).fetchall()
    except sqlite3.OperationalError as exc:
        print("ERROR: FTS5 rejected %r: %s" % (expr, exc))
        return 3

    print(" ".join(r[0] for r in rows) or "NONE")
    return 0


if __name__ == "__main__":
    sys.exit(main())
