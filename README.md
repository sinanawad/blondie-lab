# blondie-lab

Disposable, public Juju test lab run on GitHub Actions. Owner: @sinanawad. Operator: Blondie (GitHub App `blondie-sinanawad[bot]`), Sinan's senior developer/DevOps agent.

## Purpose (for agents)
- Run **live Juju** scenarios that cannot run on Blondie's box (no systemd/snapd there): bootstrap a controller on **LXD** (machine charms) or **MicroK8s** (k8s charms), run a scenario, collect logs, write a verdict.
- Typical uses: quick sanity checks; reproduce a juju/juju issue; verify a fix; compare versions (last-good vs first-bad) across snap channels or juju/juju tags/SHAs (build mode, 4.0/4.1 only in v1).
- Every run starts from a clean GitHub-hosted runner. Nothing persists between runs except uploaded artifacts (7 days) and the run's job summary.
- Builds, unit tests and `git bisect` of juju/juju happen on Blondie's box, not here. This repo is only for things that need a running Juju.

## Non-goals (v1)
- Full regression, nightly/cron schedules, perf or soak tests, multi-cloud, HA, anything needing credentials.
- **Smoke-testing a charm** (a charm source input brings its own supply-chain questions).
- Running a juju binary from a URL (the old `juju_build` input is gone; `ref` builds from juju/juju source instead).
- Issue, PR or comment writes from workflows. The lab only produces evidence; Blondie reports it.

## Rules (hard)
1. **Public repo. No secrets, ever.** No CharmHub tokens, cloud credentials, SSH keys, or `secrets.*` usage. Work needing credentials goes elsewhere (private).
2. **No non-public material.** No embargoed security fixes, no internal Canonical infra details (IPs, hosts, juju-ci internals), no customer data.
3. **Triggers:** `workflow_dispatch` and `push` to `main`; `pull_request` only for `lint.yml`. On a fork PR, `lint` fails in its first step, before checkout (fail closed: a skipped job would count as a passing required check). Never `pull_request_target`. Fork code never runs; fork PR workflows also need approval (repo setting).
4. **Least privilege:** `permissions: {}` at the top of every workflow; each job grants only what it needs (normally `contents: read`). `persist-credentials: false` on every checkout. Every action is pinned to a full commit SHA with a version comment, GitHub-owned ones included (enforced by repo policy and zizmor). Inputs reach `run:` only through `env:`, never as `${{ inputs.* }}` inline.
5. **Disposable and time-boxed:** every heavy step has its own `timeout-minutes`; the job timeout is only a backstop. Teardown is best effort; the runner VM is discarded anyway.
6. Changes go through pull requests reviewed by Sinan (ruleset on `main`: PR plus 1 approval, no force-push). **Dispatching from `main` needs no review.** Dispatching from a branch runs that branch's workflow file, which is unreviewed and can request write permissions in its own `permissions:` block (the repo's read-only default applies only to workflows without one). Use branch dispatches only to test that branch's PR, and take evidence only from `ref=main` runs (check `lab_sha` in `verdict.json`).

## Layout
| Path | What |
|---|---|
| `.github/workflows/lab-lxd.yml` | Dispatch: run a scenario on LXD. Thin caller of `_run.yml` (run-name, concurrency, permissions) |
| `.github/workflows/lab-microk8s.yml` | Same on MicroK8s |
| `.github/workflows/_run.yml` | Reusable harness: validate → (LXD, juju snap, tests checkout, deps, bootstrap) → ready → scenario → collect → scrub → verdict → upload → teardown. LXD snap mode only; MicroK8s (PR-4) and `ref` build mode / explicit `tests_ref` (PR-5) are rejected as setup-error for now |
| `.github/workflows/lint.yml` | actionlint, zizmor (online audits, `--min-severity low`), shellcheck (by shebang), and the lint-fixtures check. Single job `lint` |
| `zizmor.yml`, `lint-requirements.txt` | zizmor config (hash-pin policy for all actions) and its hash-pinned install |
| `lint-fixtures/` | Known-bad files that each linter must keep failing on. Never move them into `.github/workflows/` |
| `scripts/` | `validate.sh` (inputs + scenario contract + time budget), `run-scenario.sh` (iteration loop), `verdict.sh` (`verdict.json` + job summary), `test-harness.sh` (offline unit tests, run by lint), `check-lint-fixtures.sh`; setup: `setup-juju.sh` (snap + channel-tracking assertion), `resolve-tests.sh` (tests ref from the snap's git-commit), `deps.sh` (preflight + `DEPS`), `bootstrap.sh`; `suite.sh` (wrapper over juju/juju `tests/main.sh` with setup-phase infra signatures from `infra-signatures.txt`), `cleanup-models.sh` (between iterations), `collect.sh`, `scrub.sh`, `minimal-artifact.sh` |
| `scenarios/<name>/` | One folder per scenario: `run.sh` (entrypoint), `scenario.env`, `README.md`. Permanent harness checks: `selftest`, `selftest-exit-{1,2,3,137}`, `selftest-flaky`, `selftest-hang`. Live Juju: `smoke` (LXD) |

## Dispatch inputs (v1 contract)
| Input | Meaning | Example |
|---|---|---|
| `scenario` | Required. Folder under `scenarios/` (`^[a-z0-9][a-z0-9-]{0,63}$`) | `smoke` |
| `juju_channel` | Juju snap channel for snap mode (default `4.0/stable`) | `4.1/beta`, `3.6/stable` |
| `ref` | Optional juju/juju tag or SHA; switches to build mode (4.0/4.1 trees only, verified against juju/juju) | `v4.0.14` |
| `tests_ref` | Optional juju/juju tag or SHA for `tests/` (default: the snap's `git-commit`, or `ref` in build mode) | `v4.0.15` |
| `repeat` | Iterations, 1–10 (default 1) | `3` |
| `request_id` | Optional caller nonce for run lookup (`^[A-Za-z0-9-]{1,64}$`), shown in the run name | a UUID |

`ref`/`tests_ref` must match `^[A-Za-z0-9][A-Za-z0-9._/-]{0,99}$` and may not start with `refs/` or contain `..`, `//`, `@{`, a trailing `/` or `.lock`.

Outputs: one artifact per run, `lab-logs-<scenario>-<run_id>` (or `lab-logs-invalid-<run_id>` when `scenario` itself is invalid), with `verdict.json` (pass / fail / setup-error / inconclusive / error, with pinned SHAs), `results.jsonl` and logs; the job summary carries the verdict too. Download by run id with `gh run download <id> -p 'lab-logs-*'`, never by a name rebuilt from the inputs. A missing `verdict.json` or artifact counts as failure.

Scrub (before upload): key/value forms of `password`, `apipassword`, `statepassword`, `oldpassword`, `admin-secret` and `macaroon(s)` have their value replaced with `<redacted>` in place; `scrub_hits` is recorded and any hit turns the job red. A `BEGIN … PRIVATE KEY` block stops the full upload: the run's artifact then holds only `verdict.json` (`upload_blocked: true`, file path only) and `collect.log`, and the verdict stays the scenario's real one. **Job logs are not scrubbed** (scenario output is replayed into the step log), so scenarios use only public charms and dummy values.

`verdict.json` fields beyond the design schema: `reason` (why setup-error/error, else null), `failed` (number of `fail` iterations), and `source: "none"` for `NEEDS_JUJU=0` runs (`juju_channel` is then null). On a setup-error each input is echoed only if its own check passed (`request_id` is checked first), otherwise null.

## Scenario contract (short)
- `scenario.env` (parsed, never sourced): `SUBSTRATE=lxd|k8s|any`, `TIMEOUT_MIN=<per-iteration minutes>`, `NEEDS_TESTS=0|1`, `NEEDS_JUJU=0|1` (default 1; `0` = no substrate or bootstrap, e.g. `selftest`), `DEPS=<words>`. Unknown and repeated keys are rejected. `NEEDS_JUJU=0` requires `SUBSTRATE=any`, `NEEDS_TESTS=0`, no `DEPS`, and rejects a non-empty `ref`/`tests_ref`; `tests_ref` is rejected for `NEEDS_TESTS=0`, so an input is never silently ignored.
- `run.sh` exit codes: `0` pass, `1` fail (bug reproduced / regression), `2` setup-error, `3` inconclusive, anything else error (the per-iteration timeout gives 124, or 137 after the 60 s kill grace; the loop stops after setup-error/error).
- Time budget: `TIMEOUT_MIN × repeat + repeat + 5 × (repeat − 1) + 5 ≤ 120` minutes, checked before any setup.
- Environment: `LAB_SUBSTRATE`, `LAB_ITERATION`, `LAB_REPEAT`, `LAB_ARTIFACT_DIR` (files written there are uploaded), `LAB_SCENARIO_DIR`, `LAB_ROOT`; with `NEEDS_JUJU=1` also `LAB_CONTROLLER` (`lab`), `LAB_CLOUD` (`localhost`), `LAB_JUJU_VERSION`, `LAB_JUJU_GIT_COMMIT`, `LAB_JUJU_SOURCE` (`snap`), `LAB_TESTS_DIR`/`LAB_TESTS_SHA` (`NEEDS_TESTS=1`), `MODEL_ARCH`, `BOOTSTRAP_ADDITIONAL_ARGS`. Suite-backed scenarios call `"$LAB_ROOT/scripts/suite.sh" [main.sh flags] <suite>`. Between iterations every non-controller model is destroyed (≤ 5 min, else setup-error). No `GITHUB_ENV`/`GITHUB_OUTPUT`/`GITHUB_PATH`/`GITHUB_STATE`/`GITHUB_STEP_SUMMARY`, and workflow commands (`::...::`) in scenario output are not honoured. Harness state lives outside `LAB_ARTIFACT_DIR`.

## How an agent uses it
1. Pick or add a scenario (add via PR).
2. Dispatch via REST so the run id comes back: `gh api -X POST repos/sinanawad/blondie-lab/actions/workflows/lab-lxd.yml/dispatches -f ref=main -F return_run_details=true -f 'inputs[scenario]=<name>' -f 'inputs[juju_channel]=4.0/stable' -f 'inputs[request_id]=<uuid>'`.
3. Watch `GET /repos/sinanawad/blondie-lab/actions/runs/<id>`; download the artifact and read `verdict.json`, not the job colour.
4. To bisect across versions, dispatch the same scenario per channel or per tag via `ref`, then record last-good and first-bad with run URLs and pinned SHAs. A setup-error, error or inconclusive point is a gap, not a result.
5. Cite run URLs as evidence in triage notes. Logs are public, so check them before sharing.

The full design and implementation plan are kept in Blondie's private notes (`docs/blondie-lab-design.md`, `docs/blondie-lab-plan.md` in sinanawad/blondie-devenv).
