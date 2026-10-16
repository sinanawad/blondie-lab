#!/usr/bin/env bash
# Between iterations (design §4 repeat semantics): destroy every non-controller
# model on the lab controller and wait until none is left, within one budget
# (default 300 s). Exit 0 when clean, 1 when the budget ran out.
set -euo pipefail
export LC_ALL=C

controller=${LAB_CONTROLLER:?}
budget=${LAB_CLEANUP_TIMEOUT:-300}
[[ $budget =~ ^[0-9]+$ ]] || { echo "bad LAB_CLEANUP_TIMEOUT"; exit 1; }
deadline=$((SECONDS + budget))

models() {
	timeout 60 juju models -c "$controller" --format=json |
		jq -r '.models // [] | .[] | select(((."is-controller") | tostring) != "true" and ."short-name" != "controller") | ."short-name"'
}
left=$(models) || { echo "cleanup: juju models failed"; exit 1; }
for m in $left; do
	echo "cleanup: destroying model $m"
	timeout 120 juju destroy-model --no-prompt --force --no-wait --destroy-storage "$controller:$m" || echo "cleanup: destroy-model $m returned non-zero"
done
while ((SECONDS < deadline)); do
	left=$(models) || left="?"
	if [[ -z $left ]]; then
		echo "cleanup: no models left"
		exit 0
	fi
	sleep 5
done
echo "cleanup: models still present after ${budget}s: $left"
exit 1
