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
	setup_fail "juju bootstrap localhost $controller failed (see collect/bootstrap.log in the artifact)"
fi
juju switch "$controller" >/dev/null
agent=$(juju show-controller "$controller" --format=json | jq -r --arg c "$controller" '.[$c].details["agent-version"] // empty')
state_set controller_agent_version "$agent"
echo "bootstrapped $controller (agent $agent)"
