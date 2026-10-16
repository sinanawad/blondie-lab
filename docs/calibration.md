# Calibration

Measured numbers for the lab. PR-6 adds the per-scenario table; this file starts
with the build-mode measurements from PR-5.

## Build mode (PR-5, 2026-10-16)

All runs on GitHub-hosted `ubuntu-24.04` (root fs 145G), `ref=v4.0.15`
(`a4e2f02a2931351e25f7d3aef0d331d02a6a0c56`) unless noted.

### Go module cache

Run the same build twice: first with an empty cache (miss + save), then again
(restore). The cache entry for this measurement was saved from the PR branch
by a temporary drill commit (normally only `main` saves); it is scoped to that
branch and is not visible to `main` or other branches.

| Run | Cache | Restore | `make go-install` | Save | GOMODCACHE | Job |
|---|---|---|---|---|---|---|
| [38887047776](https://github.com/sinanawad/blondie-lab/actions/runs/38887047776) | miss | 0 s | 678 s | 18 s | 1658 MB | 1104 s |
| [38889287194](https://github.com/sinanawad/blondie-lab/actions/runs/38889287194) | exact hit (`gomod-4.0-e1d49fcb…`) | 7 s | 471 s | – | 1659 MB | 1047 s |

- Entry size: 394 MB compressed.
- Saving: ~207 s (~3.5 min, ~30%) of build time per run with a hit; cost is a
  7 s restore per run plus an 18 s save once per new `go.sum` on `main`.
- Decision: **keep the cache** (saving clearly exceeds the save cost).
- Key: `gomod-<4.x line>-<sha256 of go.sum>`, so 4.0 and 4.1 refs keep separate
  entries and a ref with a different `go.sum` misses rather than restoring a
  stale tree.

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
