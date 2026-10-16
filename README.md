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
| `.github/workflows/lab-lxd.yml` | Dispatch: run a scenario against Juju on LXD. **Currently a stub** that validates and echoes inputs |
| `.github/workflows/lab-microk8s.yml` | Same on MicroK8s. **Currently a stub** |
| `.github/workflows/lint.yml` | actionlint, zizmor (online audits, `--min-severity low`), shellcheck (by shebang), and the lint-fixtures check. Single job `lint` |
| `zizmor.yml`, `lint-requirements.txt` | zizmor config (hash-pin policy for all actions) and its hash-pinned install |
| `lint-fixtures/` | Known-bad files that each linter must keep failing on. Never move them into `.github/workflows/` |
| `scripts/` | Shared helpers (`check-lint-fixtures.sh` now; harness scripts later) |
| `scenarios/<name>/` | Planned: one folder per scenario with `run.sh`, `scenario.env`, `README.md` |

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

Outputs (from PR-2 on): artifact `lab-logs-<scenario>-<run_id>` with `verdict.json` (pass / fail / setup-error / inconclusive / error, with pinned SHAs) and logs; the job summary carries the verdict too. A missing `verdict.json` counts as failure.

## How an agent uses it
1. Pick or add a scenario (add via PR).
2. Dispatch via REST so the run id comes back: `gh api -X POST repos/sinanawad/blondie-lab/actions/workflows/lab-lxd.yml/dispatches -f ref=main -F return_run_details=true -f 'inputs[scenario]=<name>' -f 'inputs[juju_channel]=4.0/stable' -f 'inputs[request_id]=<uuid>'`.
3. Watch `GET /repos/sinanawad/blondie-lab/actions/runs/<id>`; download the artifact and read `verdict.json`, not the job colour.
4. To bisect across versions, dispatch the same scenario per channel or per tag via `ref`, then record last-good and first-bad with run URLs and pinned SHAs. A setup-error, error or inconclusive point is a gap, not a result.
5. Cite run URLs as evidence in triage notes. Logs are public, so check them before sharing.

The full design and implementation plan are kept in Blondie's private notes (`docs/blondie-lab-design.md`, `docs/blondie-lab-plan.md` in sinanawad/blondie-devenv).
