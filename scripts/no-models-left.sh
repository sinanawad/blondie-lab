#!/usr/bin/env bash
# no-models-left.sh <name> [seconds]: after a passing suite, every non-controller
# model on $LAB_CONTROLLER (all users', `juju models --all`) must be gone within <seconds> (default 600) and, on k8s
# (LAB_SUBSTRATE=k8s), so must every juju model namespace (label
# model.juju.is/name other than "controller"), within the same deadline: a
# suite's own teardown falls back to `destroy-model ... || true` on a reused
# controller, so this is where a teardown regression shows. Exit 0 when nothing
# is left, else 1 (fail).
set -euo pipefail
export LC_ALL=C
name=${1:?} limit=${2:-600}
[[ $limit =~ ^[0-9]+$ ]] || { echo "$name: bad timeout"; exit 1; }
here=$(cd "$(dirname "$0")" && pwd)
deadline=$((SECONDS + limit))
while :; do
	left=$(timeout 60 juju models --all -c "${LAB_CONTROLLER:?}" --format=json |
		jq -r '.models // [] | .[] | select(((."is-controller") | tostring) != "true") | (if (.name // "") | contains("/") then .name else ."short-name" end) | select(. != "admin/controller" and . != "controller")') ||
		left="(juju models failed)"
	[[ -z $left ]] && break
	((SECONDS < deadline)) || { echo "$name: suite passed but its teardown left models after ${limit}s: ${left//$'\n'/ }"; exit 1; }
	sleep 10
done
if [[ ${LAB_SUBSTRATE:-} == k8s ]]; then
	while :; do
		ns=$(timeout 60 "$here/lab-kubectl" get ns -l model.juju.is/name -o json |
			jq -r '.items[] | select(.metadata.labels["model.juju.is/name"] != "controller") | .metadata.name') ||
			ns="(namespace list failed)"
		[[ -z $ns ]] && break
		((SECONDS < deadline)) || { echo "$name: suite passed but model namespace(s) left after ${limit}s: ${ns//$'\n'/ }"; exit 1; }
		sleep 10
	done
	echo "$name: teardown ok, no models or model namespaces left"
	exit 0
fi
echo "$name: teardown ok, no models left"
exit 0
