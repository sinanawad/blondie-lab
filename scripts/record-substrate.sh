#!/usr/bin/env bash
# record-substrate.sh <snap>: records substrate_snap_* for a substrate set up by
# an action (LXD via canonical/setup-lxd). Exit 2 (setup-error) on failure.
set -euo pipefail
export LC_ALL=C
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"
[[ ${1:-} =~ ^(lxd|microk8s)$ ]] || setup_fail "record-substrate: unexpected snap name (workflow bug)"
record_substrate "$1"
