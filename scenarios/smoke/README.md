# smoke

- **What:** juju/juju `tests/main.sh -l "$LAB_CONTROLLER" -s test_build smoke`, i.e. `test_deploy` (`run_charmhub_deploy`: `juju-qa-test`, `juju-qa-dummy-source`, `juju-qa-dummy-sink` from CharmHub, wait for idle, destroy the model) on the lab LXD controller.
- **Skip:** `test_build` runs `make go-build` on the full juju tree; snap mode only checks out `tests/`, and building is not what this scenario tests.
- **Expected verdict:** `pass` on a healthy channel. Also the scrub zero-hit baseline (design §8): a clean run must show `scrub_hits: 0`.
- **Budget:** `TIMEOUT_MIN=25` (estimate ~10 min, unverified until calibration, plan PR-6).
