#!/usr/bin/env bash
# Offline unit tests for validate.sh, run-scenario.sh and verdict.sh (no Juju,
# no network). Run by lint.yml on every PR; run from the repo root.
set -euo pipefail
export LC_ALL=C

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
status=0
pass() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; status=1; }

# --- validate.sh -------------------------------------------------------------
mk() { # mk <name> <scenario.env lines...>
	local name=$1
	shift
	mkdir -p "$tmp/scen/$name"
	printf '#!/usr/bin/env bash\nexit 0\n' >"$tmp/scen/$name/run.sh"
	printf '%s\n' "$@" >"$tmp/scen/$name/scenario.env"
}
mk ok SUBSTRATE=any TIMEOUT_MIN=2 NEEDS_JUJU=0
mk lxd-only SUBSTRATE=lxd TIMEOUT_MIN=2 NEEDS_JUJU=0
mk t6 SUBSTRATE=any TIMEOUT_MIN=6 NEEDS_JUJU=0
mk t7 SUBSTRATE=any TIMEOUT_MIN=7 NEEDS_JUJU=0
mk juju SUBSTRATE=any TIMEOUT_MIN=2
# shellcheck disable=SC2016 # literal on purpose: must be rejected, never run
mk badkey SUBSTRATE=any TIMEOUT_MIN=2 EVIL='$(id)'

# expect <want rc> <description> <scenario> <repeat> [VAR=value ...]
expect() {
	local want=$1 desc=$2 scen=$3 rep=$4 rc=0
	shift 4
	env -i PATH="$PATH" LAB_SCENARIOS_DIR="$tmp/scen" LAB_ARTIFACT_DIR="$tmp/art" \
		GITHUB_OUTPUT="$tmp/out" LAB_SUBSTRATE=k8s LAB_IN_SCENARIO="$scen" \
		LAB_IN_JUJU_CHANNEL=4.0/stable LAB_IN_REPEAT="$rep" "$@" \
		bash scripts/validate.sh >"$tmp/log" 2>&1 || rc=$?
	if [[ $rc -eq $want ]]; then pass "validate: $desc (exit $rc)"; else bad "validate: $desc: exit $rc, want $want"; cat "$tmp/log"; fi
}
expect 0 "valid input" ok 1
expect 0 "budget boundary TIMEOUT_MIN=6 repeat=10 = 120" t6 10
expect 2 "budget TIMEOUT_MIN=7 repeat=10 = 130" t7 10
expect 2 "repeat=11" ok 11
expect 2 "repeat=0" ok 0
expect 2 "repeat=01" ok 01
expect 2 "scenario ../x" ../x 1
expect 2 "scenario that doesn't exist" nope 1
expect 2 "SUBSTRATE mismatch (lxd scenario on k8s)" lxd-only 1
expect 2 "needs Juju (not implemented yet)" juju 1
expect 2 "unknown scenario.env key" badkey 1
expect 2 "juju_channel 4.0/foo" ok 1 LAB_IN_JUJU_CHANNEL=4.0/foo
expect 2 "ref -x" ok 1 LAB_IN_REF=-x
expect 2 "ref refs/pull/1/head" ok 1 LAB_IN_REF=refs/pull/1/head
expect 2 "ref a/.b" ok 1 LAB_IN_REF=a/.b
expect 2 "ref v4.0." ok 1 LAB_IN_REF=v4.0.
expect 2 "ref v4.0.14 (build mode not implemented yet)" ok 1 LAB_IN_REF=v4.0.14
expect 2 "request_id 'a b'" ok 1 "LAB_IN_REQUEST_ID=a b"
expect 0 "request_id uuid" ok 1 LAB_IN_REQUEST_ID=0f8fad5b-d9cb-469f-a165-70867728950e
if grep -qx 'scenario_timeout=120' "$tmp/out"; then pass "validate: scenario_timeout output"; else bad "validate: scenario_timeout=120 missing from outputs"; fi

# --- run-scenario.sh + verdict.sh -------------------------------------------
# run_case <scenario> <repeat> <want verdict> <want results> <want failed>
run_case() {
	local scen=$1 rep=$2 want=$3 want_n=$4 want_failed=$5 art="$tmp/art-$1-$2" got n f
	rm -rf "$art"
	env -i PATH="$PATH" LAB_SCENARIO="$scen" LAB_REPEAT="$rep" LAB_TIMEOUT_MIN=1 \
		LAB_ARTIFACT_DIR="$art" LAB_SUBSTRATE=lxd \
		bash scripts/run-scenario.sh >"$tmp/log" 2>&1
	env -i PATH="$PATH" LAB_ARTIFACT_DIR="$art" VALIDATE_OUTCOME=success SCENARIO_OUTCOME=success \
		LAB_SUBSTRATE=lxd LAB_IN_SCENARIO="$scen" LAB_IN_JUJU_CHANNEL=4.0/stable \
		LAB_IN_REPEAT="$rep" LAB_NEEDS_JUJU=0 GITHUB_RUN_ID=1 \
		bash scripts/verdict.sh >>"$tmp/log" 2>&1
	got=$(jq -r .verdict "$art/verdict.json")
	n=$(jq '.results | length' "$art/verdict.json")
	f=$(jq .failed "$art/verdict.json")
	if [[ $got == "$want" && $n == "$want_n" && $f == "$want_failed" ]]; then
		pass "verdict: $scen repeat=$rep -> $got, $f/$n failed"
	else
		bad "verdict: $scen repeat=$rep -> $got $f/$n, want $want $want_failed/$want_n"
		cat "$tmp/log"
	fi
}
run_case selftest 2 pass 2 0
run_case selftest-exit-1 1 fail 1 1
run_case selftest-exit-2 2 setup-error 1 0
run_case selftest-exit-3 1 inconclusive 1 0
run_case selftest-exit-137 2 error 1 0
run_case selftest-flaky 3 fail 3 1

# Validation failure: setup-error with the reason, unvalidated input not echoed.
art="$tmp/art-invalid"
mkdir -p "$art"
echo "scenario: must match x" >"$art/validate-error.txt"
env -i PATH="$PATH" LAB_ARTIFACT_DIR="$art" VALIDATE_OUTCOME=failure LAB_SUBSTRATE=lxd \
	LAB_IN_SCENARIO='../x' LAB_IN_REPEAT=1 bash scripts/verdict.sh >"$tmp/log" 2>&1
if jq -e '.verdict == "setup-error" and .scenario == null and (.reason | startswith("scenario:"))' "$art/verdict.json" >/dev/null; then
	pass "verdict: validation failure -> setup-error, input not echoed"
else
	bad "verdict: validation failure"
	cat "$art/verdict.json"
fi

# Step cut short (fewer results than requested, no recorded stop) -> error.
art="$tmp/art-short"
mkdir -p "$art"
echo '{"iteration":1,"exit_code":0,"verdict":"pass","duration_s":1,"cleanup_s":0}' >"$art/results.jsonl"
env -i PATH="$PATH" LAB_ARTIFACT_DIR="$art" VALIDATE_OUTCOME=success SCENARIO_OUTCOME=failure \
	LAB_SUBSTRATE=lxd LAB_IN_SCENARIO=selftest LAB_IN_JUJU_CHANNEL=4.0/stable LAB_IN_REPEAT=3 \
	bash scripts/verdict.sh >"$tmp/log" 2>&1
if jq -e '.verdict == "error" and (.reason | test("only 1 of 3"))' "$art/verdict.json" >/dev/null; then
	pass "verdict: step cut short -> error"
else
	bad "verdict: step cut short"
	cat "$art/verdict.json"
fi

exit "$status"
