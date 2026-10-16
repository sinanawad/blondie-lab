#!/usr/bin/env bash
# relations: juju/juju tests/ relations suite (relation data, departing units, relation-list, model-get, subordinates; packs local charms with charmcraft) against the lab LXD controller.
# Skips come from skips.txt (also rendered into README.md by
# scripts/gen-suite-readme.sh). After a pass, every non-controller model (all
# users) must be gone within 10 min, else fail.
set -euo pipefail
suite=relations
cloud_args=()
here=$(cd "$(dirname "$0")" && pwd)
skips=$(awk '$1 ~ /^test_/ {printf "%s%s", sep, $1; sep = ","}' "$here/skips.txt")
args=("${cloud_args[@]}")
[[ -z $skips ]] || args+=(-s "$skips")
rc=0
"$LAB_ROOT/scripts/suite.sh" "${args[@]}" "$suite" || rc=$?
((rc == 0)) || exit "$rc"
exec "$LAB_ROOT/scripts/no-models-left.sh" relations 600
