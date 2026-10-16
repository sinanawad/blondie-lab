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
