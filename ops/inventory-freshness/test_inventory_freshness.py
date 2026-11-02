#!/usr/bin/env python3
"""Offline tests for the inventory-freshness check.

The suite copies fixtures/ into a temp directory, points INVENTORY_* at that
tree, and runs the script as a subprocess. Brain mtimes are set from
INVENTORY_NOW because git does not preserve them.
"""

import hashlib
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parent
SCRIPT = ROOT / "run-inventory-freshness.py"
FIXTURES = ROOT / "fixtures"
NOW = "2026-11-02T06:00:00+02:00"
NOW_DT = datetime.fromisoformat(NOW)
BOTS = (
    "joro",
    "blondie",
    "scout",
    "bones",
    "marty",
    "hunter",
    "drill",
    "sisyphus",
)
CHECKS = {
    "routines.missing",
    "routines.unreadable",
    "routines.not-array",
    "routines.not-object",
    "routines.missing-field",
    "routines.type",
    "routines.status",
    "routines.last-run-null",
    "routines.last-run-format",
    "routines.last-run-offset",
    "charter.unreadable",
    "brains.missing",
    "brains.no-mirror",
    "brains.charter-mismatch",
    "brains.stale",
}


def element(**overrides):
    base = {
        "name": "nightly-sweep",
        "enabled": True,
        "folder": "scout",
        "last_run": "2026-11-01T06:00:00+02:00",
        "status": "succeeded",
        "bot": "scout",
        "schedule": "0 6 * * *",
    }
    base.update(overrides)
    return base


def element_without(*fields, **overrides):
    item = element(**overrides)
    for field in fields:
        del item[field]
    return item


def routine_subject(filename, index, name=None):
    label = f"routines/{filename}[{index}]"
    if name is not None:
        return f'{label} "{name}"'
    return label


def load_module(name):
    spec = importlib.util.spec_from_file_location(name, SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def expected_owner(subject):
    if subject.startswith("routines/"):
        filename = subject[len("routines/") :].split("[", 1)[0]
        if filename.endswith(".json"):
            return filename[: -len(".json")]
        return None
    if subject.startswith("brains/") and subject.endswith("-brain.md"):
        return subject[len("brains/") : -len("-brain.md")]
    return None


class InventoryFreshnessTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / "inv"
        shutil.copytree(FIXTURES, self.root)
        self.set_brain_ages(7)

    def tearDown(self):
        subprocess.run(["chmod", "-R", "u+w", self.tmp.name], check=False)
        self.tmp.cleanup()

    def set_brain_ages(self, days, bots=None):
        timestamp = NOW_DT.timestamp() - days * 86400
        names = bots if bots is not None else BOTS
        for bot in names:
            path = self.root / "brains" / f"{bot}-brain.md"
            if path.exists():
                os.utime(path, (timestamp, timestamp))

    def write_brain(self, bot, text, age_days=7):
        path = self.root / "brains" / f"{bot}-brain.md"
        path.write_text(text, encoding="utf-8")
        self.set_brain_ages(age_days, [bot])
        return path

    def put_json(self, name, payload):
        path = self.root / "routines" / name
        path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
        return path

    def env(self, extra=None):
        values = {
            "PATH": os.environ.get("PATH", ""),
            "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONIOENCODING": "utf-8",
            "LC_ALL": "C",
            "LANG": "C",
            "INVENTORY_ROUTINES_DIR": str(self.root / "routines"),
            "INVENTORY_STATUS_PAGE_ROUTINES": str(self.root / "status-page-routines.json"),
            "INVENTORY_BRAINS_DIR": str(self.root / "brains"),
            "INVENTORY_TEAM_YAML": str(self.root / "TEAM.yaml"),
            "INVENTORY_NOW": NOW,
        }
        if extra:
            values.update(extra)
        return values

    def run_check(self, extra_env=None, stderr=""):
        env = self.env(extra_env)
        command = [sys.executable, str(SCRIPT)]
        json_proc = subprocess.run(
            command + ["--json"],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        human_proc = subprocess.run(
            command,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(json_proc.returncode, 0, json_proc.stderr + json_proc.stdout)
        self.assertEqual(human_proc.returncode, 0, human_proc.stderr + human_proc.stdout)
        self.assertEqual(json_proc.stderr, stderr)
        self.assertEqual(human_proc.stderr, stderr)
        self.assertNotIn("\U0001f7e1", json_proc.stdout)
        self.assertNotIn("\U0001f7e1", human_proc.stdout)
        try:
            data = json.loads(json_proc.stdout)
        except json.JSONDecodeError as exc:
            self.fail(f"{exc}\n{json_proc.stdout}")
        self.assertEqual(
            list(data.keys()),
            ["tool", "now", "charter_version", "yellows", "counts"],
        )
        self.assertEqual(data["tool"], "inventory-freshness")
        self.assertEqual(data["now"], NOW)
        self.assertIsInstance(data["yellows"], list)
        self.assertTrue(data["charter_version"] is None or isinstance(data["charter_version"], str))
        for yellow in data["yellows"]:
            self.assertEqual(
                list(yellow.keys()),
                ["check", "subject", "owner", "detail", "line"],
            )
            self.assertIn(yellow["check"], CHECKS)
            self.assertEqual(
                yellow["line"],
                f"YELLOW {yellow['check']} {yellow['subject']}: {yellow['detail']}",
            )
            self.assertEqual(yellow["owner"], expected_owner(yellow["subject"]))
        self.assertEqual(
            data["counts"],
            dict(Counter(yellow["check"] for yellow in data["yellows"])),
        )
        shown = f"v{data['charter_version']}" if data["charter_version"] else "unknown"
        summary = (
            f"inventory-freshness: {len(data['yellows'])} yellow "
            f"(charter {shown}, now {data['now']})"
        )
        human_lines = human_proc.stdout.splitlines()
        self.assertEqual(human_lines[:-1], [yellow["line"] for yellow in data["yellows"]])
        self.assertEqual(human_lines[-1], summary)
        self.assertTrue(human_proc.stdout.endswith("\n"))
        self.assertTrue(json_proc.stdout.endswith("\n"))
        pairs = [(yellow["check"], yellow["subject"]) for yellow in data["yellows"]]
        return data, pairs

    def snapshot(self):
        rows = []
        for dirpath, dirnames, filenames in os.walk(self.root):
            dirnames.sort()
            directory_stat = os.stat(dirpath)
            rows.append(
                (
                    "dir",
                    os.path.relpath(dirpath, self.root),
                    directory_stat.st_mtime_ns,
                    directory_stat.st_mode & 0o777,
                )
            )
            for name in sorted(filenames):
                path = os.path.join(dirpath, name)
                file_stat = os.stat(path)
                digest = hashlib.sha256(Path(path).read_bytes()).hexdigest()
                rows.append(
                    (
                        "file",
                        os.path.relpath(path, self.root),
                        file_stat.st_mtime_ns,
                        file_stat.st_mode & 0o777,
                        file_stat.st_size,
                        digest,
                    )
                )
        return tuple(rows)

    def test_good_tree_no_yellows(self):
        data, pairs = self.run_check()
        self.assertEqual(pairs, [])
        self.assertEqual(data["charter_version"], "1.10.12")
        self.assertEqual(data["counts"], {})

    def test_offset_cancun(self):
        self.put_json(
            "scout.json",
            [
                element(name="alpha", last_run="2026-07-15T06:00:00+03:00"),
                element(name="beta", last_run="2026-01-15T06:00:00+02:00"),
                element(name="nightly-sweep", last_run="2026-11-01T06:00:00-05:00"),
            ],
        )
        data, pairs = self.run_check()
        subject = routine_subject("scout.json", 2, "nightly-sweep")
        self.assertEqual(pairs, [("routines.last-run-offset", subject)])
        detail = (
            'last_run "2026-11-01T06:00:00-05:00" has offset -05:00 (Cancun); '
            "Europe/Sofia is +02:00 at that instant"
        )
        self.assertEqual(data["yellows"][0]["detail"], detail)
        self.assertEqual(data["yellows"][0]["owner"], "scout")
        self.assertEqual(
            data["yellows"][0]["line"],
            f"YELLOW routines.last-run-offset {subject}: {detail}",
        )

    def test_offset_z(self):
        self.put_json("scout.json", [element(last_run="2026-11-01T06:00:00Z")])
        data, pairs = self.run_check()
        self.assertEqual(
            pairs,
            [("routines.last-run-offset", routine_subject("scout.json", 0, "nightly-sweep"))],
        )
        self.assertEqual(
            data["yellows"][0]["detail"],
            'last_run "2026-11-01T06:00:00Z" has offset +00:00; '
            "Europe/Sofia is +02:00 at that instant",
        )
        self.assertNotIn("Cancun", data["yellows"][0]["detail"])

    def test_offset_plus_00(self):
        self.put_json("scout.json", [element(last_run="2026-11-01T06:00:00+00:00")])
        data, pairs = self.run_check()
        self.assertEqual(
            pairs,
            [("routines.last-run-offset", routine_subject("scout.json", 0, "nightly-sweep"))],
        )
        self.assertIn("has offset +00:00;", data["yellows"][0]["detail"])
        self.assertNotIn("Cancun", data["yellows"][0]["detail"])

    def test_offset_plus_02_in_july(self):
        self.put_json("scout.json", [element(last_run="2026-07-15T06:00:00+02:00")])
        data, pairs = self.run_check()
        self.assertEqual(
            pairs,
            [("routines.last-run-offset", routine_subject("scout.json", 0, "nightly-sweep"))],
        )
        self.assertEqual(
            data["yellows"][0]["detail"],
            'last_run "2026-07-15T06:00:00+02:00" has offset +02:00; '
            "Europe/Sofia is +03:00 at that instant",
        )

    def test_offset_plus_03_in_january(self):
        self.put_json("scout.json", [element(last_run="2026-01-15T06:00:00+03:00")])
        data, pairs = self.run_check()
        self.assertEqual(
            pairs,
            [("routines.last-run-offset", routine_subject("scout.json", 0, "nightly-sweep"))],
        )
        self.assertEqual(
            data["yellows"][0]["detail"],
            'last_run "2026-01-15T06:00:00+03:00" has offset +03:00; '
            "Europe/Sofia is +02:00 at that instant",
        )

    def test_naive_timestamp(self):
        self.put_json("scout.json", [element(last_run="2026-11-01T06:00:00")])
        data, pairs = self.run_check()
        self.assertEqual(
            pairs,
            [("routines.last-run-format", routine_subject("scout.json", 0, "nightly-sweep"))],
        )
        self.assertEqual(
            data["yellows"][0]["detail"],
            'last_run "2026-11-01T06:00:00" has no offset',
        )

    def test_unparseable_last_run(self):
        self.put_json("scout.json", [element(last_run="yesterday")])
        data, pairs = self.run_check()
        self.assertEqual(
            pairs,
            [("routines.last-run-format", routine_subject("scout.json", 0, "nightly-sweep"))],
        )
        self.assertEqual(
            data["yellows"][0]["detail"],
            'last_run "yesterday" is not an ISO-8601 timestamp',
        )

    def test_last_run_newline_cannot_forge_a_line(self):
        self.put_json(
            "scout.json",
            [element(last_run="yesterday\nYELLOW forged: hi")],
        )
        data, pairs = self.run_check()
        self.assertEqual(
            pairs,
            [("routines.last-run-format", routine_subject("scout.json", 0, "nightly-sweep"))],
        )
        detail = data["yellows"][0]["detail"]
        self.assertEqual(
            detail,
            'last_run "yesterday\\nYELLOW forged: hi" is not an ISO-8601 timestamp',
        )
        self.assertNotIn("\n", detail)
        self.assertNotIn("\n", data["yellows"][0]["line"])

    def test_last_run_number(self):
        self.put_json("scout.json", [element(last_run=1730000000)])
        data, pairs = self.run_check()
        self.assertEqual(
            pairs,
            [("routines.last-run-format", routine_subject("scout.json", 0, "nightly-sweep"))],
        )
        self.assertEqual(
            data["yellows"][0]["detail"],
            "last_run is int, expected an ISO-8601 timestamp with an offset",
        )

    def test_null_last_run_with_succeeded(self):
        self.put_json("scout.json", [element(status="succeeded", last_run=None)])
        data, pairs = self.run_check()
        self.assertEqual(
            pairs,
            [("routines.last-run-null", routine_subject("scout.json", 0, "nightly-sweep"))],
        )
        self.assertEqual(
            data["yellows"][0]["detail"],
            'last_run is null but status is "succeeded"',
        )

    def test_null_last_run_with_running(self):
        self.put_json("scout.json", [element(name="live", status="running", last_run=None)])
        data, pairs = self.run_check()
        self.assertEqual(
            pairs,
            [("routines.last-run-null", routine_subject("scout.json", 0, "live"))],
        )
        self.assertEqual(
            data["yellows"][0]["detail"],
            'last_run is null but status is "running"',
        )

    def test_never_run_with_timestamp_is_not_yellow(self):
        self.put_json(
            "scout.json",
            [element(name="dormant", status="never_run", last_run="2026-11-01T06:00:00+02:00")],
        )
        self.assertEqual(self.run_check()[1], [])

    def test_future_last_run_is_not_yellow(self):
        self.put_json(
            "scout.json",
            [element(name="ahead", last_run="2026-12-01T06:00:00+02:00")],
        )
        self.assertEqual(self.run_check()[1], [])

    def test_duplicate_names_are_not_yellow(self):
        self.put_json(
            "scout.json",
            [element(name="same"), element(name="same", folder="other")],
        )
        self.assertEqual(self.run_check()[1], [])

    def test_failed_status_is_valid(self):
        self.put_json(
            "scout.json",
            [element(name="broke", status="failed", last_run="2026-11-01T06:00:00+02:00")],
        )
        self.assertEqual(self.run_check()[1], [])

    def test_enabled_must_be_bool(self):
        cases = (("true", "str"), (1, "int"), (0, "int"))
        for value, shown in cases:
            with self.subTest(value=value):
                self.put_json("scout.json", [element(enabled=value)])
                data, pairs = self.run_check()
                subject = routine_subject("scout.json", 0, "nightly-sweep")
                self.assertEqual(pairs, [("routines.type", subject)])
                self.assertEqual(
                    data["yellows"][0]["detail"],
                    f"enabled is {shown}, expected bool",
                )

    def test_missing_folder(self):
        self.put_json("scout.json", [element_without("folder")])
        data, pairs = self.run_check()
        self.assertEqual(
            pairs,
            [("routines.missing-field", routine_subject("scout.json", 0, "nightly-sweep"))],
        )
        self.assertEqual(data["yellows"][0]["detail"], 'key "folder" is absent')

    def test_missing_last_run_key(self):
        self.put_json("scout.json", [element_without("last_run")])
        data, pairs = self.run_check()
        self.assertEqual(
            pairs,
            [("routines.missing-field", routine_subject("scout.json", 0, "nightly-sweep"))],
        )
        self.assertEqual(data["yellows"][0]["detail"], 'key "last_run" is absent')
        self.assertNotIn("routines.last-run-null", data["counts"])

    def test_several_missing_keys_are_each_a_yellow(self):
        self.put_json("scout.json", [element_without("name", "folder")])
        data, pairs = self.run_check()
        subject = "routines/scout.json[0]"
        self.assertEqual(
            pairs,
            [
                ("routines.missing-field", subject),
                ("routines.missing-field", subject),
            ],
        )
        self.assertEqual(
            [yellow["detail"] for yellow in data["yellows"]],
            ['key "name" is absent', 'key "folder" is absent'],
        )

    def test_status_done(self):
        self.put_json("scout.json", [element(status="done")])
        data, pairs = self.run_check()
        self.assertEqual(
            pairs,
            [("routines.status", routine_subject("scout.json", 0, "nightly-sweep"))],
        )
        self.assertEqual(
            data["yellows"][0]["detail"],
            'status "done" is not one of succeeded, failed, never_run, running',
        )

    def test_top_level_object(self):
        (self.root / "routines" / "scout.json").write_text('{"name": "x"}\n', encoding="utf-8")
        data, pairs = self.run_check()
        self.assertEqual(pairs, [("routines.not-array", "routines/scout.json")])
        self.assertEqual(data["yellows"][0]["detail"], "top level is object")

    def test_top_level_number_and_null(self):
        (self.root / "routines" / "null.json").write_text("null\n", encoding="utf-8")
        (self.root / "routines" / "number.json").write_text("1\n", encoding="utf-8")
        data, pairs = self.run_check()
        self.assertEqual(
            pairs,
            [
                ("routines.not-array", "routines/null.json"),
                ("routines.not-array", "routines/number.json"),
            ],
        )
        self.assertEqual(
            [yellow["detail"] for yellow in data["yellows"]],
            ["top level is null", "top level is number"],
        )

    def test_string_element(self):
        (self.root / "routines" / "scout.json").write_text('["hello"]\n', encoding="utf-8")
        data, pairs = self.run_check()
        self.assertEqual(pairs, [("routines.not-object", "routines/scout.json[0]")])
        self.assertEqual(data["yellows"][0]["detail"], "element is string")

    def test_invalid_json(self):
        (self.root / "routines" / "scout.json").write_text("{", encoding="utf-8")
        try:
            json.loads("{")
        except json.JSONDecodeError as exc:
            expected = f"invalid JSON at line {exc.lineno} column {exc.colno}: {exc.msg}"
        data, pairs = self.run_check()
        self.assertEqual(pairs, [("routines.unreadable", "routines/scout.json")])
        self.assertEqual(data["yellows"][0]["detail"], expected)

    def test_unreadable_routine_file(self):
        os.chmod(self.root / "routines" / "joro.json", 0)
        data, pairs = self.run_check()
        self.assertEqual(pairs, [("routines.unreadable", "routines/joro.json")])
        self.assertEqual(data["yellows"][0]["detail"], "unreadable: Permission denied")

    def test_empty_routines_directory(self):
        for path in (self.root / "routines").glob("*.json"):
            path.unlink()
        data, pairs = self.run_check()
        self.assertEqual(pairs, [("routines.missing", "routines")])
        self.assertEqual(data["yellows"][0]["detail"], "INVENTORY_ROUTINES_DIR holds no *.json")
        self.assertIsNone(data["yellows"][0]["owner"])

    def test_routines_directory_missing(self):
        shutil.rmtree(self.root / "routines")
        data, pairs = self.run_check()
        self.assertEqual(pairs, [("routines.missing", "routines")])
        self.assertEqual(data["yellows"][0]["detail"], "INVENTORY_ROUTINES_DIR is missing")

    def test_status_page_missing(self):
        (self.root / "status-page-routines.json").unlink()
        data, pairs = self.run_check()
        self.assertEqual(pairs, [("routines.missing", "status-page-routines.json")])
        self.assertEqual(
            data["yellows"][0]["detail"],
            "status-page-routines.json is missing",
        )
        self.assertIsNone(data["yellows"][0]["owner"])

    def test_both_routine_inputs_missing(self):
        shutil.rmtree(self.root / "routines")
        (self.root / "status-page-routines.json").unlink()
        _, pairs = self.run_check()
        self.assertEqual(
            pairs,
            [
                ("routines.missing", "routines"),
                ("routines.missing", "status-page-routines.json"),
            ],
        )

    def test_status_page_cancun_offset(self):
        path = self.root / "status-page-routines.json"
        path.write_text(
            json.dumps(
                [element(name="status-render", folder="status", last_run="2026-11-01T06:00:00-05:00")],
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        data, pairs = self.run_check()
        subject = 'status-page-routines.json[0] "status-render"'
        self.assertEqual(pairs, [("routines.last-run-offset", subject)])
        self.assertIsNone(data["yellows"][0]["owner"])
        self.assertIn("(Cancun)", data["yellows"][0]["detail"])

    def test_dst_fallback_hour_both_offsets_pass(self):
        self.put_json(
            "dst.json",
            [
                element(name="fold-eest", last_run="2026-10-25T03:30:00+03:00"),
                element(name="fold-eet", last_run="2026-10-25T03:30:00+02:00"),
            ],
        )
        self.assertEqual(self.run_check()[1], [])

    def test_dst_spring_forward_plus_02_fails(self):
        self.put_json(
            "dst.json",
            [element(name="spring-gap", last_run="2026-03-29T04:00:00+02:00")],
        )
        data, pairs = self.run_check()
        self.assertEqual(
            pairs,
            [("routines.last-run-offset", routine_subject("dst.json", 0, "spring-gap"))],
        )
        self.assertEqual(
            data["yellows"][0]["detail"],
            'last_run "2026-03-29T04:00:00+02:00" has offset +02:00; '
            "Europe/Sofia is +03:00 at that instant",
        )

    def test_one_element_keeps_reporting_every_fault(self):
        self.put_json(
            "scout.json",
            [
                element(
                    name="nightly-sweep",
                    enabled=1,
                    status="done",
                    last_run="2026-11-01T06:00:00-05:00",
                )
            ],
        )
        _, pairs = self.run_check()
        subject = routine_subject("scout.json", 0, "nightly-sweep")
        self.assertEqual(
            pairs,
            [
                ("routines.type", subject),
                ("routines.status", subject),
                ("routines.last-run-offset", subject),
            ],
        )

    def test_later_files_are_still_checked(self):
        (self.root / "routines" / "broken.json").write_text("{", encoding="utf-8")
        self.put_json(
            "scout.json",
            [element(name="nightly-sweep", last_run="2026-11-01T06:00:00-05:00")],
        )
        _, pairs = self.run_check()
        self.assertEqual(
            pairs,
            [
                ("routines.unreadable", "routines/broken.json"),
                ("routines.last-run-offset", routine_subject("scout.json", 0, "nightly-sweep")),
            ],
        )

    def test_version_accepts_bare_and_v_prefix(self):
        forms = (
            "version: 1.10.12\n",
            "version: v1.10.12\n",
            'version: "v1.10.12"\n',
            "version: '1.10.12'\n",
            'version: "1.10.12"\n',
        )
        prefix = 'notes:\n  version: "9.9.9"\n'
        for text in forms:
            with self.subTest(text=text):
                (self.root / "TEAM.yaml").write_text(prefix + text, encoding="utf-8")
                data, pairs = self.run_check()
                self.assertEqual(pairs, [])
                self.assertEqual(data["charter_version"], "1.10.12")

    def test_nested_version_is_not_top_level(self):
        (self.root / "TEAM.yaml").write_text('notes:\n  version: "9.9.9"\n', encoding="utf-8")
        data, pairs = self.run_check()
        self.assertEqual(pairs, [("charter.unreadable", "TEAM.yaml")])
        self.assertIsNone(data["charter_version"])
        self.assertEqual(
            data["yellows"][0]["detail"],
            "TEAM.yaml has no top-level version",
        )

    def test_charter_file_without_version(self):
        (self.root / "TEAM.yaml").write_text("name: fixture\n", encoding="utf-8")
        data, pairs = self.run_check()
        self.assertEqual(pairs, [("charter.unreadable", "TEAM.yaml")])
        self.assertIsNone(data["charter_version"])

    def test_charter_missing_still_checks_stale_and_missing(self):
        (self.root / "TEAM.yaml").unlink()
        (self.root / "brains" / "bones-brain.md").unlink()
        self.set_brain_ages(9, ["drill"])
        data, pairs = self.run_check()
        self.assertEqual(
            pairs,
            [
                ("charter.unreadable", "TEAM.yaml"),
                ("brains.missing", "brains/bones-brain.md"),
                ("brains.stale", "brains/drill-brain.md"),
            ],
        )
        self.assertIsNone(data["charter_version"])
        self.assertEqual(data["yellows"][0]["detail"], "TEAM.yaml is missing")
        self.assertNotIn("brains.charter-mismatch", data["counts"])

    def test_charter_permission_denied(self):
        os.chmod(self.root / "TEAM.yaml", 0)
        data, pairs = self.run_check()
        self.assertEqual(pairs, [("charter.unreadable", "TEAM.yaml")])
        self.assertEqual(data["yellows"][0]["detail"], "unreadable: Permission denied")
        self.assertIsNone(data["charter_version"])

    def test_default_bot_list(self):
        for path in (self.root / "brains").glob("*-brain.md"):
            path.unlink()
        _, pairs = self.run_check()
        self.assertEqual(
            pairs,
            [("brains.missing", f"brains/{bot}-brain.md") for bot in BOTS],
        )

    def test_brain_missing(self):
        (self.root / "brains" / "bones-brain.md").unlink()
        data, pairs = self.run_check()
        self.assertEqual(pairs, [("brains.missing", "brains/bones-brain.md")])
        self.assertEqual(data["yellows"][0]["detail"], "bones-brain.md is absent")
        self.assertEqual(data["yellows"][0]["owner"], "bones")

    def test_brain_without_header(self):
        self.write_brain("scout", "# scout brain\n\nThis file has no charter mirror line.\n")
        data, pairs = self.run_check()
        self.assertEqual(pairs, [("brains.no-mirror", "brains/scout-brain.md")])
        self.assertEqual(
            data["yellows"][0]["detail"],
            "no Charter mirror in the first 20 lines",
        )

    def test_header_on_line_20_passes(self):
        body = "".join(f"filler {index}\n" for index in range(1, 20))
        body += "Charter mirror: v1.10.12\n"
        self.write_brain("scout", body)
        self.assertEqual(self.run_check()[1], [])

    def test_header_on_line_21_is_no_mirror(self):
        body = "".join(f"filler {index}\n" for index in range(1, 21))
        body += "Charter mirror: v1.10.12\n"
        self.write_brain("scout", body)
        _, pairs = self.run_check()
        self.assertEqual(pairs, [("brains.no-mirror", "brains/scout-brain.md")])

    def test_header_only_on_line_50(self):
        body = "".join(f"filler {index}\n" for index in range(1, 50))
        body += "Charter mirror: v1.10.12\n"
        self.write_brain("hunter", body)
        data, pairs = self.run_check()
        self.assertEqual(pairs, [("brains.no-mirror", "brains/hunter-brain.md")])
        self.assertNotIn("brains.charter-mismatch", data["counts"])

    def test_charter_mismatch(self):
        original = (self.root / "brains" / "hunter-brain.md").read_text(encoding="utf-8")
        self.write_brain("hunter", original.replace("v1.10.12", "v1.10.11"))
        data, pairs = self.run_check()
        self.assertEqual(pairs, [("brains.charter-mismatch", "brains/hunter-brain.md")])
        self.assertEqual(
            data["yellows"][0]["detail"],
            "Charter mirror v1.10.11, TEAM.yaml v1.10.12",
        )
        self.assertEqual(data["yellows"][0]["owner"], "hunter")

    def test_mirror_trailing_period_matches_team_version(self):
        for bot in ("drill", "hunter", "marty"):
            self.write_brain(bot, f"# {bot} brain\n\nCharter mirror: v1.10.12.\n")
        data, pairs = self.run_check()
        self.assertEqual(pairs, [])
        self.assertEqual(data["charter_version"], "1.10.12")

    def test_bold_markdown_mirror_matches_team_version(self):
        self.write_brain("scout", "# scout brain\n\n**Charter mirror: v1.10.12**\n")
        data, pairs = self.run_check()
        self.assertEqual(pairs, [])
        self.assertEqual(data["charter_version"], "1.10.12")

    def test_brain_stale_at_9_days(self):
        self.set_brain_ages(9, ["drill"])
        data, pairs = self.run_check()
        self.assertEqual(pairs, [("brains.stale", "brains/drill-brain.md")])
        self.assertEqual(
            data["yellows"][0]["detail"],
            "mtime 2026-10-24T07:00:00+03:00 is 9.0 days old (> 8)",
        )

    def test_brain_exactly_8_days_passes(self):
        self.set_brain_ages(8, ["sisyphus"])
        self.assertEqual(self.run_check()[1], [])

    def test_bad_stale_days_falls_back_to_eight(self):
        self.set_brain_ages(9, ["drill"])
        self.set_brain_ages(8, ["sisyphus"])
        _, pairs = self.run_check(
            extra_env={"INVENTORY_BRAINS_STALE_DAYS": "nope"},
            stderr="INVENTORY_BRAINS_STALE_DAYS is not an integer, using 8\n",
        )
        self.assertEqual(pairs, [("brains.stale", "brains/drill-brain.md")])

    def test_stale_days_env_override(self):
        self.set_brain_ages(9, ["drill"])
        _, clear = self.run_check(extra_env={"INVENTORY_BRAINS_STALE_DAYS": "10"})
        self.assertEqual(clear, [])
        _, flagged = self.run_check(extra_env={"INVENTORY_BRAINS_STALE_DAYS": "8"})
        self.assertEqual(flagged, [("brains.stale", "brains/drill-brain.md")])

    def test_bots_env_override(self):
        (self.root / "brains" / "drill-brain.md").unlink()
        _, pairs = self.run_check(extra_env={"INVENTORY_BRAINS_BOTS": "joro"})
        self.assertEqual(pairs, [])

    def test_mismatch_and_stale_both_report(self):
        self.write_brain(
            "hunter",
            "# hunter brain\n\nCharter mirror: v1.10.11\n",
            age_days=9,
        )
        _, pairs = self.run_check()
        self.assertEqual(
            pairs,
            [
                ("brains.charter-mismatch", "brains/hunter-brain.md"),
                ("brains.stale", "brains/hunter-brain.md"),
            ],
        )

    def test_unreadable_brain_file(self):
        os.chmod(self.root / "brains" / "marty-brain.md", 0)
        data, pairs = self.run_check()
        self.assertEqual(pairs, [("brains.no-mirror", "brains/marty-brain.md")])
        self.assertEqual(data["yellows"][0]["detail"], "unreadable: Permission denied")

    def test_tree_unchanged(self):
        before = self.snapshot()
        self.run_check()
        self.assertEqual(self.snapshot(), before)

    def test_read_only_tree_still_runs(self):
        subprocess.run(["chmod", "-R", "a-w", str(self.root)], check=True)
        try:
            before = self.snapshot()
            _, pairs = self.run_check()
            self.assertEqual(pairs, [])
            self.assertEqual(self.snapshot(), before)
        finally:
            subprocess.run(["chmod", "-R", "u+w", str(self.root)], check=True)


class InventoryFreshnessScriptTests(unittest.TestCase):
    def test_source_is_read_only_stdlib(self):
        text = SCRIPT.read_text(encoding="utf-8")
        self.assertTrue(text.startswith("#!/usr/bin/env python3\n"))
        self.assertTrue(os.access(SCRIPT, os.X_OK))
        for word in ("subprocess", "socket", "urllib", "http", "\U0001f7e1"):
            self.assertNotIn(word, text)
        self.assertIn("os.stat", text)
        modules = set()
        for line in text.splitlines():
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            if stripped.startswith("import "):
                for part in stripped[len("import ") :].split(","):
                    modules.add(part.strip().split()[0].split(".")[0])
            elif stripped.startswith("from "):
                modules.add(stripped.split()[1].split(".")[0])
        self.assertEqual(
            modules,
            {"argparse", "datetime", "json", "os", "pathlib", "re", "zoneinfo"},
        )
        opens = re.findall(r"open\((.*?)\)", text, flags=re.S)
        self.assertGreaterEqual(len(opens), 1)
        for call in opens:
            self.assertIn('"r"', call)
            self.assertIsNone(re.search(r"""["'](?:w|a|x|r\+|w\+|a\+|x\+)""", call))

    def test_bad_flag_exits_2(self):
        proc = subprocess.run(
            [sys.executable, str(SCRIPT), "--nope"],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(proc.returncode, 2)
        self.assertNotIn("\U0001f7e1", proc.stdout)
        self.assertNotIn("\U0001f7e1", proc.stderr)

    def test_eu_rule_matches_zoneinfo_hourly(self):
        module = load_module("inventory_freshness_eu_rule")
        sofia = ZoneInfo("Europe/Sofia")
        instant = datetime(2025, 1, 1, tzinfo=timezone.utc)
        end = datetime(2028, 1, 1, tzinfo=timezone.utc)
        while instant < end:
            self.assertEqual(
                module.eu_sofia_offset(instant),
                instant.astimezone(sofia).utcoffset(),
                instant.isoformat(),
            )
            instant += timedelta(hours=1)
        transition_days = (
            (2025, 3, 30),
            (2025, 10, 26),
            (2026, 3, 29),
            (2026, 10, 25),
            (2027, 3, 28),
            (2027, 10, 31),
        )
        for year, month, day in transition_days:
            instant = datetime(year, month, day, tzinfo=timezone.utc)
            stop = instant + timedelta(days=1)
            while instant < stop:
                self.assertEqual(
                    module.eu_sofia_offset(instant),
                    instant.astimezone(sofia).utcoffset(),
                    instant.isoformat(),
                )
                instant += timedelta(minutes=1)

    def test_zoneinfo_fallback_warns_once_and_matches(self):
        module = load_module("inventory_freshness_fallback")

        def broken_zone(_name):
            raise Exception("no tzdata")

        module.ZoneInfo = broken_zone
        messages = []
        real_write = os.write

        def capture_stderr(fd, data):
            if fd == 2:
                messages.append(data)
                return len(data)
            return real_write(fd, data)

        module.os.write = capture_stderr
        self.assertIsNone(module.load_sofia())
        self.assertIsNone(module.load_sofia())
        self.assertEqual(messages, [b"zoneinfo unavailable, using EU DST rule\n"])
        sofia = ZoneInfo("Europe/Sofia")
        samples = (
            "2026-10-25T03:30:00+03:00",
            "2026-10-25T03:30:00+02:00",
            "2026-03-29T04:00:00+02:00",
            "2026-11-01T06:00:00-05:00",
            "2026-07-15T06:00:00+03:00",
            "2026-01-15T06:00:00+02:00",
        )
        for raw in samples:
            moment = datetime.fromisoformat(raw)
            self.assertEqual(
                module.europe_sofia_offset(moment, module.load_sofia()),
                moment.astimezone(sofia).utcoffset(),
                raw,
            )


if __name__ == "__main__":
    unittest.main()
