#!/usr/bin/env bash
# Suite-backed scenario wrapper (design §4): runs juju/juju tests/main.sh
# against the lab controller and maps exit codes.
#   suite.sh [main.sh flags] <suite> [test]   e.g. suite.sh -s test_build smoke
# - main.sh's exit 1 becomes 2 (setup-error) only if a line of the *setup phase*
#   (output before the first "===> [   ] Running:", or before the second
#   "====> Reusing bootstrapped juju" line: suites whose tests don't use `run`,
#   such as sidecar, call `ensure` per test, and a leftover from test N found by
#   test N+1's ensure is a teardown failure, not infra) matches an anchored pattern
#   in scripts/infra-signatures.txt. The matched line goes to $LAB_SIGNAL_FILE
#   for run-scenario.sh to record as infra_signature. After a test started,
#   exit 1 stays fail.
# - Every other outcome is normalised to the lab exit-code contract, because
#   main.sh (bash -e) exits with whatever the failing command returned (juju
#   exits 2 on usage errors and client panics, and passes remote codes through):
#   0 with at least one "] Success: " line -> 0; 0 without one -> 3 (no test
#   ran, inconclusive); a signal (>= 128) stays as is (error); anything else
#   -> 1 (fail), including 2 and 3.
# - main.sh's work dir (tests/tmp.*, kept on failure) is copied into the
#   artifact; scrub.sh enforces the never-collect list and drops symlinks.
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
# Suites hand mktemp files to juju (model-config --file); the strictly confined
# juju snap has a private /tmp and can't open the runner's /tmp/tmp.* ("ERROR
# open /tmp/tmp.X: no such file", cli). Keep TMPDIR inside the tests checkout
# (a non-hidden path under $HOME, readable through the snap's home interface).
rm -rf lab-tmp && mkdir lab-tmp
export TMPDIR="$LAB_TESTS_DIR/lab-tmp"
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
		match=$(awk '/^===> \[   \] Running:/ {exit} /^====> Reusing bootstrapped juju/ && ++reuse == 2 {exit} {print}' "$out" |
			grep -E -m1 -f <(printf '%s\n' "$patterns") || true)
		if [[ -n $match ]]; then
			echo "suite.sh: infra signature in setup phase -> setup-error: $match"
			[[ -n ${LAB_SIGNAL_FILE:-} ]] && printf '%s\n' "$match" >"$LAB_SIGNAL_FILE"
			exit 2
		fi
	fi
fi
if ((rc == 0)); then
	# Unanchored: run() starts the line with \r\e[1A\e[0K.
	if grep -q '\] Success: ' "$out"; then exit 0; fi
	echo "suite.sh: main.sh exit 0 but no test ran (no '] Success:' line) -> 3 (inconclusive)"
	exit 3
fi
((rc >= 128)) && exit "$rc"
((rc == 1)) || echo "suite.sh: main.sh exit $rc -> 1 (fail)"
exit 1
