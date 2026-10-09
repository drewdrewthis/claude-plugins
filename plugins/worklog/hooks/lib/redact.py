"""redact.py — secret redaction for worklog-record.sh. Stdlib only.

ONE implementation, imported by every python heredoc in the hook (wl_slice,
wl_entries), so the two sites cannot drift apart. A match
becomes <redacted:NAME>.

Two layers:
  * BUILT-IN rules — named regexes that need no binary and always run.
  * gitleaks — when on PATH, ONE invocation per batch (never per string), whose
    findings' exact `Secret` is replaced. Its failure is reported to the caller,
    never swallowed: the built-ins still ran, but the operator should see it.

OVER-REDACTION IS ACCEPTABLE. A worklog row that loses a harmless long token is
a visible, cheap loss; a key in a durable file (and in a model prompt) is not.
"""
import json
import os
import re
import shutil
import subprocess

_PEM = re.compile(
    r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?(?:-----END [A-Z ]*PRIVATE KEY-----|\Z)",
    re.S)

# Most specific first: sk-lw/sk-ant must be consumed before the generic OpenAI
# `sk-` shape, which would otherwise swallow them under the wrong name.
_RULES = [
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

# A keyword plus a separator plus a 16+ char value. The whole match is replaced,
# keyword included: dropping the keyword also removes the context gitleaks'
# generic rules key on. `auth` is not a keyword: it would match prose like
# `auth /usr/local/x/y.py`. At least one
# separator is required so "authentication..." or "tokenizer..." identifiers do not match.
# The value class excludes ':' and '>' so a value never swallows a marker.
_GENERIC = re.compile(
    r"(?:api[ _-]?key|apikey|token|secret|passw(?:or)?d|bearer)\W{1,4}"
    r"[\w+/=.~\-]{16,}", re.I)

# The keyword rule runs only on the text BETWEEN markers: a marker name can end
# in a keyword (<redacted:slack-token>), and `token> word` must not count as
# keyword + separator + value. Narrowing the separator instead would let
# `<token>VALUE</token>` through.
_MARKER = re.compile(r"(<redacted:[^<>\s]*>)")


def builtin(s):
    """Apply the named rules, then the keyword rule, to one string."""
    if not s:
        return s
    for name, rx in _RULES:
        s = rx.sub("<redacted:%s>" % name, s)
    # split() with one capture group: odd indexes are the markers themselves.
    parts = _MARKER.split(s)
    return "".join(
        p if i % 2 else _GENERIC.sub("<redacted:generic-secret>", p)
        for i, p in enumerate(parts))


def scan(text):
    """One gitleaks run over `text`. Returns (findings, failed).

    findings is [(secret, rule_id)]. Absent gitleaks is (not failed): nothing
    was attempted, so there is nothing to report.
    """
    if not shutil.which("gitleaks") or not text.strip():
        return [], False
    try:
        secs = int(os.environ.get("WORKLOG_GITLEAKS_TIMEOUT", "15"))
        p = subprocess.run(
            ["gitleaks", "stdin", "--no-banner", "--exit-code", "0",
             "--report-format", "json", "--report-path", "-", "--log-level", "error"],
            input=text.encode("utf-8", "replace"), capture_output=True, timeout=secs)
        if p.returncode != 0:
            return [], True
        found = json.loads(p.stdout.decode("utf-8", "replace") or "[]")
        out = [(f["Secret"], f.get("RuleID") or "gitleaks") for f in found
               if isinstance(f, dict) and isinstance(f.get("Secret"), str)
               # Shorter secrets are noise: replacing a 3-5 char string
               # would mangle unrelated text on every occurrence.
               and len(f["Secret"]) >= 6]
        return out, False
    except Exception:
        return [], True


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


def redact_texts(texts):
    """Built-ins on each string + ONE gitleaks batch over all. -> (texts, failed)."""
    texts = [builtin(t) for t in texts]
    findings, failed = scan("\n".join(texts))
    return [apply(t, findings) for t in texts], failed
