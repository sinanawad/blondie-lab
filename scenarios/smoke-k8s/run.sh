#!/usr/bin/env bash
# smoke-k8s: juju/juju tests/ smoke_k8s suite (test_deploy: snappass-test from
# CharmHub to idle, then destroy-model) against the lab controller on MicroK8s.
# test_destroy_controller is skipped (design Q9): it destroys the controller,
# which on a reused controller is the lab's own. After a pass, every
# non-controller model must be gone within 10 min, else fail.
set -euo pipefail
# The suite's own destroy_model waits DESTROY_TIMEOUT (main.sh default 15m);
# 5m keeps a hung destroy inside TIMEOUT_MIN, so no-models-left.sh scores it
# fail rather than the iteration timeout scoring it error.
export DESTROY_TIMEOUT=5m
rc=0
"$LAB_ROOT/scripts/suite.sh" -c microk8s -s test_destroy_controller smoke_k8s || rc=$?
((rc == 0)) || exit "$rc"
exec "$LAB_ROOT/scripts/no-models-left.sh" smoke-k8s 600
