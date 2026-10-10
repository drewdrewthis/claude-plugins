#!/usr/bin/env python3
"""Differential fuzz of hooks/lib/redact.py (claude-plugins#218).

A candidate redact lib is compared with a reference lib that this file works
out from git history on every run (see resolve_reference). A text is "worse"
when the candidate leaves more of the planted fake tokens in its output than the
reference does (see leak_spans). Exit 0: no worse text. Exit 1: one or more.
Exit 2: the harness could not run (one stderr line names the cause).

REFERENCE RULE
  (a) No sha is stored anywhere. The live library is hooks/lib/redact.py in the
      working tree. The base is the merge base of HEAD and refs/remotes/origin/main.
  (b) Live library differs from the base (blob): the reference is the base.
  (c) Live library equals the base: the reference is the first parent of the
      newest commit on the first-parent history of the base that changed the
      library blob (a mode-only commit is not a change).
  (d) A PR that makes a text worse on purpose must change the corpus or the
      score in the same PR and give the reason in the PR body. There is no
      flag, no environment variable and no workflow setting that changes or
      skips the reference.

All tokens here are generated fakes: a prefix plus seeded random characters.
No token literal is in this file or in the bats file.

Subcommands: fuzz --mode builtin|gitleaks, case --name NAME, reference, selftest.
Python 3.9-safe, stdlib only. The corpus uses only random.Random(seed) with
random(), randint(), randrange() and choice(), so it is the same on every
Python and OS.
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

LIB_PATH = "plugins/worklog/hooks/lib/redact.py"
ORIGIN_MAIN = "refs/remotes/origin/main"
HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CANDIDATE_DIR = os.path.normpath(os.path.join(HERE, "..", "lib"))
FIXTURE_DIR = os.path.join(HERE, "fixtures", "redact-regress")
# Checked-in bad libs (PR 217 regressions) and their git blob ids. A planned
# edit of a fixture must change the id here, in the open.
FIXTURE_BLOBS = {
    "cb0ab84": "1fb239a6e64ba14a251e6024e2e3fc0ab728cacc",
    "3854dc2": "b2fe72cdd7571765ead3ae5bcd84b7b6510d0935",
    "f1f1f8a": "a749eeeb36f53fc1514118de638d6a147c0651a5",
}


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


_DRAWN = []  # every rs() result since the last clear: the random parts of the token being built


def rs(rng, alphabet, n):
    s = "".join(rng.choice(alphabet) for _ in range(n))
    _DRAWN.append(s)
    return s


class Piece(str):
    """A planted piece. `rnd` holds its seeded random parts (never its fixed prefix/shape text)."""

    def __new__(cls, text, rnd=()):
        self = super().__new__(cls, text)
        self.rnd = tuple(rnd)
        return self


def make_piece(t, draws, a=0, b=None):
    """Piece t[a:b] of a built token; `draws` are the rs() results used to build t, in order."""
    b = len(t) if b is None else b
    rnd, ptr = [], 0
    for d in draws:
        i = t.find(d, ptr)
        if i < 0:
            raise HarnessError("draw not found in token")
        ptr = i + len(d)
        lo, hi = max(i, a), min(i + len(d), b)
        if hi > lo:
            rnd.append(t[lo:hi])
    return Piece(t[a:b], rnd)


def build_token(r, kind):
    """-> (token, its rs() draws)."""
    del _DRAWN[:]
    t = KINDS[kind](r)
    return t, list(_DRAWN)


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
        t, dt = build_token(r, k)
        if r.random() < NEST_P:
            # Token A cut after its prefix, token B inserted, then A's own remainder.
            u, du = build_token(r, r.choice(KIND_NAMES))
            cut = max(min(len(prefix_of(k)) + r.randint(0, 12), len(t) - 1), 4)
            tail = t[cut:cut + r.choice([0, 0, 3, 4, 5, 7, 8, 12])]
            planted.extend(x for x in (make_piece(t, dt, 0, cut), make_piece(u, du),
                                       make_piece(t, dt, cut, cut + len(tail))) if x)
            parts.append(t[:cut] + u + tail)
            continue
        if r.random() < TRUNC_P:
            if r.random() < 0.4:
                cut = min(len(prefix_of(k)) + r.randint(0, 3), len(t) - 1)
            else:
                cut = r.randint(min(6, len(t) - 1), len(t) - 1)
            cut = max(cut, 4)
            planted.append(make_piece(t, dt, 0, cut))
            parts.append(t[:cut])
            continue
        planted.append(make_piece(t, dt))
        parts.append(t)
    if not planted:  # every text plants at least one full token
        t, dt = build_token(r, r.choice(KIND_NAMES))
        planted.append(make_piece(t, dt))
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

    Deterministic: fixed internal seed PAIRS_SEED, no caller seed. The H regressions show here.
    """
    r = random.Random(PAIRS_SEED)
    kinds = [k for k in KIND_NAMES if k != "pem"]
    full = []
    for k in kinds:
        t, dt = build_token(r, k)
        full.append(make_piece(t, dt))
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
# A well-formed marker whose name shares MARKER_RUN+ consecutive chars with a
# RANDOM part of a planted piece is kept too, so a candidate cannot hide a piece
# by naming a marker after it. Only the seeded random parts count, never a
# piece's fixed prefix/shape text (`hooks.slack.com` vs a `slack-token` marker):
# marker names must not change the score, and the candidate and the reference
# may name the same text differently. 6 random chars landing in a short marker
# name by chance is negligible. Accepted limit: a bare-prefix piece, or a random
# part shorter than 6 chars, put into a marker name is not seen.
MARKER_RE = re.compile(r"<redacted:([a-z0-9-]{1,40})>")
MIN_RUN = 4
MARKER_RUN = 6
SHA_RE = re.compile(r"[0-9a-f]{7,40}")


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

    Markers (unless named after a piece) are blanked to NULs of the same length,
    so the pieces on either side never join and spans index straight into `out`. Per piece the longest common
    run is taken first; claimed chars are not counted twice.
    """
    rnd_grams = {q[i:i + MARKER_RUN] for p in planted for q in getattr(p, "rnd", ())
                 for i in range(len(q) - MARKER_RUN + 1)}

    def blank(m):
        name = m.group(1)
        if any(name[i:i + MARKER_RUN] in rnd_grams for i in range(len(name) - MARKER_RUN + 1)):
            return m.group(0)
        return "\x00" * len(m.group(0))

    res = MARKER_RE.sub(blank, out)
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


def _git(root, *args):
    return subprocess.run(["git", "-C", root] + list(args), capture_output=True)


def lib_at(root, rev):
    """Bytes of the lib at `rev`, or None when that commit has no lib file."""
    p = _git(root, "show", "%s:%s" % (rev, LIB_PATH))
    return p.stdout if p.returncode == 0 else None


def git_blob_id(data):
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def stage(tmp, name, data):
    """Write `data` as <tmp>/<name>/redact.py. -> that dir."""
    d = os.path.join(tmp, name)
    os.makedirs(d)
    with open(os.path.join(d, "redact.py"), "wb") as f:
        f.write(data)
    return d


class Reference(object):
    """The reference lib: its commit, the rule that chose it, and its bytes."""

    def __init__(self, sha, data, changed, last_change=None):
        self.sha, self.data, self.changed, self.last_change = sha, data, changed, last_change

    def line(self):
        if self.changed:
            return "reference=%s rule=merge-base library_changed=True" % self.sha
        return "reference=%s rule=parent-of-last-change library_changed=False last_change=%s" % (
            self.sha, self.last_change)


def resolve_reference(root):
    """-> Reference, by the REFERENCE RULE in the header. Checks run in this fixed order."""
    no_earlier = HarnessError("no earlier version of the lib to use as the reference")
    if _git(root, "rev-parse", "--is-shallow-repository").stdout.strip() == b"true":
        raise HarnessError("shallow clone: run: git fetch --unshallow")
    if _git(root, "rev-parse", "--verify", "-q", ORIGIN_MAIN).returncode != 0:
        raise HarnessError("no %s: run: git fetch origin main" % ORIGIN_MAIN)
    bases = _git(root, "merge-base", "--all", "HEAD", ORIGIN_MAIN).stdout.split()
    if len(bases) != 1:
        raise HarnessError("no single merge base between HEAD and %s" % ORIGIN_MAIN)
    base = bases[0].decode()
    base_lib = lib_at(root, base)
    if base_lib is None:
        raise no_earlier
    # The live lib is always the working-tree file next to this harness.
    with open(os.path.join(DEFAULT_CANDIDATE_DIR, "redact.py"), "rb") as f:
        live = f.read()
    if live != base_lib:
        return Reference(base, base_lib, True)
    # Path-limited rev-list also lists mode-only commits: compare bytes to skip them.
    for c in _git(root, "rev-list", "--first-parent", base, "--", LIB_PATH).stdout.decode().split():
        before = lib_at(root, c + "^")
        if before == lib_at(root, c):
            continue
        if before is None:
            raise no_earlier
        parent = _git(root, "rev-parse", c + "^").stdout.decode().strip()
        return Reference(parent, before, False, c)
    raise no_earlier


def candidate_bytes(args, root):
    """-> (candidate dir or None, its redact.py bytes). A sha or a fixture has no dir yet."""
    if args.candidate_sha:
        data = lib_at(root, args.candidate_sha)
        if data is None:
            raise HarnessError("candidate lib %s not found in this clone; run: git fetch --unshallow"
                               % args.candidate_sha)
        return None, data
    if args.candidate_fixture:
        name = "redact-%s.py.txt" % args.candidate_fixture
        try:
            with open(os.path.join(FIXTURE_DIR, name), "rb") as f:
                data = f.read()
        except OSError:
            raise HarnessError("fixture %s not readable" % name)
        if git_blob_id(data) != FIXTURE_BLOBS[args.candidate_fixture]:
            raise HarnessError("fixture %s: blob id differs from the recorded blob id" % name)
        return None, data
    d = args.candidate_dir or DEFAULT_CANDIDATE_DIR
    try:
        with open(os.path.join(d, "redact.py"), "rb") as f:
            return d, f.read()
    except OSError as e:
        raise HarnessError("candidate error: cannot load lib (%s)" % type(e).__name__)


def load_libs(args, ref, root, tmp):
    """-> (candidate, reference), loaded as two separate modules."""
    cand_dir, data = candidate_bytes(args, root)
    if data == ref.data:
        raise HarnessError("reference is identical to the candidate")
    if cand_dir is None:
        cand_dir = stage(tmp, "candidate", data)
    return load_from_dir("candidate", cand_dir), load_from_dir("reference", stage(tmp, "reference", ref.data))


# ------------------------------------------------------------------- running --

class Session(object):
    """Both libs, the mode, what was measured, and the checked redact call."""

    def __init__(self, mode, cand, ref, present, version):
        self.mode, self.cand, self.ref = mode, cand, ref
        self.gitleaks = mode == "gitleaks"
        self.present, self.version = present, version

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


def hide_gitleaks(tmp):
    """Point PATH at an empty dir so no lib can find gitleaks."""
    empty = os.path.join(tmp, "empty-path")
    os.makedirs(empty)
    os.environ["PATH"] = empty


def gitleaks_version():
    return subprocess.run(["gitleaks", "version"], capture_output=True, text=True).stdout.strip()


def check_libs(mode, cand, ref):
    """Both libs must report the gitleaks state the mode needs. -> measured presence."""
    measured = {}
    for label, lib in (("candidate", cand), ("reference", ref)):
        try:
            measured[label] = bool(lib.gitleaks_present())
        except Exception as e:
            raise HarnessError("%s error: gitleaks_present raised %s" % (label, type(e).__name__))
        if mode == "builtin" and measured[label]:
            raise HarnessError("gitleaks present in builtin mode (%s lib)" % label)
        if mode == "gitleaks" and not measured[label]:
            raise HarnessError("gitleaks not present in gitleaks mode (%s lib)" % label)
    return measured["candidate"]


def start_session(mode, cand, ref, tmp):
    """Set the gitleaks environment for the mode, then check both libs agree with it.

    Called after every git call, because builtin mode removes git from PATH.
    """
    version = None
    if mode == "gitleaks":
        os.environ.setdefault("WORKLOG_GITLEAKS_TIMEOUT", "120")
        version = gitleaks_version()
    else:
        hide_gitleaks(tmp)
    return Session(mode, cand, ref, check_libs(mode, cand, ref), version)


def mode_line(session):
    if session.mode == "builtin":
        return "mode=builtin gitleaks_present=%s" % session.present
    # failed=False is a literal: a failed scan exits 2 before this line prints.
    return "mode=gitleaks gitleaks_present=%s version=%s failed=False" % (
        session.present, session.version)


def worse_items(corpus, cand_out, ref_out):
    """Entries (index, text, planted, candidate output) where the candidate leaks more.

    Equal outputs score equal, so only differing outputs are scored.
    """
    found = []
    for i, (text, planted) in enumerate(corpus):
        if cand_out[i] != ref_out[i] and leak_score(planted, cand_out[i]) > leak_score(planted, ref_out[i]):
            found.append((i, text, planted, cand_out[i]))
    return found


def outputs_differ(cand_out, ref_out):
    """Count of texts whose candidate output string is not the reference output string."""
    return sum(1 for c, r in zip(cand_out, ref_out) if c != r)


def confirm_alone(session, flagged, cap):
    """Re-run the first `cap` flagged texts alone; keep the ones still worse.

    Accepted blind spot: only texts flagged in the batch are re-run alone. A text
    that is worse alone but not in the batch is not seen, because gitleaks
    replaces a found secret in every text of a batch.
    """
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


def run_fuzz(args, session):
    if args.mode == "builtin":
        corpus = random_corpus(args.seed, args.n)
    else:
        corpus = pairs_corpus()
    cand_out, ref_out = session.both([t for t, _ in corpus])
    flagged = worse_items(corpus, cand_out, ref_out)
    lines = [mode_line(session), "corpus_sha256=" + corpus_sha256(corpus)]
    if args.mode == "builtin":
        worse = flagged
    else:
        worse = confirm_alone(session, flagged, args.confirm_cap)
        lines.append("confirm_cap=%d" % args.confirm_cap)
        lines.append("flagged=%d confirmed=%d" % (len(flagged), len(worse)))
        if len(flagged) > args.confirm_cap and not worse:
            raise HarnessError("too many to confirm: %d flagged, none of the first %d worse alone"
                               % (len(flagged), args.confirm_cap))
    lines.append("outputs_differ=%d" % outputs_differ(cand_out, ref_out))
    report(lines, worse)
    return lines, worse


def run_case(args, session):
    recipe, _, seed = CASES[args.name]
    planted, text = recipe(random.Random(seed))
    cand_out, ref_out = session.both([text])
    worse = worse_items([(text, planted)], cand_out, ref_out)
    lines = [mode_line(session), "outputs_differ=%d" % outputs_differ(cand_out, ref_out)]
    report(lines, worse)
    return lines, worse


def selftest():
    """Score hand-made outputs; the marker rule is AC6b."""
    r = random.Random(1)
    body = rs(r, UPDIG, 16)
    piece = Piece("AKIA" + body, [body])
    lbody = rs(r, LO + DIG, 40)
    low = Piece("pul-" + lbody, [lbody])  # lowercase, digits, hyphen: a legal marker name
    hbody = rs(r, B64, 45)
    hook = Piece("https://hooks.slack.com/services/" + hbody, [hbody])
    # (name, planted piece, output, expected score; None = any score of 4 or more)
    checks = [
        ("raw-piece", piece, piece, len(piece)),
        ("valid-marker", piece, "<redacted:aws-access-key>", 0),
        ("uppercase-marker", piece, "<redacted:%s>" % piece, len(piece)),
        ("piece-in-marker-name", low, "<redacted:%s>" % lbody[:30], None),
        ("long-marker", low, "<redacted:%s>" % low[:41], None),
        ("digit-hyphen-marker", piece, "<redacted:a1-b2-c3>", 0),
        ("shape-text-in-marker-name", hook, "<redacted:slack-token>", 0),
    ]
    ok = True
    for name, planted, out, expect in checks:
        score = leak_score([planted], out)
        print("check=%s score=%d" % (name, score))
        ok = ok and (score >= MIN_RUN if expect is None else score == expect)
    return 0 if ok else 1


# ----------------------------------------------------------------------- cli --

def build_parser():
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--candidate-dir", help="dir holding redact.py (default: hooks/lib next to this file)")
    common.add_argument("--candidate-sha", help="use hooks/lib/redact.py from this commit")
    common.add_argument("--candidate-fixture", choices=sorted(FIXTURE_BLOBS),
                        help="use a checked-in bad lib from fixtures/redact-regress")
    common.add_argument("--dump-planted", metavar="FILE", help="write planted pieces of worse texts here")
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    f = sub.add_parser("fuzz", parents=[common])
    f.add_argument("--mode", choices=["builtin", "gitleaks"], required=True)
    # default=None tells "not given" from "given": see check_args.
    f.add_argument("--seed", type=int)
    f.add_argument("--n", type=int)
    f.add_argument("--confirm-cap", type=int)
    c = sub.add_parser("case", parents=[common])
    c.add_argument("--name", choices=sorted(CASES), required=True)
    sub.add_parser("reference", help="print the reference line and exit")
    sub.add_parser("selftest")
    return p


def check_args(args):
    """Reject a bad sha and an option the mode ignores; fill the mode defaults.

    A flag that is silently ignored would let a caller think it took effect.
    The rejected sha is not echoed: only the flag name.
    """
    if args.candidate_sha is not None and not SHA_RE.fullmatch(args.candidate_sha):
        raise HarnessError("bad sha: --candidate-sha")
    if sum(v is not None for v in (args.candidate_dir, args.candidate_sha, args.candidate_fixture)) > 1:
        raise HarnessError("use only one of --candidate-dir, --candidate-sha, --candidate-fixture")
    if args.cmd != "fuzz":
        return
    unused = (("--seed", args.seed), ("--n", args.n)) if args.mode == "gitleaks" \
        else (("--confirm-cap", args.confirm_cap),)
    for flag, value in unused:
        if value is not None:
            raise HarnessError("option not used in this mode: %s" % flag)
    if args.mode == "builtin":
        args.seed = 1 if args.seed is None else args.seed
        args.n = 3000 if args.n is None else args.n
    else:
        args.confirm_cap = 40 if args.confirm_cap is None else args.confirm_cap


def run(args):
    if args.cmd == "selftest":
        return selftest()
    if args.cmd == "reference":
        print(resolve_reference(repo_root()).line())
        return 0
    check_args(args)
    mode = args.mode if args.cmd == "fuzz" else CASES[args.name][1]
    if mode == "gitleaks" and not shutil.which("gitleaks"):
        raise HarnessError("gitleaks not found on PATH (gitleaks mode needs it)")
    with tempfile.TemporaryDirectory() as tmp:
        root = repo_root()
        ref = resolve_reference(root)
        cand, ref_lib = load_libs(args, ref, root, tmp)
        session = start_session(mode, cand, ref_lib, tmp)
        lines, worse = (run_fuzz if args.cmd == "fuzz" else run_case)(args, session)
    if worse and not ref.changed:
        lines.insert(0, "not from this change: the library change %s on main is worse than its parent"
                     % ref.last_change)
    lines.insert(0, ref.line())
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
