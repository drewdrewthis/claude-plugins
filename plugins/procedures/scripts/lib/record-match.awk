# record-match.awk — BM25-lite scorer + ranker + gloss extraction for the
# codex record stores. Invoked with `-f scripts/lib/record-match.awk` by
# scripts/query-records.sh, the PULL/on-demand interface (its former PUSH-side
# co-consumer, hooks/procedure-router.sh, was retired orchard-codex#197).
#
# Design doc: references/research/2038-discovery-matcher-bm25-ranking.md
#
# ── WHAT IT DOES ───────────────────────────────────────────────────────────
# For each candidate record, scores the overlap between its keyword tokens and
# the prompt/query token set with a BM25-lite formula (TF≡1 because keyword
# lists are deduplicated), ranks candidates WITHIN each record `kind` bucket
# best-score-first, applies an absolute document-frequency gate + a relative
# floor + a per-kind cap, and emits `path — gloss` lines.
#
#   score(rec) = Σ_{t ∈ query ∩ keywords(rec)} idf(t) · (k1+1)
#                                               ─────────────────────────────
#                                               k1·(1 − b + b·dl/avgdl) + 1
#
# where dl = #keywords in the record, avgdl = corpus mean (from the META line).
#
# ── INPUTS (all via -v) ────────────────────────────────────────────────────
#   tokfile  — path to a file holding the prompt/query token set, one
#              lowercase token per line (caller tokenizes; tokens already
#              filtered to length>=3 and stopword-stripped if desired).
#   idffile  — path to the output of record-rarity.awk: a #META line
#              (#META<TAB>N<TAB>avgdl) followed by <token><TAB><df><TAB><idf>
#              lines. Supplies per-token IDF (ranking) and df (the gate).
#   limit    — max number of `path — gloss` lines to emit PER KIND, applied to
#              the RANKED order (highest scorers survive the cap).
#              PLUGIN ADAPTATION: owner call — a query returns ALL matches by
#              default; truncation and ranking floors are opt-in knobs,
#              because the scout needs the full match set. Default 0 (0/empty
#              = uncapped, i.e. every ranked survivor is emitted).
#   gate     — 1 (default) = PUSH absolute gate ON: a record fires only when it
#                has >=2 matched tokens OR >=1 matched token with df<=K_floor.
#              0 = PULL gate OFF: any record with >=1 matched token is a
#                candidate (deliberate permissiveness — an explicit single-token
#                query must still return that token's records).
#   k1       — BM25 term-saturation (default 1.2; nearly inert since TF≡1).
#   b        — BM25 length-normalization strength (default 0.5; the real lever).
#   rel_ratio— relative floor: within a kind bucket, drop any candidate scoring
#              < rel_ratio · (bucket top score). Default 0.3.
#   k_floor  — document-frequency threshold for the absolute gate: a single
#              matched token fires alone IFF its df <= k_floor. Default 2
#              (reproduces the old "rare = in <=2 records" rule). Deriving the
#              gate from df (not a raw-score constant) keeps it corpus-size-
#              independent — the crux of the redesign.
#   usagefile— OPTIONAL frequency-prior seam (stub, no behavior yet): path to a
#              future per-procedure usage-count file (`id<TAB>count`). When set
#              and present, score is multiplied by (1 + alpha·ln(1+count)).
#              Defaults to absent/no-op; the log itself is a separate task.
#   alpha    — frequency-prior weight (default 0.1). Inert while usagefile unset.
#
# ── PRECISION / GATE (PUSH) ─────────────────────────────────────────────────
#   A record fires when EITHER
#     (a) it has >=2 distinct matched tokens, OR
#     (b) it has >=1 matched token whose df <= k_floor (corpus-rare).
#   A lone common-token overlap (df > k_floor) does NOT fire (noise suppression).
#
# Stdin: record file paths, one per line.
#
# Output: one `path — gloss` line per surviving record, ranked best-first within
# each kind, capped at `limit` per kind. Gloss = first body heading, else first
# non-empty body line; whitespace collapsed, length-capped, never the body.

BEGIN {
    # ---- defaults ----
    if (limit == "")     limit = 0
    if (gate == "")      gate = 1
    if (k1 == "")        k1 = 1.2
    if (b == "")         b = 0.5
    if (rel_ratio == "") rel_ratio = 0.3
    if (k_floor == "")   k_floor = 2
    if (alpha == "")     alpha = 0.1
    # PLUGIN ADAPTATION: min_tok is settable so the PULL path (query-records.sh)
    # can index 2-char keyword tokens that the PUSH router still ignores as
    # prompt noise. Default 3 keeps every existing caller's behavior identical.
    if (min_tok == "")   min_tok = 3

    # ---- load prompt token set ----
    while ((getline t < tokfile) > 0) {
        if (t != "") ptok[tolower(t)] = 1
    }
    close(tokfile)

    # ---- load IDF / df table + corpus stats from the pre-pass ----
    avgdl = 1
    if (idffile != "") {
        while ((getline ln < idffile) > 0) {
            if (ln == "") continue
            n = split(ln, f, "\t")
            if (f[1] == "#META") {
                # f[2] = N (unused here), f[3] = avgdl
                if (n >= 3 && f[3] + 0 > 0) avgdl = f[3] + 0
                continue
            }
            if (n >= 3) {
                tk = tolower(f[1])
                df[tk] = f[2] + 0
                idf[tk] = f[3] + 0
            }
        }
        close(idffile)
    }
    if (avgdl <= 0) avgdl = 1

    # ---- optional frequency-prior seam (stub: no-op unless usagefile set) ----
    if (usagefile != "") {
        while ((getline ul < usagefile) > 0) {
            if (ul == "") continue
            m = split(ul, uf, "\t")
            if (m >= 2) usage[uf[1]] = uf[2] + 0
        }
        close(usagefile)
    }

    nrec = 0
}

{
    path = $0
    if (path == "") next

    infm = 0; kw = ""; kind = ""; rid = ""; gloss = ""; glossset = 0
    first = 1
    while ((getline line < path) > 0) {
        if (first == 1) {
            first = 0
            if (line != "---") { infm = 0 } else { infm = 1; continue }
        }
        if (infm == 1) {
            if (line == "---") { infm = 0; continue }
            if (line ~ /^keywords:/) {
                kw = line
                sub(/^keywords:[[:space:]]*/, "", kw)
            }
            if (line ~ /^kind:/) {
                kind = line
                sub(/^kind:[[:space:]]*/, "", kind)
                sub(/[[:space:]].*$/, "", kind)
            }
            if (line ~ /^id:/) {
                rid = line
                sub(/^id:[[:space:]]*/, "", rid)
                sub(/[[:space:]].*$/, "", rid)
            }
            continue
        }
        # body: capture gloss = first heading, else first non-empty line
        if (glossset == 0) {
            if (line ~ /^#+[[:space:]]/) {
                g = line; sub(/^#+[[:space:]]*/, "", g); gloss = g; glossset = 1
            } else if (line ~ /[^[:space:]]/ && gloss == "") {
                gloss = line; glossset = 1
            }
        }
    }
    close(path)
    if (kw == "") next

    # tokenize keywords: strip brackets, split on non-alphanumerics, dedupe.
    gsub(/[][]/, "", kw)
    kwl = tolower(kw)
    nt = split(kwl, arr, /[^a-z0-9]+/)

    delete seen
    matched_count = 0
    rare_match = 0
    score = 0
    dl = 0
    for (i = 1; i <= nt; i++) {
        tk = arr[i]
        if (length(tk) < min_tok) continue
        if (tk in seen) continue
        seen[tk] = 1
        dl++                                  # record length = #distinct keywords
        if (!(tk in ptok)) continue
        matched_count++
        # df defaults: a token absent from the IDF table is unseen elsewhere ->
        # treat as df=1 (maximally rare) so it both clears the gate and ranks high.
        tdf = (tk in df) ? df[tk] : 1
        tidf = (tk in idf) ? idf[tk] : log(1 + (1 + 0.5) / (1 + 0.5))
        if (tdf <= k_floor) rare_match = 1
        # BM25-lite contribution (TF=1). Accumulate raw Σ idf here; the shared
        # length-normalization factor is applied once below, after the record's
        # true dl (#distinct keywords) is fully counted.
        score += tidf
    }
    if (matched_count == 0) next

    # absolute gate (PUSH only): >=2 matched OR a rare (df<=k_floor) match.
    if (gate == 1 && matched_count < 2 && rare_match == 0) next

    # Apply the BM25 length-normalization factor once, using the record's true
    # dl (now known). score above is the raw Σ idf; multiply by the shared norm.
    norm = (k1 + 1) / (k1 * (1 - b + b * (dl / avgdl)) + 1)
    score = score * norm

    # frequency-prior seam (no-op unless usagefile supplied a count for this id).
    if (rid != "" && (rid in usage)) {
        score = score * (1 + alpha * log(1 + usage[rid]))
    }

    # neutral gloss: collapse whitespace, cap length, no body dump.
    gsub(/[[:space:]]+/, " ", gloss); sub(/^ /, "", gloss); sub(/ $/, "", gloss)
    if (gloss == "") gloss = "(record)"
    if (length(gloss) > 90) gloss = substr(gloss, 1, 87) "..."

    if (kind == "") kind = "(unknown)"

    # buffer the candidate for per-kind ranking in END.
    nrec++
    r_kind[nrec]  = kind
    r_score[nrec] = score
    r_path[nrec]  = path
    r_gloss[nrec] = gloss
}

END {
    # Rank WITHIN each kind bucket, best-score-first, then emit each bucket's
    # top-`limit`. Buckets are kept separate (Drew's explicit choice) so one
    # kind cannot crowd out the rest. A simple insertion sort over the (small)
    # candidate set keeps this pure-awk and dependency-free.
    #
    # Sort key: score DESC, then path ASC (forward/lexicographic) as a stable,
    # least-surprise tie-break — among equal-scoring records the lexicographically
    # SMALLER path ranks first, matching the prior filesystem-sort intuition.
    # Ranking is driven by score; the path tie-break only orders genuine ties.
    for (a = 1; a <= nrec; a++) {
        ord[a] = a
    }
    for (a = 2; a <= nrec; a++) {
        key = ord[a]
        j = a - 1
        while (j >= 1 && less(ord[j], key)) {
            ord[j + 1] = ord[j]
            j--
        }
        ord[j + 1] = key
    }

    for (a = 1; a <= nrec; a++) {
        idx = ord[a]
        k = r_kind[idx]
        # bucket top score: first time we see the kind in ranked order, this is
        # the max for that kind.
        if (!(k in bucket_top)) bucket_top[k] = r_score[idx]
        # relative floor: drop candidates below rel_ratio * bucket top.
        if (r_score[idx] < rel_ratio * bucket_top[k]) continue
        # per-kind cap on the RANKED order. limit<=0 = uncapped.
        if (limit > 0 && kindcount[k] >= limit) continue
        printf "%s — %s\n", r_path[idx], r_gloss[idx]
        kindcount[k]++
    }
}

# less(x, y): true when candidate x should sort AFTER candidate y (i.e. x is
# "less ranked"). Higher score ranks first; ties broken by path ASC.
function less(x, y) {
    if (r_score[x] < r_score[y]) return 1
    if (r_score[x] > r_score[y]) return 0
    # equal score: path ASC -> the lexicographically SMALLER path ranks first,
    # so x is "less" when its path is lexicographically greater.
    return (r_path[x] > r_path[y])
}
