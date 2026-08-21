#!/usr/bin/env python3
"""Sync a directory of heartbeat units into one managed region of a crontab.

Responsibility: everything that touches a crontab. Parsing and rendering units
belongs to `units.py`; this script only compares the rendered block against the
live crontab and, on explicit approval, splices it in.

    render        units dir -> the managed block on stdout
    diff          unified diff, live managed region vs rendered block
    drift-check   exit 0 iff they are identical, else name each drifted unit
    install       replace or append ONLY the managed region

There is no auto-install path. `install` without `--approve` prints what it
would do and exits non-zero having touched nothing -- a crontab is shared
mutable state on a live machine, and a plugin that could rewrite it as a side
effect of a read would be unusable. The splice is not even computed until the
approval gate has been passed.

Only lines between the markers are ever rewritten. Everything else in the
crontab, including a pre-existing crontab with no markers at all, survives the
splice byte for byte, with exactly ONE normalisation: a crontab whose final
line lacks a newline gets one. Line CONTENT is never altered -- reads split on
"\\n" alone and writes join on "\\n" alone, so a CRLF crontab keeps its CR
bytes on every line outside the block. (The block itself is always written LF.)

Failure is never guessed at. A crontab whose markers are unpaired or duplicated
is an error on every operation, not a "no block yet"; and a `crontab -l` that
fails for any reason other than "this user has no crontab" is an error, not an
empty crontab. Both defaults would end in the same place: a crontab containing
the managed block and nothing else.

Exit codes: 0 success; 1 error; 2 approval required; 3 drift detected.

The live crontab is reachable through an injection point so tests never touch a
real one: `--crontab-file PATH` (or `HEARTBEATS_CRONTAB_FILE`) substitutes a
plain file for `crontab -l` / `crontab -`.
"""

import argparse
import difflib
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from units import (  # noqa: E402  (path shim above must run first)
    UNIT_PREFIX,
    CrontabError,
    UnitError,
    load_units,
    region_units,
    render_block,
    split_region,
    without_cr,
)

EXIT_ERROR = 1
EXIT_APPROVAL_REQUIRED = 2
EXIT_DRIFT = 3

# The one `crontab -l` failure that genuinely means "empty". Every other
# non-zero exit -- no permission, cron not installed, transient failure -- is
# reported, because treating it as empty and then installing would drop every
# unmanaged job the user has.
NO_CRONTAB_RE = re.compile(r"no crontab for", re.IGNORECASE)


def resolve_units_dir(argument):
    """Units directory: flag, then env, then the ADR-001 data root default.

    Never a literal path -- the directory is a runtime input, and the default is
    derived from the caller's own home so nothing about one machine's layout is
    baked into this file.
    """
    if argument:
        return Path(argument).expanduser()
    from_env = os.environ.get("HEARTBEATS_UNITS_DIR")
    if from_env:
        return Path(from_env).expanduser()
    codex_root = os.environ.get("CODEX_ROOT")
    root = Path(codex_root).expanduser() if codex_root else Path.home() / ".claude"
    return root / "heartbeats" / "units"


def resolve_crontab_file(argument):
    """Return the file standing in for the real crontab, or None to use cron.

    Flag beats `HEARTBEATS_CRONTAB_FILE`; with neither, the real user crontab is
    read and written through the `crontab` command.
    """
    from_env = os.environ.get("HEARTBEATS_CRONTAB_FILE")
    path = argument or from_env
    return Path(path).expanduser() if path else None


def _to_lines(text):
    """Split crontab text on "\\n" ONLY, dropping the trailing empty element.

    Not `str.splitlines()`. splitlines breaks on a dozen Unicode code points
    that a "\\n"-join does not reproduce, so a value carrying one of them reads
    back as more lines than were written -- enough to forge an END marker. Read
    and write have to agree on exactly what a line is.
    """
    if text == "":
        return []
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return lines


def _decode(raw, source):
    """Decode crontab bytes, refusing rather than mangling invalid UTF-8.

    A lossy decode here would be written straight back out, silently rewriting
    bytes in lines this plugin does not manage.
    """
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise CrontabError(
            "%s is not valid UTF-8 (%s) -- refusing to rewrite it, because "
            "doing so would corrupt the bytes it holds" % (source, error)
        )


def read_crontab(crontab_file):
    """Return the live crontab as a list of lines. No crontab yet -> empty.

    Reads with newline translation OFF. Python's text mode would fold a CRLF
    crontab's line endings to "\\n", and the write side would then hand cron
    back a file whose every unmanaged line had silently lost its CR.

    Raises CrontabError on any failure that is not "this user has no crontab".
    """
    if crontab_file is not None:
        if not crontab_file.exists():
            return []
        try:
            raw = crontab_file.read_bytes()
        except OSError as error:
            raise CrontabError("cannot read %s: %s" % (crontab_file, error))
        return _to_lines(_decode(raw, str(crontab_file)))

    try:
        result = subprocess.run(["crontab", "-l"], capture_output=True, check=False)
    except OSError as error:
        raise CrontabError("cannot run `crontab -l`: %s" % error)

    if result.returncode != 0:
        stderr = result.stderr.decode("utf-8", "replace")
        if result.stdout == b"" and NO_CRONTAB_RE.search(stderr):
            return []
        raise CrontabError(
            "`crontab -l` failed (exit %d): %s -- refusing to treat this as an "
            "empty crontab, because installing over it would delete every "
            "unmanaged job" % (result.returncode, stderr.strip() or "no output")
        )
    return _to_lines(_decode(result.stdout, "`crontab -l` output"))


def write_crontab(crontab_file, lines):
    """Write `lines` back as the whole crontab, joined with "\\n" plus a final one.

    Byte-oriented for the same reason the read is: nothing here may translate a
    line ending the caller did not ask to have translated.
    """
    text = "\n".join(lines) + "\n" if lines else ""
    payload = text.encode("utf-8")
    if crontab_file is not None:
        # Write-then-rename, not write_bytes. write_bytes opens with O_TRUNC,
        # so a failure part way through -- ENOSPC, a kill -- leaves a TRUNCATED
        # crontab: the same data loss this plugin exists to prevent, reached by
        # a different road. os.replace within one directory is atomic, so the
        # target holds either the old bytes or the new ones and never a prefix
        # of either. The `crontab -` branch below needs no equivalent; cron
        # swaps its own spool file atomically.
        try:
            crontab_file.parent.mkdir(parents=True, exist_ok=True)
            descriptor, temp_name = tempfile.mkstemp(
                dir=str(crontab_file.parent), prefix=".heartbeats-", suffix=".tmp"
            )
        except OSError as error:
            raise CrontabError("cannot write %s: %s" % (crontab_file, error))
        try:
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(payload)
            # mkstemp creates 0600; carry the existing file's mode across so a
            # rename is not also a silent permission change.
            if crontab_file.exists():
                os.chmod(temp_name, crontab_file.stat().st_mode & 0o7777)
            os.replace(temp_name, str(crontab_file))
        except OSError as error:
            # The target still holds its original bytes. Drop the partial file.
            try:
                os.unlink(temp_name)
            except OSError:
                pass
            raise CrontabError("cannot write %s: %s" % (crontab_file, error))
        return
    try:
        result = subprocess.run(
            ["crontab", "-"], input=payload, capture_output=True, check=False
        )
    except OSError as error:
        raise CrontabError("cannot run `crontab -`: %s" % error)
    if result.returncode != 0:
        stderr = result.stderr.decode("utf-8", "replace").strip()
        raise CrontabError("`crontab -` failed: %s" % (stderr or "?"))


def unified(live_region, block):
    """Return the unified-diff lines from the live managed region to `block`."""
    return list(
        difflib.unified_diff(
            live_region,
            block,
            fromfile="crontab (managed region)",
            tofile="rendered from units",
            lineterm="",
        )
    )


def emit_diff(live_region, block):
    """Print the diff if there is one. Shared by `diff` and the install dry run."""
    diff = unified(live_region, block)
    if diff:
        print("\n".join(diff))


def drifted_units(live_region, block):
    """Return human-readable drift lines, empty when the two regions agree."""
    if live_region == block:
        return []
    if not live_region:
        return ["DRIFT: managed block is not present in the crontab"]

    live_by_name, live_stray, live_anomalies = region_units(live_region)
    want_by_name, _, _ = region_units(block)

    report = []
    for name in sorted(set(live_by_name) | set(want_by_name)):
        if name not in live_by_name:
            report.append("DRIFT %s: missing from crontab" % name)
        elif name not in want_by_name:
            report.append("DRIFT %s: present in crontab but has no unit file" % name)
        elif live_by_name[name] != want_by_name[name]:
            report.append(
                "DRIFT %s: crontab lines differ from the rendered unit" % name
            )
    for anomaly in live_anomalies:
        report.append("DRIFT: %s" % anomaly)
    if live_stray:
        report.append(
            "DRIFT: %d unattributed line(s) inside the managed block" % len(live_stray)
        )
    if not report:
        # Same units, same lines, different order -- still not what we render.
        report.append("DRIFT: managed block ordering differs from the rendered block")
    return report


def _build_parser():
    parser = argparse.ArgumentParser(
        prog="heartbeats", description=__doc__.split("\n")[0]
    )
    parser.add_argument(
        "operation", choices=("render", "diff", "drift-check", "install")
    )
    parser.add_argument("--units-dir", help="directory of *.md unit files")
    parser.add_argument(
        "--crontab-file",
        help="read/write this file instead of the real crontab (test injection point)",
    )
    parser.add_argument(
        "--approve",
        action="store_true",
        help="required by `install`; without it install is a dry run",
    )
    return parser


def _unit_header_names(lines):
    """Unit names on the per-unit header lines of a rendered region.

    A suspended unit's header carries `[SUSPENDED] <reason>` after the name, so
    only the first whitespace-separated token is the name.
    """
    names = []
    for line in lines:
        bare = without_cr(line)
        if not bare.startswith(UNIT_PREFIX):
            continue
        tokens = bare[len(UNIT_PREFIX) :].split()
        if tokens:
            names.append(tokens[0])
    return names


def _removed_unit_count(live_region, block):
    """How many units the live region names that the new block no longer does."""
    surviving = set(_unit_header_names(block))
    return sum(1 for name in _unit_header_names(live_region) if name not in surviving)


def _run_against_crontab(args, units, block):
    crontab_file = resolve_crontab_file(args.crontab_file)
    live_lines = read_crontab(crontab_file)
    # Raises on unpaired or duplicated markers rather than reporting "no block".
    before, live_region, after = split_region(live_lines)
    region = live_region if live_region is not None else []

    if args.operation == "diff":
        emit_diff(region, block)
        return 0

    if args.operation == "drift-check":
        report = drifted_units(region, block)
        if not report:
            return 0
        print("\n".join(report))
        return EXIT_DRIFT

    if not args.approve:
        print(
            "heartbeats: install requires --approve; nothing was written.",
            file=sys.stderr,
        )
        emit_diff(region, block)
        return EXIT_APPROVAL_REQUIRED

    # Spliced only AFTER the approval gate, so the dry run has no path that can
    # build a new crontab body at all. First install appends with no separator
    # line: every existing line has to come back byte-identical, and an inserted
    # blank is a change to the file the user did not ask for. One expression
    # covers both append and replace: with no live region `split_region`
    # returns an empty `after`, so the two cases are not actually distinct.
    updated = before + block + after

    # Nothing to say means nothing to write. A `crontab -` round trip that
    # reinstalls byte-identical content is still a write: it takes the risk of
    # the write path for no change, and it makes the common case (a scheduled
    # drift repair that finds no drift) indistinguishable in the logs from a
    # real edit.
    if updated == live_lines:
        print("heartbeats: already current, nothing written")
        return 0

    write_crontab(crontab_file, updated)
    # An install that DROPS jobs is the change most worth saying out loud: the
    # crontab shrinks, nothing errors, and "installed 0 unit(s)" on its own
    # reads like a no-op rather than a removal.
    removed = _removed_unit_count(region, block)
    message = "heartbeats: installed %d unit(s)" % len(units)
    if removed:
        message += " (removed %d previously managed)" % removed
    print(message)
    return 0


def main(argv=None):
    args = _build_parser().parse_args(argv)

    try:
        units = load_units(resolve_units_dir(args.units_dir))
    except UnitError as error:
        # Fail closed: no partial block reaches stdout.
        print("heartbeats: %s" % error, file=sys.stderr)
        return EXIT_ERROR

    block = render_block(units)

    if args.operation == "render":
        print("\n".join(block))
        return 0

    try:
        return _run_against_crontab(args, units, block)
    except CrontabError as error:
        print("heartbeats: %s" % error, file=sys.stderr)
        return EXIT_ERROR


if __name__ == "__main__":
    try:
        STATUS = main()
    except BrokenPipeError:
        # `render | head` closes the pipe once it has what it wants. Python
        # flushes stdout again at shutdown, which would raise a second time and
        # print "Exception ignored ..." to stderr, so point the fd at devnull
        # and let the shutdown flush go nowhere.
        os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        # Exit 0, not 141. A reader closing the pipe early is a normal use of a
        # read-only command, not a failure of this one -- and 0/1/2/3 is a
        # vocabulary the skill instructs agents to act on, so a fifth code
        # meaning "your pager quit" would be reported as a real failure.
        STATUS = 0
    sys.exit(STATUS)
