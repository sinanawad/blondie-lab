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
mk() { # mk <name> <run.sh body> <scenario.env lines...>
	local name=$1 body=$2
	shift 2
	mkdir -p "$tmp/scen/$name"
	printf '#!/usr/bin/env bash\n%s\n' "$body" >"$tmp/scen/$name/run.sh"
	printf '%s\n' "$@" >"$tmp/scen/$name/scenario.env"
}
mk ok 'exit 0' SUBSTRATE=any TIMEOUT_MIN=2 NEEDS_JUJU=0
mk lxd-only 'exit 0' SUBSTRATE=lxd TIMEOUT_MIN=2 NEEDS_JUJU=0
mk t6 'exit 0' SUBSTRATE=any TIMEOUT_MIN=6 NEEDS_JUJU=0
mk t7 'exit 0' SUBSTRATE=any TIMEOUT_MIN=7 NEEDS_JUJU=0
mk juju 'exit 0' SUBSTRATE=any TIMEOUT_MIN=2
mk juju-notests 'exit 0' SUBSTRATE=any TIMEOUT_MIN=2 NEEDS_TESTS=0
# shellcheck disable=SC2016 # literal on purpose: must be rejected, never run
mk badkey 'exit 0' SUBSTRATE=any TIMEOUT_MIN=2 NEEDS_JUJU=0 EVIL='$(id)'
mk dupkey 'exit 0' SUBSTRATE=any TIMEOUT_MIN=2 NEEDS_JUJU=0 TIMEOUT_MIN=1
mk nojuju-deps 'exit 0' SUBSTRATE=any TIMEOUT_MIN=2 NEEDS_JUJU=0 DEPS=foo

# expect <rc> <desc> <scenario> <repeat> <want> [VAR=value ...]
#   rc=2: <want> must be a substring of validate-error.txt.
#   rc=0: <want> is a space-separated list of exact output lines.
expect() {
	local want_rc=$1 desc=$2 scen=$3 rep=$4 want=$5 rc=0 line miss=""
	shift 5
	rm -rf "$tmp/state"
	: >"$tmp/out"
	env -i PATH="$PATH" LAB_SCENARIOS_DIR="$tmp/scen" LAB_STATE_DIR="$tmp/state" \
		GITHUB_OUTPUT="$tmp/out" LAB_SUBSTRATE=k8s LAB_IN_SCENARIO="$scen" \
		LAB_IN_JUJU_CHANNEL=4.0/stable LAB_IN_REPEAT="$rep" "$@" \
		bash scripts/validate.sh >"$tmp/log" 2>&1 || rc=$?
	if [[ $rc -ne $want_rc ]]; then
		bad "validate: $desc: exit $rc, want $want_rc"
		cat "$tmp/log" "$tmp/state/validate-error.txt" 2>/dev/null
		return
	fi
	if [[ $want_rc -eq 2 ]]; then
		if grep -qF -- "$want" "$tmp/state/validate-error.txt"; then
			pass "validate: $desc (exit 2: $want)"
		else
			bad "validate: $desc: reason $(cat "$tmp/state/validate-error.txt"), want '$want'"
		fi
		return
	fi
	for line in $want; do grep -qxF -- "$line" "$tmp/out" || miss+=" $line"; done
	if [[ -z $miss ]]; then pass "validate: $desc (exit 0: $want)"; else bad "validate: $desc: missing outputs:$miss"; cat "$tmp/out"; fi
}
expect 0 "valid input repeat=1" ok 1 "scenario=ok repeat=1 scenario_timeout=8 timeout_min=2 needs_juju=0"
expect 0 "valid input repeat=3" ok 3 "repeat=3 scenario_timeout=24 timeout_min=2"
expect 0 "valid input repeat=10" ok 10 "scenario_timeout=80"
expect 0 "budget boundary TIMEOUT_MIN=6 repeat=10 = 120" t6 10 "scenario_timeout=120 timeout_min=6"
expect 2 "budget TIMEOUT_MIN=7 repeat=10 = 130" t7 10 "budget: scenario_timeout 130 min"
expect 2 "repeat=11" ok 11 "repeat: must be an integer 1..10"
expect 2 "repeat=0" ok 0 "repeat: must be"
expect 2 "repeat=01" ok 01 "repeat: must be"
expect 2 "scenario ../x" ../x 1 "scenario: must match"
expect 2 "scenario that doesn't exist" nope 1 "does not exist"
expect 2 "SUBSTRATE mismatch (lxd scenario on k8s)" lxd-only 1 "needs SUBSTRATE=lxd, this workflow is k8s"
expect 2 "NEEDS_JUJU=0 with SUBSTRATE=lxd" lxd-only 1 "NEEDS_JUJU=0 requires SUBSTRATE=any" LAB_SUBSTRATE=lxd
expect 2 "NEEDS_JUJU=0 with DEPS" nojuju-deps 1 "NEEDS_JUJU=0 excludes"
expect 2 "needs Juju (not implemented yet)" juju 1 "needs Juju; the k8s substrate is not implemented"
expect 2 "ref on a Juju scenario (build mode not implemented yet)" juju 1 "build mode is not implemented" LAB_IN_REF=v4.0.14
expect 2 "tests_ref with NEEDS_TESTS=0" juju-notests 1 "tests_ref: not used by scenario juju-notests (NEEDS_TESTS=0)" LAB_IN_TESTS_REF=v4.0.14
expect 2 "unknown scenario.env key" badkey 1 "unknown key EVIL"
expect 2 "duplicate scenario.env key" dupkey 1 "duplicate key TIMEOUT_MIN"
expect 2 "juju_channel 4.0/foo" ok 1 "juju_channel: must match" LAB_IN_JUJU_CHANNEL=4.0/foo
expect 2 "ref -x" ok 1 "ref: must match" LAB_IN_REF=-x
expect 2 "ref refs/pull/1/head" ok 1 "ref: refs/ prefix" LAB_IN_REF=refs/pull/1/head
expect 2 "ref a/.b" ok 1 "ref: refs/ prefix" LAB_IN_REF=a/.b
expect 2 "ref v4.0." ok 1 "ref: refs/ prefix" LAB_IN_REF=v4.0.
expect 2 "ref v4.0.14 on a NEEDS_JUJU=0 scenario" ok 1 "ref: not used by scenario ok (NEEDS_JUJU=0)" LAB_IN_REF=v4.0.14
expect 2 "tests_ref -x" ok 1 "tests_ref: must match" LAB_IN_TESTS_REF=-x
expect 2 "tests_ref a..b" ok 1 "tests_ref: refs/ prefix" LAB_IN_TESTS_REF=a..b
expect 2 "tests_ref x.lock" ok 1 "tests_ref: refs/ prefix" LAB_IN_TESTS_REF=x.lock
expect 2 "tests_ref v4.0.14 on a NEEDS_JUJU=0 scenario" ok 1 "tests_ref: not used by scenario ok (NEEDS_JUJU=0)" LAB_IN_TESTS_REF=v4.0.14
expect 2 "request_id 'a b'" ok 1 "request_id: must match" "LAB_IN_REQUEST_ID=a b"
expect 0 "request_id uuid" ok 1 "scenario=ok" LAB_IN_REQUEST_ID=0f8fad5b-d9cb-469f-a165-70867728950e

# --- run-scenario.sh + verdict.sh -------------------------------------------
# pipeline <art> <scenarios dir> <scenario> <repeat> [VAR=value ...]
# Runs validate -> run-scenario -> verdict like _run.yml does (outputs from validate).
pipeline() {
	local art=$1 sdir=$2 scen=$3 rep=$4 vrc=0
	shift 4
	rm -rf "$art" "$art.state"
	: >"$art.out"
	env -i PATH="$PATH" LAB_SCENARIOS_DIR="$sdir" LAB_STATE_DIR="$art.state" GITHUB_OUTPUT="$art.out" \
		LAB_SUBSTRATE=lxd LAB_IN_SCENARIO="$scen" LAB_IN_JUJU_CHANNEL=4.0/stable LAB_IN_REPEAT="$rep" \
		LAB_IN_REQUEST_ID=req-1 "$@" bash scripts/validate.sh >"$tmp/log" 2>&1 || vrc=$?
	if ((vrc == 0)); then
		env -i PATH="$PATH" LAB_SCENARIOS_DIR="$sdir" LAB_STATE_DIR="$art.state" LAB_ARTIFACT_DIR="$art" \
			LAB_SUBSTRATE=lxd LAB_SCENARIO="$(sed -n 's/^scenario=//p' "$art.out")" \
			LAB_REPEAT="$(sed -n 's/^repeat=//p' "$art.out")" LAB_TIMEOUT_MIN="$(sed -n 's/^timeout_min=//p' "$art.out")" \
			GITHUB_ENV="$art.ghenv" GITHUB_OUTPUT="$art.ghout" GITHUB_PATH="$art.ghpath" GITHUB_STEP_SUMMARY="$art.ghsum" \
			"$@" bash scripts/run-scenario.sh >"$art.runlog" 2>&1
	fi
	: >"$art.vout"
	env -i PATH="$PATH" LAB_STATE_DIR="$art.state" LAB_ARTIFACT_DIR="$art" LAB_SUBSTRATE=lxd \
		VALIDATE_OUTCOME="$( ((vrc == 0)) && echo success || echo failure)" \
		READY_OUTCOME="$( ((vrc == 0)) && echo success || echo skipped)" \
		SCENARIO_OUTCOME="$( ((vrc == 0)) && echo success || echo skipped)" \
		GITHUB_RUN_ID=1 GITHUB_OUTPUT="$art.vout" GITHUB_STEP_SUMMARY="$art.summary" \
		bash scripts/verdict.sh >>"$tmp/log" 2>&1
}
# check <desc> <art> <jq filter on verdict.json>
check() {
	if jq -e "$3" "$2/verdict.json" >/dev/null 2>&1; then pass "$1"; else
		bad "$1"
		cat "$2/verdict.json" "$tmp/log" 2>/dev/null
	fi
}
# run_case <scenario> <repeat> <want verdict> <want results> <want failed>
run_case() {
	local art="$tmp/art-$1-$2"
	pipeline "$art" scenarios "$1" "$2"
	check "verdict: $1 repeat=$2 -> $3, $5/$4 failed" "$art" \
		".verdict == \"$3\" and (.results | length) == $4 and .failed == $5 and .scenario == \"$1\" and .request_id == \"req-1\" and .source == \"none\" and .juju_channel == null"
}
run_case selftest 2 pass 2 0
run_case selftest-exit-1 1 fail 1 1
run_case selftest-exit-2 2 setup-error 1 0
run_case selftest-exit-3 1 inconclusive 1 0
run_case selftest-exit-137 2 error 1 0
run_case selftest-flaky 3 fail 3 1
art="$tmp/art-selftest-2"
if [[ -f $art/selftest-1.txt && -f $art/selftest-2.txt && -f $art/results.jsonl ]] &&
	grep -qx 'artifact_name=lab-logs-selftest-1' "$art.vout"; then
	pass "artifact: selftest-{1,2}.txt, results.jsonl, name lab-logs-selftest-1"
else
	bad "artifact: selftest files or name"
	ls "$art"
	cat "$art.vout"
fi

# Per-iteration timeout: a hang becomes 124 (TERM) or 137 (TERM ignored -> KILL),
# verdict error, and the loop stops after it.
mk hang 'echo hanging; sleep 30' SUBSTRATE=any TIMEOUT_MIN=1 NEEDS_JUJU=0
mk hang-noterm "trap '' TERM; echo hanging; sleep 30" SUBSTRATE=any TIMEOUT_MIN=1 NEEDS_JUJU=0
pipeline "$tmp/art-hang" "$tmp/scen" hang 2 LAB_ITER_TIMEOUT=2s LAB_KILL_GRACE=1
check "timeout: hang -> exit 124, error, loop stopped" "$tmp/art-hang" \
	'.verdict == "error" and (.results | length) == 1 and .results[0].exit_code == 124'
pipeline "$tmp/art-hang-noterm" "$tmp/scen" hang-noterm 2 LAB_ITER_TIMEOUT=2s LAB_KILL_GRACE=1
check "timeout: TERM ignored -> exit 137, error, loop stopped" "$tmp/art-hang-noterm" \
	'.verdict == "error" and (.results | length) == 1 and .results[0].exit_code == 137'

# Isolation: no GITHUB_* command files, workflow commands in output disabled,
# no LAB_STATE_DIR, harness state not in the artifact dir.
# shellcheck disable=SC2016 # literal on purpose: expanded by the scenario
mk sneaky 'for f in GITHUB_ENV GITHUB_OUTPUT GITHUB_PATH GITHUB_STEP_SUMMARY; do [[ -n ${!f:-} ]] && echo X >>"${!f}"; done; [[ -z ${LAB_STATE_DIR:-} ]] || exit 9; echo "::warning::from scenario"; exit 0' \
	SUBSTRATE=any TIMEOUT_MIN=1 NEEDS_JUJU=0
art="$tmp/art-sneaky"
pipeline "$art" "$tmp/scen" sneaky 1
if [[ ! -s $art.ghenv && ! -s $art.ghout && ! -s $art.ghpath && ! -s $art.ghsum ]] &&
	grep -qx '::stop-commands::[0-9a-f]\{32\}' "$art.runlog" &&
	tok=$(sed -n 's/^::stop-commands:://p' "$art.runlog") && grep -qx "::$tok::" "$art.runlog" &&
	[[ $(grep -n '::warning::from scenario' "$art.runlog" | cut -d: -f1) -gt $(grep -n '^::stop-commands::' "$art.runlog" | cut -d: -f1) ]] &&
	[[ ! -e $art/valid.env ]] && jq -e '.verdict == "pass"' "$art/verdict.json" >/dev/null; then
	pass "isolation: GITHUB_* unset, LAB_STATE_DIR unset, output inside stop-commands, state outside artifact"
else
	bad "isolation"
	cat "$art.runlog"
	ls -la "$art"
fi

# Validation failures: per-field echo and artifact naming.
art="$tmp/art-inv-path"
pipeline "$art" scenarios ../x 1
check "verdict: scenario ../x -> setup-error, scenario null, request_id echoed" "$art" \
	'.verdict == "setup-error" and .scenario == null and .request_id == "req-1" and .iterations == null and (.reason | startswith("scenario: must match"))'
if grep -qx 'artifact_name=lab-logs-invalid-1' "$art.vout"; then pass "artifact: invalid scenario -> lab-logs-invalid-1"; else bad "artifact name for invalid scenario: $(cat "$art.vout")"; fi
art="$tmp/art-inv-rep"
pipeline "$art" scenarios selftest 11
check "verdict: repeat=11 -> setup-error, scenario + request_id echoed, iterations null" "$art" \
	'.verdict == "setup-error" and .scenario == "selftest" and .request_id == "req-1" and .juju_channel == "4.0/stable" and .iterations == null and (.reason | startswith("repeat:")) and .results == []'
if grep -qx 'artifact_name=lab-logs-selftest-1' "$art.vout"; then pass "artifact: valid scenario, bad repeat -> lab-logs-selftest-1"; else bad "artifact name for bad repeat: $(cat "$art.vout")"; fi
art="$tmp/art-inv-rid"
pipeline "$art" scenarios selftest 1 "LAB_IN_REQUEST_ID=a b"
check "verdict: bad request_id -> setup-error, nothing echoed" "$art" \
	'.verdict == "setup-error" and .request_id == null and .scenario == null'

# Setup between validate and ready failed (ready skipped) -> setup-error.
art="$tmp/art-ready"
pipeline "$art" scenarios selftest 1
rm -f "$art/verdict.json"
env -i PATH="$PATH" LAB_STATE_DIR="$art.state" LAB_ARTIFACT_DIR="$art" LAB_SUBSTRATE=lxd \
	VALIDATE_OUTCOME=success READY_OUTCOME=skipped SCENARIO_OUTCOME=skipped \
	bash scripts/verdict.sh >"$tmp/log" 2>&1
check "verdict: ready skipped -> setup-error" "$art" \
	'.verdict == "setup-error" and (.reason | test("ready step: skipped")) and .results == [] and .scenario == "selftest"'

# Step cut short (fewer results than requested, no recorded stop) -> error.
art="$tmp/art-short"
pipeline "$art" scenarios selftest 3
echo '{"iteration":1,"exit_code":0,"verdict":"pass","duration_s":1,"cleanup_s":0}' >"$art.state/results.jsonl"
env -i PATH="$PATH" LAB_STATE_DIR="$art.state" LAB_ARTIFACT_DIR="$art" LAB_SUBSTRATE=lxd \
	VALIDATE_OUTCOME=success READY_OUTCOME=success SCENARIO_OUTCOME=failure \
	bash scripts/verdict.sh >"$tmp/log" 2>&1
check "verdict: step cut short -> error" "$art" '.verdict == "error" and (.reason | test("only 1 of 3"))'

# Excerpt prefers the first fail over an earlier inconclusive.
art="$tmp/art-excerpt"
pipeline "$art" scenarios selftest 2
printf '%s\n' '{"iteration":1,"exit_code":3,"verdict":"inconclusive","duration_s":1,"cleanup_s":0}' \
	'{"iteration":2,"exit_code":1,"verdict":"fail","duration_s":1,"cleanup_s":0}' >"$art.state/results.jsonl"
echo "log one" >"$art/iteration-1.log"
echo "log two" >"$art/iteration-2.log"
: >"$art.summary"
env -i PATH="$PATH" LAB_STATE_DIR="$art.state" LAB_ARTIFACT_DIR="$art" LAB_SUBSTRATE=lxd \
	VALIDATE_OUTCOME=success READY_OUTCOME=success SCENARIO_OUTCOME=success GITHUB_STEP_SUMMARY="$art.summary" \
	bash scripts/verdict.sh >"$tmp/log" 2>&1
if grep -q 'Last 50 lines of iteration 2' "$art.summary" && grep -qx 'log two' "$art.summary" && ! grep -qx 'log one' "$art.summary"; then
	pass "summary: excerpt shows the first fail (iteration 2)"
else
	bad "summary excerpt"
	cat "$art.summary"
fi

exit "$status"
