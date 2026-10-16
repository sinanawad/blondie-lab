#!/usr/bin/env bash
# Between iterations (design §4 repeat semantics): destroy every non-controller
# model on the lab controller and wait until none is left and, on k8s
# (LAB_SUBSTRATE=k8s), until every juju model namespace is gone too: the
# namespaces of the models destroyed here and any other namespace labelled
# model.juju.is/name other than the controller's (a suite that destroyed its own
# model leaves it Terminating, and add-model of the same name then fails). Both
# waits share one budget (default 300 s). Exit 0 when clean, 1 when the budget
# ran out or the state can't be read.
set -euo pipefail
export LC_ALL=C

controller=${LAB_CONTROLLER:?}
budget=${LAB_CLEANUP_TIMEOUT:-300}
[[ $budget =~ ^[0-9]+$ ]] || { echo "bad LAB_CLEANUP_TIMEOUT"; exit 1; }
deadline=$((SECONDS + budget))
here=$(cd "$(dirname "$0")" && pwd)
kubectl="$here/lab-kubectl"

models() {
	timeout 60 juju models -c "$controller" --format=json |
		jq -r '.models // [] | .[] | select(((."is-controller") | tostring) != "true" and ."short-name" != "controller") | ."short-name"'
}
# Namespaces of juju models (label model.juju.is/name, not "controller").
model_namespaces() {
	timeout 60 "$kubectl" get ns -l model.juju.is/name -o json |
		jq -r '.items[] | select(.metadata.labels["model.juju.is/name"] != "controller") | .metadata.name'
}
left=$(models) || { echo "cleanup: juju models failed"; exit 1; }
destroyed=$left
for m in $left; do
	echo "cleanup: destroying model $m"
	timeout 120 juju destroy-model --no-prompt --force --no-wait --destroy-storage "$controller:$m" || echo "cleanup: destroy-model $m returned non-zero"
done
while :; do
	left=$(models) || left="?"
	[[ -z $left ]] && { echo "cleanup: no models left"; break; }
	((SECONDS < deadline)) || { echo "cleanup: models still present after ${budget}s: ${left//$'\n'/ }"; exit 1; }
	sleep 5
done
[[ ${LAB_SUBSTRATE:-} == k8s ]] || exit 0

# The models destroyed here are waited for by name, plus every labelled model
# namespace (seen now or appearing during the wait).
ns=$(model_namespaces) || { echo "cleanup: listing namespaces failed"; exit 1; }
declare -A want=()
for n in $destroyed $ns; do [[ $n =~ ^[a-z0-9-]{1,63}$ ]] && want[$n]=1; done
names="${!want[*]}"
echo "cleanup: waiting for model namespace(s) to be gone: ${names:-none}"
while :; do
	pending=""
	for n in "${!want[@]}"; do
		if out=$(timeout 30 "$kubectl" get ns "$n" -o name 2>&1); then
			pending+=" $n"
		elif [[ $out == *NotFound* ]]; then
			echo "cleanup: namespace $n gone (NotFound)"
			unset "want[$n]"
		else
			pending+=" $n(?)"
		fi
	done
	extra=$(model_namespaces) || { extra=""; pending+=" (namespace list failed)"; }
	for n in $extra; do
		[[ $n =~ ^[a-z0-9-]{1,63}$ && -z ${want[$n]:-} ]] || continue
		want[$n]=1
		pending+=" $n"
	done
	if [[ -z $pending ]]; then
		echo "cleanup: no model namespaces left"
		exit 0
	fi
	((SECONDS < deadline)) || { echo "cleanup: still present after ${budget}s:$pending"; exit 1; }
	sleep 5
done
