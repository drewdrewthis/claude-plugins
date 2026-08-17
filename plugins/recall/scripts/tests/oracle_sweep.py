#!/usr/bin/env python3
"""Assert translate()'s drop-oracle agrees with FTS5's tokenizer, per character.

THE ROUND-SEVEN LESSON, as a property rather than a row.

Defects 6 and 7 were both "a token that renders to an EMPTY FTS5 phrase, which
ANDs to nothing and silently empties the result". Defect 6 was fixed by dropping
such tokens; defect 7 was that the regex deciding WHICH tokens to drop (`\\w`)
was a WIDER oracle than the tokenizer it approximated — `_` is a word character
to Python and a separator to unicode61 — so the fix's own guard leaked the very
defect it was written to stop.

Patching the regex again would have been the fifth symptom-level patch. This
pins the invariant instead: for every character, translate() drops it exactly
when FTS5 would tokenize it to nothing. A future divergence — a changed
tokenizer, an edited regex — fails here by construction, before it can become
another wrong answer.

⚠ "Fails by construction" has a second half: this sweep must also fail when it
stops COMPARING. A refusal is skipped rather than checked, so a regression that
refused every token would find zero divergences and exit green over zero
comparisons. STRUCTURAL_REFUSALS and MIN_COMPARED below close that hole.
"""

import itertools
import os
import sqlite3
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from fts5_query import Fts5QueryError, translate  # noqa: E402

# Every ASCII printable, plus the non-ASCII classes a real transcript carries:
# accented Latin, Greek, Cyrillic, CJK, Hangul, non-Latin digits, superscripts,
# dashes, combining marks, emoji — and the connector punctuation behind defect 7.
# ⚠ RANGES, not a curated list. A hand-picked sample is exactly what the last
# eight rounds were: the previous version of this file listed 134 characters,
# passed, and missed 10,839 divergences — including the 21 that silently
# emptied every result. Sweep the whole BMP plus SMP-adjacent planes, skipping
# only the surrogate range (not valid standalone code points).
SWEEP = [chr(c) for c in range(0x20, 0xD800)] + [chr(c) for c in range(0xE000, 0x11000)]

# The refusal set is CLOSED and tiny. Only `(` and `)` reach translate() here as
# structure — `translate("kubernetes (")` is an unbalanced-parens refusal, not a
# drop decision — and nothing else in this sweep can refuse, because the combo
# alphabet below holds no paren and no NOT. A refusal outside this set is a
# FAILURE, not a skip: it means translate() stopped answering the question this
# file asks about that token.
STRUCTURAL_REFUSALS = {"(", ")"}

# ⚠ Floor on the number of tokens actually COMPARED against the tokenizer.
# Refused tokens are skipped, so without this floor a regression that made
# translate() refuse EVERYTHING would produce zero mismatches and exit green
# over zero comparisons — the sweep failing to fail, which is the one outcome
# this file's whole premise forbids. Measured: 92,809 compared of 92,811 swept.
# The floor sits just under that: narrowing the sweep is the exact regression
# the eight rounds above are made of, so it must be a deliberate edit HERE
# rather than a silent one upstream.
MIN_COMPARED = 90000


def main():
    db = sqlite3.connect(":memory:")
    # porter here, plain unicode61 in fts5_query.py's probe: deliberate, not
    # drift. The oracle must mirror the REAL index (fts5_harness.py, and
    # recall's own tables); the probe only asks whether a token exists at all,
    # which stemming cannot change.
    db.execute("CREATE VIRTUAL TABLE t USING fts5(b, tokenize='porter unicode61')")

    def fts5_indexes(ch):
        """Does the tokenizer produce a token for a document made only of `ch`?"""
        db.execute("DELETE FROM t")
        db.execute("INSERT INTO t(b) VALUES (?)", (ch,))
        phrase = '"' + ch.replace('"', '""') + '"'
        try:
            return (
                db.execute(
                    "SELECT count(*) FROM t WHERE t MATCH ?", (phrase,)
                ).fetchone()[0]
                > 0
            )
        except sqlite3.OperationalError:
            # A phrase FTS5 will not even parse indexes nothing, by definition.
            return False

    mismatches = []
    refused = []

    def check(tok):
        """Record a mismatch if translate's drop decision disagrees with FTS5."""
        try:
            dropped = translate("kubernetes " + tok) == '"kubernetes"'
        except Fts5QueryError:
            refused.append(tok)
            return
        indexed = fts5_indexes(tok)
        # The invariant, stated forwards: translate() must drop exactly the
        # tokens the tokenizer indexes nothing for. Spelled with `should_drop`
        # because the equivalent `dropped == indexed` reads as agreement and
        # means the opposite.
        should_drop = not indexed
        if dropped != should_drop:
            mismatches.append(
                (repr(tok), "n/a" if len(tok) != 1 else hex(ord(tok)),
                 "dropped" if dropped else "kept",
                 "indexed" if indexed else "not-indexed")
            )

    # ⚠ SINGLE characters are not sufficient. Both defects this pins arrived as
    # multi-character tokens (`...`, `^_^`), and a token can in principle be
    # non-empty under a per-character oracle while the tokenizer still yields
    # nothing for it — the same class, invisible to a single-char sweep. So
    # sweep every 1-3 character combination over the separator/word alphabet
    # that actually produced defects 6 and 7.
    combo_alphabet = list("_.-!^:@~#$%&+=|\\/,;`'?") + ["a", "1", "é", "日", "\u0301", "＿", "﹍"]
    for n in (1, 2, 3):
        for combo in itertools.product(combo_alphabet, repeat=n):
            check("".join(combo))

    for ch in SWEEP:
        # `(` and `)` refuse rather than compare — see STRUCTURAL_REFUSALS,
        # which pins that set so a refusal cannot become a silent skip.
        check(ch)

    swept = len(SWEEP) + sum(len(combo_alphabet) ** n for n in (1, 2, 3))
    compared = swept - len(refused)
    failed = False

    # ⚠ Assert the SWEEP before asserting its result. An empty disagreement list
    # is only evidence when something was actually compared.
    unexpected = sorted(set(refused) - STRUCTURAL_REFUSALS)
    if unexpected:
        print("REFUSED beyond the structural set: %s%s"
              % (", ".join(repr(t) for t in unexpected[:20]),
                 ", ..." if len(unexpected) > 20 else ""))
        print("%d token(s) skipped rather than checked — translate() no longer "
              "answers the drop question for them, so this sweep cannot vouch "
              "for them." % len(unexpected))
        failed = True

    if compared < MIN_COMPARED:
        print("COLLAPSED: only %d token(s) compared against the tokenizer, "
              "floor is %d (%d swept, %d refused). A sweep that compares "
              "nothing agrees about nothing." % (compared, MIN_COMPARED, swept,
                                                 len(refused)))
        failed = True

    if mismatches:
        for m in mismatches[:20]:
            print("MISMATCH %s %s: translate %s it, tokenizer %s it" % m)
        print("%d character(s) where the oracle disagrees" % len(mismatches))
        failed = True

    if failed:
        return 1
    print("ok: oracle agrees with the tokenizer over %d tokens "
          "(%d refused as structure)" % (compared, len(refused)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
