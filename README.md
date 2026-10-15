# blondie-lab

Disposable, public Juju test lab run on GitHub Actions. Owner: @sinanawad. Operator: Blondie (GitHub App `blondie-sinanawad[bot]`), Sinan's senior developer/DevOps agent.

## Purpose (for agents)
- Run **live Juju** scenarios that cannot run on Blondie's box (no systemd/snapd there): bootstrap a controller on **LXD** (machine charms) or **MicroK8s** (k8s charms), deploy, exercise, collect logs, tear down.
- Typical uses: reproduce a juju/juju issue, confirm a regression across snap channels/versions (last-good vs first-bad), smoke-test a charm or a locally built juju.
- Every run starts from a clean GitHub-hosted runner. Nothing persists between runs except uploaded artifacts.
- Builds, unit tests and `git bisect` of juju/juju happen on Blondie's box, not here. This repo is only for things that need a running Juju.

## Rules (hard)
1. **Public repo. No secrets, ever.** No CharmHub tokens, cloud credentials, SSH keys, or `secrets.*` usage. Work needing credentials goes elsewhere (private).
2. **No non-public material.** No embargoed security fixes, no internal Canonical infra details (IPs, hosts, juju-ci internals), no customer data.
3. **Triggers:** `workflow_dispatch` and `push` to `main` only. Never `pull_request_target`; never run on fork PRs.
4. **Least privilege:** every workflow sets `permissions: contents: read` (raise per job only if justified). Third-party actions pinned by full commit SHA with a version comment.
5. **Disposable:** each job tears down what it creates. Keep jobs under ~60 min, set `timeout-minutes`.
6. Changes to workflows go through pull requests reviewed by Sinan. Dispatching an existing workflow does not need review.

## Layout (planned)
| Path | What |
|---|---|
| `.github/workflows/lab-lxd.yml` | Dispatch: bootstrap Juju on LXD, run a scenario, upload logs |
| `.github/workflows/lab-microk8s.yml` | Dispatch: bootstrap Juju on MicroK8s, run a scenario, upload logs |
| `scenarios/<name>/` | One folder per scenario: `run.sh` (entrypoint, exit 0 = pass), optional bundle/charm, `README.md` (what it proves, linked issue) |
| `scripts/` | Shared helpers: bootstrap, `juju debug-log` and `juju status` capture, pod/event dump on failure |

## Dispatch inputs (contract, planned)
| Input | Meaning | Example |
|---|---|---|
| `juju_channel` | Juju snap channel to install | `4.0/stable`, `4.1/beta`, `latest/edge` |
| `juju_build` | Optional: URL/artifact of a locally built juju to use instead of the snap | (empty) |
| `scenario` | Folder under `scenarios/` to run | `relation-hook-order` |
| `ref` | Optional juju/juju ref (for scenarios that build from source) | `main`, `4.0`, a SHA |

Outputs: job summary (pass/fail, juju version, controller/model status) plus an artifact `lab-logs-<scenario>-<run_id>` with `juju status --format=yaml`, `debug-log`, machine/pod logs.

## How an agent uses it
1. Pick or add a scenario (add via PR).
2. Dispatch: `gh workflow run lab-lxd.yml -R sinanawad/blondie-lab -f juju_channel=4.0/stable -f scenario=<name>` (or REST `POST /repos/sinanawad/blondie-lab/actions/workflows/lab-lxd.yml/dispatches`).
3. Watch: `gh run watch` / `GET .../actions/runs`. Fetch the artifact for evidence.
4. To bisect across releases, dispatch the same scenario per channel/version and compare. Record last-good and first-bad versions with run URLs.
5. Cite run URLs as evidence in triage notes. Logs are public, so check them for anything sensitive before sharing.
