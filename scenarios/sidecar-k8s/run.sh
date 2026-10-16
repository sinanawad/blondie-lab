#!/usr/bin/env bash
# sidecar-k8s: juju/juju tests/ sidecar suite (sidecar charm deploy/remove, pebble notices and checks, credential-get, rootless) against the lab MicroK8s controller.
# Skips come from skips.txt (also rendered into README.md by
# scripts/gen-suite-readme.sh). After a pass, every non-controller model (all
# users) must be gone within 10 min, else fail.
set -euo pipefail
suite=sidecar
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
exec "$LAB_ROOT/scripts/no-models-left.sh" sidecar-k8s 600
