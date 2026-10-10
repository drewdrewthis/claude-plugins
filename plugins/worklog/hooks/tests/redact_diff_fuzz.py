#!/usr/bin/env python3
"""Differential fuzz of hooks/lib/redact.py (claude-plugins#218).

A candidate redact lib is compared with a pinned reference lib. A text is
"worse" when the candidate leaves more of the planted fake tokens in its output
than the reference does (see leak_spans). Exit 0: no worse text. Exit 1: one or
more. Exit 2: the harness could not run (one stderr line names the cause).

PIN RULE
  (a) The reference is one constant, PINNED_SHA below. It is the only place the
      full sha stands outside the release-please CHANGELOG.md files. Do not copy
      it anywhere else.
  (b) Move PINNED_SHA to the new commit after each merged change to redact.py.
  (c) After a move, the named-case runs and the teeth runs in
      redact-diff-fuzz.bats must give the same exit codes as before.
  (d) A PR that makes a text worse on purpose fails this test. That PR must
      change the score or the corpus in the same PR, and give the reason in the
      PR body.

All tokens here are generated fakes: a prefix plus seeded random characters.
No token literal is in this file or in the bats file.

Subcommands: fuzz --mode builtin|gitleaks, case --name NAME, selftest.
Python 3.9-safe, stdlib only. The corpus uses only random.Random(seed) with
random(), randint() and choice(), so it is the same on every Python and OS.
"""
import argparse
import hashlib
import importlib.util
import os
import random
import re
import shutil
import string
import subprocess
import sys
import tempfile

PINNED_SHA = "0da91ef40956fb99b0b78da59d3cb2dfb8e809cf"
LIB_PATH = "plugins/worklog/hooks/lib/redact.py"
HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CANDIDATE_DIR = os.path.normpath(os.path.join(HERE, "..", "lib"))


class HarnessError(Exception):
    """The harness could not run; main() prints the message and exits 2."""


# ---------------------------------------------------------------- generator --

UP = string.ascii_uppercase
LO = string.ascii_lowercase
DIG = string.digits
ALNUM = UP + LO + DIG
UPDIG = UP + DIG
HEX = "0123456789abcdef"
HEXU = "0123456789abcdefABCDEF"
WORD = ALNUM + "_"
B64 = ALNUM + "+/"
URLB64 = ALNUM + "_-"


def rs(rng, alphabet, n):
    return "".join(rng.choice(alphabet) for _ in range(n))


def _jwt(r):
    return "eyJ" + rs(r, URLB64, 20) + ".eyJ" + rs(r, URLB64, 20) + "." + rs(r, URLB64, 16)


def _pem(r):
    # Built in parts so this file never holds a whole key header.
    dash = "-----"
    return (dash + "BEGIN RSA PRIV" + "ATE KEY" + dash + "\n" + rs(r, B64, 40) + "\n"
            + dash + "END RSA PRIV" + "ATE KEY" + dash)


# One builder per rule in redact.py (plus the pulumi shape only gitleaks knows).
KINDS = {
    "pem": _pem,
    "sk-lw": lambda r: "sk-lw-" + rs(r, ALNUM, 24),
    "sk-ant": lambda r: "sk-ant-" + rs(r, URLB64, 40),
    "openai": lambda r: "sk-" + rs(r, ALNUM, 48),
    "openai-proj": lambda r: "sk-proj-" + rs(r, URLB64, 40),
    "ghp": lambda r: "ghp_" + rs(r, ALNUM, 36),
    "gho": lambda r: "gho_" + rs(r, ALNUM, 38),
    "github_pat": lambda r: "github_pat_" + rs(r, WORD, 40),
    "xoxb": lambda r: "xoxb-" + rs(r, ALNUM + "-", 26),
    "akia": lambda r: "AKIA" + rs(r, UPDIG, 16),
    "asia": lambda r: "ASIA" + rs(r, UPDIG, 16),
    "akia-run": lambda r: "AKIA" + rs(r, UPDIG, 22),
    "aiza": lambda r: "AIza" + rs(r, ALNUM + "_-", 35),
    "sk_live": lambda r: "sk_live_" + rs(r, ALNUM, 24),
    "rk_live": lambda r: "rk_live_" + rs(r, ALNUM, 20),
    "sk_test": lambda r: "sk_test_" + rs(r, ALNUM, 22),
    "xoxe": lambda r: "xoxe-" + rs(r, ALNUM + "-", 30),
    "xapp": lambda r: "xapp-1-A" + rs(r, DIG, 8) + "-" + rs(r, DIG, 10) + "-" + rs(r, ALNUM, 24),
    "slack-webhook": lambda r: "https://hooks.slack.com/services/" + rs(r, B64, 45),
    "npm": lambda r: "npm_" + rs(r, ALNUM, 38),
    "glpat": lambda r: "glpat-" + rs(r, WORD + ".-", 24),
    "hf": lambda r: "hf_" + rs(r, UP + LO, 36),
    "sendgrid": lambda r: "SG." + rs(r, WORD + "-", 22) + "." + rs(r, WORD + "-", 45),
    "ops": lambda r: "ops_eyJ" + rs(r, B64 + "=_-", 255),
    "jwt": _jwt,
    "do": lambda r: "dop_v1_" + rs(r, HEX, 64),
    "pypi": lambda r: "pypi-AgEIcHlwaS5vcmc" + rs(r, WORD + "-", 54),
    "shpat": lambda r: "shpat_" + rs(r, HEXU, 32),
    "linear": lambda r: "lin_api_" + rs(r, ALNUM, 42),
    "vault": lambda r: "hvs." + rs(r, WORD + "-", 92),
    "doppler": lambda r: "dp.pt." + rs(r, ALNUM, 44),
    "atlassian": lambda r: "ATATT3" + rs(r, WORD + "-=", 190),
    "grafana-glsa": lambda r: "glsa_" + rs(r, ALNUM, 32) + "_" + rs(r, HEXU, 8),
    "grafana-glc": lambda r: "glc_" + rs(r, B64, 34),
    "pulumi": lambda r: "pul-" + rs(r, HEX, 40),
}
KIND_NAMES = list(KINDS)

# Ordinary text glued between tokens.
FRAGS = [
    lambda r: " ",
    lambda r: "=",
    lambda r: 'key = "',
    lambda r: rs(r, LO, r.randint(3, 10)),
    lambda r: r.choice(["https://example.com/", "/api/v1/", "@github.com/", ".git", "?q="]),
    lambda r: r.choice(LO),
    lambda r: "\n",
    lambda r: '"',
    lambda r: "token: ",
    lambda r: "-",
    lambda r: "_",
    lambda r: rs(r, UP, r.randint(1, 3)),
]

TOKEN_P = 0.6   # a part is a token, not a fragment
NEST_P = 0.15   # a token part holds another token cut into it
TRUNC_P = 0.25  # a token part is a cut log line
_PREFIXES = {}


def prefix_of(kind):
    """Fixed prefix of a kind: common prefix of 6 fake samples, seed-independent."""
    if kind not in _PREFIXES:
        rr = random.Random(987654321)
        _PREFIXES[kind] = os.path.commonprefix([KINDS[kind](rr) for _ in range(6)])
    return _PREFIXES[kind]


def gen_text(r):
    """-> (text, [planted pieces]). 2 to 4 parts glued with no separator.

    Truncated and nested tokens are in the mix on purpose: the PR 217 regressions
    F and G only show on a short-bodied or prefix-only token.
    """
    n = r.randint(2, 4)
    parts, planted = [], []
    for _ in range(n):
        if r.random() >= TOKEN_P:
            parts.append(r.choice(FRAGS)(r))
            continue
        k = r.choice(KIND_NAMES)
        t = KINDS[k](r)
        if r.random() < NEST_P:
            # Token A cut after its prefix, token B inserted, then A's own remainder.
            u = KINDS[r.choice(KIND_NAMES)](r)
            cut = max(min(len(prefix_of(k)) + r.randint(0, 12), len(t) - 1), 4)
            tail = t[cut:cut + r.choice([0, 0, 3, 4, 5, 7, 8, 12])]
            planted.extend(x for x in (t[:cut], u, tail) if x)
            parts.append(t[:cut] + u + tail)
            continue
        if r.random() < TRUNC_P:
            if r.random() < 0.4:
                cut = min(len(prefix_of(k)) + r.randint(0, 3), len(t) - 1)
            else:
                cut = r.randint(min(6, len(t) - 1), len(t) - 1)
            t = t[:max(cut, 4)]
        planted.append(t)
        parts.append(t)
    if not planted:  # every text plants at least one full token
        t = KINDS[r.choice(KIND_NAMES)](r)
        planted.append(t)
        parts[r.randrange(n)] = t
    return "".join(parts), planted


def random_corpus(seed, n):
    r = random.Random(seed)
    return [gen_text(r) for _ in range(n)]


PAIRS_SEED = 11
PAIRS_CONTEXTS = ['key = "', "token: ", ""]
PAIRS_LIMIT = 1000


def pairs_corpus(limit=PAIRS_LIMIT):
    """First `limit` texts of: context + A + B over full tokens, bare prefixes and one word.

    Deterministic and seed-free. The H regressions show here (first hit near text 720).
    """
    r = random.Random(PAIRS_SEED)
    kinds = [k for k in KIND_NAMES if k != "pem"]
    full = [KINDS[k](r) for k in kinds]
    prefixes = sorted({prefix_of(k) for k in kinds})
    parts = full + prefixes + ["abwz"]
    out = []
    for ctx in PAIRS_CONTEXTS:
        for a in parts:
            for b in parts:
                out.append((ctx + a + b, [a, b]))
                if len(out) == limit:
                    return out
    return out


def corpus_sha256(corpus):
    h = hashlib.sha256()
    for text, planted in corpus:
        h.update(text.encode("utf-8") + b"\x00" + b"\x01".join(p.encode("utf-8") for p in planted) + b"\x02")
    return h.hexdigest()


# -------------------------------------------------------------- named cases --

def case_f(r):
    p = "npm_" + rs(r, LO, 20) + "AKIA" + rs(r, UPDIG, 18) + rs(r, LO, 20)
    return [p], p


def case_g1(r):
    a = "shpat_" + rs(r, HEX, 32)
    b = "glpat-" + "AKIA" + rs(r, UPDIG, 22) + "tail"
    return [a, b], a + b


def _g2(r, tail_len):
    a = "shpat_" + rs(r, HEX, 32)
    # The npm body must end in a lowercase letter so the AKIA start guard accepts.
    b = "npm_" + rs(r, ALNUM, 15) + r.choice(LO) + "AKIA" + rs(r, UPDIG, 22) + rs(r, LO, tail_len)
    return [a, b], a + b


def case_g2(r):
    # Exact PR 217 shape: only marker names differ, the leak score is 0.
    return _g2(r, 8)


def case_g2b(r):
    # A 6-char tail is under the sweep width, so it stays raw: the case with teeth.
    return _g2(r, 6)


def case_h1(r):
    tok = "pul-" + "AKIA" + rs(r, UPDIG, 16) + "ASIA" + rs(r, UPDIG, 16) + rs(r, ALNUM, 7)
    return [tok], 'key = "' + tok + '"'


def case_h2(r):
    a = "sk_live_" + rs(r, ALNUM, 19)
    b = "glpat-" + rs(r, LO, 4)
    c = "ASIA" + rs(r, UPDIG, 20)
    return [a, b, c], a + b + c


# name -> (recipe, mode, fixed seed)
CASES = {
    "F": (case_f, "builtin", 1),
    "G1": (case_g1, "builtin", 1),
    "G2": (case_g2, "builtin", 1),
    "G2b": (case_g2b, "builtin", 1),
    "H1": (case_h1, "gitleaks", 1),
    "H2": (case_h2, "gitleaks", 1),
}


# ---------------------------------------------------------------- leak score --

# Only a well-formed marker is cut out. A planted piece inside any other
# `<redacted:...>` shape (an uppercase name, a name over 40 chars) still counts.
MARKER_RE = re.compile(r"<redacted:[a-z0-9-]{1,40}>")
MIN_RUN = 4


def _longest_common(a, b, used):
    """Longest common substring of a and b over unclaimed b chars. -> (len, a_start, b_start)."""
    best, end_a, end_b = 0, 0, 0
    prev = [0] * (len(b) + 1)
    for i in range(1, len(a) + 1):
        cur = [0] * (len(b) + 1)
        for j in range(1, len(b) + 1):
            if a[i - 1] == b[j - 1] and not used[j - 1]:
                cur[j] = prev[j - 1] + 1
                if cur[j] > best:
                    best, end_a, end_b = cur[j], i, j
        prev = cur
    return best, end_a - best, end_b - best


def leak_spans(planted, out):
    """Spans (start, end) of `out` that are surviving runs of 4+ chars of a planted piece.

    Markers are blanked to NULs of the same length, so the pieces on either side
    never join and spans index straight into `out`. Per piece the longest common
    run is taken first; claimed chars are not counted twice.
    """
    res = MARKER_RE.sub(lambda m: "\x00" * len(m.group(0)), out)
    grams = {res[i:i + MIN_RUN] for i in range(len(res) - MIN_RUN + 1)
             if "\x00" not in res[i:i + MIN_RUN]}
    used = [False] * len(res)
    spans = []
    for piece in planted:
        if not any(piece[i:i + MIN_RUN] in grams for i in range(len(piece) - MIN_RUN + 1)):
            continue
        left = piece
        while True:
            n, ia, jb = _longest_common(left, res, used)
            if n < MIN_RUN:
                break
            spans.append((jb, jb + n))
            for k in range(jb, jb + n):
                used[k] = True
            left = left[:ia] + "\x01" * n + left[ia + n:]
    return spans


def leak_score(planted, out):
    return sum(e - s for s, e in leak_spans(planted, out))


def scrub(windows, text):
    """Star the tail of every 8-char window of the planted pieces (`windows`).

    A last guard: a fragment such as a URL can repeat a fixed prefix, and two
    adjacent leaked runs can read as one longer run. Nothing printed may hold
    8 consecutive chars of a planted piece.
    """
    chars = list(text)
    for i in range(len(text) - 7):
        if text[i:i + 8] in windows:
            chars[i + MIN_RUN:i + 8] = "*" * (8 - MIN_RUN)
    return "".join(chars)


def mask_output(planted, out):
    """Keep 4 chars of each leaked run (touching runs merged); star the rest."""
    chars = list(out)
    merged = []
    for s, e in sorted(leak_spans(planted, out)):
        if merged and s <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], e)
        else:
            merged.append([s, e])
    for s, e in merged:
        for k in range(s + MIN_RUN, e):
            chars[k] = "*"
    return "".join(chars)


def mask_input(planted, text):
    """Keep 4 chars of each planted piece (so a fixed prefix is masked too)."""
    for p in sorted(set(planted), key=lambda x: -len(x)):
        text = text.replace(p, p[:MIN_RUN] + "*" * (len(p) - MIN_RUN))
    return text


# --------------------------------------------------------------- lib loading --

def repo_root():
    p = subprocess.run(["git", "-C", HERE, "rev-parse", "--show-toplevel"],
                       capture_output=True, text=True)
    if p.returncode != 0:
        raise HarnessError("not inside a git clone: cannot read lib by sha")
    return p.stdout.strip()


def _load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def load_from_dir(name, directory):
    try:
        return _load_module(name, os.path.join(directory, "redact.py"))
    except Exception as e:
        raise HarnessError("%s error: cannot load lib (%s)" % (name, type(e).__name__))


def load_from_sha(name, sha, tmp, hint):
    p = subprocess.run(["git", "-C", repo_root(), "show", "%s:%s" % (sha, LIB_PATH)],
                       capture_output=True)
    if p.returncode != 0:
        raise HarnessError("%s lib %s not found in this clone; run: %s" % (name, sha, hint))
    d = os.path.join(tmp, name)
    os.makedirs(d)
    with open(os.path.join(d, "redact.py"), "wb") as f:
        f.write(p.stdout)
    return load_from_dir(name, d)


def load_libs(args, tmp):
    """-> (candidate, reference), loaded as two separate modules."""
    ref = load_from_sha("reference", args.reference_sha or PINNED_SHA, tmp, "git fetch --unshallow")
    if args.candidate_sha:
        cand = load_from_sha("candidate", args.candidate_sha, tmp, "git fetch origin refs/pull/217/head")
    else:
        cand = load_from_dir("candidate", args.candidate_dir or DEFAULT_CANDIDATE_DIR)
    return cand, ref


# ------------------------------------------------------------------- running --

class Session(object):
    """Both libs, the mode, and the checked redact call."""

    def __init__(self, mode, cand, ref):
        self.mode, self.cand, self.ref = mode, cand, ref
        self.gitleaks = mode == "gitleaks"

    def redact(self, label, lib, texts):
        try:
            out, failed = lib.redact_texts(list(texts))
        except Exception as e:
            raise HarnessError("%s error: redact_texts raised %s" % (label, type(e).__name__))
        if len(out) != len(texts):
            raise HarnessError("%s output count %d differs from input count %d" % (label, len(out), len(texts)))
        if self.gitleaks and failed:
            raise HarnessError("gitleaks failed in %s run" % label)
        return out

    def both(self, texts):
        return self.redact("candidate", self.cand, texts), self.redact("reference", self.ref, texts)


def start_session(mode, cand, ref, tmp):
    """Set the gitleaks environment for the mode and check both libs agree with it.

    Called after every `git show`, because builtin mode removes git from PATH.
    """
    if mode == "gitleaks":
        os.environ.setdefault("WORKLOG_GITLEAKS_TIMEOUT", "120")
        version = subprocess.run(["gitleaks", "version"], capture_output=True, text=True).stdout.strip()
    else:
        empty = os.path.join(tmp, "empty-path")
        os.makedirs(empty)
        os.environ["PATH"] = empty
        version = None
    for label, lib in (("candidate", cand), ("reference", ref)):
        try:
            present = bool(lib.gitleaks_present())
        except Exception as e:
            raise HarnessError("%s error: gitleaks_present raised %s" % (label, type(e).__name__))
        if present and mode == "builtin":
            raise HarnessError("gitleaks present in builtin mode (%s lib)" % label)
    return Session(mode, cand, ref), version


def mode_line(mode, version):
    if mode == "builtin":
        return "mode=builtin gitleaks_present=False"
    return "mode=gitleaks gitleaks_present=True version=%s failed=False" % version


def worse_items(corpus, cand_out, ref_out):
    """Entries (index, text, planted, candidate output) where the candidate leaks more.

    Equal outputs score equal, so only differing outputs are scored.
    """
    found = []
    for i, (text, planted) in enumerate(corpus):
        if cand_out[i] != ref_out[i] and leak_score(planted, cand_out[i]) > leak_score(planted, ref_out[i]):
            found.append((i, text, planted, cand_out[i]))
    return found


def confirm_alone(session, corpus, flagged, cap):
    """Re-run the first `cap` flagged texts alone; keep the ones still worse."""
    kept = []
    for i, text, planted, _ in flagged[:cap]:
        cand_out, ref_out = session.both([text])
        if leak_score(planted, cand_out[0]) > leak_score(planted, ref_out[0]):
            kept.append((i, text, planted, cand_out[0]))
    return kept


def report(lines, worse):
    lines.append("worse=%d" % len(worse))
    windows = {p[i:i + 8] for _, _, planted, _ in worse for p in planted for i in range(len(p) - 7)}
    for i, text, planted, out in worse:
        lines.append("text %d" % i)
        lines.append(scrub(windows, "  in : %r" % mask_input(planted, text)))
        lines.append(scrub(windows, "  out: %r" % mask_output(planted, out)))


def dump_planted(path, worse):
    """One planted piece per line (a piece with newlines is split). Never stdout."""
    if not path:
        return
    with open(path, "w") as f:
        for _, _, planted, _ in worse:
            for piece in planted:
                for line in piece.split("\n"):
                    f.write(line + "\n")


def run_fuzz(args, session, version):
    if args.mode == "builtin":
        corpus = random_corpus(args.seed, args.n)
    else:
        corpus = pairs_corpus()
    cand_out, ref_out = session.both([t for t, _ in corpus])
    flagged = worse_items(corpus, cand_out, ref_out)
    lines = [mode_line(args.mode, version), "corpus_sha256=" + corpus_sha256(corpus)]
    if args.mode == "builtin":
        worse = flagged
    else:
        worse = confirm_alone(session, corpus, flagged, args.confirm_cap)
        lines.append("flagged=%d confirmed=%d" % (len(flagged), len(worse)))
        if len(flagged) > args.confirm_cap and not worse:
            raise HarnessError("too many to confirm: %d flagged, none of the first %d worse alone"
                               % (len(flagged), args.confirm_cap))
    report(lines, worse)
    return lines, worse


def run_case(args, session, version):
    recipe, mode, seed = CASES[args.name]
    planted, text = recipe(random.Random(seed))
    cand_out, ref_out = session.both([text])
    worse = worse_items([(text, planted)], cand_out, ref_out)
    lines = [mode_line(mode, version)]
    report(lines, worse)
    return lines, worse


def selftest():
    """Score three hand-made outputs; the marker rule is AC6b."""
    piece = "AKIA" + rs(random.Random(1), UPDIG, 16)
    checks = [
        ("raw-piece", piece, len(piece)),
        ("valid-marker", "<redacted:aws-access-key>", 0),
        ("uppercase-marker", "<redacted:%s>" % piece, len(piece)),
    ]
    ok = True
    for name, out, expect in checks:
        score = leak_score([piece], out)
        print("check=%s score=%d" % (name, score))
        ok = ok and score == expect
    return 0 if ok else 1


# ----------------------------------------------------------------------- cli --

def build_parser():
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--candidate-dir", help="dir holding redact.py (default: hooks/lib next to this file)")
    common.add_argument("--candidate-sha", help="use hooks/lib/redact.py from this commit")
    common.add_argument("--reference-sha", help="override the pinned reference (tests only)")
    common.add_argument("--dump-planted", metavar="FILE", help="write planted pieces of worse texts here")
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    f = sub.add_parser("fuzz", parents=[common])
    f.add_argument("--mode", choices=["builtin", "gitleaks"], required=True)
    f.add_argument("--seed", type=int, default=1)
    f.add_argument("--n", type=int, default=3000)
    f.add_argument("--confirm-cap", type=int, default=40)
    c = sub.add_parser("case", parents=[common])
    c.add_argument("--name", choices=sorted(CASES), required=True)
    sub.add_parser("selftest")
    return p


def run(args):
    if args.cmd == "selftest":
        return selftest()
    mode = args.mode if args.cmd == "fuzz" else CASES[args.name][1]
    if mode == "gitleaks" and not shutil.which("gitleaks"):
        raise HarnessError("gitleaks not found on PATH (gitleaks mode needs it)")
    with tempfile.TemporaryDirectory() as tmp:
        cand, ref = load_libs(args, tmp)
        session, version = start_session(mode, cand, ref, tmp)
        lines, worse = (run_fuzz if args.cmd == "fuzz" else run_case)(args, session, version)
    dump_planted(args.dump_planted, worse)
    print("\n".join(lines))
    return 1 if worse else 0


def main(argv):
    try:
        return run(build_parser().parse_args(argv))
    except HarnessError as e:
        print(str(e), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
