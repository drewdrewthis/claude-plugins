# record-rarity.awk — IDF / corpus-stats pre-pass for query-records.sh, the
# PULL/on-demand interface (its former PUSH-side co-consumer,
# hooks/procedure-router.sh, was retired orchard-codex#197). Reads record file
# paths on stdin, counts for each keyword token how many records' `keywords:`
# contain it (document frequency, df / n_t), and emits the per-token IDF plus
# the corpus statistics the BM25-lite scorer in record-match.awk needs.
#
# Invoked with `-f scripts/lib/record-rarity.awk`. Output feeds the `idffile`
# variable of record-match.awk. ONE implementation, two consumers.
#
# ── OUTPUT FORMAT (read by record-match.awk) ───────────────────────────────
# Two record types, distinguished by the first field:
#
#   1. A single META line, ALWAYS emitted first:
#        #META<TAB>N<TAB>avgdl
#      where N = number of records scanned (corpus size) and
#      avgdl = mean number of (distinct, len>=3) keyword tokens per record.
#
#   2. One TOKEN line per distinct keyword token:
#        <token><TAB><df><TAB><idf>
#      where df = n_t = #records whose keywords contain the token, and
#        idf(t) = ln(1 + (N - n_t + 0.5) / (n_t + 0.5))   [BM25 IDF, always > 0]
#
# Fields are TAB-separated. Tokens are lowercase, len>=3, counted once per
# record (term frequency within a keyword list is always 1 — lists are deduped).
#
# The df column lets the matcher reproduce the old binary "rare" rule as a
# document-frequency threshold (df <= K_floor), which is corpus-size-
# independent — a fixed raw-score floor is NOT (it behaves differently in a
# 7-record fixture vs the 477-record live corpus). The idf column drives the
# BM25-lite ranking score.
#
# Inputs (via -v):
#   raremax — retained for backward compat with any caller that still passes it;
#             it does NOT affect output (the matcher now derives the rare/floor
#             gate from the df column via its own K_floor). Ignored if unset.
#
# Stdin: record file paths, one per line.

# PLUGIN ADAPTATION: min_tok must match the value record-match.awk is given, or
# the df/idf table is computed over a different token set than the one scored.
BEGIN { N = 0; total_kw = 0; if (min_tok == "") min_tok = 3 }

{
    path = $0
    if (path == "") next

    infm = 0; kw = ""; first = 1
    while ((getline line < path) > 0) {
        if (first == 1) {
            first = 0
            if (line != "---") { infm = 0 } else { infm = 1; continue }
        }
        if (infm == 1) {
            if (line == "---") { infm = 0; break }
            if (line ~ /^keywords:/) {
                kw = line
                sub(/^keywords:[[:space:]]*/, "", kw)
            }
        }
    }
    close(path)

    # Every readable record counts toward N and avgdl, even one with no
    # keywords (dl = 0) — it is still a corpus document.
    N++
    if (kw == "") next

    gsub(/[][]/, "", kw)
    kwl = tolower(kw)
    nt = split(kwl, arr, /[^a-z0-9]+/)
    # count each DISTINCT token once per record; tally this record's length (dl)
    delete localseen
    dl = 0
    for (i = 1; i <= nt; i++) {
        tk = arr[i]
        if (length(tk) < min_tok) continue
        if (tk in localseen) continue
        localseen[tk] = 1
        doc_count[tk]++
        dl++
    }
    total_kw += dl
}

END {
    avgdl = (N > 0) ? (total_kw / N) : 0
    # META line first so the matcher can read corpus stats before tokens.
    printf "#META\t%d\t%.6f\n", N, avgdl
    for (tk in doc_count) {
        nt = doc_count[tk]
        idf = log(1 + (N - nt + 0.5) / (nt + 0.5))
        printf "%s\t%d\t%.6f\n", tk, nt, idf
    }
}
