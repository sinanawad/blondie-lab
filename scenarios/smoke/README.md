# smoke

- **What:** juju/juju `tests/main.sh -l "$LAB_CONTROLLER" -s test_build smoke`, i.e. `test_deploy` (`run_charmhub_deploy`: `juju-qa-test`, `juju-qa-dummy-source`, `juju-qa-dummy-sink` from CharmHub, wait for idle, destroy the model) on the lab LXD controller. `run_local_deploy` is commented out upstream on 4.0.
- **Teardown check:** upstream's `destroy_controller` on a reused controller ends in `destroy-model … || true`, so after a pass `run.sh` waits up to 10 min for every non-controller model to be gone and exits 1 (`fail`) if one is left. A model-destroy regression scores `fail`, not a later cleanup `setup-error`.
- **No test ran:** `suite.sh` turns a main.sh exit 0 without any `] Success:` line into 3 (`inconclusive`).
- **Skip:** `test_build` runs `make go-build` on the full juju tree; snap mode only checks out `tests/`, and building is not what this scenario tests.
- **Expected verdict:** `pass` on a healthy channel. Also the scrub zero-hit baseline (design §8): a clean run must show `scrub_hits: 0`.
- **Budget:** `TIMEOUT_MIN=10` per iteration (calibration: `docs/calibration.md`; scenario 154 s on 4.0/stable).
