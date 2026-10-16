#!/usr/bin/env bash
# TEMPORARY drill (plan PR-3 acceptance, removed before merge): forced failure.
set -euo pipefail
m="drill-fail-i${LAB_ITERATION}"
juju add-model -c "$LAB_CONTROLLER" "$m"
if ! juju deploy -m "$LAB_CONTROLLER:$m" no-such-charm; then
	echo "drill-fail: juju deploy no-such-charm failed as intended"
	exit 1
fi
echo "drill-fail: deploy unexpectedly succeeded"
exit 0
