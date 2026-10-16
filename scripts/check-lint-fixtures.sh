#!/usr/bin/env bash
# Asserts that each linter still FAILS on its known-bad fixture in lint-fixtures/,
# with a real finding (not a config or usage error) for the expected rule.
# Guards against a linter upgrade or config change that quietly stops catching a
# rule, and against zizmor silently dropping to offline mode (impostor-commit is
# an online-only audit). Run from the repo root; zizmor needs GH_TOKEN.
set -euo pipefail
export LC_ALL=C

ACTIONLINT=${ACTIONLINT:-actionlint}
ZIZMOR=${ZIZMOR:-zizmor}
SHELLCHECK=${SHELLCHECK:-shellcheck}
status=0

bad() {
	echo "FAIL: $1"
	printf '%s\n' "$2"
	status=1
}

# zizmor exits 11-14 when it reports findings and 1-3 on errors; require a
# finding and check the audit id in the JSON output.
expect_zizmor() {
	local name=$1 ident=$2 file=$3 out rc=0
	out=$("$ZIZMOR" --config zizmor.yml --min-severity low --format json "$file" 2>/dev/null) || rc=$?
	if [[ $rc -lt 10 ]]; then
		bad "${name}: zizmor exit ${rc} (want >= 10, a finding)" "$out"
	elif ! jq -e --arg id "$ident" 'any(.[]; .ident == $id)' <<<"$out" >/dev/null; then
		bad "${name}: no ${ident} finding" "$out"
	else
		echo "ok: ${name} (exit ${rc}, finding ${ident})"
	fi
}

# expect_rc1 <name> <command...> -- <ERE>... : exit must be exactly 1 (findings,
# not a usage/fatal error) and every ERE must appear in the output.
expect_rc1() {
	local name=$1 out rc=0 p
	shift
	local cmd=()
	while [[ $1 != -- ]]; do cmd+=("$1"); shift; done
	shift
	out=$("${cmd[@]}" 2>&1) || rc=$?
	if [[ $rc -ne 1 ]]; then
		bad "${name}: exit ${rc} (want 1)" "$out"
		return
	fi
	for p in "$@"; do
		if ! grep -Eq -- "$p" <<<"$out"; then
			bad "${name}: output lacks /${p}/" "$out"
			return
		fi
	done
	echo "ok: ${name} (exit 1, matched $*)"
}

expect_zizmor "zizmor template injection" template-injection lint-fixtures/bad-injection.yml
expect_zizmor "zizmor unpinned action" unpinned-uses lint-fixtures/unpinned-action.yml
expect_zizmor "zizmor checkout without persist-credentials: false" artipacked lint-fixtures/no-persist-credentials.yml
expect_zizmor "zizmor impostor commit (proves online mode)" impostor-commit lint-fixtures/impostor-commit.yml
expect_rc1 "actionlint unknown key + bad expression" \
	"$ACTIONLINT" -no-color lint-fixtures/actionlint-bad.yml -- '\[syntax-check\]$' '\[expression\]$'
expect_rc1 "shellcheck SC2086" \
	"$SHELLCHECK" -f gcc lint-fixtures/sc2086.sh -- '\[SC2086\]$'

exit "$status"
