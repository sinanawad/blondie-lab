#!/usr/bin/env bash
# Bootstraps the lab controller (snap mode) on $LAB_CLOUD: localhost (LXD) or
# microk8s (juju's built-in cloud for strictly confined MicroK8s; this step runs
# under `sg snap_microk8s`). Full --debug output goes to
# $LAB_ARTIFACT_DIR/collect/bootstrap.log only (scrubbed before upload), not to
# the public step log. Bootstrap gets LAB_BOOTSTRAP_TIMEOUT seconds (default
# 1080, inside the 20 min step timeout so the step itself never kills it): on
# timeout the k8s state is dumped to collect/k8s-bootstrap-timeout/ *before*
# juju is killed (SIGKILL, so juju doesn't tear the namespace down first), and
# collect.sh dumps it again. Exit 2 (setup-error) on failure.
set -euo pipefail
export LC_ALL=C
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/lib.sh
. "$here/lib.sh"

controller=${LAB_CONTROLLER:?}
cloud=${LAB_CLOUD:?}
limit=${LAB_BOOTSTRAP_TIMEOUT:-1080}
[[ $cloud =~ ^(localhost|microk8s)$ ]] || setup_fail "LAB_CLOUD: unexpected value (workflow bug)"
[[ $limit =~ ^[1-9][0-9]*$ ]] || setup_fail "LAB_BOOTSTRAP_TIMEOUT: unexpected value (workflow bug)"
mkdir -p "${LAB_ARTIFACT_DIR:?}/collect"
log="$LAB_ARTIFACT_DIR/collect/bootstrap.log"
df -h >"$LAB_ARTIFACT_DIR/collect/df-before-bootstrap.txt" 2>&1 || true
if [[ $cloud == microk8s ]]; then
	# The juju snap reads MicroK8s' credentials through its peers content plug.
	conn=$(snap connections juju 2>/dev/null | awk '$2 == "juju:peers" {print $3}')
	echo "juju:peers -> ${conn:-none}"
	[[ -n $conn && $conn != - ]] || setup_fail "juju:peers is not connected to microk8s (juju can't see the microk8s cloud)"
	timeout 60 juju clouds --client --format=json | jq -e '.microk8s.type == "k8s"' >/dev/null ||
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
	echo "bootstrap still running after ${limit}s"
	if [[ $cloud == microk8s ]]; then
		"$here/k8s-dump.sh" "$LAB_ARTIFACT_DIR/collect/k8s-bootstrap-timeout" "$LAB_ARTIFACT_DIR/collect/k8s-bootstrap-timeout.log"
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
juju switch "$controller" >/dev/null
agent=$(juju show-controller "$controller" --format=json | jq -r --arg c "$controller" '.[$c].details["agent-version"] // empty')
[[ $agent =~ ^[0-9]+\.[0-9]+[.0-9A-Za-z-]*$ ]] || setup_fail "no controller agent version after bootstrap"
# Snap mode bootstraps the packaged agent from the streams unless juju had to
# use its own local jujud (design §4, PR-5 identity check).
if grep -q 'Looking for packaged Juju agent version' "$log" && ! grep -q 'Preparing local Juju agent binary' "$log"; then
	agent_source=packaged
elif grep -q 'Preparing local Juju agent binary' "$log"; then
	agent_source=local
else
	agent_source=unknown
fi
state_set controller_agent_version "$agent"
state_set agent_source "$agent_source"
echo "bootstrapped $controller on $cloud (agent $agent, $agent_source)"
