#!/usr/bin/env bash
# TEMPORARY drill (plan PR-3 acceptance, removed before merge): signature
# negative. A throwaway suite whose *in-test* step prints the exact bootstrap()
# leftover-model sentence (second ensure of the same model) and exits 1. It
# comes after the first "===> [   ] Running:" line, so it must stay fail with
# infra_signature null.
set -euo pipefail
mkdir -p "$LAB_TESTS_DIR/suites/labdrill"
cat >"$LAB_TESTS_DIR/suites/labdrill/task.sh" <<'SUITE'
run_labdrill_dup() {
	echo
	ensure "labdrill-dup" "${TEST_DIR}/labdrill-dup.log"
	ensure "labdrill-dup" "${TEST_DIR}/labdrill-dup.log"
}

test_labdrill() {
	(
		set_verbosity
		run "run_labdrill_dup"
	)
}
SUITE
exec "$LAB_ROOT/scripts/suite.sh" labdrill
