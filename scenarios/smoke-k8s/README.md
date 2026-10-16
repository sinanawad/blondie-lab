# smoke-k8s

- **What:** juju/juju `tests/main.sh -l "$LAB_CONTROLLER" -c microk8s -s test_destroy_controller smoke_k8s`, i.e. `test_deploy` (`run_charmstore_deploy`: `snappass-test` revision 8 from CharmHub, wait for idle, destroy the model) on the lab MicroK8s controller. `test_smoke_k8s` then calls `destroy_controller test-smoke-k8s`, which on a reused controller falls back to `destroy-model` (no controller of that name).
- **Skip:** `test_destroy_controller` (design Q9) deploys into `test-deploy-destroy` and then destroys `$BOOTSTRAPPED_JUJU_CTRL_NAME`, which here is the lab controller itself. Controller-destruction coverage, if needed, becomes a separate `destroy-controller-k8s` scenario. After a run, `collect.sh` still sees the controller (`juju show-controller`), which proves the skip.
- **Teardown check:** as in `smoke`, after a pass every non-controller model must be gone within 10 min, else `fail`. Between iterations (`repeat`) the harness also waits for each model namespace to be gone (shared 5 min cleanup budget).
- **No test ran:** `suite.sh` turns a main.sh exit 0 without any `] Success:` line into 3 (`inconclusive`).
- **Expected verdict:** `pass` on a healthy channel.
- **Budget:** `TIMEOUT_MIN=20` (design estimate; final number at calibration, plan PR-6).
