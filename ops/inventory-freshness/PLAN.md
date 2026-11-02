# Inventory freshness: implementation plan

Status: plan only. Bones/Sinan optional F, 2026-11-02. Charter bot-crew v1.10.12.
Source notes: Bones draft "Inventory freshness" (28 Oct 2026, after charter v1.10.9).

Read-only box script that validates crew inventory freshness and prints yellow
flags for standup prep. Joro runs it inside the 06:00 Europe/Sofia standup. It
needs no dedicated agent wake and never rewrites inventory files. It is modeled
on `ops/cve-sweep/`: versioned here for review, symlinked from
`/workspace/.blondie/`, and never executed by workflows.

## 1. File layout

| Path | What |
|---|---|
| `ops/inventory-freshness/README.md` | Purpose, read-only guarantee, box install, usage, env table, output format, exit codes (same section order as `ops/cve-sweep/README.md`) |
| `ops/inventory-freshness/run-inventory-freshness.py` | The check. `#!/usr/bin/env python3`, stdlib only (`json`, `datetime`, `zoneinfo`, `pathlib`, `re`, `argparse`, `os`). Executable bit set |
| `ops/inventory-freshness/test_inventory_freshness.py` | Offline `unittest` suite (see section 4) |
| `ops/inventory-freshness/fixtures/` | Static fixture trees: `routines/*.json`, `status-page-routines.json`, `brains/*-brain.md`, `TEAM.yaml` |
| `.github/workflows/lint.yml` | One new step: `python3 -m unittest discover -s ops/inventory-freshness -p 'test_*.py'` |
| `README.md` | One new Layout row for `ops/inventory-freshness/`, next to `ops/cve-sweep/` |

There is no `.gitignore` and no `reports/` directory because the script writes nothing.
The script is Python, so the shellcheck step (which selects files by shell
shebang) skips it. The unittest step covers it instead.

### Env (mirrors `CVE_SWEEP_*`)

| Variable | Default |
|---|---|
| `INVENTORY_ROUTINES_DIR` | `/workspace/.bot-status/routines` |
| `INVENTORY_STATUS_PAGE_ROUTINES` | `/workspace/bin/status-page-routines.json` |
| `INVENTORY_BRAINS_DIR` | `/workspace/.bot-status/brains` |
| `INVENTORY_TEAM_YAML` | `/workspace/team/TEAM.yaml` |
| `INVENTORY_BRAINS_BOTS` | `joro blondie scout bones marty hunter drill sisyphus` (charter v1.10.12 `brains.files`) |
| `INVENTORY_BRAINS_STALE_DAYS` | `8` (charter `brains.stale`) |
| `INVENTORY_NOW` | unset, meaning the wall clock. An ISO-8601 instant with an offset, used by tests for a fixed clock |

## 2. Validation rules

Every failure is one yellow. A yellow never stops the run; every remaining file and
element is still checked. Each yellow has a stable `check` id so Joro can group the
yellows and dedupe them across days.

### Routines (each `routines/*.json`, plus `status-page-routines.json`)

| Check id | Rule | Yellow when |
|---|---|---|
| `routines.missing` | Input exists | `INVENTORY_ROUTINES_DIR` is missing or holds no `*.json`, or `status-page-routines.json` is missing |
| `routines.unreadable` | File reads and parses as JSON | `OSError` or `json.JSONDecodeError` (the message includes the line and column) |
| `routines.not-array` | Top level is a JSON array | Top level is an object, string, number, or null |
| `routines.not-object` | Every element is an object | `routines[i]` is not a dict |
| `routines.missing-field` | Keys `name`, `enabled`, `folder`, `last_run`, `status` are present | A key is absent (`last_run` must be present even when its value is `null`) |
| `routines.type` | `name` is str, `enabled` is bool, `folder` is str | Wrong type. Use `type(v) is bool`, because `isinstance(1, bool)` is false but `isinstance(True, int)` is true, so `0` and `1` must be rejected explicitly |
| `routines.status` | `status` is in {`succeeded`, `failed`, `never_run`, `running`} | Any other value or type |
| `routines.last-run-null` | `last_run` is `null` only when `status` is `never_run` | `null` with any other status |
| `routines.last-run-format` | `last_run` is a str that `datetime.fromisoformat` parses and that carries an offset | Not a str, does not parse, or has no offset |
| `routines.last-run-offset` | The offset equals Europe/Sofia's real offset at that instant (`dt.utcoffset() == dt.astimezone(ZoneInfo("Europe/Sofia")).utcoffset()`) | `-05:00` (the message says "Cancun"), `Z`/`+00:00`, `+02:00` during Sofia summer time, or `+03:00` during winter time |

`bot` and `schedule` are allowed and not validated. Other keys are not flagged,
because this plan adds no schema fields. Routine files are not tied to the brains
bot list; the check covers every `*.json` in the directory.

The offset rule handles the October fall-back hour. Both `03:30+03:00` and
`03:30+02:00` on 2026-10-25 are real Sofia times, and both pass (this was checked
with Python 3.12).

### Brains (each bot in `INVENTORY_BRAINS_BOTS`)

| Check id | Rule | Yellow when |
|---|---|---|
| `charter.unreadable` | `TEAM.yaml` reads and has a top-level `version:` | Missing file or no match for `^version:\s*["']?v?([0-9][0-9A-Za-z.\-]*)`. The version comparison is then skipped for all brains; the other brain checks still run |
| `brains.missing` | `<bot>-brain.md` exists | Absent |
| `brains.no-mirror` | The header has `Charter mirror: v<version>` | No match for `Charter mirror: v(\S+)` in the first 20 lines |
| `brains.charter-mismatch` | The mirror version equals the `TEAM.yaml` version | The strings differ after a leading `v` is stripped (exact string compare, no semver ordering) |
| `brains.stale` | mtime is at most 8 days old | `now - st_mtime > 8 * 86400` s (strictly older than 8 days) |

### Process guarantees

- Exit `0` whenever the script finishes, whether it found zero or many yellows.
  Per-file `OSError` and JSON errors become yellows. An uncaught exception
  propagates: Python prints a traceback on stderr and exits `1`, so Joro reports
  "inventory-freshness crashed". A bad CLI flag gives argparse's `2`.
- Files are only opened with `open(..., "r")` and `os.stat` is used for mtimes. The
  script does not touch inventory files, has no `subprocess`, sockets, or HTTP, and
  reads no secrets. Stderr is used only for diagnostics, for example "zoneinfo
  unavailable, using EU DST rule".
- If `zoneinfo` cannot load `Europe/Sofia` (no tzdata on the box), the script falls
  back to the EU rule: +03:00 from the last Sunday of March 01:00 UTC to the last
  Sunday of October 01:00 UTC, otherwise +02:00. It writes one stderr diagnostic
  when it does this.

## 3. CLI usage for Joro's standup

```
/workspace/.blondie/inventory-freshness/run-inventory-freshness.py          # human one-liners
/workspace/.blondie/inventory-freshness/run-inventory-freshness.py --json   # one JSON object
```

Default stdout has one line per yellow, then a summary line. The grammar is fixed
(`YELLOW <check> <subject>: <detail>`), so the output can also be grepped:

```
YELLOW routines.last-run-offset routines/scout.json[2] "nightly-sweep": last_run 2026-11-01T06:00:00-05:00 has offset -05:00 (Cancun); Europe/Sofia is +02:00 at that instant
YELLOW brains.charter-mismatch brains/hunter-brain.md: Charter mirror v1.10.11, TEAM.yaml v1.10.12
YELLOW brains.stale brains/drill-brain.md: mtime 2026-10-23T05:10:00+03:00 is 9.9 days old (> 8)
inventory-freshness: 3 yellow (charter v1.10.12, now 2026-11-02T06:00:04+02:00)
```

With zero yellows, the output is only the summary line, `inventory-freshness: 0 yellow (...)`.

`--json` prints one object. Its fields are `tool`, `now`, `charter_version`
(str or null), `yellows` (a list of `{check, subject, owner, detail, line}`, where
`owner` is the bot taken from the file name, or null for `status-page-routines.json`
and the charter), and `counts` (by `check`). The `line` field is the human one-liner.

Standup recipe (wording to add to Joro's routine, not part of this repo):
1. Run `timeout 30 /workspace/.blondie/inventory-freshness/run-inventory-freshness.py --json`.
2. An exit other than 0, or stdout that is not JSON, gets one line: "🟡 inventory-freshness crashed (rc=N)".
3. An empty `yellows` list gets "inventory: green". Otherwise, paste each `line`
   under 🟡 inventory and @ each distinct `owner`. The script never @s anyone itself.

## 4. Tests and fixtures

`test_inventory_freshness.py` runs the script as a subprocess with `INVENTORY_*`
pointed at a `tempfile` copy of `fixtures/`. It sets `INVENTORY_NOW` to
`2026-11-02T06:00:00+02:00`. Git does not keep mtimes, so the test sets brain mtimes
with `os.utime` relative to `INVENTORY_NOW`. The test needs no network and no box
paths, and runs on `ubuntu-24.04` (Python 3.12, tzdata present).

Fixture cases (each asserts the exact set of `(check, subject)` pairs from `--json`):

- Good: `routines/joro.json` with a July `+03:00` element, a January `+02:00`
  element, `never_run` + `null`, and `running`, and with `bot` and `schedule`
  present. It gives no yellows.
- Routines bad: `-05:00`; `Z`; `+02:00` in July; a naive timestamp; `"yesterday"`;
  `last_run: 1730000000`; `null` with `succeeded`; `enabled: "true"`;
  `enabled: 1`; a missing `folder`; a missing `last_run` key; `status: "done"`; an
  object at the top level; a string element; invalid JSON; an empty directory.
- `status-page-routines.json`: one good copy and one variant with `-05:00`.
- DST edge cases: both readings of 2026-10-25 03:30 pass, and `+02:00` on
  2026-03-29 04:00 fails.
- Brains: all 8 bots fresh at 7 days with no yellows; one missing; one with no
  header; one whose header is only on line 50 (`no-mirror`); `v1.10.11`
  (`charter-mismatch`); one at 9 days (`stale`); one exactly 8 days old (passes,
  since the rule is strictly older).
- Charter: `TEAM.yaml` missing gives `charter.unreadable`, the mismatch checks
  are skipped, and the `stale` and `missing` checks still fire.
- Guarantees: every case exits `0`. A hash and mtime snapshot of the temp tree
  taken before and after the run is identical. A run with the tree set to
  `chmod -R a-w` still succeeds. A source scan asserts the script has no
  `subprocess`, `socket`, `urllib`, `http`, or `open(` call with a write mode.
- Fallback: an in-process unit test checks that the EU-rule fallback matches
  `zoneinfo` hourly across 2025–2027.

## 5. Box symlink steps (same pattern as cve-sweep)

After the PR merges, with the box checkout of blondie-lab on `main` at
`/workspace/blondie-lab` (the path `CVE_SWEEP_REPOS` already uses):

```
git -C /workspace/blondie-lab pull --ff-only origin main
mkdir -p /workspace/.blondie/inventory-freshness
ln -sfn /workspace/blondie-lab/ops/inventory-freshness/run-inventory-freshness.py \
  /workspace/.blondie/inventory-freshness/run-inventory-freshness.py
readlink -f /workspace/.blondie/inventory-freshness/run-inventory-freshness.py
/workspace/.blondie/inventory-freshness/run-inventory-freshness.py; echo "rc=$?"
```

The script goes under `/workspace/.blondie/`, not `/workspace/bin/`. That matches
cve-sweep, and `/workspace/bin/` holds one of the script's inputs
(`status-page-routines.json`), so the tool should not live next to the data it
checks. The README documents only this path.

## 6. Open questions

1. `brains.files` and `brains.stale`. Should the script parse these from
   `TEAM.yaml` instead of using the env defaults? That needs either PyYAML on the
   box or a known YAML shape (a list of bot names or a list of paths). This plan
   hardcodes the v1.10.12 values and uses a regex only for `version:`.
2. Is the `TEAM.yaml` key literally top-level `version:`, and is the value bare
   (`1.10.12`) or prefixed (`v1.10.12`)? The plan accepts both.
3. Header scope. Does "header" mean the first 20 lines, or the block before the
   first `##`?
4. Should `status: never_run` with a non-null `last_run` be flagged? The quoted
   schema only constrains the reverse, so it is not flagged.
5. Should a future `last_run`, or duplicate `name` values in one file, be flagged?
   Neither is in the quoted schema, so neither is flagged.
6. Bones' draft "inventory lag" check (`last_run` older than the routine's last
   expected fire) and `notes/<bot>.json` freshness are out of scope here. They need
   `schedule` semantics, which the quoted schema does not define. Make them a
   follow-up F?
7. Style reference. `status-page-gen` and `/workspace/bin/*` are not in this repo.
   Before implementing, confirm on the box that they are stdlib-only Python 3 and
   that the box Python is at least 3.9 (needed for `zoneinfo`) and has tzdata.
8. Output marker. The script prints `YELLOW` (ASCII, greppable) and Joro renders
   🟡. Is that acceptable, or should the script print the emoji itself?
