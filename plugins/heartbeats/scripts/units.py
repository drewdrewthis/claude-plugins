"""Parse heartbeat unit files and render them as one managed crontab block.

Responsibility: a units directory -> the block text, plus locating that block
inside crontab lines. This module never reads, writes, or shells out to a
crontab; `heartbeats.py` owns all of that.

A unit is a markdown file with YAML-ish frontmatter and free prose below it:

    ---
    name: example-daily-report
    cron: 30 6 * * *
    command: /usr/local/bin/example-job --flag
    log: /var/log/example/daily-report.log
    enabled: true
    ---
    Prose here documents the unit for a human or an agent. It is not parsed.

The frontmatter parser is a strict line-oriented reader, not a YAML parser.
The schema is flat scalars only, so a real parser would buy nothing and cost a
third-party dependency this repo does not take. Strictness is the point: every
shape it cannot read is an error naming the file, never a silent default.

Everything here fails CLOSED. A directory with one malformed unit renders
NOTHING -- a partial block installed into a crontab silently deletes the jobs
that failed to parse, which is the one outcome this plugin exists to prevent.

Two validations exist because a field value can otherwise forge crontab
structure, and both cost real jobs when skipped:

  * A line-break character other than a plain newline (U+2028 and friends) is
    invisible in an editor, survives into the rendered block as one line, and
    reads back as TWO -- long enough to forge an END marker, after which the
    block grows without bound and every install duplicates the live jobs.
  * An unescaped `%` in a cron command is not a percent sign. crontab(5) reads
    it as newline-plus-stdin, so a command ending `--at 50%` silently becomes
    `--at 50` with the rest fed to it as input.

Both are REJECTED rather than escaped: rewriting an operator's command line is
a worse surprise than refusing it.

LINE ENDINGS. Unit files are read as bytes and decoded strictly, NOT in text
mode: text mode would translate an interior CR into a newline before the
line-break guard could see it, so a `log:` value with a CR spliced into the
middle of it would smuggle an `enabled: true` the file never declares onto a
line of its own. A CRLF-authored unit still parses, because the trailing CR
goes with the surrounding whitespace when the value is stripped; an interior CR
is rejected. Marker and unit-header recognition
tolerates a trailing CR, so a CRLF crontab's existing block is still found
rather than being mistaken for "no block" and appended to a second time. The
block this module renders is always LF; crontab lines outside it keep their own
bytes, which is `heartbeats.py`'s job to preserve.
"""

import re

# The block is identified in the live crontab by these two exact lines. They are
# the entire contract with `heartbeats.py`'s splicer: anything outside them
# belongs to the user and is never rewritten.
BEGIN_MARKER = "# >>> heartbeats:begin - managed block, do not edit between markers >>>"
END_MARKER = "# <<< heartbeats:end <<<"

# Prefix of the per-unit comment that precedes each rendered cron line. Drift
# detection parses the live region back into units by finding these, so the
# prefix and the name must survive verbatim.
UNIT_PREFIX = "# heartbeats-unit: "
RESTORE_PREFIX = "# heartbeats-restore: "

REQUIRED_FIELDS = ("name", "cron", "command", "log", "enabled")
SUSPENSION_FIELDS = ("suspension_reason", "restore_condition")
KNOWN_FIELDS = REQUIRED_FIELDS + SUSPENSION_FIELDS

# Fields that land verbatim on the rendered crontab line, where crontab(5)'s
# `%` rule applies. `cron` is included: a `%` in the schedule reaches the live
# line exactly like one in the command, and fails only by luck of the parser.
PERCENT_CHECKED_FIELDS = ("cron", "command", "log")

# A name lands inside a crontab comment and is the drift-detection key, so it
# must not contain whitespace or anything that reads as structure.
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")

# Every code point `str.splitlines()` treats as a line break EXCEPT the plain
# newline (which cannot reach a field value -- values are read one line at a
# time). Any of these in a value would render as one line and read back as two.
# Spelled as code points on purpose: as literals they would be invisible in this
# source, which is the exact property that makes them dangerous.
LINE_BREAK_CHARS = frozenset(
    chr(code)
    for code in (0x0B, 0x0C, 0x0D, 0x1C, 0x1D, 0x1E, 0x85, 0x2028, 0x2029)
)

# A `%` not already escaped. Deliberately naive about `\\%`: the remedy printed
# is the same either way, and the operator retypes the field.
UNESCAPED_PERCENT_RE = re.compile(r"(?<!\\)%")

DELIMITER = "---"

# Spelled as a code point for the same reason as LINE_BREAK_CHARS above: a
# literal U+FEFF here would be invisible in this source, and invisibility is
# the whole reason it needs its own diagnostic.
BOM = chr(0xFEFF)

REPAIR_HINT = (
    "repair the crontab by hand (`crontab -e`) so it holds at most one "
    "heartbeats block with both markers, then re-run"
)


class UnitError(Exception):
    """A unit file could not be read as a unit. The message names the file."""


class CrontabError(Exception):
    """The crontab could not be read, written, or trusted.

    Distinct from UnitError because the remedy differs: a UnitError means fix a
    file this plugin owns; a CrontabError means fix (or gain access to) state
    this plugin deliberately does not own.
    """


def without_cr(line):
    """Return `line` with one trailing CR removed, for comparison only.

    Never used to rewrite a line -- a CRLF crontab's bytes outside the managed
    block have to survive an install untouched.
    """
    return line[:-1] if line.endswith("\r") else line


def _split_frontmatter(text, filename):
    lines = text.split("\n")
    if not lines or lines[0].strip() != DELIMITER:
        # A BOM is the one cause of this failure that is invisible in an
        # editor, so name it rather than leaving the author staring at a '---'
        # that looks like it is already the first thing in the file.
        if text.startswith(BOM):
            raise UnitError(
                "%s: file begins with a UTF-8 BOM; remove it -- the "
                "frontmatter '---' must be the very first bytes" % filename
            )
        raise UnitError(
            "%s: frontmatter must start with a '---' line as the very first line"
            % filename
        )
    for index in range(1, len(lines)):
        if lines[index].strip() == DELIMITER:
            return lines[1:index]
    raise UnitError("%s: frontmatter has no closing '---' line" % filename)


def _parse_fields(body_lines, filename):
    fields = {}
    for offset, line in enumerate(body_lines, start=2):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        key, separator, value = line.partition(":")
        if not separator:
            raise UnitError(
                "%s: line %d is not a 'key: value' pair: %r" % (filename, offset, line)
            )
        key = key.strip()
        value = value.strip()
        if key in fields:
            raise UnitError("%s: duplicate field %r" % (filename, key))
        if key not in KNOWN_FIELDS:
            raise UnitError(
                "%s: unknown field %r (known: %s)"
                % (filename, key, ", ".join(KNOWN_FIELDS))
            )
        if not value:
            raise UnitError("%s: field %r has an empty value" % (filename, key))
        for character in value:
            if character in LINE_BREAK_CHARS:
                raise UnitError(
                    "%s: field %r contains line-break character U+%04X, which "
                    "would render as one crontab line and read back as two"
                    % (filename, key, ord(character))
                )
        fields[key] = value
    return fields


def parse_unit(text, filename):
    """Return a validated unit dict, or raise UnitError naming `filename`.

    `cron` is validated only as "5 whitespace-separated fields" -- this module
    does not implement crontab(5)'s schedule grammar. A schedule with the right
    shape but invalid contents (`99 * * * *`) is caught by `crontab -` at write
    time, which rejects the whole payload, so the failure is still closed.
    """
    fields = _parse_fields(_split_frontmatter(text, filename), filename)

    for key in REQUIRED_FIELDS:
        if key not in fields:
            raise UnitError("%s: missing required field %r" % (filename, key))

    if not NAME_RE.match(fields["name"]):
        raise UnitError(
            "%s: field 'name' must match %s, got %r"
            % (filename, NAME_RE.pattern, fields["name"])
        )

    # Checked BEFORE the arity check, and before anything else that could
    # report a different reason for the same value. A schedule starting with
    # '#' passes the arity check happily -- '#30 6 * * *' is five fields -- and
    # then renders a line that crontab(5) reads as a comment. The unit installs
    # "successfully", drift-check reports clean, and the job never fires: an
    # enabled unit that is dead while every audit surface says healthy. The
    # same guard closes the phantom-header shape, where a cron value such as
    # '# heartbeats-unit: phantom a b' renders a line beginning with
    # UNIT_PREFIX and would be attributed to a unit that has no file.
    if fields["cron"].startswith("#"):
        raise UnitError(
            "%s: field 'cron' starts with '#'; crontab(5) reads the whole line "
            "as a comment, so this unit would install as an enabled job that "
            "never runs" % filename
        )

    if len(fields["cron"].split()) != 5:
        raise UnitError(
            "%s: field 'cron' must have exactly 5 whitespace-separated fields, "
            "got %r; @reboot-style nicknames are not supported -- use a 5-field "
            "schedule" % (filename, fields["cron"])
        )

    for key in PERCENT_CHECKED_FIELDS:
        if UNESCAPED_PERCENT_RE.search(fields[key]):
            raise UnitError(
                "%s: field %r contains an unescaped '%%'; cron reads that as "
                "newline-plus-stdin and silently truncates the command -- "
                "escape it as '\\%%'" % (filename, key)
            )

    if fields["enabled"] not in ("true", "false"):
        raise UnitError(
            "%s: field 'enabled' must be exactly 'true' or 'false', got %r"
            % (filename, fields["enabled"])
        )
    enabled = fields["enabled"] == "true"

    if not enabled:
        missing = [key for key in SUSPENSION_FIELDS if key not in fields]
        if missing:
            raise UnitError(
                "%s: 'enabled: false' requires %s; missing %s"
                % (filename, " and ".join(SUSPENSION_FIELDS), ", ".join(missing))
            )

    return {
        "name": fields["name"],
        "cron": fields["cron"],
        "command": fields["command"],
        "log": fields["log"],
        "enabled": enabled,
        "suspension_reason": fields.get("suspension_reason", ""),
        "restore_condition": fields.get("restore_condition", ""),
        "filename": filename,
    }


def load_units(units_dir):
    """Read every `*.md` in `units_dir` as a unit, sorted by name.

    Non-`.md` files are ignored so a README can live beside the units. An empty
    directory is valid and yields no units.
    """
    if not units_dir.is_dir():
        raise UnitError("units directory does not exist: %s" % units_dir)

    try:
        # Listing is a separate failure from reading any one file: a units dir
        # that exists but cannot be listed (permissions, a dead mount) would
        # otherwise escape as a raw PermissionError traceback.
        entries = sorted(units_dir.iterdir())
    except OSError as error:
        raise UnitError("cannot list %s: %s" % (units_dir, error))

    units = []
    seen = {}
    for path in entries:
        if not path.is_file() or path.suffix != ".md":
            continue
        try:
            # Bytes, then a STRICT decode. `read_text` would do two harmful
            # things at once: universal-newline translation turns an interior
            # CR into "\n" before LINE_BREAK_CHARS can see it (which smuggles a
            # field the file never declares onto its own line), and a
            # UnicodeDecodeError is a ValueError, so it would escape the
            # `except OSError` below as a raw traceback instead of an error
            # naming the file.
            text = path.read_bytes().decode("utf-8")
        except (OSError, UnicodeDecodeError) as error:
            raise UnitError("%s: cannot read: %s" % (path.name, error))
        unit = parse_unit(text, path.name)
        if unit["name"] in seen:
            raise UnitError(
                "%s: duplicate unit name %r, already defined by %s"
                % (path.name, unit["name"], seen[unit["name"]])
            )
        seen[unit["name"]] = path.name
        units.append(unit)

    units.sort(key=lambda unit: unit["name"])
    return units


def render_unit_lines(unit):
    """Return the crontab lines for one unit, header comment first.

    A suspended unit renders its cron line COMMENTED rather than omitted: an
    operator reading the crontab has to be able to see that the job exists and
    why it is off, which an absent line cannot tell them.
    """
    job = "%s %s >> %s 2>&1" % (unit["cron"], unit["command"], unit["log"])
    if unit["enabled"]:
        return [UNIT_PREFIX + unit["name"], job]
    return [
        "%s%s [SUSPENDED] %s" % (UNIT_PREFIX, unit["name"], unit["suspension_reason"]),
        RESTORE_PREFIX + unit["restore_condition"],
        "#" + job,
    ]


def render_block(units):
    """Return the full managed block as a list of lines, markers included."""
    lines = [BEGIN_MARKER]
    for unit in units:
        lines.extend(render_unit_lines(unit))
    lines.append(END_MARKER)
    return lines


def split_region(lines):
    """Locate the managed region in crontab `lines`.

    Returns `(before, region, after)` where `region` is the marker lines and
    everything between them. With NO markers at all, returns `(lines, None, [])`
    -- a first install.

    Every other marker arrangement raises CrontabError rather than degrading to
    the first-install answer. Treating an orphan BEGIN as "no block" is what
    makes the next install append a second block, after which the region spans
    orphan-BEGIN to new-END and every user line between them is deleted. A
    second complete block is the same trap read from the other end: it makes
    drift-check report clean while a stale block keeps firing real jobs. Both
    are repaired by a human, never guessed at here.
    """
    begins = [i for i, line in enumerate(lines) if without_cr(line) == BEGIN_MARKER]
    ends = [i for i, line in enumerate(lines) if without_cr(line) == END_MARKER]

    if not begins and not ends:
        return lines, None, []
    if len(begins) > 1:
        raise CrontabError(
            "malformed managed block: %d heartbeats BEGIN markers found (lines %s), "
            "expected at most 1 -- %s"
            % (len(begins), ", ".join(str(i + 1) for i in begins), REPAIR_HINT)
        )
    if len(ends) > 1:
        raise CrontabError(
            "malformed managed block: %d heartbeats END markers found (lines %s), "
            "expected at most 1 -- %s"
            % (len(ends), ", ".join(str(i + 1) for i in ends), REPAIR_HINT)
        )
    if not begins:
        raise CrontabError(
            "malformed managed block: heartbeats END marker at line %d with no "
            "BEGIN marker -- %s" % (ends[0] + 1, REPAIR_HINT)
        )
    if not ends:
        raise CrontabError(
            "malformed managed block: heartbeats BEGIN marker at line %d with no "
            "END marker -- %s" % (begins[0] + 1, REPAIR_HINT)
        )
    if ends[0] < begins[0]:
        raise CrontabError(
            "malformed managed block: heartbeats END marker (line %d) precedes the "
            "BEGIN marker (line %d) -- %s" % (ends[0] + 1, begins[0] + 1, REPAIR_HINT)
        )
    return lines[: begins[0]], lines[begins[0] : ends[0] + 1], lines[ends[0] + 1 :]


def region_units(region):
    """Parse a rendered region into `(attributed, stray, anomalies)`.

    Drift is reported per unit, so the live region has to be attributed back to
    unit names. `attributed` maps name -> its lines; `stray` holds lines that
    could not be attributed; `anomalies` holds human-readable descriptions of
    header shapes that are themselves the drift.

    A nameless header and a repeated name are anomalies, not buckets. Folding a
    repeated name's lines into the first bucket would let two live copies of one
    job compare equal to a single rendered copy.
    """
    attributed = {}
    stray = []
    anomalies = []
    current = None

    for raw in region:
        line = without_cr(raw)
        if line in (BEGIN_MARKER, END_MARKER):
            continue
        if line.startswith(UNIT_PREFIX):
            remainder = line[len(UNIT_PREFIX) :].split()
            name = remainder[0] if remainder else ""
            if not name:
                anomalies.append("a unit header in the block carries no unit name")
                current = None
            elif name in attributed:
                anomalies.append("unit %r has more than one header in the block" % name)
                current = None
            else:
                attributed[name] = []
                current = name
        if current is None:
            stray.append(raw)
        else:
            attributed[current].append(raw)

    return attributed, stray, anomalies
