#!/usr/bin/env bash
# TEMPORARY drill (plan PR-3 acceptance, removed before merge): signature
# positive. A leftover test-smoke model makes the smoke suite's bootstrap()
# (setup phase, before any test runs) print its "already exists. Use the
# following to clean up the environment:" sentence and exit 1 -> setup-error.
set -euo pipefail
juju add-model -c "$LAB_CONTROLLER" test-smoke
exec "$LAB_ROOT/scripts/suite.sh" -s test_build smoke
