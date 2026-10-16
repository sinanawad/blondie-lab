#!/usr/bin/env bash
# TEMPORARY DRILL (PR-4): leaves a fixed-name model with a workload behind, so
# cleanup-models.sh must destroy it and wait for its namespace before the next
# iteration re-adds the same name.
set -euo pipefail
juju add-model -c "$LAB_CONTROLLER" drill-ns
lab-kubectl get ns drill-ns --show-labels
juju deploy -m "$LAB_CONTROLLER:drill-ns" snappass-test --revision 8 --channel stable
# shellcheck disable=SC2016 # expanded by the inner bash
timeout 600 bash -c 'until juju status -m "$LAB_CONTROLLER:drill-ns" --format=json | jq -e ".applications[\"snappass-test\"][\"application-status\"].current == \"active\"" >/dev/null; do sleep 5; done'
echo "drill-ns: model left in place for cleanup"
