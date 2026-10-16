#!/usr/bin/env bash
# selftest-flaky: fails on even iterations, passes on odd ones.
set -euo pipefail
if ((LAB_ITERATION % 2 == 0)); then
	echo "selftest-flaky: iteration ${LAB_ITERATION} fails"
	exit 1
fi
echo "selftest-flaky: iteration ${LAB_ITERATION} passes"
