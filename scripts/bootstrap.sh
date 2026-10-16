#!/usr/bin/env bash
# Bootstraps the lab controller on $LAB_CLOUD: localhost (LXD) or microk8s
# (juju's built-in cloud for strictly confined MicroK8s; this step runs under
# `sg snap_microk8s`). Full --debug output goes to
# $LAB_ARTIFACT_DIR/collect/bootstrap.log only (scrubbed before upload), not to
# the public step log. Exit 2 (setup-error) on failure.
#
# Time budget (test-harness.sh checks it against the step's timeout-minutes in
# _run.yml): preflight <= 60 s, bootstrap LAB_BOOTSTRAP_TIMEOUT (set in the
# step env; 900 s default), timeout dump <= 155 s, post-bootstrap <= 60 s.
# On timeout juju is SIGSTOPped first (a stopped juju can't progress or run
# its interrupt cleanup, which deletes the controller namespace; a later
# SIGINT from the runner stays pending), the k8s state is dumped to
# collect/k8s-bootstrap-timeout/, then juju is SIGKILLed.
set -euo pipefail
export LC_ALL=C
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/lib.sh
. "$here/lib.sh"

controller=${LAB_CONTROLLER:?}
cloud=${LAB_CLOUD:?}
source=${LAB_JUJU_SOURCE:?}
limit=${LAB_BOOTSTRAP_TIMEOUT:-900}
[[ $cloud =~ ^(localhost|microk8s)$ ]] || setup_fail "LAB_CLOUD: unexpected value (workflow bug)"
[[ $source =~ ^(snap|build)$ ]] || setup_fail "LAB_JUJU_SOURCE: unexpected value (workflow bug)"
[[ $limit =~ ^[1-9][0-9]*$ ]] || setup_fail "LAB_BOOTSTRAP_TIMEOUT: unexpected value (workflow bug)"
mkdir -p "${LAB_ARTIFACT_DIR:?}/collect"
log="$LAB_ARTIFACT_DIR/collect/bootstrap.log"
df -h >"$LAB_ARTIFACT_DIR/collect/df-before-bootstrap.txt" 2>&1 || true
if [[ $cloud == microk8s ]]; then
	# The juju snap reads MicroK8s' credentials through its peers content plug;
	# a non-snap (build mode) juju reads /var/snap/microk8s/current directly.
	if [[ $source == snap ]]; then
		conn=$(timeout 30 snap connections juju 2>/dev/null | awk '$2 == "juju:peers" {print $3}') || conn=""
		echo "juju:peers -> ${conn:-none}"
		[[ -n $conn && $conn != - ]] || setup_fail "juju:peers is not connected to microk8s (juju can't see the microk8s cloud)"
	fi
	timeout 30 juju clouds --client --format=json | jq -e '.microk8s.type == "k8s"' >/dev/null ||
		setup_fail "juju does not list the built-in microk8s cloud"
fi
# BOOTSTRAP_ADDITIONAL_ARGS is a fixed string from the workflow (copied from
# juju/juju smoke.yml), split on purpose.
# shellcheck disable=SC2086
juju bootstrap "$cloud" "$controller" --debug ${BOOTSTRAP_ADDITIONAL_ARGS:-} >"$log" 2>&1 &
pid=$!
deadline=$((SECONDS + limit))
while kill -0 "$pid" 2>/dev/null && ((SECONDS < deadline)); do sleep 2; done
if kill -0 "$pid" 2>/dev/null; then
	kill -STOP "$pid" 2>/dev/null || true
	echo "bootstrap still running after ${limit}s; juju stopped (SIGSTOP)"
	if [[ $cloud == microk8s ]]; then
		timeout -k 5 150 "$here/k8s-dump.sh" "$LAB_ARTIFACT_DIR/collect/k8s-bootstrap-timeout" "$LAB_ARTIFACT_DIR/collect/k8s-bootstrap-timeout.log" ||
			echo "k8s dump cut at 150s"
		echo "k8s state dumped to collect/k8s-bootstrap-timeout/ before teardown"
	fi
	kill -KILL "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null || true
	state_set bootstrap_failed 1
	setup_fail "juju bootstrap $cloud $controller timed out after ${limit}s (see collect/bootstrap.log in the artifact)"
fi
rc=0
wait "$pid" || rc=$?
if ((rc != 0)); then
	state_set bootstrap_failed 1
	setup_fail "juju bootstrap $cloud $controller failed (see collect/bootstrap.log in the artifact)"
fi
timeout 20 juju switch "$controller" >/dev/null || setup_fail "juju switch $controller failed"
agent=$(timeout 20 juju show-controller "$controller" --format=json | jq -r --arg c "$controller" '.[$c].details["agent-version"] // empty') || agent=""
[[ $agent =~ ^[0-9]+\.[0-9]+[.0-9A-Za-z-]*$ ]] || setup_fail "no controller agent version after bootstrap"
if [[ $cloud == microk8s ]]; then
	# On k8s the agent is the controller pod's image: record every container's
	# image and digest (PR-5 compares the digest, PR-7 watches it for drift).
	# Snap mode can't run a local agent on k8s, so the api-server image being
	# the default repo's jujud-operator:<agent version> means packaged.
	pod=$(timeout 20 "$here/lab-kubectl" -n "controller-$controller" get pod controller-0 -o json) ||
		setup_fail "could not read pod controller-0 in controller-$controller"
	images=$(jq -c '[(.status.initContainerStatuses // [])[], (.status.containerStatuses // [])[] | {name, image, imageID}]' <<<"$pod") ||
		setup_fail "could not parse the controller pod's container statuses"
	api_image=$(jq -r '.[] | select(.name == "api-server") | .image' <<<"$images")
	if [[ $source == snap && $api_image == "ghcr.io/juju/jujud-operator:$agent" ]]; then
		agent_source=packaged
	else
		agent_source=unknown
	fi
	state_set controller_images "$images"
	echo "controller images: $images"
# Snap mode bootstraps the packaged agent from the streams unless juju had to
# use its own local jujud (design §4, PR-5 identity check).
elif grep -q 'Looking for packaged Juju agent version' "$log" && ! grep -q 'Preparing local Juju agent binary' "$log"; then
	agent_source=packaged
elif grep -q 'Preparing local Juju agent binary' "$log"; then
	agent_source=local
else
	agent_source=unknown
fi
state_set controller_agent_version "$agent"
state_set agent_source "$agent_source"
echo "bootstrapped $controller on $cloud (agent $agent, $agent_source)"
