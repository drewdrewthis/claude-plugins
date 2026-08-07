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


def main():
    db = sqlite3.connect(":memory:")
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
        if dropped == fts5_indexes(tok):
            mismatches.append(
                (repr(tok), "n/a" if len(tok) != 1 else hex(ord(tok)),
                 "dropped" if dropped else "kept",
                 "indexed" if fts5_indexes(tok) else "not-indexed")
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
        # A LOUD refusal is the documented third outcome and is never this
        # defect class — that class is always silent. `(` and `)` land there
        # correctly: they are structure, not tokens.
        check(ch)

    checked = len(SWEEP) + sum(len(combo_alphabet) ** n for n in (1, 2, 3))
    if mismatches:
        for m in mismatches[:20]:
            print("MISMATCH %s %s: translate %s it, tokenizer %s it" % m)
        print("%d character(s) where the oracle disagrees" % len(mismatches))
        return 1
    print("ok: oracle agrees with the tokenizer over %d tokens "
          "(%d refused as structure)" % (checked - len(refused), len(refused)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
