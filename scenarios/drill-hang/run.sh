#!/usr/bin/env bash
# TEMPORARY drill (plan PR-3 acceptance, removed before merge): forced hang past
# TIMEOUT_MIN=1 with a model present, so collect.sh has something to collect.
set -euo pipefail
juju add-model -c "$LAB_CONTROLLER" drill-hang
echo "drill-hang: sleeping past TIMEOUT_MIN"
sleep 600
