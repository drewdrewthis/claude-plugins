"""Translate a human's words into a valid FTS5 MATCH expression.

`translate(str) -> str`. Deterministic and free of filesystem or environment
access, so every behaviour is directly table-testable.

⚠ It DOES open an in-memory SQLite connection, and that is deliberate. Deciding
which tokens FTS5 will index is not something a regex can do: SQLite's unicode61
alphanumeric table is a frozen, hardcoded range list and Python's `re` table
tracks the interpreter build, so the two diverge on every Unicode release, in
both directions, forever. Approximating one with the other cost eight rounds of
silent wrong answers (`_`, then 21 Tai Lue / Vedic marks that emptied results,
plus ~9,700 characters that silently widened them). The module now ASKS the
tokenizer instead of predicting it. Purity was a means to testability, and it
was buying the wrong thing.

FTS5 reads its input as a query language, so ordinary prose detonates it: a
hyphen reads as a column filter (`rate-limiter` -> "no such column: limiter"),
an apostrophe as an unterminated string. Quoting each bare term makes it a
literal while leaving the operators the caller relies on intact.

The token set FTS5 treats as syntax is CLOSED, and this module enumerates it:

    AND OR NOT   binary infix    -- preserved, runs collapsed (see _collapse_run)
    ( )          grouping        -- preserved; re-associating is a wrong answer
    NEAR         needs NEAR(a b, N) grouping the caller cannot express -- dropped
    trailing *   prefix match    -- preserved
    " : ^        syntax          -- neutralised by quoting

⚠ Every defect this module has ever shipped was a *silent wrong answer* — a
valid expression that searched for something other than what was asked. None
raised. That is why the tests assert which documents come back from a real FTS5
index (polarity), never merely the rendered string.

`Fts5QueryError` is raised for three inputs: a non-string, a query whose
parentheses do not balance, and a NOT with no left operand. Everything else is
repaired rather than refused, because a caller building a union
programmatically emits dangling operators routinely and a refusal there would
be noise.
"""

import re
import sqlite3

__all__ = ["translate", "Fts5QueryError", "BINARY_OPS"]

# Narrowest first. _collapse_run relies on this order: when a run mixes
# operators, the earliest one here wins, because a narrower result can never
# contain a document the caller asked to exclude.
BINARY_OPS = ("NOT", "AND", "OR")

# A bare trailing-* prefix term, e.g. `kuber*` — passed through unquoted.
PREFIX_TERM = re.compile(r"^\w+\*$")

# The one FTS5 question a regex cannot answer: will the tokenizer index
# anything for this token? A token it indexes nothing for renders to an EMPTY
# phrase, and an empty phrase ANDed against real terms matches NOTHING.
_PROBE = None
_TOKENIZABLE_CACHE = {}


def _tokenizable(raw):
    r"""True when FTS5's unicode61 tokenizer yields at least one token for `raw`.

    Asks the tokenizer rather than approximating it. Two regexes have already
    tried and both were wrong in ways that shipped: `\w` kept `_` (a separator
    to unicode61), and `[^\W_]` kept 21 Tai Lue and Vedic marks — each one
    quoting into an empty phrase that zeroed the result set — while dropping
    ~9,700 characters unicode61 would have indexed.

    Cached per token: a cold probe is one INSERT and one MATCH against an
    in-memory table, and real queries repeat their vocabulary heavily.
    """
    global _PROBE
    if raw in _TOKENIZABLE_CACHE:
        return _TOKENIZABLE_CACHE[raw]
    if _PROBE is None:
        _PROBE = sqlite3.connect(":memory:")
        # unicode61 alone, NOT porter: stemming changes which token you get
        # back, never whether there is one, and the question here is only
        # whether there is one.
        _PROBE.execute("CREATE VIRTUAL TABLE t USING fts5(b, tokenize='unicode61')")
    _PROBE.execute("DELETE FROM t")
    _PROBE.execute("INSERT INTO t(b) VALUES (?)", (raw,))
    try:
        answer = _PROBE.execute(
            "SELECT count(*) FROM t WHERE t MATCH ?", (_quote(raw),)
        ).fetchone()[0] > 0
    except sqlite3.OperationalError:
        # A phrase FTS5 will not parse indexes nothing, by definition.
        answer = False
    _TOKENIZABLE_CACHE[raw] = answer
    return answer


class Fts5QueryError(ValueError):
    """A query that cannot be translated without changing what was asked."""


def _quote(token):
    """Render a token as an FTS5 string literal, escaping embedded quotes."""
    return '"' + token.replace('"', '""') + '"'


def _collapse_run(run):
    """Reduce consecutive binary operators to the one that preserves meaning.

    Callers build unions programmatically, so runs like `a AND NOT b` and
    `a OR OR b` both arrive. FTS5 accepts only one operator between operands.

    The narrowest operator in the run wins. NOT is narrowest and matters most:
    it is the only operator whose loss INVERTS the result rather than merely
    widening it. `a AND NOT b` collapsed to AND returns exactly the documents
    the caller asked to exclude — the defect this module was extracted to kill.
    AND beats OR for the same reason in weaker form, and it makes the rule
    total, so `a AND OR b` and `a OR AND b` no longer disagree on nothing more
    than which operator the caller happened to emit first.

    ⚠ One shape narrows rather than round-trips: `a NOT NOT b` is a double
    negation meaning `a AND b`, and this returns `a NOT b`. FTS5 gives the
    caller no way to write a deliberate double negation, so this is a ratified
    choice, not an oversight — but the "can only ever return fewer documents"
    rule does not literally hold there, and it is cheaper to say so than to let
    the next reader rediscover it.
    """
    for op in BINARY_OPS:
        if op in run:
            return op
    raise AssertionError("empty operator run")  # pragma: no cover


def _lex(query):
    """Split into paren tokens and everything-between-parens-and-whitespace.

    Lexing the WHOLE string rather than peeling parens off each whitespace
    token is what makes grouping uniform. Peeling at token edges left two holes,
    both found in review: an interior `)(` was never structure, so
    `(a OR b)(c)` silently became the phrase `"b)(c"` and dropped a document;
    and any trailing punctuation — `(a OR b).` — hid the `)`, turning a balanced
    query into an unbalanced-parens refusal that blamed the user.

    The trade, ratified deliberately: `foo(bar)` is now grouping rather than a
    literal. A paren a human meant literally is no longer honoured anywhere,
    which is the price of there being no positional exception to trip over.
    """
    for raw in re.findall(r"[()]|[^\s()]+", query):
        if raw in ("(", ")"):
            yield raw
        elif raw == "NEAR":
            # FTS5 spells proximity NEAR(a b, N); a bare NEAR is not an infix
            # operator, and quoting it searches for the literal word — so
            # `running NEAR` returned 0 hits instead of every "running" doc.
            # Dropping it widens the result set, the safe direction for recall.
            continue
        elif raw in BINARY_OPS:
            yield raw
        elif not _tokenizable(raw):
            # ⚠ A token with nothing tokenizable in it — a stray `.`, `!`, `-`
            # left by ordinary prose — must be DROPPED, not quoted. Quoting it
            # yields an empty FTS5 phrase, and an empty phrase ANDed against
            # real terms matches NOTHING: `kubernetes AND (postgres OR notes).`
            # silently returned zero rows. Introduced by the whole-string lexer
            # and caught before commit, same class as everything else here.
            continue
        else:
            # ⚠ A prefix term whose STEM is syntax must stay quoted: `NOT*`
            # matches PREFIX_TERM but is not in BINARY_OPS, so passing it
            # through bare emitted `... AND NOT* AND ...` and FTS5 raised
            # `syntax error near "NOT"` — a raw OperationalError escaping a
            # module that documents only Fts5QueryError.
            stem = raw[:-1]
            bare = PREFIX_TERM.match(raw) and stem not in BINARY_OPS and stem != "NEAR"
            yield raw if bare else _quote(raw)


def _parse(tokens):
    """Fold a flat token stream into nested groups, one list per paren depth."""
    root = []
    stack = [root]
    for token in tokens:
        if token == "(":
            group = []
            stack[-1].append(group)
            stack.append(group)
        elif token == ")":
            if len(stack) == 1:
                raise Fts5QueryError(
                    "unbalanced parentheses: a ')' with no matching '('"
                )
            stack.pop()
        else:
            stack[-1].append(token)
    if len(stack) != 1:
        raise Fts5QueryError("unbalanced parentheses: a '(' was never closed")
    return root


def _refuse_leading_not(out, run):
    """Refuse a NOT with no left operand, wherever it is stranded.

    FTS5's NOT is binary. With nothing to subtract from, DROPPING it returns the
    exact complement of what was asked — a silent inversion, the defect class
    this module exists to end. Called at all three places a run can die: before
    an operand, when an empty group eats the run, and at end of group.
    """
    if not out and "NOT" in run:
        raise Fts5QueryError(
            "NOT needs a left operand — FTS5 excludes with 'a NOT b'"
        )


def _normalise(items):
    """Drop what carries no meaning, and reduce each operator run to one token.

    Returns a list alternating operand, operator, operand, ... An operand is a
    rendered term or a nested list. Empty groups vanish, and so does any
    operator left without an operand on both sides — a dangling operator is an
    artifact of programmatic union building, not something to preserve.
    """
    out = []
    run = []
    for item in items:
        if isinstance(item, str) and item in BINARY_OPS:
            run.append(item)
            continue
        if isinstance(item, list):
            item = _normalise(item)
            if not item:
                # `a AND ()` — the group contributed nothing, so the operator
                # that would have joined it must go too. ⚠ Check for a stranded
                # NOT FIRST: clearing the run here used to swallow it, so
                # `NOT () kubernetes` silently returned the complement while
                # `() NOT kubernetes` was correctly refused.
                _refuse_leading_not(out, run)
                run.clear()
                continue
        _refuse_leading_not(out, run)
        if out:
            if not run:
                # Two operands with nothing between them: FTS5 reads adjacency
                # as an implicit AND, which is what a human typing two words
                # means. Make it explicit rather than rely on the default.
                out.append("AND")
            else:
                out.append(_collapse_run(run))
        run.clear()
        out.append(item)
    # A trailing run has no right operand; there is nothing to preserve —
    # except a NOT, which had no left operand either and so is a refusal, not a
    # no-op. That is what makes a group of only `(NOT)` loud.
    _refuse_leading_not(out, run)
    return out


def _render(items):
    parts = []
    for item in items:
        parts.append("(" + _render(item) + ")" if isinstance(item, list) else item)
    return " ".join(parts)


def translate(query):
    """Translate `query` into an FTS5 MATCH expression.

    Returns "" when the query holds no searchable terms; the caller decides
    whether that is an error.
    """
    if not isinstance(query, str):
        raise Fts5QueryError("query must be a string, got %s" % type(query).__name__)
    return _render(_normalise(_parse(_lex(query))))
