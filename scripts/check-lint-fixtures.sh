#!/usr/bin/env bash
# Asserts that each linter still FAILS on its known-bad fixture in lint-fixtures/,
# for the expected reason. Guards against a linter upgrade or config change that
# quietly stops catching a rule. Run from the repo root.
set -euo pipefail

ACTIONLINT=${ACTIONLINT:-actionlint}
ZIZMOR=${ZIZMOR:-zizmor}
SHELLCHECK=${SHELLCHECK:-shellcheck}
status=0

# expect_fail <name> <ERE that must appear in the output> <command...>
expect_fail() {
	local name=$1 pattern=$2 out rc=0
	shift 2
	out=$("$@" 2>&1) || rc=$?
	if [[ $rc -eq 0 ]]; then
		echo "NOT CAUGHT: ${name}: linter exited 0"
		printf '%s\n' "$out"
		status=1
	elif ! grep -Eq -- "$pattern" <<<"$out"; then
		echo "WRONG REASON: ${name}: exit ${rc}, output lacks /${pattern}/"
		printf '%s\n' "$out"
		status=1
	else
		echo "ok: ${name} (exit ${rc}, matched /${pattern}/)"
	fi
}

expect_fail "zizmor template injection" 'template-injection' \
	"$ZIZMOR" --config zizmor.yml --min-severity medium lint-fixtures/bad-injection.yml
expect_fail "zizmor unpinned action (hash-pin policy)" 'unpinned-uses' \
	"$ZIZMOR" --config zizmor.yml --min-severity medium lint-fixtures/unpinned-action.yml
expect_fail "actionlint syntax/expression error" '\[(syntax-check|expression)\]' \
	"$ACTIONLINT" -no-color lint-fixtures/actionlint-bad.yml
expect_fail "shellcheck SC2086" 'SC2086' \
	"$SHELLCHECK" lint-fixtures/sc2086.sh

exit "$status"
