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
mk juju-tests 'exit 0' SUBSTRATE=lxd TIMEOUT_MIN=2 NEEDS_TESTS=1 DEPS=charmcraft
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
expect 2 "Juju scenario on k8s (PR-4)" juju 1 "the k8s substrate is not implemented yet (plan PR-4)"
expect 0 "Juju scenario on lxd" juju 1 "needs_juju=1 needs_tests=0 deps= juju_channel=4.0/stable" LAB_SUBSTRATE=lxd
expect 0 "Juju scenario with tests + DEPS on lxd" juju-tests 2 "needs_juju=1 needs_tests=1 deps=charmcraft scenario_timeout=16" LAB_SUBSTRATE=lxd
expect 2 "ref on a Juju scenario (build mode not implemented yet)" juju 1 "build mode is not implemented" LAB_IN_REF=v4.0.14 LAB_SUBSTRATE=lxd
expect 2 "explicit tests_ref (trust check is PR-5)" juju-tests 1 "explicit tests_ref needs the ref trust check" LAB_IN_TESTS_REF=v4.0.14 LAB_SUBSTRATE=lxd
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

# --- scrub.sh / minimal-artifact.sh ----------------------------------------------
art="$tmp/scrub-art"
st="$tmp/scrub-state"
rm -rf "$art" "$st"
mkdir -p "$art/sub" "$st"
printf '%s\n' '{"password": "x"}' 'password reset requested' 'the password field is empty' >"$art/a.txt"
printf '%s\n' 'admin-secret: hunter2' 'ApiPassword=abc def' "  statepassword: 'q'" 'macaroons: [[{"c":1}]]' 'passwords are hard' >"$art/sub/b.yaml"
: >"$tmp/scrub.out"
env -i PATH="$PATH" LAB_ARTIFACT_DIR="$art" LAB_STATE_DIR="$st" GITHUB_OUTPUT="$tmp/scrub.out" bash scripts/scrub.sh >"$tmp/log" 2>&1
if grep -qx 'scrub_hits=5' "$st/scrub.env" && grep -qx 'upload_blocked=false' "$st/scrub.env" &&
	grep -qx '{"password": <redacted>' "$art/a.txt" && grep -qx 'password reset requested' "$art/a.txt" &&
	grep -qx 'the password field is empty' "$art/a.txt" && grep -qx 'admin-secret: <redacted>' "$art/sub/b.yaml" &&
	grep -qx 'ApiPassword=<redacted> def' "$art/sub/b.yaml" && grep -qx '  statepassword: <redacted>' "$art/sub/b.yaml" &&
	grep -qx 'macaroons: <redacted>' "$art/sub/b.yaml" && grep -qx 'passwords are hard' "$art/sub/b.yaml" && grep -qx 'scrub_hits=5' "$tmp/scrub.out"; then
	pass "scrub: 5 key/value hits redacted in place, bare words untouched"
else
	bad "scrub key/value"
	cat "$st/scrub.env" "$art/a.txt" "$art/sub/b.yaml" "$tmp/log"
fi
art="$tmp/scrub-clean"
rm -rf "$art" "$st"
mkdir -p "$art" "$st"
printf '%s\n' 'password reset requested' 'juju add-model --password-stdin' >"$art/c.txt"
env -i PATH="$PATH" LAB_ARTIFACT_DIR="$art" LAB_STATE_DIR="$st" bash scripts/scrub.sh >"$tmp/log" 2>&1
if grep -qx 'scrub_hits=0' "$st/scrub.env"; then pass "scrub: no key/value form -> 0 hits"; else bad "scrub clean"; cat "$st/scrub.env"; fi
art="$tmp/scrub-pk"
rm -rf "$art" "$st" "$tmp/min"
mkdir -p "$art/keys" "$st"
{ printf -- '-----BEGIN %s PRIVATE KEY-----\n' OPENSSH; echo zz; } >"$art/keys/k.txt"
echo '{"verdict":"pass"}' >"$art/verdict.json"
echo "collect ok" >"$art/collect.log"
env -i PATH="$PATH" LAB_ARTIFACT_DIR="$art" LAB_STATE_DIR="$st" bash scripts/scrub.sh >"$tmp/log" 2>&1
env -i PATH="$PATH" LAB_ARTIFACT_DIR="$art" LAB_MINIMAL_DIR="$tmp/min" bash scripts/minimal-artifact.sh >>"$tmp/log" 2>&1
if grep -qx 'upload_blocked=true' "$st/scrub.env" && grep -qx 'upload_blocked_path=keys/k.txt' "$st/scrub.env" &&
	[[ $(find "$tmp/min" -type f -printf '%f\n' | sort | tr '\n' ' ') == "collect.log verdict.json " ]] && ! grep -rq 'PRIVATE KEY' "$tmp/min"; then
	pass "scrub: private key -> upload_blocked, path only; minimal = verdict.json + collect.log"
else
	bad "scrub private key"
	cat "$st/scrub.env" "$tmp/log"
fi
{ printf -- '-----BEGIN %s PRIVATE KEY-----\n' RSA; } >"$art/collect.log"
env -i PATH="$PATH" LAB_ARTIFACT_DIR="$art" LAB_MINIMAL_DIR="$tmp/min" bash scripts/minimal-artifact.sh >"$tmp/log" 2>&1
if grep -qx 'collect.log withheld: it contains private key material' "$tmp/min/collect.log"; then pass "minimal: collect.log with key material withheld"; else bad "minimal withhold"; fi

# --- suite.sh: infra signatures only in the setup phase -------------------------
stub="$tmp/stub-bin"
mkdir -p "$stub"
for t in curl yq shellcheck; do
	command -v "$t" >/dev/null || printf '#!/bin/sh\nexit 0\n' >"$stub/$t"
done
chmod +x "$stub"/* 2>/dev/null || true
# fake_tests <name> <exit code> <output lines...>: a tests/ dir whose main.sh prints the lines.
fake_tests() {
	local d="$tmp/tests-$1" rc=$2
	shift 2
	mkdir -p "$d"
	{
		echo '#!/usr/bin/env bash'
		echo 'mkdir -p tmp.abc && echo "suite log" >tmp.abc/test.log'
		printf 'printf "%%s\\n"'
		printf " '%s'" "$@"
		echo
		echo "exit $rc"
	} >"$d/main.sh"
	chmod +x "$d/main.sh"
}
SIG_DUP='test-smoke already exists. Use the following to clean up the environment:'
fake_tests depmiss 1 '==> Checking for dependencies' 'Missing dependencies: yq'
fake_tests leftover 1 '==> TEST BEGIN: smoke' "$SIG_DUP" '    juju switch lab'
# After the marker: the sentence unprefixed (as main.sh -v streams a test log) and prefixed (RUN OUTPUT).
fake_tests intest 1 '==> TEST BEGIN: labdrill' '===> [   ] Running: labdrill dup' "$SIG_DUP" 'Missing dependencies: jq' '==> RUN OUTPUT: test_labdrill' "    | $SIG_DUP" 'ERROR model "x" already exists'
fake_tests plainfail 1 '==> TEST BEGIN: smoke' 'something failed'
fake_tests ok 0 '===> [   ] Running: charmhub deploy'
# suite_case <name> <want rc> <want signal ("" = none)>
suite_case() {
	local name=$1 want=$2 wsig=$3 rc=0 art="$tmp/suite-art-$1" sig="$tmp/suite-sig-$1"
	rm -rf "$art" "$sig"
	mkdir -p "$art"
	env -i PATH="$stub:$PATH" LAB_TESTS_DIR="$tmp/tests-$name" LAB_CONTROLLER=lab LAB_ARTIFACT_DIR="$art" \
		LAB_ITERATION=1 LAB_SIGNAL_FILE="$sig" bash scripts/suite.sh smoke >"$tmp/log" 2>&1 || rc=$?
	local got_sig=""
	[[ -f $sig ]] && got_sig=$(cat "$sig")
	if [[ $rc == "$want" && $got_sig == "$wsig" && -f $art/suite-i1/tmp.abc/test.log && ! -e $tmp/tests-$name/tmp.abc ]]; then
		pass "suite.sh: $name -> exit $rc, signature [${wsig}], work dir copied"
	else
		bad "suite.sh: $name -> exit $rc sig '$got_sig', want $want '$wsig'"
		cat "$tmp/log"
	fi
}
suite_case depmiss 2 'Missing dependencies: yq'
suite_case leftover 2 "$SIG_DUP"
suite_case intest 1 ''
suite_case plainfail 1 ''
suite_case ok 0 ''

# Signature end to end: run-scenario records it (exit 2 only), verdict shows it.
mk sig-pos "exec \"$PWD/scripts/suite.sh\" smoke" SUBSTRATE=any TIMEOUT_MIN=1 NEEDS_JUJU=0
mk sig-neg "exec \"$PWD/scripts/suite.sh\" smoke" SUBSTRATE=any TIMEOUT_MIN=1 NEEDS_JUJU=0
pipeline "$tmp/art-sig-pos" "$tmp/scen" sig-pos 1 PATH="$stub:$PATH" LAB_TESTS_DIR="$tmp/tests-leftover" LAB_CONTROLLER=lab
check "verdict: setup-phase signature -> setup-error, infra_signature = full sentence" "$tmp/art-sig-pos" \
	".verdict == \"setup-error\" and .infra_signature == \"$SIG_DUP\" and (.reason | test(\"infra signature\"))"
pipeline "$tmp/art-sig-neg" "$tmp/scen" sig-neg 1 PATH="$stub:$PATH" LAB_TESTS_DIR="$tmp/tests-intest" LAB_CONTROLLER=lab
check "verdict: same sentence after a test started -> fail, infra_signature null" "$tmp/art-sig-neg" \
	'.verdict == "fail" and .infra_signature == null'
# A signal file without exit 2 is ignored.
# shellcheck disable=SC2016 # expanded by the scenario
mk sig-forged 'echo "forged" >"$LAB_SIGNAL_FILE"; exit 1' SUBSTRATE=any TIMEOUT_MIN=1 NEEDS_JUJU=0
pipeline "$tmp/art-sig-forged" "$tmp/scen" sig-forged 1
check "verdict: signal without exit 2 ignored -> fail" "$tmp/art-sig-forged" '.verdict == "fail" and .infra_signature == null'

# --- cleanup between iterations (LAB_NEEDS_JUJU=1) --------------------------------
fj="$tmp/fake-juju"
mkdir -p "$fj"
cat >"$fj/juju" <<'FAKE'
#!/usr/bin/env bash
case $1 in
models) if [[ -s $FAKE_MODELS ]]; then printf '{"models":[{"short-name":"controller","is-controller":true},{"short-name":"%s","is-controller":false}]}\n' "$(cat "$FAKE_MODELS")"; else echo '{"models":[{"short-name":"controller","is-controller":true}]}'; fi ;;
destroy-model) echo "destroy $*" >>"$FAKE_LOG"; [[ ${FAKE_STUCK:-0} == 1 ]] || : >"$FAKE_MODELS" ;;
esac
FAKE
chmod +x "$fj/juju"
# shellcheck disable=SC2016 # expanded by the scenario
mk leaves-model 'echo m1 >"$FAKE_MODELS"; exit 0' SUBSTRATE=any TIMEOUT_MIN=1 NEEDS_JUJU=0
: >"$tmp/fake.log"
pipeline "$tmp/art-clean-ok" "$tmp/scen" leaves-model 2 PATH="$fj:$PATH" LAB_NEEDS_JUJU=1 LAB_CONTROLLER=lab \
	FAKE_MODELS="$tmp/fake.models" FAKE_LOG="$tmp/fake.log"
if jq -e '.verdict == "pass" and (.results | length) == 2' "$tmp/art-clean-ok/verdict.json" >/dev/null &&
	[[ $(grep -c 'destroy-model --no-prompt --force --no-wait --destroy-storage lab:m1' "$tmp/fake.log") == 1 ]] &&
	[[ -f $tmp/art-clean-ok/cleanup-1.log && ! -e $tmp/art-clean-ok/cleanup-2.log ]]; then
	pass "cleanup: model destroyed between iterations only (not after the last)"
else
	bad "cleanup between iterations"
	cat "$tmp/fake.log" "$tmp/art-clean-ok/verdict.json"
fi
pipeline "$tmp/art-clean-stuck" "$tmp/scen" leaves-model 3 PATH="$fj:$PATH" LAB_NEEDS_JUJU=1 LAB_CONTROLLER=lab \
	FAKE_MODELS="$tmp/fake.models" FAKE_LOG="$tmp/fake.log" FAKE_STUCK=1 LAB_CLEANUP_TIMEOUT=2
check "cleanup: unfinished cleanup stops the loop -> setup-error" "$tmp/art-clean-stuck" \
	'.verdict == "setup-error" and (.results | length) == 1 and .results[0].verdict == "pass" and (.reason | test("cleanup after iteration 1"))'

# --- verdict.sh: juju + scrub state -> verdict.json, job outputs ----------------------
art="$tmp/art-jujustate"
pipeline "$art" scenarios selftest 1
printf '%s\n' juju_version=4.0.1 juju_git_commit=0123456789abcdef0123456789abcdef01234567 juju_snap_revision=31000 source=snap \
	substrate_snap_name=lxd substrate_snap_channel=latest/candidate substrate_snap_revision=33000 \
	tests_sha=0123456789abcdef0123456789abcdef01234567 tests_source=git-commit >"$art.state/juju.env"
printf '%s\n' scrub_hits=2 upload_blocked=false upload_blocked_path= >"$art.state/scrub.env"
: >"$art.vout"
env -i PATH="$PATH" LAB_STATE_DIR="$art.state" LAB_ARTIFACT_DIR="$art" LAB_SUBSTRATE=lxd \
	VALIDATE_OUTCOME=success READY_OUTCOME=success SCENARIO_OUTCOME=success GITHUB_OUTPUT="$art.vout" \
	bash scripts/verdict.sh >"$tmp/log" 2>&1
check "verdict: juju.env + scrub.env fields" "$art" \
	'.juju_version == "4.0.1" and .juju_snap_revision == 31000 and .tests_source == "git-commit" and .substrate_snap.revision == 33000 and .scrub_hits == 2 and .upload_blocked == false and .upload_blocked_path == null'
if grep -qx 'scrub_hits=2' "$art.vout" && grep -qx 'upload_blocked=false' "$art.vout"; then pass "verdict: scrub outputs for the job result"; else bad "verdict scrub outputs"; cat "$art.vout"; fi
art="$tmp/art-blocked"
pipeline "$art" scenarios selftest-exit-1 1
printf '%s\n' scrub_hits=0 upload_blocked=true upload_blocked_path=iteration-1.log >"$art.state/scrub.env"
: >"$art.summary"
env -i PATH="$PATH" LAB_STATE_DIR="$art.state" LAB_ARTIFACT_DIR="$art" LAB_SUBSTRATE=lxd \
	VALIDATE_OUTCOME=success READY_OUTCOME=success SCENARIO_OUTCOME=success GITHUB_STEP_SUMMARY="$art.summary" \
	bash scripts/verdict.sh >"$tmp/log" 2>&1
if jq -e '.verdict == "fail" and .upload_blocked == true and .upload_blocked_path == "iteration-1.log"' "$art/verdict.json" >/dev/null &&
	grep -q 'Upload blocked' "$art.summary" && ! grep -q 'Last 50 lines' "$art.summary"; then
	pass "verdict: blocked upload keeps the real verdict, no log excerpt in the summary"
else
	bad "verdict blocked"
	cat "$art.summary"
fi
art="$tmp/art-setupreason"
pipeline "$art" scenarios selftest 1
echo "DEPS: unknown dependency 'nonexistent' (v1 vocabulary: charmcraft)" >"$art.state/setup-error.txt"
env -i PATH="$PATH" LAB_STATE_DIR="$art.state" LAB_ARTIFACT_DIR="$art" LAB_SUBSTRATE=lxd \
	VALIDATE_OUTCOME=success READY_OUTCOME=skipped SCENARIO_OUTCOME=skipped bash scripts/verdict.sh >"$tmp/log" 2>&1
check "verdict: setup failure reason from setup-error.txt" "$art" '.verdict == "setup-error" and (.reason | startswith("DEPS: unknown dependency"))'

# --- deps.sh -----------------------------------------------------------------------
rc=0
env -i PATH="$PATH" LAB_STATE_DIR="$tmp/deps-state" LAB_DEPS=nonexistent bash scripts/deps.sh >"$tmp/log" 2>&1 || rc=$?
if [[ $rc == 2 ]] && grep -q "unknown dependency 'nonexistent'" "$tmp/deps-state/setup-error.txt"; then pass "deps: unknown dep -> exit 2 with reason"; else bad "deps unknown: rc $rc"; cat "$tmp/log"; fi

exit "$status"
