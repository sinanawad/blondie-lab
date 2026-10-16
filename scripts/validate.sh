#!/usr/bin/env bash
# Validates the dispatch inputs and the scenario contract before any setup.
# Inputs arrive only via env (LAB_IN_*), never interpolated into the workflow.
#
# Per-field record: each field that passes its check is appended as key=value
# to $LAB_STATE_DIR/valid.env (harness-owned, outside the uploaded artifact dir).
# verdict.sh reads values only from there, so a field that never passed is null.
# request_id is checked first so it is echoed in verdict.json for any later failure.
#
# On success: writes key=value outputs to $GITHUB_OUTPUT (or stdout) and exits 0.
# On failure: writes the reason to $LAB_STATE_DIR/validate-error.txt, prints
# a ::error:: line and exits 2 (verdict setup-error).
set -euo pipefail
export LC_ALL=C

SCENARIOS_DIR=${LAB_SCENARIOS_DIR:-scenarios}
STATE_DIR=${LAB_STATE_DIR:?LAB_STATE_DIR not set}
OUT=${GITHUB_OUTPUT:-/dev/stdout}
BUDGET_MAX=120
mkdir -p "$STATE_DIR"
VALID="$STATE_DIR/valid.env"
: >"$VALID"
rm -f "$STATE_DIR/validate-error.txt"

fail() {
	printf '%s\n' "$*" >"$STATE_DIR/validate-error.txt"
	echo "::error::validate: $*"
	exit 2
}
ok() { printf '%s=%s\n' "$1" "$2" >>"$VALID"; } # only called with regex-checked values

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

if [[ -n $request_id ]]; then
	[[ $request_id =~ $re_request_id ]] || fail "request_id: must match $re_request_id"
fi
ok request_id "$request_id"
[[ $substrate == lxd || $substrate == k8s ]] || fail "substrate: must be lxd or k8s (workflow bug)"
ok substrate "$substrate"
[[ $scenario =~ $re_scenario ]] || fail "scenario: must match $re_scenario"
ok scenario "$scenario"
[[ $channel =~ $re_channel ]] || fail "juju_channel: must match $re_channel"
ok juju_channel "$channel"

check_ref() {
	local name=$1 v=$2
	if [[ -n $v ]]; then
		[[ $v =~ $re_ref ]] || fail "$name: must match $re_ref"
		# git check-ref-format rules the regex doesn't cover ('@' is outside its
		# character set, so '@{' can't occur).
		case $v in
		refs/* | *..* | *//* | */.* | *.lock | *.lock/* | */ | *.)
			fail "$name: refs/ prefix, '..', '//', a component starting with '.' or ending in '.lock', or a trailing '/' or '.' is not allowed"
			;;
		esac
	fi
	ok "$name" "$v"
}
check_ref ref "$ref"
check_ref tests_ref "$tests_ref"
[[ $repeat =~ ^([1-9]|10)$ ]] || fail "repeat: must be an integer 1..10"
ok repeat "$repeat"

dir="$SCENARIOS_DIR/$scenario"
[[ -d $dir ]] || fail "scenario: $dir does not exist"
[[ -f $dir/run.sh ]] || fail "scenario: $dir/run.sh is missing"
[[ -f $dir/scenario.env ]] || fail "scenario: $dir/scenario.env is missing"

# scenario.env is parsed, never sourced: KEY=VALUE lines for known keys only,
# each at most once.
SUBSTRATE='' TIMEOUT_MIN='' NEEDS_TESTS=0 NEEDS_JUJU=1 DEPS=''
declare -A seen=()
while IFS= read -r line || [[ -n $line ]]; do
	[[ $line =~ ^[[:space:]]*(#.*)?$ ]] && continue
	[[ $line =~ ^([A-Z_]+)=(.*)$ ]] || fail "scenario.env: bad line: $line"
	key=${BASH_REMATCH[1]} val=${BASH_REMATCH[2]}
	case $key in
	SUBSTRATE | TIMEOUT_MIN | NEEDS_TESTS | NEEDS_JUJU | DEPS) ;;
	*) fail "scenario.env: unknown key $key" ;;
	esac
	[[ -z ${seen[$key]:-} ]] || fail "scenario.env: duplicate key $key"
	seen[$key]=1
	case $key in
	SUBSTRATE) [[ $val =~ ^(lxd|k8s|any)$ ]] || fail "scenario.env: SUBSTRATE must be lxd, k8s or any"; SUBSTRATE=$val ;;
	TIMEOUT_MIN) [[ $val =~ ^[1-9][0-9]{0,2}$ ]] || fail "scenario.env: TIMEOUT_MIN must be a positive integer"; TIMEOUT_MIN=$val ;;
	NEEDS_TESTS) [[ $val =~ ^[01]$ ]] || fail "scenario.env: NEEDS_TESTS must be 0 or 1"; NEEDS_TESTS=$val ;;
	NEEDS_JUJU) [[ $val =~ ^[01]$ ]] || fail "scenario.env: NEEDS_JUJU must be 0 or 1"; NEEDS_JUJU=$val ;;
	DEPS) [[ $val =~ ^[a-z0-9\ -]*$ ]] || fail "scenario.env: DEPS must be space-separated [a-z0-9-] words"; DEPS=$val ;;
	esac
done <"$dir/scenario.env"
[[ -n $SUBSTRATE ]] || fail "scenario.env: SUBSTRATE is required"
[[ -n $TIMEOUT_MIN ]] || fail "scenario.env: TIMEOUT_MIN is required"
ok needs_juju "$NEEDS_JUJU"
ok needs_tests "$NEEDS_TESTS"
[[ $SUBSTRATE == any || $SUBSTRATE == "$substrate" ]] ||
	fail "scenario $scenario needs SUBSTRATE=$SUBSTRATE, this workflow is $substrate"

# scenario_timeout must exceed the timeouts nested in it (design §2):
# per-iteration TIMEOUT_MIN + 1 min kill grace, 5 min cleanup between iterations, 5 margin.
scenario_timeout=$((TIMEOUT_MIN * repeat + repeat + 5 * (repeat - 1) + 5))
((scenario_timeout <= BUDGET_MAX)) ||
	fail "budget: scenario_timeout $scenario_timeout min (TIMEOUT_MIN=$TIMEOUT_MIN, repeat=$repeat) exceeds $BUDGET_MAX; use a smaller repeat and dispatch more runs"

# An explicit input is never silently ignored.
if [[ $NEEDS_JUJU == 0 ]]; then
	# No substrate is set up and no Juju is installed for these scenarios.
	[[ $SUBSTRATE == any ]] || fail "scenario.env: NEEDS_JUJU=0 requires SUBSTRATE=any"
	[[ -z $ref ]] || fail "ref: not used by scenario $scenario (NEEDS_JUJU=0)"
	[[ -z $tests_ref ]] || fail "tests_ref: not used by scenario $scenario (NEEDS_JUJU=0)"
	[[ $NEEDS_TESTS == 0 && -z $DEPS ]] || fail "scenario.env: NEEDS_JUJU=0 excludes NEEDS_TESTS=1 and DEPS"
else
	[[ $NEEDS_TESTS == 1 || -z $tests_ref ]] || fail "tests_ref: not used by scenario $scenario (NEEDS_TESTS=0)"
	# Not implemented yet: these fail as setup-error rather than doing something partial.
	[[ -z $ref ]] || fail "ref: build mode is not implemented yet (plan PR-5)"
	# An explicit tests_ref runs code from that ref in the job, so it needs the
	# ref trust check (design §8), which lands with build mode.
	[[ -z $tests_ref ]] || fail "tests_ref: an explicit tests_ref needs the ref trust check (plan PR-5); omit it to use the snap's git-commit"
	# DEPS words must be in the vocabulary deps.sh installs from (fail in seconds,
	# not after the LXD and juju setup).
	for d in $DEPS; do
		awk -v d="$d" '$1 == d { f = 1 } END { exit !f }' "$(dirname "$0")/deps-vocab.txt" ||
			fail "scenario.env: DEPS: unknown dependency '$d' (vocabulary: scripts/deps-vocab.txt)"
	done
fi

{
	echo "scenario=$scenario"
	echo "repeat=$repeat"
	echo "scenario_timeout=$scenario_timeout"
	echo "timeout_min=$TIMEOUT_MIN"
	echo "needs_juju=$NEEDS_JUJU"
	echo "needs_tests=$NEEDS_TESTS"
	echo "deps=$DEPS"
	echo "juju_channel=$channel"
} >>"$OUT"
echo "validate: ok (scenario=$scenario substrate=$substrate repeat=$repeat TIMEOUT_MIN=$TIMEOUT_MIN scenario_timeout=$scenario_timeout)"
