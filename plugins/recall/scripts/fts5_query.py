"""Translate a human's words into a valid FTS5 MATCH expression.

Pure and dependency-free: `translate(str) -> str`, raising `Fts5QueryError` for
the one input that cannot be honoured. Nothing here touches a database, the
filesystem, or the environment, so every behaviour is directly table-testable.

FTS5 reads its input as a query language, so ordinary prose detonates it: a
hyphen reads as a column filter (`rate-limiter` -> "no such column: limiter"),
an apostrophe as an unterminated string. Quoting each bare term makes it a
literal while leaving the boolean operators the caller relies on intact.

The token set FTS5 treats as syntax is CLOSED, and this module enumerates it:

    AND OR NOT   binary infix    -- preserved
    NEAR         needs NEAR(a b, N) grouping the caller cannot express
    trailing *   prefix match    -- preserved
    " ( ) : ^    syntax          -- neutralised by quoting

⚠ Every defect this module has ever shipped was a *silent wrong answer* — a
valid expression that searched for something other than what was asked. None
raised. That is why the tests assert which documents come back from a real FTS5
index (polarity), never merely the rendered string.
"""

import re

__all__ = ["translate", "Fts5QueryError", "BINARY_OPS"]

# The three infix boolean operators. Order within a collapsed run matters; see
# _collapse_run.
BINARY_OPS = ("AND", "OR", "NOT")

# A bare trailing-* prefix term, e.g. `kuber*` — passed through unquoted.
PREFIX_TERM = re.compile(r"^\w+\*$")


class Fts5QueryError(ValueError):
    """A query that cannot be translated without changing what was asked."""


def _quote(token):
    """Render a token as an FTS5 string literal, escaping embedded quotes."""
    return '"' + token.replace('"', '""') + '"'


def _collapse_run(run):
    """Reduce consecutive binary operators to the one that preserves meaning.

    Callers build unions programmatically, so runs like `a AND NOT b` and
    `a OR OR b` both arrive. FTS5 accepts only one operator between terms.

    NOT wins any run it appears in: it is the only operator whose loss INVERTS
    the result rather than merely widening it. `a AND NOT b` collapsed to `AND`
    returns exactly the documents the caller asked to exclude — the defect this
    module was extracted to kill. Collapsing to `NOT` instead can only ever
    return fewer documents than intended, never the forbidden ones.
    """
    return "NOT" if "NOT" in run else run[0]


def translate(query):
    """Translate `query` into an FTS5 MATCH expression.

    Returns "" when the query holds no searchable terms; the caller decides
    whether that is an error. Raises `Fts5QueryError` only for a leading NOT.
    """
    if not isinstance(query, str):
        raise Fts5QueryError("query must be a string, got %s" % type(query).__name__)

    out = []
    run = []

    def flush_run():
        if run:
            out.append(_collapse_run(run))
            run.clear()

    for token in query.split():
        if token == "NEAR":
            # FTS5 spells proximity NEAR(a b, N); a bare NEAR is not an infix
            # operator, and quoting it searches for the literal word — so
            # `running NEAR` returned 0 hits instead of every "running" doc.
            # Dropping it widens the result set, the safe direction for recall.
            continue
        if token in BINARY_OPS:
            run.append(token)
            continue
        flush_run()
        out.append(token if PREFIX_TERM.match(token) else _quote(token))

    # A trailing run is dropped, not flushed: `a AND` is a syntax error, and a
    # dangling operator carries no meaning to preserve.
    run.clear()

    # A leading NOT cannot be honoured: FTS5's NOT is binary, so dropping it
    # silently returns the exact complement of what was asked for.
    if out and out[0] == "NOT":
        raise Fts5QueryError(
            "a query cannot begin with NOT — FTS5 excludes with 'a NOT b'"
        )
    # A programmatic union can still open on AND/OR, which is a syntax error
    # rather than a no-op.
    while out and out[0] in BINARY_OPS:
        out.pop(0)
    return " ".join(out)
