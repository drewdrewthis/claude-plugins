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

@test "a dangling operator is dropped at either end" {
  assert_hits "kubernetes AND"     "a c"
  assert_hits "AND kubernetes"     "a c"
  assert_hits "OR kubernetes OR"   "a c"
  assert_hits "kubernetes AND NOT" "a c"
}

@test "a leading NOT is refused, never silently inverted" {
  # FTS5's NOT is binary. Dropping a leading NOT returns the exact complement
  # of what was asked, so refusing loudly is the only honest option.
  run python3 "$HARNESS" "NOT postgres"
  [ "$status" -eq 2 ]
  [[ "$output" == ERROR:* ]]
  [[ "$output" == *"cannot begin with NOT"* ]]
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
  for a in kubernetes kuber\* AND OR NOT NEAR rate-limiter '"x' '(y)' 'z:1' '^q'; do
    for b in kubernetes kuber\* AND OR NOT NEAR rate-limiter '"x' '(y)' 'z:1' '^q'; do
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
