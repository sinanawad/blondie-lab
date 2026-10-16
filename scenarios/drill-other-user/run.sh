#!/usr/bin/env bash
# TEMPORARY DRILL (#6 review): another user's model must be removed by
# cleanup-models.sh between iterations. Dispatch with repeat=2: iteration 2
# fails if iteration 1's lab:bob/m1 survived the cleanup. Removed after the run.
set -euo pipefail
c=${LAB_CONTROLLER:?}
if timeout 60 juju show-model "$c:bob/m1" >/dev/null 2>&1; then
	echo "drill: $c:bob/m1 survived the cleanup between iterations"
	exit 1
fi
# add-user prints a registration token: never let it reach the log.
timeout 60 juju show-user -c "$c" bob >/dev/null 2>&1 || timeout 60 juju add-user -c "$c" bob >/dev/null 2>&1
timeout 300 juju add-model -c "$c" m1 --owner bob --no-switch >/dev/null
timeout 60 juju models --all -c "$c" --format=json | jq -r '.models[] | "drill: model \(.name) short-name=\(."short-name")"'
if [[ ${LAB_SUBSTRATE:-} == k8s ]]; then
	timeout 60 "$LAB_ROOT/scripts/lab-kubectl" get ns -L model.juju.is/name | sed 's/^/drill: ns /'
fi
exit 0
