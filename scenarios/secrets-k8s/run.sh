#!/usr/bin/env bash
# secrets-k8s: juju/juju tests/ secrets_k8s suite (charm and user secrets, drain, parallel adds, cross-model secrets) against the lab MicroK8s controller.
# Skips come from skips.txt (also rendered into README.md by
# scripts/gen-suite-readme.sh). After a pass, every non-controller model (all
# users) must be gone within 10 min, else fail.
set -euo pipefail
suite=secrets_k8s
cloud_args=(-c microk8s)
here=$(cd "$(dirname "$0")" && pwd)
skips=$(awk '$1 ~ /^test_/ {printf "%s%s", sep, $1; sep = ","}' "$here/skips.txt")
args=("${cloud_args[@]}")
[[ -z $skips ]] || args+=(-s "$skips")
# The suite's own destroy_model waits DESTROY_TIMEOUT (main.sh default 15m);
# 5m keeps a hung destroy inside TIMEOUT_MIN, so no-models-left.sh scores it
# fail rather than the iteration timeout scoring it error.
export DESTROY_TIMEOUT=5m
rc=0
"$LAB_ROOT/scripts/suite.sh" "${args[@]}" "$suite" || rc=$?
((rc == 0)) || exit "$rc"
# The suite's known leftovers (leftovers.txt) are destroyed here, by name, in
# the background: no-models-left.sh starts at once, so the whole teardown is
# one 10 min window and a hung destroy scores fail (the iteration's process
# kill reaps any straggler). Anything else still left is a leak, and
# no-models-left.sh fails it.
while read -r m; do
	[[ -z $m || $m == \#* ]] && continue
	echo "secrets-k8s: destroying known leftover admin/$m (background)"
	timeout 600 juju destroy-model --no-prompt --destroy-storage "$LAB_CONTROLLER:admin/$m" >/dev/null 2>&1 </dev/null &
done <"$here/leftovers.txt"
exec "$LAB_ROOT/scripts/no-models-left.sh" secrets-k8s 600
