#!/usr/bin/env bash
# record-substrate.sh <snap>: records substrate_snap_* for a substrate set up by
# an action (LXD via canonical/setup-lxd). `record-substrate.sh --dep lxd`
# records LXD set up only for charmcraft on a k8s runner as dep_lxd instead
# (verdict.deps[]); held either way. Exit 2 (setup-error) on failure.
set -euo pipefail
export LC_ALL=C
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"
if [[ ${1:-} == --dep ]]; then
	# LXD set up only for a dependency (charmcraft on a k8s runner).
	[[ ${2:-} == lxd ]] || setup_fail "record-substrate: unexpected dep snap name (workflow bug)"
	record_dep_snap lxd
	exit 0
fi
[[ ${1:-} =~ ^(lxd|microk8s)$ ]] || setup_fail "record-substrate: unexpected snap name (workflow bug)"
record_substrate "$1"
