#!/usr/bin/env bash
# Bootstraps the lab controller on LXD (snap mode). Full --debug output goes to
# $LAB_ARTIFACT_DIR/collect/bootstrap.log only (scrubbed before upload), not to
# the public step log. Exit 2 (setup-error) on failure.
set -euo pipefail
export LC_ALL=C
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

controller=${LAB_CONTROLLER:?}
mkdir -p "${LAB_ARTIFACT_DIR:?}/collect"
log="$LAB_ARTIFACT_DIR/collect/bootstrap.log"
df -h >"$LAB_ARTIFACT_DIR/collect/df-before-bootstrap.txt" 2>&1 || true
# BOOTSTRAP_ADDITIONAL_ARGS is a fixed string from the workflow (copied from
# juju/juju smoke.yml), split on purpose.
# shellcheck disable=SC2086
if ! juju bootstrap localhost "$controller" --debug ${BOOTSTRAP_ADDITIONAL_ARGS:-} >"$log" 2>&1; then
	state_set bootstrap_failed 1
	setup_fail "juju bootstrap localhost $controller failed (see collect/bootstrap.log in the artifact)"
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
echo "bootstrapped $controller (agent $agent, $agent_source)"
