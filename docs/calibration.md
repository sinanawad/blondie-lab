# Calibration

Measured numbers for the lab. PR-6 adds the per-scenario table; this file starts
with the build-mode measurements from PR-5.

## Build mode (PR-5, 2026-10-16)

All runs on GitHub-hosted `ubuntu-24.04` (root fs 145G), `ref=v4.0.15`
(`a4e2f02a2931351e25f7d3aef0d331d02a6a0c56`) unless noted.

### Go module cache: dropped (owner decision, 2026-10-16)

PR-5 first added a `GOMODCACHE` cache (`actions/cache`, saved from `main`
only). The cache is **not part of v1**: the owner decided to start without it.
Revisit if builds prove slow; each build verdict now records
`build.gomod_download_s` (the part a module cache would save) separately from
`build.go_install_s`.

The numbers taken with the cache don't support a clear saving.
`go_install_s` then included the module download:

| Run | Substrate | Cache | `make go-install` |
|---|---|---|---|
| [38884372679](https://github.com/sinanawad/blondie-lab/actions/runs/38884372679) | LXD | miss | 663 s |
| [38887047776](https://github.com/sinanawad/blondie-lab/actions/runs/38887047776) | LXD | miss (+18 s save, 394 MB entry) | 678 s |
| [38886533883](https://github.com/sinanawad/blondie-lab/actions/runs/38886533883) | k8s | miss | 687 s |
| [38889287194](https://github.com/sinanawad/blondie-lab/actions/runs/38889287194) | LXD | exact hit (7 s restore) | 471 s |
| [38891816974](https://github.com/sinanawad/blondie-lab/actions/runs/38891816974) | LXD | exact hit (13 s restore) | 512 s |
| [38894668287](https://github.com/sinanawad/blondie-lab/actions/runs/38894668287) | k8s | exact hit (10 s restore) | 670 s |
| [38884396333](https://github.com/sinanawad/blondie-lab/actions/runs/38884396333) | LXD | miss (v4.0.14) | 420 s |

Runner-to-runner variance (420–760 s for the same inputs) is larger than the
apparent hit/miss difference. The k8s pair differs by 17 s, and one uncached
run was faster than both cached LXD runs. A cached GOMODCACHE is 1658 MB on
disk and 394 MB compressed per `go.sum`. Earlier text here said a different
`go.sum` "misses"; that was wrong, because `restore-keys` restored the nearest
entry. That no longer matters now that the cache is gone.

### Build and bootstrap times

| Run | Substrate | Ref | Build step | of which operator image | Bootstrap | Result |
|---|---|---|---|---|---|---|
| [38884372679](https://github.com/sinanawad/blondie-lab/actions/runs/38884372679) | LXD | v4.0.15 | 664 s | – | 70 s (`--build-agent`) | pass, agent 4.0.15.1 |
| [38884379252](https://github.com/sinanawad/blondie-lab/actions/runs/38884379252) | LXD | 4.1 head `b25763ad` | 459 s | – | 58 s | pass, agent 4.1-beta3.1 |
| [38884396333](https://github.com/sinanawad/blondie-lab/actions/runs/38884396333) | LXD | v4.0.14 | 421 s | – | – | agent 4.0.14.1 (identity drill) |
| [38886533883](https://github.com/sinanawad/blondie-lab/actions/runs/38886533883) | microk8s | v4.0.15 | 757 s | 69 s | – | pass, api-server digest = imported |

Build times vary 420–760 s between runners with the same inputs; the 45 min
build step limit and 30 min LXD build-mode bootstrap limit leave wide margin.

### Disk

| Point (k8s run 38886533883) | Free on `/` |
|---|---|
| Job start | 86G |
| After the cleanup step | 105G |
| After the build, incl. operator image | 88G |

The build uses ~15G on k8s (103G before, 88G after) and ~10G on LXD (run
38889287194: 102G before, 92G after).
The cleanup step (removing dotnet, android,
ghc and docker images) took 50–288 s in the runs above, so it now runs only
when `/` has less than 30G free. The plan's floor (~3G free at the end of the
k8s build) is met by a wide margin either way.

## Smoke set (PR-6, 2026-10-16)

Snap mode, GitHub-hosted `ubuntu-24.04`, one iteration per run. 4.0/stable is
juju 4.0.15 (snap r36241), 4.1/edge is 4.1-beta3 (snap r36731, git `f17f1c5`):
there is no 4.1/stable channel yet, so the plan's "4.1/stable once" ran on
4.1/edge. Tests are the snap's git-commit tree unless noted. "Setup" is LXD
and/or MicroK8s setup, juju snap install, tests checkout and `DEPS`; "Scenario"
is the `run.sh` iteration incl. the teardown check. Minutes are rounded.
Every run below has `scrub_hits: 0` unless noted. `lab` is the blondie-lab
commit the run used.

| Scenario | Substrate | Channel | Setup | Bootstrap | Scenario | Job | Verdict | Run | lab |
|---|---|---|---|---|---|---|---|---|---|
| smoke | LXD | 4.0/stable | 1.0 | 1.0 | 2.6 | 4.9 | pass | [38905835587](https://github.com/sinanawad/blondie-lab/actions/runs/38905835587) | 7d3db74 |
| smoke-k8s | k8s | 4.0/stable | 2.6 | 0.5 | 1.9 | 7.3 | pass | [38905842358](https://github.com/sinanawad/blondie-lab/actions/runs/38905842358) | 7d3db74 |
| smoke-k8s | k8s | 3.6/stable, tests v4.0.15 | 2.5 | 0.7 | 1.4 | 6.4 | pass, job red (scrub 3) | [38919894631](https://github.com/sinanawad/blondie-lab/actions/runs/38919894631) | ef1c0b5 |
| relations | LXD | 4.0/stable | 0.9 | 0.9 | 14.8 | 16.9 | pass | [38910626879](https://github.com/sinanawad/blondie-lab/actions/runs/38910626879) | 90c76a8 |
| relations | LXD | 4.1/edge | 1.1 | 1.2 | 15.4 | 18.0 | pass | [38914966882](https://github.com/sinanawad/blondie-lab/actions/runs/38914966882) | 5d4288f |
| model-lifecycle | LXD | 4.0/stable | 0.9 | 1.1 | 10.6 | 12.9 | pass | [38910633513](https://github.com/sinanawad/blondie-lab/actions/runs/38910633513) | 90c76a8 |
| model-lifecycle | LXD | 4.1/edge | 0.9 | 1.2 | 15.9 | 18.2 | pass | [38914974002](https://github.com/sinanawad/blondie-lab/actions/runs/38914974002) | 5d4288f |
| cli-basics | LXD | 4.0/stable | 0.8 | 0.9 | 2.1 | 4.1 | pass | [38917978596](https://github.com/sinanawad/blondie-lab/actions/runs/38917978596) | ef1c0b5 |
| cli-basics | LXD | 4.1/edge | 0.8 | 1.0 | 2.4 | 4.3 | pass | [38919935196](https://github.com/sinanawad/blondie-lab/actions/runs/38919935196) | ef1c0b5 |
| hooks-dispatch | LXD | 4.0/stable | 1.2 | 1.1 | 9.9 | 12.6 | pass | [38913128648](https://github.com/sinanawad/blondie-lab/actions/runs/38913128648) | 148cad8 |
| hooks-dispatch | LXD | 4.1/edge | 1.2 | 1.0 | 8.3 | 10.8 | pass | [38917847855](https://github.com/sinanawad/blondie-lab/actions/runs/38917847855) | 0c085e6 |
| sidecar-k8s | k8s (+LXD) | 4.0/stable | 3.3 | 0.5 | 13.5 | 19.6 | pass | [38913379189](https://github.com/sinanawad/blondie-lab/actions/runs/38913379189) | 5d4288f |
| sidecar-k8s | k8s (+LXD) | 4.1/edge † | 3.3 | 0.7 | 3.4 (stopped) | 10.1 | fail (juju facade bug, below) | [38917856456](https://github.com/sinanawad/blondie-lab/actions/runs/38917856456) | 0c085e6 |
| secrets-k8s | k8s | 4.0/stable | 2.5 | 0.5 | 15.8 | 21.2 | pass | [38911744571](https://github.com/sinanawad/blondie-lab/actions/runs/38911744571) | 148cad8 |
| secrets-k8s | k8s | 4.1/edge † | 2.7 | 0.6 | 18.0 | 23.6 | pass | [38914982038](https://github.com/sinanawad/blondie-lab/actions/runs/38914982038) | 5d4288f |

† Mixed client/controller: on k8s the 4.1/edge controller is the
`jujud-operator:4.1-beta3` image from the testing registry (`agent_source:
unknown`), agent-git-commit `4d3ea36` (2026-10-05), while the client is
`f17f1c5` (2026-10-16). The LXD 4.1/edge rows upload the client's own jujud
(`4.1-beta3.1`), so they match.

### Budgets

`TIMEOUT_MIN` = 1.5 × the longest measured scenario, rounded up to 5 min,
**plus 10 min** for the teardown check. A hung model destroy must end as
`fail` (from `no-models-left.sh`), not as `error` from the iteration timeout
(exit 124): `error` is not a regression for the bisect/sweep logic, so the
teardown bug class would become impossible to bisect. To keep that true,
every `run.sh` exports `DESTROY_TIMEOUT=5m` (main.sh's default is 15m) for
the suite's own `destroy_model`, and secrets-k8s starts its leftover destroys
in the background, so its whole teardown is one 10 min window.

| Scenario | Longest scenario | 1.5×, to 5 min | `TIMEOUT_MIN` (was) |
|---|---|---|---|
| smoke | 154 s | 5 | 15 (25) |
| smoke-k8s | 116 s | 5 | 15 (20) |
| relations | 924 s | 25 | 35 (60) |
| model-lifecycle | 953 s | 25 | 35 (60) |
| cli-basics | 141 s (+ `test_model_constraints` alone) | 5 | 15 (60) |
| hooks-dispatch | 596 s | 15 | 25 (45) |
| sidecar-k8s | 811 s | 25 | 35 (60) |
| secrets-k8s | 1080 s | 30 | 40 (60) |

All fit validate.sh's 120 min scenario budget at `repeat=2`. Fixed overhead
per job: LXD setup ~1 min, MicroK8s setup ~2.2 min, LXD on k8s (charmcraft)
+0.6 min, bootstrap 0.5–1.2 min.

### Findings

- **4.1 LXD agent:** every 4.1/edge LXD run bootstrapped agent `4.1-beta3.1`
  (`agent_source: local`): no agent for 4.1-beta3 is published in streams, so
  the snap uploads its own jujud (same git commit as the client). 4.0/stable
  uses the packaged 4.0.15 agent.
- **4.1/edge sidecar: juju facade-versioning bug (verdict `fail`).**
  `test_pebble_notices` fails at the first `juju ssh --container`:
  `unknown method "SSHServerPort" at version 15 for facade type
  "Controller"`. juju/juju #23365 (merged to 4.1 on 2026-10-14) added
  `SSHServerPort` to the **existing** Controller facade v15 (register.go:
  "v15 adds SSHServerHostKey" → "v15 adds SSHServerHostKey and
  SSHServerPort") instead of registering a v16. Client: 4.1/edge snap git
  `f17f1c5` (2026-10-16). Controller: `jujud-operator:4.1-beta3`,
  agent-git-commit `4d3ea36` (2026-10-05, 439 commits behind), which already
  has v15 without the method. Both sides agree on v15, so the client calls a
  method the server doesn't have and fails hard; a v16 would have let the
  client's facade-version check refuse cleanly. The k8s version skew (no local
  agent upload on k8s) exposes it. Candidate upstream report, drafted for the
  owner, not filed. No skip.
- **3.6/stable on k8s:** bootstrap to the built-in `microk8s` cloud works
  (agent 3.6.29, packaged). The 3.6 tests tree (`0e1f039`) has no
  `smoke_k8s` suite and its `main.sh` checks for `expect` (first run
  [38918565370](https://github.com/sinanawad/blondie-lab/actions/runs/38918565370):
  `setup-error`, "Missing dependencies: expect"), so the live check used
  `tests_ref=v4.0.15`. Scrub baseline on 3.6 is 3, not 0, and the job result
  step fails on any hit. Two hits are `--tlsCertificateKeyFilePassword=ignored`
  (a literal placeholder, juju v3.6.29 `mongo/service.go`) in `bootstrap.log`
  and `describe-pods.txt`. The third is a different form: mongod's own JSON
  options line in the controller pod log, `"certificateKeyFilePassword":…`,
  whose original value isn't in the artifact (mongod normally masks it as
  `"<password>"`). All three are redacted.
- **secrets-k8s:** `test_secrets_cmr` runs and passes on both channels.
  `test_secrets_cmr_cross_controller` is not in the v4.0.15 tree, so on
  4.0/stable the skip is a no-op; only the 4.1/edge runs (tree `f17f1c5`)
  actually skip it. It stays skipped by design §5 (second controller). The
  open cost is memory for a second controller on one runner, not time (k8s
  bootstrap 0.5–0.7 min); not tried (owner question, parked).
- **charmcraft:** 4.x/stable = 4.4.2, r8265, in `snap list` and
  `verdict.deps` for relations, hooks-dispatch and sidecar-k8s.
- **Harness fixes found here** (separate PRs, per the scope rule): models of
  all users by qualified name (#6); `testcharms/` in the sparse tests checkout,
  bootstrap `--model-default mode=`, LXD on k8s when `DEPS` has charmcraft,
  `TMPDIR` inside the tests checkout for snap juju (#8).

### Skipped upstream tests

| Scenario | Test | Why | Evidence |
|---|---|---|---|
| cli-basics | `test_model_constraints` (**not skipped: runs alone after the suite**, `alone.txt`) | upstream ordering bug in the full suite: runs on the current model, which `test_model_config` destroyed | [38916474921](https://github.com/sinanawad/blondie-lab/actions/runs/38916474921); upstream CI runs each cli test alone (juju-qa-jenkins `test-cli.yml`), which hides it |
| model-lifecycle | `test_model_metrics` | lab limitation: `model/task.sh` bootstraps with `CHARM_REVISION_UPDATE_INTERVAL=15s`, a reused controller keeps the 24 h period, and the 4.0 charmrevisioner's first update waits `jitter(period)` | [38907752372](https://github.com/sinanawad/blondie-lab/actions/runs/38907752372); upstream runs it on a fresh controller (`test-model.yml`) |
| hooks-dispatch | `test_start_hook_fires_after_reboot` | design §5: machine reboot, cost unmeasured; also drops `run_reboot_monitor_state_cleanup` (no reboot) | by design |
| secrets-k8s | `test_secrets_cmr_cross_controller` | design §5: second controller; no-op on v4.0.15 (not in the tree) | by design |
| smoke, smoke-k8s | `test_destroy_controller` | design Q9: would destroy the lab controller | by design |
