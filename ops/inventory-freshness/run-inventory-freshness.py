#!/usr/bin/env python3
"""Read-only crew inventory freshness check.

Prints one yellow per problem and exits 0 when it finishes. Files are opened
only for reading, and mtimes come from os.stat. The check does not start
child processes or open network connections.

If Europe/Sofia cannot be loaded, offsets fall back to the EU daylight-saving
rule and one diagnostic is written to stderr.
"""

import argparse
import json
import os
import re
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

DEFAULT_ROUTINES_DIR = "/workspace/.bot-status/routines"
DEFAULT_STATUS_PAGE = "/workspace/bin/status-page-routines.json"
DEFAULT_BRAINS_DIR = "/workspace/.bot-status/brains"
DEFAULT_TEAM_YAML = "/workspace/team/TEAM.yaml"
DEFAULT_BOTS = "joro blondie scout bones marty hunter drill sisyphus"
DEFAULT_STALE_DAYS = "8"

VERSION_RE = re.compile(r"""^version:\s*["']?v?([0-9][0-9A-Za-z.\-]*)""")
MIRROR_RE = re.compile(r"Charter mirror: v(\S+)")
REQUIRED_FIELDS = ("name", "enabled", "folder", "last_run", "status")
STATUSES = {"succeeded", "failed", "never_run", "running"}
HEADER_LINES = 20

_SOFIA_ZONE = None
_SOFIA_READY = False


def eu_sofia_offset(utc):
    """Europe/Sofia offset at an absolute instant, using the EU rule.

    UTC+3 from the last Sunday of March at 01:00 UTC until the last Sunday
    of October at 01:00 UTC, and UTC+2 otherwise. The October fall-back hour
    is two real instants, so both +03:00 and +02:00 can be valid.
    """
    utc = utc.astimezone(timezone.utc)
    year = utc.year
    start = datetime(year, 3, _last_sunday(year, 3), 1, 0, tzinfo=timezone.utc)
    end = datetime(year, 10, _last_sunday(year, 10), 1, 0, tzinfo=timezone.utc)
    if start <= utc < end:
        return timedelta(hours=3)
    return timedelta(hours=2)


def _last_sunday(year, month):
    if month == 12:
        first_next = datetime(year + 1, 1, 1)
    else:
        first_next = datetime(year, month + 1, 1)
    last = first_next - timedelta(days=1)
    return (last - timedelta(days=(last.weekday() - 6) % 7)).day


def load_sofia():
    """Return ZoneInfo('Europe/Sofia'), or None when zone data is unavailable."""
    global _SOFIA_ZONE, _SOFIA_READY
    if _SOFIA_READY:
        return _SOFIA_ZONE
    _SOFIA_READY = True
    try:
        zone = ZoneInfo("Europe/Sofia")
        datetime.now(zone)
    except Exception:
        os.write(2, b"zoneinfo unavailable, using EU DST rule\n")
        _SOFIA_ZONE = None
        return None
    _SOFIA_ZONE = zone
    return zone


def europe_sofia_offset(moment, zone):
    """Offset of Europe/Sofia at the absolute instant `moment`."""
    if zone is not None:
        return moment.astimezone(zone).utcoffset()
    return eu_sofia_offset(moment.astimezone(timezone.utc))


def strip_v(value):
    if value.startswith("v"):
        return value[1:]
    return value


def parse_team_version(text):
    """Return the top-level version with one leading v removed, or None."""
    for line in text.splitlines():
        match = VERSION_RE.match(line)
        if match:
            return strip_v(match.group(1))
    return None


def format_offset(delta):
    total = int(delta.total_seconds())
    sign = "+" if total >= 0 else "-"
    total = abs(total)
    hours, remainder = divmod(total, 3600)
    minutes = remainder // 60
    return f"{sign}{hours:02d}:{minutes:02d}"


def format_sofia_datetime(moment, zone):
    if zone is not None:
        local = moment.astimezone(zone)
    else:
        offset = eu_sofia_offset(moment.astimezone(timezone.utc))
        local = moment.astimezone(timezone.utc).astimezone(timezone(offset))
    return local.isoformat(timespec="seconds")


def format_sofia_timestamp(timestamp, zone):
    if zone is not None:
        local = datetime.fromtimestamp(timestamp, zone)
    else:
        utc = datetime.fromtimestamp(timestamp, timezone.utc)
        offset = eu_sofia_offset(utc)
        local = datetime.fromtimestamp(timestamp, timezone(offset))
    return local.isoformat(timespec="seconds")


def json_kind(value):
    if value is None:
        return "null"
    if type(value) is bool:
        return "bool"
    if type(value) is str:
        return "string"
    if type(value) in (int, float):
        return "number"
    if type(value) is dict:
        return "object"
    if type(value) is list:
        return "array"
    return type(value).__name__


def type_name(value):
    if value is None:
        return "null"
    if type(value) is bool:
        return "bool"
    if type(value) is str:
        return "str"
    if type(value) is int:
        return "int"
    if type(value) is float:
        return "float"
    return type(value).__name__


def quote_name(name):
    escaped = (
        name.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\r", "\\r")
        .replace("\n", "\\n")
    )
    return f'"{escaped}"'


def element_subject(base_label, index, name):
    label = f"{base_label}[{index}]"
    if type(name) is str:
        return f"{label} {quote_name(name)}"
    return label


class Report:
    def __init__(self):
        self.yellows = []

    def add(self, check, subject, owner, detail):
        self.yellows.append(
            {
                "check": check,
                "subject": subject,
                "owner": owner,
                "detail": detail,
                "line": f"YELLOW {check} {subject}: {detail}",
            }
        )


def read_text(path):
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        return handle.read()


def read_header(path, limit=HEADER_LINES):
    lines = []
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for index, line in enumerate(handle):
            if index >= limit:
                break
            lines.append(line)
    return "".join(lines)


def check_last_run(report, base_label, owner, element, index, name, zone):
    if "last_run" not in element:
        return
    last_run = element["last_run"]
    subject = element_subject(base_label, index, name)
    if last_run is None:
        if "status" in element and element["status"] != "never_run":
            status = element["status"]
            shown = f'"{status}"' if type(status) is str else type_name(status)
            report.add(
                "routines.last-run-null",
                subject,
                owner,
                f"last_run is null but status is {shown}",
            )
        return
    if type(last_run) is not str:
        report.add(
            "routines.last-run-format",
            subject,
            owner,
            f"last_run is {type_name(last_run)}, expected an ISO-8601 timestamp with an offset",
        )
        return
    try:
        parsed = datetime.fromisoformat(last_run)
    except ValueError:
        report.add(
            "routines.last-run-format",
            subject,
            owner,
            f'last_run "{last_run}" is not an ISO-8601 timestamp',
        )
        return
    if parsed.utcoffset() is None:
        report.add(
            "routines.last-run-format",
            subject,
            owner,
            f"last_run {last_run} has no offset",
        )
        return
    expected = europe_sofia_offset(parsed, zone)
    if parsed.utcoffset() == expected:
        return
    got = format_offset(parsed.utcoffset())
    want = format_offset(expected)
    cancun = " (Cancun)" if got == "-05:00" else ""
    report.add(
        "routines.last-run-offset",
        subject,
        owner,
        f"last_run {last_run} has offset {got}{cancun}; Europe/Sofia is {want} at that instant",
    )


def check_element(report, base_label, owner, element, index, zone):
    if type(element) is not dict:
        report.add(
            "routines.not-object",
            element_subject(base_label, index, None),
            owner,
            f"element is {json_kind(element)}",
        )
        return
    name = element["name"] if "name" in element and type(element["name"]) is str else None
    for field in REQUIRED_FIELDS:
        if field not in element:
            report.add(
                "routines.missing-field",
                element_subject(base_label, index, name),
                owner,
                f'key "{field}" is absent',
            )
    if "name" in element and type(element["name"]) is not str:
        report.add(
            "routines.type",
            element_subject(base_label, index, name),
            owner,
            f"name is {type_name(element['name'])}, expected str",
        )
    if "enabled" in element and type(element["enabled"]) is not bool:
        report.add(
            "routines.type",
            element_subject(base_label, index, name),
            owner,
            f"enabled is {type_name(element['enabled'])}, expected bool",
        )
    if "folder" in element and type(element["folder"]) is not str:
        report.add(
            "routines.type",
            element_subject(base_label, index, name),
            owner,
            f"folder is {type_name(element['folder'])}, expected str",
        )
    if "status" in element:
        status = element["status"]
        if type(status) is not str or status not in STATUSES:
            subject = element_subject(base_label, index, name)
            if type(status) is str:
                detail = (
                    f'status "{status}" is not one of succeeded, failed, never_run, running'
                )
            else:
                detail = (
                    f"status is {type_name(status)}, expected one of "
                    "succeeded, failed, never_run, running"
                )
            report.add("routines.status", subject, owner, detail)
    check_last_run(report, base_label, owner, element, index, name, zone)


def check_routine_file(report, path, base_label, owner, zone):
    try:
        text = read_text(path)
    except OSError as exc:
        report.add(
            "routines.unreadable",
            base_label,
            owner,
            f"unreadable: {exc.strerror or exc}",
        )
        return
    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        report.add(
            "routines.unreadable",
            base_label,
            owner,
            f"invalid JSON at line {exc.lineno} column {exc.colno}: {exc.msg}",
        )
        return
    if type(data) is not list:
        report.add(
            "routines.not-array",
            base_label,
            owner,
            f"top level is {json_kind(data)}",
        )
        return
    for index, item in enumerate(data):
        check_element(report, base_label, owner, item, index, zone)


def check_routines_dir(report, directory, zone):
    try:
        is_dir = directory.is_dir()
    except OSError:
        is_dir = False
    if not is_dir:
        report.add(
            "routines.missing",
            "routines",
            None,
            "INVENTORY_ROUTINES_DIR is missing",
        )
        return
    try:
        files = sorted(path for path in directory.glob("*.json") if path.is_file())
    except OSError as exc:
        report.add(
            "routines.unreadable",
            "routines",
            None,
            f"unreadable: {exc.strerror or exc}",
        )
        return
    if not files:
        report.add(
            "routines.missing",
            "routines",
            None,
            "INVENTORY_ROUTINES_DIR holds no *.json",
        )
        return
    for path in files:
        filename = path.name
        owner = filename[: -len(".json")] if filename.endswith(".json") else None
        check_routine_file(report, path, f"routines/{filename}", owner, zone)


def check_status_page(report, path, zone):
    try:
        is_file = path.is_file()
    except OSError:
        is_file = False
    if not is_file:
        report.add(
            "routines.missing",
            path.name,
            None,
            f"{path.name} is missing",
        )
        return
    check_routine_file(report, path, path.name, None, zone)


def check_charter(report, path):
    try:
        is_file = path.is_file()
    except OSError:
        is_file = False
    if not is_file:
        report.add(
            "charter.unreadable",
            path.name,
            None,
            f"{path.name} is missing",
        )
        return None
    try:
        text = read_text(path)
    except OSError as exc:
        report.add(
            "charter.unreadable",
            path.name,
            None,
            f"unreadable: {exc.strerror or exc}",
        )
        return None
    version = parse_team_version(text)
    if version is None:
        report.add(
            "charter.unreadable",
            path.name,
            None,
            f"{path.name} has no top-level version",
        )
        return None
    return version


def check_brains(report, directory, bots, stale_days, charter_version, now, zone):
    for bot in bots:
        path = directory / f"{bot}-brain.md"
        subject = f"brains/{bot}-brain.md"
        try:
            is_file = path.is_file()
        except OSError:
            is_file = False
        if not is_file:
            report.add(
                "brains.missing",
                subject,
                bot,
                f"{bot}-brain.md is absent",
            )
            continue
        try:
            header = read_header(path)
        except OSError as exc:
            report.add(
                "brains.no-mirror",
                subject,
                bot,
                f"unreadable: {exc.strerror or exc}",
            )
            header = None
        if header is not None:
            match = MIRROR_RE.search(header)
            if match is None:
                report.add(
                    "brains.no-mirror",
                    subject,
                    bot,
                    "no Charter mirror in the first 20 lines",
                )
            elif charter_version is not None:
                mirror = strip_v(match.group(1))
                if mirror != charter_version:
                    report.add(
                        "brains.charter-mismatch",
                        subject,
                        bot,
                        f"Charter mirror v{mirror}, TEAM.yaml v{charter_version}",
                    )
        try:
            mtime = os.stat(path).st_mtime
        except OSError:
            continue
        age_seconds = now.timestamp() - mtime
        if age_seconds > stale_days * 86400:
            shown = format_sofia_timestamp(mtime, zone)
            days = age_seconds / 86400
            report.add(
                "brains.stale",
                subject,
                bot,
                f"mtime {shown} is {days:.1f} days old (> {stale_days})",
            )


def resolve_now(zone):
    raw = os.environ.get("INVENTORY_NOW")
    if raw is not None and raw.strip() != "":
        moment = datetime.fromisoformat(raw.strip())
        if moment.utcoffset() is None:
            raise ValueError("INVENTORY_NOW must include an offset")
        return moment
    if zone is not None:
        return datetime.now(zone)
    utc_now = datetime.now(timezone.utc)
    return datetime.now(timezone(eu_sofia_offset(utc_now)))


def configured_paths():
    return (
        Path(os.environ.get("INVENTORY_ROUTINES_DIR", DEFAULT_ROUTINES_DIR)),
        Path(os.environ.get("INVENTORY_STATUS_PAGE_ROUTINES", DEFAULT_STATUS_PAGE)),
        Path(os.environ.get("INVENTORY_BRAINS_DIR", DEFAULT_BRAINS_DIR)),
        Path(os.environ.get("INVENTORY_TEAM_YAML", DEFAULT_TEAM_YAML)),
    )


def bot_names():
    return os.environ.get("INVENTORY_BRAINS_BOTS", DEFAULT_BOTS).split()


def stale_day_limit():
    return int(os.environ.get("INVENTORY_BRAINS_STALE_DAYS", DEFAULT_STALE_DAYS))


def emit(report, charter_version, now, zone, as_json):
    now_text = format_sofia_datetime(now, zone)
    if as_json:
        counts = {}
        for yellow in report.yellows:
            counts[yellow["check"]] = counts.get(yellow["check"], 0) + 1
        payload = {
            "tool": "inventory-freshness",
            "now": now_text,
            "charter_version": charter_version,
            "yellows": report.yellows,
            "counts": counts,
        }
        print(json.dumps(payload))
        return
    for yellow in report.yellows:
        print(yellow["line"])
    shown = f"v{charter_version}" if charter_version else "unknown"
    count = len(report.yellows)
    print(f"inventory-freshness: {count} yellow (charter {shown}, now {now_text})")


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="run-inventory-freshness.py",
        description="Read-only crew inventory freshness check for standup prep.",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="print one JSON object instead of human one-liners",
    )
    args = parser.parse_args(argv)
    zone = load_sofia()
    now = resolve_now(zone)
    routines_dir, status_page, brains_dir, team_yaml = configured_paths()
    report = Report()
    check_routines_dir(report, routines_dir, zone)
    check_status_page(report, status_page, zone)
    charter_version = check_charter(report, team_yaml)
    check_brains(
        report,
        brains_dir,
        bot_names(),
        stale_day_limit(),
        charter_version,
        now,
        zone,
    )
    emit(report, charter_version, now, zone, args.json)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
