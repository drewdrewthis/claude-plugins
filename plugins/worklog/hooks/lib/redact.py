"""redact.py — secret redaction for worklog-record.sh. Stdlib only.

ONE implementation, imported by every python heredoc in the hook (wl_slice,
wl_entries, wl_scrub_row), so the three sites cannot drift apart. A match
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
    ("sk-lw", re.compile(r"sk-lw-[A-Za-z0-9_-]{20,}")),
    ("sk-ant", re.compile(r"sk-ant-[A-Za-z0-9_-]{20,}")),
    ("openai-key", re.compile(r"sk-(?:proj-)?[A-Za-z0-9_-]{32,}")),
    ("github-pat", re.compile(r"gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,}")),
    ("slack-token", re.compile(r"xox[abposr]-[A-Za-z0-9-]{10,}")),
    ("aws-access-key", re.compile(r"(?<![A-Z0-9])(?:AKIA|ASIA)[A-Z0-9]{16}(?![A-Z0-9])")),
    ("google-api-key", re.compile(r"AIza[0-9A-Za-z_-]{35}")),
    ("stripe-key", re.compile(r"[sr]k_live_[0-9A-Za-z]{16,}")),
]

# A keyword plus a separator plus a 16+ char value. The whole match is replaced,
# keyword included: the tests pin that shape, and dropping the keyword also
# removes the context gitleaks' generic rules key on. At least one separator is
# required so "authentication..." or "tokenizer..." identifiers do not match.
# The value class excludes ':' and '>' so an existing <redacted:...> marker is
# never re-matched.
_GENERIC = re.compile(
    r"(?:api[ _-]?key|apikey|token|secret|passw(?:or)?d|bearer|auth)\W{1,4}"
    r"[\w+/=.~\-]{16,}", re.I)


def builtin(s):
    """Apply the named rules, then the keyword rule, to one string."""
    if not s:
        return s
    for name, rx in _RULES:
        s = rx.sub("<redacted:%s>" % name, s)
    return _GENERIC.sub("<redacted:generic-secret>", s)


def scan(text):
    """One gitleaks run over `text`. Returns (findings, failed).

    findings is [(secret, rule_id)]. Absent gitleaks is (not failed): nothing
    was attempted, so there is nothing to report.
    """
    if not shutil.which("gitleaks") or not text.strip():
        return [], False
    try:
        secs = int(os.environ.get("WORKLOG_GITLEAKS_TIMEOUT", "30"))
        p = subprocess.run(
            ["gitleaks", "stdin", "--no-banner", "--exit-code", "0",
             "--report-format", "json", "--report-path", "-", "--log-level", "error"],
            input=text.encode("utf-8", "replace"), capture_output=True, timeout=secs)
        if p.returncode != 0:
            return [], True
        found = json.loads(p.stdout.decode("utf-8", "replace") or "[]")
        out = [(f["Secret"], f.get("RuleID") or "gitleaks") for f in found
               if isinstance(f, dict) and isinstance(f.get("Secret"), str)
               and len(f["Secret"]) >= 6]
        return out, False
    except Exception:
        return [], True


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


def _fields(row):
    for key in ("requests", "outcomes", "mistakes"):
        for e in row.get(key) or []:
            if isinstance(e, dict):
                yield e


def _dump(row):
    return json.dumps(row, ensure_ascii=False, separators=(",", ":"))


def scrub_row(row_json):
    """Final gate before the append. -> (row_json, gitleaks_failed).

    The row is scanned SERIALIZED because the juxtaposition of text and quote is
    what supplies gitleaks' keyword context. Findings are redacted inside the
    parsed text/quote fields, never by surgery on the JSON string. If anything
    is still flagged on the rescan, the entries are emptied: a hollow row beats
    a leaking one.
    """
    row = json.loads(row_json)
    for e in _fields(row):
        for k in ("text", "quote"):
            if isinstance(e.get(k), str):
                e[k] = builtin(e[k])
    findings, failed = scan(_dump(row))
    if findings:
        for e in _fields(row):
            for k in ("text", "quote"):
                if isinstance(e.get(k), str):
                    e[k] = apply(e[k], findings)
        again, failed2 = scan(_dump(row))
        failed = failed or failed2
        if again:
            row["requests"], row["outcomes"], row["mistakes"] = [], [], []
    return _dump(row), failed
