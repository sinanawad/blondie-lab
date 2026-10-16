#!/usr/bin/env bash
# no-models-left.sh <name> [seconds]: after a passing suite, every non-controller
# model on $LAB_CONTROLLER must be gone within <seconds> (default 600): a suite's
# own teardown falls back to `destroy-model ... || true` on a reused controller,
# so this is where a teardown regression shows. Exit 0 when none is left, else 1.
set -euo pipefail
export LC_ALL=C
name=${1:?} limit=${2:-600}
[[ $limit =~ ^[0-9]+$ ]] || { echo "$name: bad timeout"; exit 1; }
deadline=$((SECONDS + limit))
while :; do
	left=$(timeout 60 juju models -c "${LAB_CONTROLLER:?}" --format=json |
		jq -r '.models // [] | .[] | select(((."is-controller") | tostring) != "true" and ."short-name" != "controller") | ."short-name"') ||
		left="(juju models failed)"
	[[ -z $left ]] && { echo "$name: teardown ok, no models left"; exit 0; }
	((SECONDS < deadline)) || break
	sleep 10
done
echo "$name: suite passed but its teardown left models after ${limit}s: ${left//$'\n'/ }"
exit 1
