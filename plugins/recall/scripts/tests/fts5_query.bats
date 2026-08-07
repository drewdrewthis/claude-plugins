#!/usr/bin/env bats
# Table-driven tests for scripts/fts5_query.py — the FTS5 query translator.
#
# WHY THIS SHAPE. Four consecutive fix rounds on this translator each shipped a
# NEW defect of the same class: a token combination nobody enumerated, rendered
# into a valid FTS5 expression that matched the wrong documents. Every round's
# test was written against the symptom just reported, so every round passed
# while the next instance shipped.
#
# Two rules follow, and they are the reason the module was extracted:
#
#   1. Assert on WHICH DOCUMENTS COME BACK, never on the rendered string. A
#      polarity inversion produces a perfectly well-formed expression; only the
#      result set distinguishes `a NOT b` from `a AND b`.
#   2. Cover the token set IN COMBINATION, not in isolation. Every shipped
#      defect lived at an adjacency (`AND` then `NOT`), never in a lone token —
#      each token had already been tested by itself and passed.
#
# The fixture corpus is in fts5_harness.py. Doc `c` deliberately holds both
# discriminating terms, so a wrong operator changes the answer rather than
# coincidentally agreeing with the right one.
#
# Run: cd plugins/recall && bats scripts/tests/fts5_query.bats

setup() {
  HARNESS="$BATS_TEST_DIRNAME/fts5_harness.py"
}

# assert_hits <query> <expected-ids>
# Fails with both sides printed, so a red row reads without re-running by hand.
assert_hits() {
  local query="$1" want="$2" got
  got="$(python3 "$HARNESS" "$query")"
  if [ "$got" != "$want" ]; then
    echo "query:    $query" >&2
    echo "expected: $want" >&2
    echo "actual:   $got" >&2
    return 1
  fi
}

# --- the operator each round broke -----------------------------------------

@test "NOT excludes, alone and after every other operator" {
  # THE regression pin. `kubernetes AND NOT postgres` collapsed its operator run
  # to AND and returned doc c — precisely the session the caller asked to
  # exclude. Delete the NOT-wins branch in _collapse_run and this row goes red.
  assert_hits "kubernetes NOT postgres"     "a"
  assert_hits "kubernetes AND NOT postgres" "a"
  assert_hits "kubernetes OR NOT postgres"  "a"
  assert_hits "kubernetes NOT NOT postgres" "a"
}

@test "AND intersects and OR unions" {
  assert_hits "kubernetes AND postgres" "c"
  assert_hits "kubernetes OR postgres"  "a b c"
}

@test "a repeated operator collapses instead of detonating" {
  assert_hits "kubernetes AND AND postgres" "c"
  assert_hits "kubernetes OR OR postgres"   "a b c"
}

@test "a mixed operator run collapses to the narrowest, whatever the order" {
  # The one adjacency the first round of tests missed: two DIFFERENT non-NOT
  # operators next to each other. Taking run[0] made the answer depend on which
  # the caller happened to emit first — `AND OR` gave c, `OR AND` gave a b c,
  # for queries that mean the same thing. Narrowest wins, so both give c.
  assert_hits "kubernetes AND OR postgres" "c"
  assert_hits "kubernetes OR AND postgres" "c"
  assert_hits "kubernetes OR AND NOT postgres" "a"
  assert_hits "kubernetes NOT OR AND postgres" "a"
}

@test "parentheses group instead of being flattened into the expression" {
  # BLOCKING defect, found by review. Quoting a paren the way a hyphen is quoted
  # neutralises a GROUPING token: `"(postgres"` still tokenizes to `postgres`,
  # so the term survives while the grouping evaporates. FTS5 precedence then
  # re-associates `k AND (p OR n)` into `(k AND p) OR n`, which returned doc b —
  # a document containing no term the caller asked for. Valid expression, no
  # exception, wrong answer: exactly the class this module exists to end.
  assert_hits "kubernetes AND (postgres OR notes)" "a c"
  assert_hits "(kubernetes OR postgres) NOT migration" "a b"
  assert_hits "(kubernetes)"                  "a c"
  assert_hits "((kubernetes))"                "a c"
  assert_hits "kubernetes AND (postgres)"     "c"
}

@test "parens are structural wherever they sit, not only at token edges" {
  # Round-five defects, both from peeling parens off each whitespace token
  # instead of lexing the whole string.
  #
  # An interior `)(` was never structure, so the group boundary MOVED: the
  # expression became the phrase `"postgres)(notes"` and doc b vanished.
  assert_hits "(kubernetes OR postgres)(notes)"  "a b c"
  assert_hits "(kubernetes OR postgres) (notes)" "a b c"
  # A `)` followed by ordinary punctuation was hidden, turning a BALANCED query
  # into an unbalanced-parens refusal that blamed the user's parentheses.
  assert_hits "kubernetes AND (postgres OR notes)." "a c"
  assert_hits "notes (kubernetes OR postgres)!"    "a b c"
}

@test "a token with nothing tokenizable in it is dropped, not quoted" {
  # Quoting such a token yields an EMPTY FTS5 phrase, and an empty phrase ANDed
  # against real terms matches nothing — so a trailing period silently emptied
  # the whole result set. Introduced by the whole-string lexer above; this row
  # is what caught it.
  assert_hits "kubernetes ."     "a c"
  assert_hits "kubernetes AND ." "a c"
  assert_hits "..."              "EMPTY"
  assert_hits "- ! ."            "EMPTY"
}

@test "an operator-shaped prefix term is quoted, never emitted as syntax" {
  # `NOT*` matches the prefix-term pattern but is NOT in BINARY_OPS, so it was
  # emitted bare: `"the" AND NOT* AND "pass"`, and FTS5 raised `syntax error
  # near "NOT"` — a raw OperationalError escaping a module that documents only
  # Fts5QueryError. A detonation prints ERROR and exits 3, so a document-set
  # assertion discriminates it from an honest empty result.
  assert_hits "the NOT* pass"  "NONE"
  assert_hits "the AND* pass"  "NONE"
  assert_hits "the OR* pass"   "NONE"
  assert_hits "the NEAR* pass" "NONE"
  # The ordinary prefix term must still survive — the fix must not over-quote.
  assert_hits "kuber*" "a c"
}

@test "a NOT stranded by an empty group is refused, not swallowed" {
  # `() NOT kubernetes` was correctly refused while `NOT () kubernetes` was
  # not: clearing the operator run for the empty group ate the NOT before the
  # guard could see it, and the query silently returned the complement.
  local q
  for q in "NOT () kubernetes" "(NOT) kubernetes" "NOT (()) kubernetes" "() NOT kubernetes"; do
    run python3 "$HARNESS" "$q"
    [ "$status" -eq 2 ] || { echo "not refused: $q -> $output" >&2; return 1; }
    [[ "$output" == *"NOT needs a left operand"* ]] || { echo "wrong error: $q -> $output" >&2; return 1; }
  done
}

@test "unbalanced parentheses are refused, not guessed at" {
  # Guessing where the missing paren goes IS re-association — the defect above
  # wearing a different hat. There is no safe default, so refuse.
  local q
  for q in "kubernetes AND (postgres OR notes" "kubernetes) AND postgres" "((kubernetes)"; do
    run python3 "$HARNESS" "$q"
    [ "$status" -eq 2 ] || { echo "not refused: $q -> $output" >&2; return 1; }
    [[ "$output" == *"unbalanced parentheses"* ]] || { echo "wrong error: $q -> $output" >&2; return 1; }
  done
}

@test "an empty group takes its dangling operator with it" {
  assert_hits "kubernetes AND ()" "a c"
  assert_hits "() OR kubernetes"  "a c"
  assert_hits "()"                "EMPTY"
  # The discriminating shape: an empty group BETWEEN two operators. The
  # operator that would have joined the group must go with it, or it survives
  # to bind the two real operands and silently changes the answer — `AND`
  # instead of `OR` here, which is doc c instead of docs a b c.
  assert_hits "kubernetes AND () OR postgres" "a b c"
}

@test "a leading NOT is refused inside a group too" {
  # Same inversion, one level down. _normalise checks per group, so this is
  # caught rather than silently returning the complement within the group.
  run python3 "$HARNESS" "(NOT postgres) OR kubernetes"
  [ "$status" -eq 2 ]
  [[ "$output" == *"NOT needs a left operand"* ]]
}

@test "a dangling operator is dropped at either end" {
  assert_hits "kubernetes AND"     "a c"
  assert_hits "AND kubernetes"     "a c"
  assert_hits "OR kubernetes OR"   "a c"
  assert_hits "kubernetes AND NOT" "a c"
}

@test "a NOT with no left operand is refused, never silently inverted" {
  # FTS5's NOT is binary. Dropping a leading NOT returns the exact complement
  # of what was asked, so refusing loudly is the only honest option.
  run python3 "$HARNESS" "NOT postgres"
  [ "$status" -eq 2 ]
  [[ "$output" == ERROR:* ]]
  [[ "$output" == *"NOT needs a left operand"* ]]
}

# --- the tokens FTS5 treats as syntax ---------------------------------------

@test "NEAR is dropped rather than searched for as a word" {
  # FTS5 spells proximity NEAR(a b, N). A bare NEAR is not infix; quoting it
  # searched for the literal word and returned 0 hits for `running NEAR`.
  assert_hits "running NEAR"          "e"
  assert_hits "NEAR running"          "e"
  assert_hits "running NEAR the"      "e"
  assert_hits "kubernetes NEAR NOT postgres" "a"
}

@test "a trailing-* prefix term survives translation" {
  assert_hits "kuber*"            "a c"
  assert_hits "kuber* NOT postgres" "a"
  assert_hits "kuber* OR postgr*" "a b c"
}

@test "punctuation is neutralised instead of parsed as syntax" {
  # Each of these is FTS5 syntax that raises rather than mis-answers: a hyphen
  # reads as a column filter, an unpaired quote as an unterminated string.
  assert_hits "rate-limiter"  "d"
  assert_hits '"ship'         "f"
  assert_hits "(finally)"     "f"
  assert_hits "re:launch"     "f"
  assert_hits "^now"          "f"
}

@test "an all-syntax query yields no expression rather than a broken one" {
  assert_hits "NEAR" "EMPTY"
  assert_hits "AND"  "EMPTY"
  assert_hits ""     "EMPTY"
  assert_hits "   "  "EMPTY"
}

@test "no input renders an expression FTS5 rejects" {
  # A blanket sweep over the closed syntax set in adjacent pairs. Distinct from
  # the polarity rows above: this one asserts nothing DETONATES, so a future
  # token added to the translator cannot regress into a syntax error unseen.
  local a b
  local alphabet=(kubernetes 'kuber*' AND OR NOT NEAR rate-limiter '"x' '(y)' 'z:1' '^q' \
                  'NOT*' 'AND*' 'OR*' 'NEAR*' ')(' '(' ')' '.' '-')
  for a in "${alphabet[@]}"; do
    for b in "${alphabet[@]}"; do
      run python3 "$HARNESS" "$a $b"
      [ "$status" -ne 3 ] || {
        echo "FTS5 rejected the expression from: $a $b" >&2
        echo "$output" >&2
        return 1
      }
    done
  done
}

# --- the contract itself -----------------------------------------------------

@test "translate is pure: same input, same output, no side effects" {
  # Pinning purity is what lets every row above be a plain table lookup. If the
  # translator ever reaches for the environment or a database, this goes red.
  run python3 -c "
import sys, os
sys.path.insert(0, '$BATS_TEST_DIRNAME/..')
from fts5_query import translate
before = dict(os.environ)
first = translate('kubernetes AND NOT postgres')
second = translate('kubernetes AND NOT postgres')
assert first == second, (first, second)
assert os.environ == before, 'translate mutated the environment'
assert 'NOT' in first, first
print('ok')"
  [ "$status" -eq 0 ]
  [[ "$output" == *ok* ]]
}

@test "a non-string query is refused, not coerced" {
  run python3 -c "
import sys
sys.path.insert(0, '$BATS_TEST_DIRNAME/..')
from fts5_query import translate, Fts5QueryError
try:
    translate(None)
except Fts5QueryError as e:
    print('refused:', e)
else:
    raise SystemExit('None was accepted')"
  [ "$status" -eq 0 ]
  [[ "$output" == refused:* ]]
}
