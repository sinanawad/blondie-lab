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
rc=0
"$LAB_ROOT/scripts/suite.sh" "${args[@]}" "$suite" || rc=$?
((rc == 0)) || exit "$rc"
exec "$LAB_ROOT/scripts/no-models-left.sh" secrets-k8s 600
