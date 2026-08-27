# ADR-002: Keep the hand-rolled FTS5 query repair, don't adopt apsw.fts5query

**Status:** Accepted. Resolves issue #55 ("evaluate apsw.fts5query vs
hand-rolled fts5_query.py").

## The problem

`plugins/recall/scripts/fts5_query.py` (270 lines) translates lenient,
user-typed prose-ish search strings into valid SQLite FTS5 query syntax,
repairing the malformed constructs users actually type. Issue #55 asked
whether `apsw.fts5query` — the FTS5 query-string parser/AST/serializer
shipped with the `apsw` SQLite driver — could replace this hand-rolled code,
either shrinking it or removing it outright.

## What apsw.fts5query actually is

A direct probe of `apsw` 3.53.4.0 (manylinux wheel, installed in a
throwaway venv) shows `apsw.fts5query` provides `parse_query_string`,
`to_query_string`, and `quote` — a parser, AST, and serializer for text
that is **already valid FTS5 syntax**. It is built for programmatic query
construction and modification (build an AST, mutate it, re-serialize it),
not for accepting arbitrary user input.

That is a different requirement from what `fts5_query.py` solves: lenient
prose→FTS5 translation versus strict FTS5 AST manipulation. Reuse doesn't
cover the actual requirement, so the evaluation turned on whether apsw
could still shrink the repair logic. It can't.

## Evidence

Feeding apsw.fts5query the inputs `fts5_query.py` exists to repair, all of
them are rejected with `ParseError`:

- `foo(bar)` — "Unexpected", position 3.
- `a AND OR b` and `a AND NOT b` — "Expected a search term".
- `rate-limiter` — "Expected :"; the hyphen is read as a column filter.
- `it's broken` — the apostrophe is read as an invalid character.
- Trailing punctuation, e.g. `(postgres OR notes).`

One case parses but disagrees with the intended behavior: `running NEAR`
is accepted, but apsw treats the bare `NEAR` as a literal search word.
`fts5_query.py` instead deliberately drops a bare `NEAR` silently, because
a bare `NEAR` can't take the `NEAR(a b, N)` grouping the caller hasn't
supplied — treating it as a literal token would silently change the
query's meaning rather than degrade gracefully.

One case matches: `kuber*` prefix syntax works identically in both.

None of the three defects issue #55 flagged — `_collapse_run` precedence
handling, the bare-`NEAR` drop, and `foo(bar)` misread as a grouping — is
addressed by apsw. apsw *rejects* malformed input; `fts5_query.py`
*repairs* it. Adopting apsw would leave all of the existing repair logic
in place, unchanged, with a native C-extension dependency added
underneath it for no offsetting reduction in code.

`fts5_query.py` also does something apsw has no equivalent for: it probes
SQLite's real `unicode61` tokenizer per-token (`_tokenizable`, lines
61-92) to avoid empty-phrase zero-result bugs. Two earlier regex-based
approximations of tokenizability shipped silent wrong answers before this
probe replaced them — that failure mode is specific to lenient
translation and isn't a problem apsw's strict parser needs to solve.

On the dependency question: `apsw.fts5query` only needs `apsw.stricmp`, so
adopting it would not have forced swapping out the stdlib `sqlite3`
driver. That removes one objection, but it doesn't change the outcome —
the dependency isn't worth paying because it solves a different problem
than the one `fts5_query.py` was built for.

## Decision

Keep `plugins/recall/scripts/fts5_query.py` as the hand-rolled FTS5 query
repair layer. Do not adopt `apsw.fts5query`.

## Consequences

- The three behaviors issue #55 flagged (`_collapse_run` precedence
  handling, the bare-`NEAR` drop, `foo(bar)` treated as a grouping) remain
  deliberate, documented choices in `fts5_query.py`, not gaps to be closed
  by a library swap.
- No new dependency (`apsw`) is introduced; the stdlib `sqlite3` driver
  stays as-is.
- Revisit this decision only if the requirement changes shape — from
  lenient prose→FTS5 translation to programmatic manipulation of queries
  that are already valid FTS5 syntax (e.g. building or rewriting an AST
  rather than repairing free-typed input). That is the problem
  `apsw.fts5query` is actually built for.

Refs: issue #55
