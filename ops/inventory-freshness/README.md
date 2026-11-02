# Inventory freshness

Read-only check of crew routine inventory and brain files for standup prep.
The rules are in `PLAN.md` in this directory. Charter reference: bot-crew v1.10.12.

## Purpose

The check validates routine JSON and brain files and prints one yellow per
problem. Joro runs it inside the 06:00 Europe/Sofia standup. It needs no
dedicated agent wake.

Read-only guarantee: the script opens files only for reading and uses `os.stat`
for mtimes. It does not rewrite inventory files, start child processes, or open
network connections. It reads no secrets. It is Python 3 standard library only,
including `zoneinfo`. Stderr is used only when timezone data is missing.

If `Europe/Sofia` cannot be loaded, offsets use the EU rule: UTC+3 from the
last Sunday of March at 01:00 UTC until the last Sunday of October at 01:00
UTC, otherwise UTC+2. The script then writes one stderr line:
`zoneinfo unavailable, using EU DST rule`.

There is no `reports/` directory and no `.gitignore` here, because the script
writes nothing.

## Box install

This copy is versioned at `sinanawad/blondie-lab:ops/inventory-freshness/`. On
the box, after this lands on `main`, with the blondie-lab checkout at
`/workspace/blondie-lab`:

```
git -C /workspace/blondie-lab pull --ff-only origin main
mkdir -p /workspace/.blondie/inventory-freshness
ln -sfn /workspace/blondie-lab/ops/inventory-freshness/run-inventory-freshness.py \
  /workspace/.blondie/inventory-freshness/run-inventory-freshness.py
readlink -f /workspace/.blondie/inventory-freshness/run-inventory-freshness.py
/workspace/.blondie/inventory-freshness/run-inventory-freshness.py; echo "rc=$?"
```

The installed path is only
`/workspace/.blondie/inventory-freshness/run-inventory-freshness.py`. The
script does not live under `/workspace/bin/`, because that directory holds
`status-page-routines.json`, one of the inputs. The box checkout stays on
`main`, so the symlink runs the reviewed script.

Workflows do not run the check against the box. `lint.yml` runs the offline
unit tests.

## Usage

```
/workspace/.blondie/inventory-freshness/run-inventory-freshness.py
/workspace/.blondie/inventory-freshness/run-inventory-freshness.py --json
```

The default print is one line per yellow, then a summary line. `--json` prints
one JSON object and no summary line.

| Variable | Default |
|---|---|
| `INVENTORY_ROUTINES_DIR` | `/workspace/.bot-status/routines` |
| `INVENTORY_STATUS_PAGE_ROUTINES` | `/workspace/bin/status-page-routines.json` |
| `INVENTORY_BRAINS_DIR` | `/workspace/.bot-status/brains` |
| `INVENTORY_TEAM_YAML` | `/workspace/team/TEAM.yaml` |
| `INVENTORY_BRAINS_BOTS` | `joro blondie scout bones marty hunter drill sisyphus` |
| `INVENTORY_BRAINS_STALE_DAYS` | `8` |
| `INVENTORY_NOW` | unset, meaning the wall clock in Europe/Sofia |

`INVENTORY_BRAINS_BOTS` is a space-separated list of bot names (charter
v1.10.12 `brains.files`). `INVENTORY_BRAINS_STALE_DAYS` is an integer count of
86400-second days (charter `brains.stale`). A value that is not an integer
writes one stderr line, `INVENTORY_BRAINS_STALE_DAYS is not an integer, using 8`,
and the check uses 8. `INVENTORY_NOW`, when set, is an
ISO-8601 instant with an offset. Tests use it to pin the clock. The summary
prints that instant in Europe/Sofia local time.

A yellow does not stop the run. Every remaining file and element is still
checked. `bot`, `schedule`, and any other extra keys are allowed and are not
validated. `status: never_run` may carry a non-null `last_run`. A future
`last_run`, and duplicate `name` values in one file, are not flagged.

## Outputs

The script prints the ASCII word `YELLOW`. It does not print an emoji. Human
lines use the grammar `YELLOW <check> <subject>: <detail>`:

```
YELLOW routines.last-run-offset routines/scout.json[2] "nightly-sweep": last_run "2026-11-01T06:00:00-05:00" has offset -05:00 (Cancun); Europe/Sofia is +02:00 at that instant
YELLOW brains.charter-mismatch brains/hunter-brain.md: Charter mirror v1.10.11, TEAM.yaml v1.10.12
YELLOW brains.stale brains/drill-brain.md: mtime 2026-10-24T07:00:00+03:00 is 9.0 days old (> 8)
inventory-freshness: 3 yellow (charter v1.10.12, now 2026-11-02T06:00:00+02:00)
```

The count word stays `yellow` for zero, one, and many. With zero yellows the
output is only the summary line, `inventory-freshness: 0 yellow (...)`.
Routine indexes are 0-based. A quoted routine `name` is included when that
field is a string. `charter unknown` means `TEAM.yaml` could not be read or
had no top-level `version:`.

An offset of `-05:00` is labeled Cancun in the detail. `last_run` is quoted
the same way as a routine name, with newlines escaped, so the value cannot
break into a second line. A trailing `Z` is read as `+00:00` before parsing.
`Z` and `+00:00` are offset failures, not format failures. On the October fall-back day, both
`03:30+03:00` and `03:30+02:00` pass when each is Europe/Sofia's real offset
at that instant. A brain file exactly 8 days old passes. Only an age strictly
older than `INVENTORY_BRAINS_STALE_DAYS` is yellow. Age is elapsed seconds
divided by 86400, shown to one decimal place.

`--json` prints one object:

| Field | Meaning |
|---|---|
| `tool` | `inventory-freshness` |
| `now` | Europe/Sofia local time, `YYYY-MM-DDTHH:MM:SS±HH:MM` |
| `charter_version` | Top-level `version:` with one leading `v` removed (`1.10.12`), or null |
| `yellows` | List of `{check, subject, owner, detail, line}` |
| `counts` | Object mapping each fired `check` id to its count |

`owner` is the bot taken from the file name (`scout` from
`routines/scout.json`, `hunter` from `brains/hunter-brain.md`). It is null for
`status-page-routines.json`, for a missing routines directory, and for the
charter. `line` is the human one-liner for that yellow. `counts` omits checks
that did not fire.

| Check id | Yellow when |
|---|---|
| `routines.missing` | Routines directory missing or empty of `*.json`, or the status-page file missing |
| `routines.unreadable` | The file cannot be read, or the JSON does not parse (detail includes line and column) |
| `routines.not-array` | Top level is not an array |
| `routines.not-object` | An element is not an object |
| `routines.missing-field` | `name`, `enabled`, `folder`, `last_run`, or `status` is absent (`last_run` must be present even when null) |
| `routines.type` | `name` or `folder` is not a string, or `enabled` is not a boolean (`0` and `1` fail) |
| `routines.status` | `status` is outside `succeeded`, `failed`, `never_run`, `running` |
| `routines.last-run-null` | `last_run` is null and `status` is not `never_run` |
| `routines.last-run-format` | `last_run` is not a string, does not parse, or has no offset |
| `routines.last-run-offset` | The offset is not Europe/Sofia's offset at that instant |
| `charter.unreadable` | `TEAM.yaml` is missing, unreadable, or has no top-level `version:` |
| `brains.missing` | `<bot>-brain.md` is absent |
| `brains.no-mirror` | No `Charter mirror: v<version>` in the first 20 lines, or the file cannot be read |
| `brains.charter-mismatch` | Mirror version differs from `TEAM.yaml` after one leading `v` is stripped |
| `brains.stale` | mtime is strictly older than the stale-day limit |

Version compare is an exact string compare, not semver ordering. `1.10.12`
and `v1.10.12` both match a mirror of `v1.10.12`. The mirror token is
`Charter mirror:` plus optional space plus `v` and a dotted version. A
trailing period (`v1.10.12.`) and markdown bold (`**Charter mirror: v1.10.12**`)
are not part of the token, so both match `1.10.12`. The version line in
`TEAM.yaml` is read with the top-level regex in `PLAN.md` only. When the charter version cannot
be read, mismatch checks are skipped. Missing and stale brain checks still run.
Routine files are not limited to `INVENTORY_BRAINS_BOTS`. Every `*.json` in
the routines directory is checked, plus `status-page-routines.json`.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | The script finished, with zero or more yellows |
| 1 | Uncaught exception. Python prints a traceback on stderr |
| 2 | Bad CLI flag (`argparse`) |
