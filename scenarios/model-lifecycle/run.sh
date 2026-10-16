#!/usr/bin/env bash
# model-lifecycle: juju/juju tests/ model suite (model config, multiple models, metrics, destroy, status) against the lab LXD controller.
# Skips come from skips.txt (also rendered into README.md by
# scripts/gen-suite-readme.sh). After a pass, every non-controller model (all
# users) must be gone within 10 min, else fail.
set -euo pipefail
suite=model
cloud_args=()
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
exec "$LAB_ROOT/scripts/no-models-left.sh" model-lifecycle 600
