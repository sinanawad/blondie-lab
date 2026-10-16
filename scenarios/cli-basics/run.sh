#!/usr/bin/env bash
# cli-basics: juju/juju tests/ cli suite (clouds, local charms, model config/defaults/constraints, unregister, block commands, diff-bundle) against the lab LXD controller.
# Skips come from skips.txt (also rendered into README.md by
# scripts/gen-suite-readme.sh). After a pass, every non-controller model (all
# users) must be gone within 10 min, else fail.
set -euo pipefail
suite=cli
cloud_args=()
here=$(cd "$(dirname "$0")" && pwd)
skips=$(cat "$here/skips.txt" "$here/alone.txt" | awk '$1 ~ /^test_/ {printf "%s%s", sep, $1; sep = ","}')
args=("${cloud_args[@]}")
[[ -z $skips ]] || args+=(-s "$skips")
# The suite's own destroy_model waits DESTROY_TIMEOUT (main.sh default 15m);
# 5m keeps a hung destroy inside TIMEOUT_MIN, so no-models-left.sh scores it
# fail rather than the iteration timeout scoring it error.
export DESTROY_TIMEOUT=5m
rc=0
"$LAB_ROOT/scripts/suite.sh" "${args[@]}" "$suite" || rc=$?
((rc == 0)) || exit "$rc"
# Tests in alone.txt run on their own after the suite, as upstream CI runs
# every cli test (main.sh <suite> <test>: a fresh `ensure test-cli`, then that
# test only). They are in the -s list above too.
while read -r t _; do
	[[ $t =~ ^test_[a-z0-9_]+$ ]] || continue
	"$LAB_ROOT/scripts/suite.sh" "${cloud_args[@]}" "$suite" "$t" || exit $?
done <"$here/alone.txt"
exec "$LAB_ROOT/scripts/no-models-left.sh" cli-basics 600
