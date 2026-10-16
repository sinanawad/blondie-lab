#!/usr/bin/env bash
# Validates the dispatch inputs and the scenario contract before any setup.
# Inputs arrive only via env (LAB_IN_*), never interpolated into the workflow.
# On success: writes key=value outputs to $GITHUB_OUTPUT (or stdout) and exits 0.
# On failure: writes the reason to $LAB_ARTIFACT_DIR/validate-error.txt, prints
# a ::error:: line and exits 2 (verdict setup-error).
set -euo pipefail
export LC_ALL=C

SCENARIOS_DIR=${LAB_SCENARIOS_DIR:-scenarios}
ARTIFACT_DIR=${LAB_ARTIFACT_DIR:?LAB_ARTIFACT_DIR not set}
OUT=${GITHUB_OUTPUT:-/dev/stdout}
BUDGET_MAX=120
mkdir -p "$ARTIFACT_DIR"

fail() {
	printf '%s\n' "$*" >"$ARTIFACT_DIR/validate-error.txt"
	echo "::error::validate: $*"
	exit 2
}

substrate=${LAB_SUBSTRATE:-}
scenario=${LAB_IN_SCENARIO:-}
channel=${LAB_IN_JUJU_CHANNEL:-}
ref=${LAB_IN_REF:-}
tests_ref=${LAB_IN_TESTS_REF:-}
repeat=${LAB_IN_REPEAT:-}
request_id=${LAB_IN_REQUEST_ID:-}

re_scenario='^[a-z0-9][a-z0-9-]{0,63}$'
re_ref='^[A-Za-z0-9][A-Za-z0-9._/-]{0,99}$'
re_channel='^(latest|[0-9]+\.[0-9]+)/(stable|candidate|beta|edge)$'
re_request_id='^[A-Za-z0-9-]{1,64}$'

[[ $substrate == lxd || $substrate == k8s ]] || fail "substrate: must be lxd or k8s (workflow bug)"
[[ $scenario =~ $re_scenario ]] || fail "scenario: must match $re_scenario"
[[ $channel =~ $re_channel ]] || fail "juju_channel: must match $re_channel"

check_ref() {
	local name=$1 v=$2
	[[ -z $v ]] && return 0
	[[ $v =~ $re_ref ]] || fail "$name: must match $re_ref"
	# git check-ref-format rules the regex doesn't cover ('@' is outside its
	# character set, so '@{' can't occur).
	case $v in
	refs/* | *..* | *//* | */.* | *.lock | *.lock/* | */ | *.)
		fail "$name: refs/ prefix, '..', '//', a component starting with '.' or ending in '.lock', or a trailing '/' or '.' is not allowed"
		;;
	esac
}
check_ref ref "$ref"
check_ref tests_ref "$tests_ref"
[[ $repeat =~ ^([1-9]|10)$ ]] || fail "repeat: must be an integer 1..10"
if [[ -n $request_id ]]; then
	[[ $request_id =~ $re_request_id ]] || fail "request_id: must match $re_request_id"
fi

dir="$SCENARIOS_DIR/$scenario"
[[ -d $dir ]] || fail "scenario: $dir does not exist"
[[ -f $dir/run.sh ]] || fail "scenario: $dir/run.sh is missing"
[[ -f $dir/scenario.env ]] || fail "scenario: $dir/scenario.env is missing"

# scenario.env is parsed, never sourced: KEY=VALUE lines for known keys only.
SUBSTRATE='' TIMEOUT_MIN='' NEEDS_TESTS=0 NEEDS_JUJU=1 DEPS=''
while IFS= read -r line || [[ -n $line ]]; do
	[[ $line =~ ^[[:space:]]*(#.*)?$ ]] && continue
	[[ $line =~ ^([A-Z_]+)=(.*)$ ]] || fail "scenario.env: bad line: $line"
	key=${BASH_REMATCH[1]} val=${BASH_REMATCH[2]}
	case $key in
	SUBSTRATE) [[ $val =~ ^(lxd|k8s|any)$ ]] || fail "scenario.env: SUBSTRATE must be lxd, k8s or any"; SUBSTRATE=$val ;;
	TIMEOUT_MIN) [[ $val =~ ^[1-9][0-9]{0,2}$ ]] || fail "scenario.env: TIMEOUT_MIN must be a positive integer"; TIMEOUT_MIN=$val ;;
	NEEDS_TESTS) [[ $val =~ ^[01]$ ]] || fail "scenario.env: NEEDS_TESTS must be 0 or 1"; NEEDS_TESTS=$val ;;
	NEEDS_JUJU) [[ $val =~ ^[01]$ ]] || fail "scenario.env: NEEDS_JUJU must be 0 or 1"; NEEDS_JUJU=$val ;;
	DEPS) [[ $val =~ ^[a-z0-9\ -]*$ ]] || fail "scenario.env: DEPS must be space-separated [a-z0-9-] words"; DEPS=$val ;;
	*) fail "scenario.env: unknown key $key" ;;
	esac
done <"$dir/scenario.env"
[[ -n $SUBSTRATE ]] || fail "scenario.env: SUBSTRATE is required"
[[ -n $TIMEOUT_MIN ]] || fail "scenario.env: TIMEOUT_MIN is required"
[[ $SUBSTRATE == any || $SUBSTRATE == "$substrate" ]] ||
	fail "scenario $scenario needs SUBSTRATE=$SUBSTRATE, this workflow is $substrate"

# scenario_timeout must exceed the timeouts nested in it (design §2):
# per-iteration TIMEOUT_MIN + 1 min kill grace, 5 min cleanup between iterations, 5 margin.
scenario_timeout=$((TIMEOUT_MIN * repeat + repeat + 5 * (repeat - 1) + 5))
((scenario_timeout <= BUDGET_MAX)) ||
	fail "budget: scenario_timeout $scenario_timeout min (TIMEOUT_MIN=$TIMEOUT_MIN, repeat=$repeat) exceeds $BUDGET_MAX; use a smaller repeat and dispatch more runs"

# Not implemented yet: these fail as setup-error rather than doing something partial.
[[ -z $ref ]] || fail "ref: build mode is not implemented yet (plan PR-5)"
[[ $NEEDS_JUJU == 0 ]] || fail "scenario $scenario needs Juju; the $substrate substrate is not implemented yet (plan PR-3/PR-4)"
[[ -z $DEPS ]] || fail "DEPS: not implemented yet (plan PR-3)"
[[ $NEEDS_TESTS == 0 ]] || fail "NEEDS_TESTS=1: tests checkout is not implemented yet (plan PR-3)"
if [[ -n $tests_ref ]]; then
	echo "::warning::tests_ref is ignored: scenario $scenario has NEEDS_TESTS=0"
fi

{
	echo "scenario_timeout=$scenario_timeout"
	echo "timeout_min=$TIMEOUT_MIN"
	echo "needs_juju=$NEEDS_JUJU"
} >>"$OUT"
echo "validate: ok (scenario=$scenario substrate=$substrate repeat=$repeat TIMEOUT_MIN=$TIMEOUT_MIN scenario_timeout=$scenario_timeout)"
