"""redact.py — secret redaction for worklog-record.sh. Stdlib only.

One built-in pass is: base rules, keyword pass, added rules, keyword pass. A
changing pass, a key id run replacement or a tail sweep is one step. Steps
repeat until the text stops changing; text still changing on the 8th step
becomes <redacted:glued-secrets>. redact_texts runs two stages (_rules, then
builtin), each with its own cap, so a body can take more steps than a lone
builtin() call; both stages fail closed.

ONE implementation, imported by every python heredoc in the hook (wl_slice,
wl_entries), so the two sites cannot drift apart. A match
becomes <redacted:NAME>.

Two layers:
  * BUILT-IN rules — named regexes that need no binary and always run.
  * gitleaks — when usable (gitleaks_present), ONE invocation per batch
    (never per string), whose findings' exact `Secret` is replaced. Its
    failure is reported to the caller, never swallowed: the built-ins still
    ran, but the operator should see it. Its ABSENCE is not a failure; the
    caller reports it once per session (the built-in list is narrower than
    gitleaks' rule set). It scans the output of the rules alone; the key id run
    and tail steps then run on its result.

Limits of the built-in layer: once the rules settle, a run of 8 or more token
characters directly after a marker is swept into <redacted:glued-secrets>, so a
glued second token (ghp_ then ghp_) leaves no raw body; two glued AWS key ids
are taken whole by the key id run rule. A tail
shorter than 8 characters directly after a marker stays. A letter, digit or
underscore glued directly in front of a start-guarded token (an uppercase
letter or digit for an AWS key id) hides it from the start guard, because the
guard keeps ordinary identifiers such as npm_config_registry unchanged. The
sweep also removes ordinary text glued directly after a marker, and an
all-uppercase word of 20 or more characters that starts with AKIA or ASIA is
redacted as a key id; that over-redaction is accepted. gitleaks scans the
rules' output, where its generic rule covers some of these and misses others.

These limits are ACCEPTED (owner decision, issue #219:
https://github.com/drewdrewthis/claude-plugins/issues/219). The glued-prefix
limit leaves the WHOLE usable token raw. With gitleaks present it still holds
for some shapes (npm, AWS key id); gitleaks finds others (Shopify). The
differential fuzz (hooks/tests/redact_diff_fuzz.py) compares each change of
this file with the pinned reference.

What the gitleaks layer does (issue #238,
https://github.com/drewdrewthis/claude-plugins/issues/238): gitleaks is called
with --ignore-gitleaks-allow, so it ignores gitleaks allow comments in the
text. In the same single run it also scans 4 copies of the text with one
space in front of punctuation and of every non-ASCII character, so a token that
only gitleaks finds (Pulumi and others) is found when punctuation directly
follows it. Copies are limited by a byte budget (smallest texts first).

Limits that REMAIN: (1) a gitleaks-only token directly followed by "-", "=",
"+" or "_" stays raw. (2) A word character glued in front (limit of issue #219,
above). (3) A token whose own alphabet holds punctuation can be redacted in
part or stay raw; measured on gitleaks 8.30.1 these rules: aws-amazon-bedrock-
api-key-long-lived, azure-ad-client-secret, cloudflare-origin-ca-key,
curl-auth-user, dropbox-short-lived-api-token, flyio-access-token, jwt,
lob-pub-api-key, mapbox-api-token, rubygems-api-token, sidekiq-secret,
telegram-bot-api-token, twitter-bearer-token, vault-service-token,
yandex-access-token (rubygems-api-token and twitter-bearer-token can be
redacted in part). (4) Texts beyond the copy budget (the copy budget,
_COPY_BUDGET, in bytes of original text per batch, smallest texts first) get no copies; for them a gitleaks-only
token before punctuation stays raw. (5) Without gitleaks nothing changes:
gitleaks-only shapes stay raw. (6) gitleaks 8.19.0 and older cannot run the stdin
call, so the scan fails on every system and the row is stored unjudged
(gitleaks-failed). The minimum version is 8.19.1 on Linux and 8.22.0 on other
systems. There, an older or unreadable version is not run: the row is stored
unjudged (gitleaks-failed, gitleaks-too-old) and only the built-in rules redact
(https://github.com/drewdrewthis/claude-plugins/issues/245). If a file named "-"
appears or changes during a run, the scan fails and gitleaks-report-file is noted;
the hook removes nothing. (7) The
copies make the one gitleaks run larger (about 0.5 to 0.9 MB more), so a batch that is
close to the gitleaks time limit without them can pass it with them; the row is
then stored unjudged (gitleaks-failed), never unredacted.
The "known limit:" tests pin a sample of these.
Because the two stages above have separate step caps, a body can settle where
the same text as a quote hits the cap; the quote is then dropped or matches
only as the bare glued-secrets marker. No raw text either way.

OVER-REDACTION IS ACCEPTABLE. A worklog row that loses a harmless long token is
a visible, cheap loss; a key in a durable file (and in a model prompt) is not.
"""
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import time

_PEM = re.compile(
    r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?(?:-----END [A-Z ]*PRIVATE KEY-----|\Z)",
    re.S)

# Start guard for short prefixes: not mid-identifier. A JSON escape
# (\n \r \t \b \f or \uXXXX) directly before the prefix still counts as a
# start. Separate alternatives because lookbehinds are fixed-width.
_B = r"(?:(?<![A-Za-z0-9_])|(?<=\\[nrtbf])|(?<=\\u[0-9A-Fa-f]{4}))"

# _RULES_BASE holds the base rules; they and the keyword pass run first,
# unchanged, and _RULES_ADD runs on that output, so the additions can only ADD
# redaction. Never widen or guard a rule in _RULES_BASE — add to _RULES_ADD
# instead. Most specific first: sk-lw/sk-ant must be consumed before the generic
# OpenAI `sk-` shape, which would otherwise swallow them under the wrong name.
_RULES_BASE = [
    ("private-key", _PEM),
    # Loose on purpose: the prefix is distinctive, so anything up to whitespace,
    # a quote or an angle bracket goes. A strict alphabet let a key with one
    # odd character through whole.
    ("sk-lw", re.compile(r"sk-lw-[^\s\"'<>]{8,}")),
    ("sk-ant", re.compile(r"sk-ant-[^\s\"'<>]{8,}")),
    ("openai-key", re.compile(r"sk-(?:proj-)?[A-Za-z0-9_-]{32,}")),
    ("github-pat", re.compile(r"gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,}")),
    ("slack-token", re.compile(r"xox[abposr]-[A-Za-z0-9-]{10,}")),
    ("aws-access-key", re.compile(r"(?<![A-Z0-9])(?:AKIA|ASIA)[A-Z0-9]{16}(?![A-Z0-9])")),
    ("google-api-key", re.compile(r"AIza[0-9A-Za-z_-]{35}")),
    ("stripe-key", re.compile(r"[sr]k_live_[0-9A-Za-z]{16,}")),
]

_RULES_ADD = [
    ("slack-token", re.compile(r"xoxe-[A-Za-z0-9-]{10,}|(?i:xapp-\d-[A-Za-z0-9]+-\d+-[A-Za-z0-9]+)")),
    ("slack-webhook", re.compile(
        r"(?:https?://)?hooks\.slack\.com/(?:services|workflows|triggers)/[A-Za-z0-9+/]{43,}")),
    ("stripe-key", re.compile(_B + r"[sr]k_(?:live|test|prod)_[0-9A-Za-z]{10,}")),
    # Widths are gitleaks 8.30.1's minimums, open-ended so a longer token
    # leaves no raw tail. Rules that start with _B are start-guarded so
    # ordinary identifiers are left alone.
    ("npm-token", re.compile(_B + r"npm_[A-Za-z0-9]{36,}")),
    ("gitlab-pat", re.compile(_B + r"glpat-[\w.-]{20,}")),
    ("huggingface-token", re.compile(_B + r"hf_[A-Za-z]{34,}")),
    ("sendgrid-key", re.compile(_B + r"SG\.[\w-]{22}\.[\w-]{43,}")),
    # Own prefix; the jwt rule needs two eyJ segments, so order is not load-bearing.
    ("1password-token", re.compile(r"ops_eyJ[A-Za-z0-9+/=_-]{250,}")),
    ("jwt", re.compile(r"eyJ[A-Za-z0-9_-]{17,}\.eyJ[A-Za-z0-9_-]{17,}\.[A-Za-z0-9_-]{10,}")),
    ("digitalocean-token", re.compile(_B + r"do[opr]_v1_[a-f0-9]{64,}")),
    ("pypi-token", re.compile(r"pypi-AgEIcHlwaS5vcmc[\w-]{50,}")),
    ("shopify-token", re.compile(_B + r"shp(?:at|ca|pa|ss)_[a-fA-F0-9]{32,}")),
    ("linear-key", re.compile(_B + r"lin_api_[A-Za-z0-9]{40,}")),
    ("vault-token", re.compile(_B + r"hvs\.[\w-]{90,}")),
    ("doppler-token", re.compile(_B + r"dp\.pt\.[A-Za-z0-9]{43,}")),
    ("atlassian-token", re.compile(r"ATATT3[A-Za-z0-9_\-=]{186,}")),
    ("grafana-token", re.compile(
        _B + r"glsa_[A-Za-z0-9]{32}_[A-Fa-f0-9]{8,}|" + _B + r"glc_[A-Za-z0-9+/]{32,}={0,2}")),
]

# Open-ended twin of the base aws rule: no end guard, so a longer run (two glued
# ids, an id plus extra characters) is redacted whole. It is not in _RULES_ADD:
# it runs only on settled text (see _step), so a token rule that is still
# blocked cannot lose part of its body to it. Exception: a token blocked by a
# glued key id run does not keep its named marker; the tail sweep takes its pieces.
_AWS_RUN = re.compile(r"(?<![A-Z0-9])(?:AKIA|ASIA)[A-Z0-9]{16,}")

# Characters a secret value can hold; shared by the keyword rule and tail sweep.
_VALUE = r"[\w+/=.~\-]"

# A keyword plus a separator plus a 16+ char value. The whole match is replaced,
# keyword included: dropping the keyword also removes the context gitleaks'
# generic rules key on. `auth` is not a keyword: it would match prose like
# `auth /usr/local/x/y.py`. At least one
# separator is required so "authentication..." or "tokenizer..." identifiers do not match.
# The value class excludes ':' and '>' so a value never swallows a marker.
_GENERIC = re.compile(
    r"(?:api[ _-]?key|apikey|token|secret|passw(?:or)?d|bearer)\W{1,4}"
    + _VALUE + r"{16,}", re.I)

# The keyword rule runs only on the text BETWEEN markers: a marker name can end
# in a keyword (<redacted:slack-token>), and `token> word` must not count as
# keyword + separator + value. Narrowing the separator instead would let
# `<token>VALUE</token>` through.
_MARKER = re.compile(r"(<redacted:[^<>\s]*>)")


def _generic(s):
    """Apply the keyword rule to the text between <redacted:...> markers."""
    # split() with one capture group: odd indexes are the markers themselves.
    parts = _MARKER.split(s)
    return "".join(
        p if i % 2 else _GENERIC.sub("<redacted:generic-secret>", p)
        for i, p in enumerate(parts))


# A glued token can need its neighbour to be a marker before it matches, so a
# long chain needs one step per link and an uncapped loop is quadratic. Each
# changing pass, key id run replacement or tail sweep is one step; text still
# changing on the 8th step becomes <redacted:glued-secrets>. redact_texts runs
# two stages (_rules, then builtin), each with its own cap, so a body can take
# more steps than a lone builtin() call; both stages fail closed.
_MAX_PASSES = 8
_GLUED = "<redacted:glued-secrets>"


def _pass(s):
    """One built-in pass: base, keyword, added, keyword rules."""
    # The added rules run last, on the base output, so they never split a
    # keyword-glued run before the keyword rule has seen it. The keyword pass
    # runs again to catch keyword context that only appears after an added rule.
    for name, rx in _RULES_BASE:
        s = rx.sub("<redacted:%s>" % name, s)
    s = _generic(s)
    for name, rx in _RULES_ADD:
        s = rx.sub("<redacted:%s>" % name, s)
    return _generic(s)


# A token glued after a marker can lose its prefix to the first body, so no rule
# matches it. Once the rules settle, 8+ token characters straight after a marker
# are such a leftover. `<` is not in the class, so marker-marker is left alone.
# Needs the capture group in _MARKER: the sweep keeps the marker as \1.
_TAIL = re.compile(_MARKER.pattern + _VALUE + r"{8,}")


def _sweep(s):
    """Replace 8+ value characters glued directly after a marker."""
    return _TAIL.sub(r"\1" + _GLUED, s)


def _aws_runs(s):
    """Replace long AKIA/ASIA runs in the text between markers."""
    parts = _MARKER.split(s)
    return "".join(
        p if i % 2 else _AWS_RUN.sub("<redacted:aws-access-key>", p)
        for i, p in enumerate(parts))


def _step(s):
    """One step: the rules; once they settle, long key id runs, then tails."""
    out = _pass(s)
    if out != s:
        return out
    # Only on settled text, so every token rule takes its token first and
    # chains keep their named markers (except a token blocked by a glued key id
    # run: the tail sweep takes its pieces).
    out = _aws_runs(s)
    return out if out != s else _sweep(s)


def builtin(s):
    """Repeat _step until the text is stable; fail closed past _MAX_PASSES."""
    if not s:
        return s
    for _ in range(_MAX_PASSES):
        out = _step(s)
        if out == s:
            return s
        s = out
    # Still changing after the cap, so some token may be raw: one marker for the
    # whole string, never a partly redacted one.
    return _GLUED


def _rules(s):
    """The rules alone, repeated until stable; fail closed past _MAX_PASSES."""
    # gitleaks scans the rules' output only: a run or tail marker would split a
    # value its rules need whole.
    for _ in range(_MAX_PASSES):
        out = _pass(s)
        if out == s:
            return s
        s = out
    return _GLUED


def gitleaks_present():
    """True when a usable (executable, on PATH) gitleaks exists.

    Single definition of "usable", shared by scan() and the caller's absent note.
    """
    return bool(shutil.which("gitleaks"))


# Where gitleaks writes its JSON report. Linux only: /dev/stdout gives the
# report on stdout from 8.19.1 on, but macOS gives no report there (measured
# on 8.21.2 and 8.30.1). Other systems use "-", which is stdout from 8.22.0 on.
# https://github.com/drewdrewthis/claude-plugins/issues/245
_REPORT_PATH = "/dev/stdout" if sys.platform.startswith("linux") else "-"

# First gitleaks version where the report path "-" means stdout. Older versions
# write the raw report to a file named "-" in the working directory.
_MIN_DASH_VERSION = (8, 22, 0)

# Set by scan(); the hook reads them to note gitleaks-too-old (non-Linux gitleaks
# older than _MIN_DASH_VERSION or unreadable, so it was not run) and
# gitleaks-report-file (a "-" file appeared or changed during a run; the hook never removes it).
gitleaks_too_old = False
report_file_left = False


def _report_path_usable():
    """False when the report path is absent or a regular file.

    With a writable /dev that has no stdout entry, gitleaks creates a regular
    file there with the raw secret and prints nothing (measured on 8.21.2 and
    8.30.1). lstat, not stat, so a closed stdout of this process does not trip
    the guard. Known limit: a /dev/stdout that is a symlink to a regular file
    passes this guard (it needs a replaced /dev/stdout).
    """
    try:
        return not stat.S_ISREG(os.lstat(_REPORT_PATH).st_mode)
    except OSError:
        return False


def _dash_entry():
    """(inode, size, mtime) of the "-" entry in the working directory, or None."""
    try:
        st = os.lstat("-")
        return st.st_ino, st.st_size, st.st_mtime_ns
    except OSError:
        return None


def _timeout_secs():
    return int(os.environ.get("WORKLOG_GITLEAKS_TIMEOUT", "15"))


def _gitleaks_version(secs):
    """The (major, minor, patch) of `gitleaks version`, or None when unreadable."""
    try:
        p = subprocess.run(["gitleaks", "version"], capture_output=True, timeout=secs)
        m = re.search(r"(\d+)\.(\d+)\.(\d+)", p.stdout.decode("utf-8", "replace"))
        return tuple(int(g) for g in m.groups()) if p.returncode == 0 and m else None
    except Exception:
        return None


def _run_gitleaks(text, secs=None):
    try:
        secs = _timeout_secs() if secs is None else secs
        p = subprocess.run(
            ["gitleaks", "stdin", "--no-banner", "--exit-code", "0",
             "--report-format", "json", "--report-path", _REPORT_PATH, "--log-level", "error",
             "--ignore-gitleaks-allow"],
            input=text.encode("utf-8", "replace"), capture_output=True, timeout=secs)
        if p.returncode != 0:
            return [], True
        # gitleaks 8.22.0 prints nothing on a clean scan, so empty stdout is not a failure.
        found = json.loads(p.stdout.decode("utf-8", "replace") or "[]")
        out = [(f["Secret"], f.get("RuleID") or "gitleaks") for f in found
               if isinstance(f, dict) and isinstance(f.get("Secret"), str)
               # Shorter secrets are noise: replacing a 3-5 char string
               # would mangle unrelated text on every occurrence.
               and len(f["Secret"]) >= 6]
        return out, False
    except Exception:
        return [], True


def scan(text):
    """One gitleaks run over `text`. Returns (findings, failed).

    findings is [(secret, rule_id)]. Absent gitleaks is (not failed): nothing
    was attempted; the caller reports absence via gitleaks_present().
    """
    global gitleaks_too_old, report_file_left
    if not gitleaks_present() or not text.strip():
        return [], False
    if _REPORT_PATH != "-":
        if not _report_path_usable():
            return [], True
        return _run_gitleaks(text)
    # The version is read first: gitleaks older than 8.22.0 writes its raw report
    # to a file named "-", and removing that file afterwards races with a second
    # hook run in the same directory (issue #245,
    # https://github.com/drewdrewthis/claude-plugins/issues/245). The hook removes nothing.
    # The claim TTL in worklog-record.sh counts one WORKLOG_GITLEAKS_TIMEOUT per
    # batch, so the version read and the scan share that one budget.
    try:
        secs = _timeout_secs()
    except ValueError:
        # A timeout that is not a number fails the scan, as it does on Linux.
        return [], True
    start = time.monotonic()
    version = _gitleaks_version(secs)
    if version is None or version < _MIN_DASH_VERSION:
        gitleaks_too_old = True
        return [], True
    remaining = secs - (time.monotonic() - start)
    if remaining <= 0:
        return [], True
    before = _dash_entry()
    result = _run_gitleaks(text, remaining)
    if _dash_entry() != before:
        # The version was misread: a report file is new or was rewritten, so stdout
        # holds no findings. An old gitleaks also rewrites a "-" that was there before.
        # Nothing is removed. An unchanged "-" that was already there stays ignored.
        report_file_left = True
        return [], True
    return result


_MARK = "<redacted:"


def truncate(s, n):
    """s[:n], but never leave a partial <redacted:...> marker at the cut."""
    c = s[:n]
    if len(s) <= n:
        return c
    i = c.rfind(_MARK)
    if i >= 0 and ">" not in c[i:]:
        return c[:i]
    for k in range(len(_MARK) - 1, 0, -1):
        if c.endswith(_MARK[:k]):
            return c[:-k]
    return c


def apply(s, findings):
    """Replace each finding's exact Secret, longest first."""
    for secret, rule in sorted(findings, key=lambda f: -len(f[0])):
        s = s.replace(secret, "<redacted:%s>" % rule)
    return s


# Byte budget for the spaced copies. It counts the UTF-8 bytes of the ORIGINAL
# texts that get copies. The four spacer patterns match disjoint characters, so
# the copies add 4 to 5 times the bytes of the covered texts (5.0 times when
# every character is punctuation), plus the four separators: about 0.5 MB for
# one text at the budget, up to about 0.9 MB for a batch of very many tiny
# texts, because the joining newlines are not counted. gitleaks time grows with
# input size (measured: a 990,000-byte run of one letter took 7 s alone and 19 s
# with copies, over the 15 s limit, which leaves the row unjudged). Texts that
# do not fit still get the flag, just no copies.
_COPY_BUDGET = 100000

# Scan parts are joined by 12 newlines, one line of 512 "(" characters, 12
# newlines. A gitleaks rule can match across a part boundary (measured with
# gitleaks 8.30.1): a keyword rule bridges a few whitespace characters, the
# kubernetes rule about 200 characters of any kind, some rules any run of
# whitespace, and the curl rules any text on up to 5 following lines. The line
# of 512 non-space characters stops the whitespace and bounded gaps; 12 newlines
# on each side are more line breaks than the curl rules cross.
_SEPARATOR = "\n" * 12 + "(" * 512 + "\n" * 12

# Where each spaced copy gets one space in front of a character. gitleaks rules
# end a token at a terminator; a space in front of the punctuation supplies it.
# One copy with a space in front of all punctuation would split every token that
# holds ".", "/", ":" or "-" itself (the Pulumi prefix has "-"), so "." "/" and
# ":" each get their own copy and the first copy leaves them alone.
# re.ASCII makes every non-ASCII character (no-break space, curly quote, and
# letters too) match the first pattern. "-", "=", "+", "_" are left out on
# purpose: a space there would split tokens whose alphabet holds them
# (accepted limit).
_SPACERS = [re.compile(p, re.ASCII) for p in (
    r"(?=[^\w\s.\-/+=:])",
    r"(?=\.)",
    r"(?=/)",
    r"(?=:)",
)]


def _texts_within_budget(texts):
    """The texts that get spaced copies, in their original order: non-blank
    texts, smallest UTF-8 size first (stable), while the running sum of sizes
    stays at or below _COPY_BUDGET.
    """
    # A whitespace-only text holds no token.
    sizes = [(len(t.encode("utf-8", "replace")), i)
             for i, t in enumerate(texts) if t.strip()]
    fit, total = set(), 0
    for size, i in sorted(sizes):
        if total + size > _COPY_BUDGET:
            break
        total += size
        fit.add(i)
    return [t for i, t in enumerate(texts) if i in fit]


def _scan_input(texts):
    """The text for the single gitleaks run: the joined texts, then, when any
    text fits the budget, four spaced copies of those texts, parts joined by
    _SEPARATOR. No final newline is added: the end of the input ends a token for gitleaks.
    The copies join only the texts that fit, so two texts with an over-budget
    text between them are neighbours in a copy; a match across them can only
    add redaction.
    """
    joined = "\n".join(texts)
    fit = _texts_within_budget(texts)
    if not fit:
        return joined
    base = "\n".join(fit)
    return _SEPARATOR.join([joined] + [r.sub(" ", base) for r in _SPACERS])


def redact_texts(texts):
    """Rules, ONE gitleaks batch over all, full built-ins. -> (texts, failed)."""
    pre = [_rules(t) for t in texts]
    findings, failed = scan(_scan_input(pre))
    # builtin() adds the key id run and tail steps. The result must be a
    # builtin() fixed point: verified_quote runs builtin() on the model's quote
    # and then needs an exact match in this body. A gitleaks marker with a glued
    # tail would break that match.
    return [builtin(apply(t, findings)) for t in pre], failed
