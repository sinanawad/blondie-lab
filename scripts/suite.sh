#!/usr/bin/env bash
# Suite-backed scenario wrapper (design §4): runs juju/juju tests/main.sh
# against the lab controller and maps exit codes.
#   suite.sh [main.sh flags] <suite> [test]   e.g. suite.sh -s test_build smoke
# - main.sh's exit 1 becomes 2 (setup-error) only if a line of the *setup phase*
#   (output before the first "===> [   ] Running:") matches an anchored pattern
#   in scripts/infra-signatures.txt. The matched line goes to $LAB_SIGNAL_FILE
#   for run-scenario.sh to record as infra_signature. After a test started,
#   exit 1 stays fail.
# - main.sh's work dir (tests/tmp.*, kept on failure) is copied into the artifact.
set -euo pipefail
export LC_ALL=C

: "${LAB_TESTS_DIR:?}" "${LAB_CONTROLLER:?}" "${LAB_ARTIFACT_DIR:?}" "${LAB_ITERATION:?}"
here=$(cd "$(dirname "$0")" && pwd)
sigs=${LAB_INFRA_SIGNATURES:-$here/infra-signatures.txt}

for t in curl yq shellcheck; do
	command -v "$t" >/dev/null || { echo "suite.sh: missing $t (preflight)"; exit 2; }
done

out=$(mktemp)
trap 'rm -f "$out"' EXIT
cd "$LAB_TESTS_DIR"
rm -rf tmp.*
rc=0
# BOOTSTRAP_BASE stays unset so bootstrap() reuses the controller (design §4).
env -u BOOTSTRAP_BASE ./main.sh -l "$LAB_CONTROLLER" "$@" 2>&1 | tee "$out" || rc=${PIPESTATUS[0]}

for d in tmp.*; do
	[[ -d $d ]] || continue
	mkdir -p "$LAB_ARTIFACT_DIR/suite-i$LAB_ITERATION"
	cp -r "$d" "$LAB_ARTIFACT_DIR/suite-i$LAB_ITERATION/" || true
	rm -rf "$d"
done

if ((rc == 1)); then
	patterns=$(grep -vE '^[[:space:]]*(#|$)' "$sigs" || true)
	if [[ -n $patterns ]]; then
		match=$(awk '/^===> \[   \] Running:/ {exit} {print}' "$out" | grep -E -m1 -f <(printf '%s\n' "$patterns") || true)
		if [[ -n $match ]]; then
			echo "suite.sh: infra signature in setup phase -> setup-error: $match"
			[[ -n ${LAB_SIGNAL_FILE:-} ]] && printf '%s\n' "$match" >"$LAB_SIGNAL_FILE"
			exit 2
		fi
	fi
fi
exit "$rc"
