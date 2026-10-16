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
mk juju-baddeps 'exit 0' SUBSTRATE=lxd TIMEOUT_MIN=2 NEEDS_TESTS=1 DEPS=nonexistent

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
expect 2 "unknown DEPS word rejected at input" juju-baddeps 1 "DEPS: unknown dependency 'nonexistent'" LAB_SUBSTRATE=lxd
expect 0 "Juju scenario on k8s" juju 1 "needs_juju=1 needs_tests=0 deps= juju_channel=4.0/stable"
expect 0 "Juju scenario on lxd" juju 1 "needs_juju=1 needs_tests=0 deps= juju_channel=4.0/stable" LAB_SUBSTRATE=lxd
expect 0 "Juju scenario with tests + DEPS on lxd" juju-tests 2 "needs_juju=1 needs_tests=1 deps=charmcraft scenario_timeout=16" LAB_SUBSTRATE=lxd
expect 0 "ref on a Juju scenario -> build mode, trust check" juju 1 "source=build trust=1 ref=v4.0.14 tests_ref=" LAB_IN_REF=v4.0.14 LAB_SUBSTRATE=lxd
expect 0 "explicit tests_ref -> snap mode, trust check" juju-tests 1 "source=snap trust=1 ref= tests_ref=v4.0.14" LAB_IN_TESTS_REF=v4.0.14 LAB_SUBSTRATE=lxd
expect 0 "no ref/tests_ref -> snap mode, no trust check" juju 1 "source=snap trust=0" LAB_SUBSTRATE=lxd
expect 0 "NEEDS_JUJU=0 -> source none" ok 1 "source=none trust=0"
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
printf '%s\n' scrub_hits=0 upload_blocked=false upload_blocked_path= >"$art.state/scrub.env"
env -i PATH="$PATH" LAB_STATE_DIR="$art.state" LAB_ARTIFACT_DIR="$art" LAB_UPLOAD_DIR="$art" LAB_SUBSTRATE=lxd \
	VALIDATE_OUTCOME=success READY_OUTCOME=success SCENARIO_OUTCOME=success GITHUB_STEP_SUMMARY="$art.summary" \
	bash scripts/verdict.sh >"$tmp/log" 2>&1
if grep -q 'Last 50 lines of iteration 2' "$art.summary" && grep -qx 'log two' "$art.summary" && ! grep -qx 'log one' "$art.summary"; then
	pass "summary: excerpt shows the first fail (iteration 2)"
else
	bad "summary excerpt"
	cat "$art.summary"
fi
# No excerpt unless a scrub completed and the excerpt comes from the snapshot.
rm -f "$art.state/scrub.env"
: >"$art.summary"
env -i PATH="$PATH" LAB_STATE_DIR="$art.state" LAB_ARTIFACT_DIR="$art" LAB_UPLOAD_DIR="$art" LAB_SUBSTRATE=lxd \
	VALIDATE_OUTCOME=success READY_OUTCOME=success SCENARIO_OUTCOME=success GITHUB_STEP_SUMMARY="$art.summary" \
	bash scripts/verdict.sh >"$tmp/log" 2>&1
if ! grep -q 'Last 50 lines' "$art.summary"; then pass "summary: no excerpt without a completed scrub"; else bad "summary excerpt without scrub"; fi

# --- scrub.sh / minimal-artifact.sh ----------------------------------------------
# scrub_run <name>: scrubs $tmp/<name> (source) into $tmp/<name>.up; state in $tmp/<name>.st.
scrub_run() {
	local a="$tmp/$1"
	rm -rf "$a.up" "$a.st"
	mkdir -p "$a.st"
	: >"$a.out"
	srcrc=0
	env -i PATH="$PATH" LAB_ARTIFACT_DIR="$a" LAB_UPLOAD_DIR="$a.up" LAB_STATE_DIR="$a.st" GITHUB_OUTPUT="$a.out" \
		bash scripts/scrub.sh >"$a.log" 2>&1 || srcrc=$?
}
sx() { grep -qx -- "$2" "$tmp/$1.st/scrub.env"; } # sx <name> <exact scrub.env line>
art="$tmp/kv"
rm -rf "$art"
mkdir -p "$art/sub"
printf '%s\n' '{"password": "x"}' 'password reset requested' 'the password field is empty' >"$art/a.txt"
printf '%s\n' 'admin-secret: hunter2' 'ApiPassword=abc def' "  statepassword: 'q'" 'macaroons: [[{"c":1}]]' 'passwords are hard' >"$art/sub/b.yaml"
scrub_run kv
u="$art.up"
if ((srcrc == 0)) && sx kv scrub_hits=5 && sx kv upload_blocked=false &&
	grep -qx '{"password": <redacted>}' "$u/a.txt" && grep -qx 'password reset requested' "$u/a.txt" &&
	grep -qx 'the password field is empty' "$u/a.txt" && grep -qx 'admin-secret: <redacted>' "$u/sub/b.yaml" &&
	grep -qx 'ApiPassword=<redacted> def' "$u/sub/b.yaml" && grep -qx '  statepassword: <redacted>' "$u/sub/b.yaml" &&
	grep -qx 'macaroons: <redacted>' "$u/sub/b.yaml" && grep -qx 'passwords are hard' "$u/sub/b.yaml" &&
	grep -qx 'scrub_hits=5' "$art.out" && grep -qx '{"password": "x"}' "$art/a.txt"; then
	pass "scrub: 5 key/value hits redacted in the snapshot, bare words untouched, source dir untouched"
else
	bad "scrub key/value (rc $srcrc)"
	cat "$art.st/scrub.env" "$u/a.txt" "$u/sub/b.yaml" "$art.log"
fi
# One case per regex bypass from the PR-3 review.
# bypass_case <desc> <want line in the snapshot> <input lines...>
bypass_case() {
	local desc=$1 want=$2
	shift 2
	rm -rf "$tmp/bp"
	mkdir -p "$tmp/bp"
	printf '%s\n' "$@" >"$tmp/bp/f.txt"
	scrub_run bp
	if ((srcrc == 0)) && ! sx bp scrub_hits=0 && grep -qxF -- "$want" "$tmp/bp.up/f.txt"; then
		pass "scrub bypass closed: $desc"
	else
		bad "scrub bypass: $desc"
		cat "$tmp/bp.up/f.txt" "$tmp/bp.st/scrub.env" "$tmp/bp.log"
	fi
}
bypass_case 'escaped JSON (logsink.log)' '{\"password\":<redacted>,\"x\":1}' '{\"password\":\"hunter2\",\"x\":1}'
bypass_case 'quoted multi-word value' 'password: <redacted> tail' 'password: "two words" tail'
bypass_case 'value on the next line (|)' '    <redacted>' 'admin-secret: |' '    line one' '    line two' 'next: 1'
bypass_case 'empty value, list on the next line' '  <redacted>' 'statepassword:' '  - deep' 'other: 1'
bypass_case 'kubeconfig client-key-data' '    client-key-data: <redacted>' '    client-key-data: QUJDREVGRw=='
bypass_case 'bearer token (k8s credential)' '  token: <redacted>' '  token: eyJhbGciOiJSUzI1NiJ9.abc'
bypass_case 'non-empty authToken' 'request authToken: <redacted>' 'request authToken: "eyJhbGciOi"'
bypass_case 'upper-case env var TOKEN=' '+ export JUJU_TOKEN=<redacted>' '+ export JUJU_TOKEN=abc'
bypass_case 'GITHUB_TOKEN=ghs_' 'GITHUB_TOKEN=<redacted>' 'GITHUB_TOKEN=ghs_abcdefghijklmnopqrstuvwxyz0123456789'
bypass_case '--token=' 'kubectl --token=<redacted> get pods' 'kubectl --token=abc get pods'
bypass_case '--token <value>' 'kubectl --token <redacted> get pods' 'kubectl --token abc get pods'
bypass_case 'access_token query string' 'https://x/?access_token=<redacted>' 'https://x/?access_token=abc'
bypass_case 'Bearer JWT (value shape)' 'Authorization: Bearer <redacted>' 'Authorization: Bearer eyJhbGciOiJSUzI1.eyJzdWIiOiJzeXN0.sig'
bypass_case 'bare GitHub token (value shape)' 'url https://x:<redacted>@github.com' 'url https://x:ghp_abcdefghijklmnopqrstuvwxyz0123456789@github.com'
bypass_case 'ClientKeyData (juju k8s credential)' 'ClientKeyData: <redacted>' 'ClientKeyData: abc'
bypass_case 'client_key_data' 'client_key_data: <redacted>' 'client_key_data: abc'
bypass_case 'empty quotes glued to a value' 'password: <redacted>' 'password: ""secret'
bypass_case 'macaroon-<id>= cookie' 'macaroon-abc_12-z=<redacted> Path=/' 'macaroon-abc_12-z=eyJhYmMi; Path=/'
rm -rf "$tmp/bp" && mkdir -p "$tmp/bp" && printf '%s\n' 'admin-secret: |' '    line one' 'next: 1' >"$tmp/bp/f.txt" && scrub_run bp
if grep -qx 'next: 1' "$tmp/bp.up/f.txt" && ! grep -q 'line one' "$tmp/bp.up/f.txt"; then pass "scrub: YAML block ends at the next key"; else bad "scrub block end"; cat "$tmp/bp.up/f.txt"; fi
art="$tmp/clean"
rm -rf "$art" && mkdir -p "$art"
# Baseline-clean forms seen on real runs: juju's empty authToken and a charm's
# shell-trace token= (test data).
printf '%s\n' 'password reset requested' 'juju add-model --password-stdin' 'cert: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t' \
	'DEBUG juju.apiserver admin.go:248 request authToken: ""' '{"message":"request authToken: \"\""}' '+ token=yeah-boi' >"$art/c.txt"
scrub_run clean
if sx clean scrub_hits=0 && sx clean upload_blocked=false; then pass "scrub: no key/value form, base64 certificate, empty authToken, token= -> 0 hits, not blocked"; else bad "scrub clean"; cat "$art.st/scrub.env"; fi
art="$tmp/pk"
rm -rf "$art" "$tmp/min" && mkdir -p "$art/keys"
{ printf -- '-----BEGIN %s PRIVATE KEY-----\n' OPENSSH; echo zz; } >"$art/keys/k.txt"
echo "collect ok, password: x" >"$art/collect.log"
scrub_run pk
echo '{"verdict":"pass"}' >"$art.up/verdict.json"
env -i PATH="$PATH" LAB_ARTIFACT_DIR="$art" LAB_UPLOAD_DIR="$art.up" LAB_MINIMAL_DIR="$tmp/min" bash scripts/minimal-artifact.sh >>"$art.log" 2>&1
if sx pk upload_blocked=true && sx pk upload_blocked_path=keys/k.txt &&
	[[ $(find "$tmp/min" -type f -printf '%f\n' | sort | tr '\n' ' ') == "collect.log verdict.json " ]] && ! grep -rq 'PRIVATE KEY' "$tmp/min" &&
	grep -qx 'collect ok, password: <redacted>' "$tmp/min/collect.log"; then
	pass "scrub: private key -> upload_blocked, path only; minimal = verdict.json + redacted collect.log"
else
	bad "scrub private key"
	cat "$art.st/scrub.env" "$art.log"
fi
{ printf -- '-----BEGIN %s PRIVATE KEY-----\n' RSA; } >"$art.up/collect.log"
env -i PATH="$PATH" LAB_ARTIFACT_DIR="$art" LAB_UPLOAD_DIR="$art.up" LAB_MINIMAL_DIR="$tmp/min" bash scripts/minimal-artifact.sh >"$tmp/log" 2>&1
if grep -q '^collect.log withheld: it contains private key material' "$tmp/min/collect.log"; then pass "minimal: collect.log with key material withheld"; else bad "minimal withhold"; fi
art="$tmp/pk64"
rm -rf "$art" && mkdir -p "$art"
echo "client-key-data: $(printf -- '-----BEGIN %s PRIVATE KEY-----' RSA | base64 -w0)" >"$art/kubeish.txt"
scrub_run pk64
if sx pk64 upload_blocked=true && sx pk64 upload_blocked_path=kubeish.txt; then pass "scrub: base64 PEM private key -> upload_blocked"; else bad "scrub base64 pk"; cat "$art.st/scrub.env"; fi
# Symlinks (the uploader follows them) are dropped from the snapshot, never scanned or uploaded.
art="$tmp/links"
rm -rf "$art" "$tmp/outside" && mkdir -p "$art" "$tmp/outside/dir"
echo 'statepassword: s3cret' >"$tmp/outside/agent.txt"
{ printf -- '-----BEGIN %s PRIVATE KEY-----\n' OPENSSH; } >"$tmp/outside/dir/id"
ln -s "$tmp/outside/agent.txt" "$art/link-file"
ln -s "$tmp/outside/dir" "$art/link-dir"
mkfifo "$art/fifo"
echo plain >"$art/real.txt"
scrub_run links
if ((srcrc == 0)) && sx links scrub_dropped=3 && [[ $(find "$art.up" -mindepth 1 -printf '%P\n') == real.txt ]] && ! grep -rq s3cret "$art.up"; then
	pass "scrub: symlinked file, symlinked dir and FIFO dropped from the snapshot (scrub_dropped=3)"
else
	bad "scrub symlinks (rc $srcrc)"
	find "$art.up" -mindepth 1
	cat "$art.st/scrub.env" "$art.log"
fi
# A file name with a newline can't inject a step output; a control character blocks.
art="$tmp/nl"
rm -rf "$art" && mkdir -p "$art"
{ printf -- '-----BEGIN %s PRIVATE KEY-----\n' OPENSSH; } >"$art/a"$'\n'"upload_blocked=false"
scrub_run nl
if sx nl upload_blocked=true && sx nl 'upload_blocked_path=<unprintable path>' &&
	[[ $(grep -c '^upload_blocked=' "$art.out") == 1 ]] && grep -qx 'upload_blocked=true' "$art.out"; then
	pass "scrub: newline in a file name -> blocked, placeholder path, exactly one upload_blocked output"
else
	bad "scrub newline name"
	cat "$art.out" "$art.log"
fi
rm -rf "$art" && mkdir -p "$art" && echo clean >"$art/x"$'\t'"y"
scrub_run nl
if sx nl upload_blocked=true; then pass "scrub: control character in a file name -> blocked"; else bad "scrub control char"; cat "$art.out"; fi
# Never-collect list (design §8) enforced by name.
art="$tmp/never"
rm -rf "$art" && mkdir -p "$art/suite-i1/tmp.x/juju/ssh" "$art/suite-i1/tmp.x/juju/cookies"
for f in accounts.yaml credentials.yaml agent.conf juju/ssh/juju_id_rsa juju/cookies/lab.json c.key my-kubeconfig keep.txt; do echo data >"$art/suite-i1/tmp.x/$f"; done
scrub_run never
if sx never scrub_withheld=7 && [[ $(find "$art.up" -type f -printf '%P\n') == suite-i1/tmp.x/keep.txt ]]; then
	pass "scrub: never-collect names withheld (accounts, credentials, agent.conf, ssh/, cookies/, *.key, *kubeconfig*)"
else
	bad "scrub never-collect"
	find "$art.up" -type f
	cat "$art.st/scrub.env"
fi

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
fake_tests ok 0 '===> [   ] Running: charmhub deploy' $'\r\e[1A\e[0K===> [ \xe2\x9c\x94 ] Success: charmhub deploy (1s)'
# Exit-code normalisation (Blocker): main.sh passes through whatever failed.
fake_tests noneran 0 '==> TEST BEGIN: smoke' '==> TEST SKIPPED: smoke deploy tests'
fake_tests rc2after 2 '===> [   ] Running: charmhub deploy' 'ERROR option provided but not defined: --nope'
fake_tests rc3after 3 '===> [   ] Running: charmhub deploy' 'remote command exited 3'
fake_tests rc2before 2 '==> TEST BEGIN: smoke' 'panic: runtime error'
fake_tests rc130 130 '===> [   ] Running: charmhub deploy'
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
suite_case noneran 3 ''
suite_case rc2after 1 ''
suite_case rc3after 1 ''
suite_case rc2before 1 ''
suite_case rc130 130 ''
# Owner's check end to end: main.sh exit 2 after the marker scores fail, not setup-error.
mk suite-rc2 "exec \"$PWD/scripts/suite.sh\" smoke" SUBSTRATE=any TIMEOUT_MIN=1 NEEDS_JUJU=0
pipeline "$tmp/art-suite-rc2" "$tmp/scen" suite-rc2 1 PATH="$stub:$PATH" LAB_TESTS_DIR="$tmp/tests-rc2after" LAB_CONTROLLER=lab
check "verdict: main.sh exit 2 after a test started -> fail, no signature" "$tmp/art-suite-rc2" \
	'.verdict == "fail" and .infra_signature == null and .results[0].exit_code == 1'
pipeline "$tmp/art-suite-rc2b" "$tmp/scen" suite-rc2 1 PATH="$stub:$PATH" LAB_TESTS_DIR="$tmp/tests-rc2before" LAB_CONTROLLER=lab
check "verdict: main.sh exit 2 before any test, no signature -> fail" "$tmp/art-suite-rc2b" '.verdict == "fail" and .infra_signature == null'
pipeline "$tmp/art-suite-none" "$tmp/scen" suite-rc2 1 PATH="$stub:$PATH" LAB_TESTS_DIR="$tmp/tests-noneran" LAB_CONTROLLER=lab
check "verdict: no test ran -> inconclusive, not pass" "$tmp/art-suite-none" '.verdict == "inconclusive"'

# --- step-log replay goes through the redaction; private key -> withheld ----------
mk leaky-pk 'printf -- "-----BEGIN %s PRIVATE KEY-----\n" RSA; echo "password: x"; exit 0' SUBSTRATE=any TIMEOUT_MIN=1 NEEDS_JUJU=0
pipeline "$tmp/art-leaky-pk" "$tmp/scen" leaky-pk 1
if ! grep -q 'PRIVATE KEY' "$tmp/art-leaky-pk.runlog" && ! grep -q 'password: x' "$tmp/art-leaky-pk.runlog" &&
	grep -q 'iteration 1 log withheld from the step log' "$tmp/art-leaky-pk.runlog"; then
	pass "replay: PEM block + password in scenario output -> neither in the step log (withheld)"
else
	bad "replay pk"
	cat "$tmp/art-leaky-pk.runlog"
fi
mk leaky-kv 'echo "password: x"; echo "hello"; exit 0' SUBSTRATE=any TIMEOUT_MIN=1 NEEDS_JUJU=0
pipeline "$tmp/art-leaky-kv" "$tmp/scen" leaky-kv 1
if grep -qx 'password: <redacted>' "$tmp/art-leaky-kv.runlog" && grep -qx hello "$tmp/art-leaky-kv.runlog" && ! grep -q 'password: x' "$tmp/art-leaky-kv.runlog"; then
	pass "replay: key/value redacted in the step log, rest shown"
else
	bad "replay kv"
	cat "$tmp/art-leaky-kv.runlog"
fi

# --- leftover scenario processes are killed after the iteration --------------------
alive() { [[ -e /proc/$1 ]] && ! grep -q '^State:.*Z' "/proc/$1/status" 2>/dev/null; }
# shellcheck disable=SC2016 # expanded by the scenario
mk bgproc 'sleep 300 >/dev/null 2>&1 & echo $! >"$LAB_ARTIFACT_DIR/bg1.pid"; setsid sleep 301 >/dev/null 2>&1 & echo $! >"$LAB_ARTIFACT_DIR/bg2.pid"; exit 0' SUBSTRATE=any TIMEOUT_MIN=1 NEEDS_JUJU=0
pipeline "$tmp/art-bg" "$tmp/scen" bgproc 1
p1=$(cat "$tmp/art-bg/bg1.pid") p2=$(cat "$tmp/art-bg/bg2.pid")
if ! alive "$p1" && ! alive "$p2" && grep -q 'iteration 1: killed 2 leftover process(es)' "$tmp/art-bg.runlog"; then
	pass "reap: background and setsid processes from the scenario killed after the iteration"
else
	bad "reap leftovers ($p1 $p2)"
	cat "$tmp/art-bg.runlog"
	kill "$p1" "$p2" 2>/dev/null || true
fi

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
# $FAKE_MODELS: one qualified model name per line. Other users' models
# (qualifier != admin) are listed only with --all, like juju's admin view.
models)
	all=0
	for a in "$@"; do [[ $a == --all ]] && all=1; done
	{
		echo '{"name":"admin/controller","short-name":"controller","is-controller":true}'
		if [[ -s $FAKE_MODELS ]]; then
			while read -r m; do
				[[ $all == 1 || $m == admin/* ]] || continue
				jq -nc --arg n "$m" '{name: $n, "short-name": ($n | sub(".*/"; "")), "is-controller": false}'
			done <"$FAKE_MODELS"
		fi
	} | jq -sc '{models: .}' ;;
destroy-model)
	echo "destroy $*" >>"$FAKE_LOG"
	if [[ ${FAKE_STUCK:-0} != 1 ]]; then
		m=${*: -1}
		m=${m#*:}
		grep -vxF -- "$m" "$FAKE_MODELS" >"$FAKE_MODELS.n" || true
		mv "$FAKE_MODELS.n" "$FAKE_MODELS"
	fi ;;
esac
FAKE
chmod +x "$fj/juju"
# shellcheck disable=SC2016 # expanded by the scenario
mk leaves-model 'echo admin/m1 >"$FAKE_MODELS"; exit 0' SUBSTRATE=any TIMEOUT_MIN=1 NEEDS_JUJU=0
: >"$tmp/fake.log"
pipeline "$tmp/art-clean-ok" "$tmp/scen" leaves-model 2 PATH="$fj:$PATH" LAB_NEEDS_JUJU=1 LAB_CONTROLLER=lab \
	FAKE_MODELS="$tmp/fake.models" FAKE_LOG="$tmp/fake.log"
if jq -e '.verdict == "pass" and (.results | length) == 2' "$tmp/art-clean-ok/verdict.json" >/dev/null &&
	[[ $(grep -c 'destroy-model --no-prompt --force --no-wait --destroy-storage lab:admin/m1' "$tmp/fake.log") == 1 ]] &&
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

# --- k8s: cleanup namespace wait, bootstrap watchdog ------------------------------
# Fake microk8s (lab-kubectl execs `microk8s kubectl`): namespaces are lines in
# $FAKE_NS ("name label"); `get ns NAME` decrements $FAKE_NS_DIR/NAME (calls
# left until gone, absent = gone).
fk="$tmp/fake-k8s"
mkdir -p "$fk"
cat >"$fk/microk8s" <<'FAKE'
#!/usr/bin/env bash
[[ $1 == kubectl ]] || exit 0
shift
echo "kubectl $*" >>"$FAKE_LOG"
if [[ $1 == get && $2 == ns && $3 == -l ]]; then
	for f in "$FAKE_NS_DIR"/*; do
		[[ -f $f ]] || continue
		n=${f##*/}
		printf '{"metadata":{"name":"%s","labels":{"model.juju.is/name":"%s"}}}\n' "$n" "$(sed -n 2p "$f")"
	done | jq -s '{items: .}'
	exit 0
fi
if [[ $1 == get && $2 == ns && -n ${3:-} ]]; then
	f="$FAKE_NS_DIR/$3"
	[[ -f $f ]] || { echo "Error from server (NotFound): namespaces \"$3\" not found" >&2; exit 1; }
	left=$(sed -n 1p "$f")
	label=$(sed -n 2p "$f")
	if [[ $left == stuck ]]; then echo "namespace/$3"; exit 0; fi
	if ((left <= 1)); then rm -f "$f"; echo "namespace/$3"; exit 0; fi
	printf '%s\n%s\n' $((left - 1)) "$label" >"$f"
	echo "namespace/$3"
	exit 0
fi
if [[ $1 == -n && $3 == get && $4 == pod ]]; then
	jq -n --arg img "${FAKE_API_IMAGE:-ghcr.io/juju/jujud-operator:4.0.15}" --arg id "${FAKE_API_ID:-ghcr.io/juju/jujud-operator@sha256:aa}" '{status: {initContainerStatuses: [{name: "charm-init", image: $img, imageID: "ghcr.io/juju/jujud-operator@sha256:aa"}],
		containerStatuses: [{name: "charm", image: "ghcr.io/juju/charm-base:ubuntu-24.04", imageID: "ghcr.io/juju/charm-base@sha256:bb"}, {name: "api-server", image: $img, imageID: $id}]}}'
	exit 0
fi
echo "fake kubectl $*"
FAKE
chmod +x "$fk/microk8s"
nsd="$tmp/fake-ns"
fakens() { rm -rf "$nsd" && mkdir -p "$nsd" && while (($#)); do printf '%s\n%s\n' "$2" "$3" >"$nsd/$1"; shift 3; done; }
cleanup_run() { # cleanup_run <name> [VAR=value...]
	local n=$1
	shift
	: >"$tmp/fake.log"
	crc=0
	env -i PATH="$fk:$fj:$PATH" HOME="$tmp" LAB_CONTROLLER=lab FAKE_MODELS="$tmp/fake.models" FAKE_LOG="$tmp/fake.log" \
		FAKE_NS_DIR="$nsd" "$@" bash scripts/cleanup-models.sh >"$tmp/$n.out" 2>&1 || crc=$?
}
echo admin/m1 >"$tmp/fake.models"
fakens m1 3 m1 suite-ns 2 suite-ns controller-lab stuck controller
cleanup_run nsok LAB_SUBSTRATE=k8s
if ((crc == 0)) && grep -qx 'cleanup: namespace m1 gone (NotFound)' "$tmp/nsok.out" &&
	grep -qx 'cleanup: namespace suite-ns gone (NotFound)' "$tmp/nsok.out" &&
	tail -n 1 "$tmp/nsok.out" | grep -qx 'cleanup: no model namespaces left' && ! grep -q 'controller-lab' "$tmp/nsok.out"; then
	pass "cleanup k8s: waits for the destroyed model's and a labelled leftover namespace, not the controller's"
else
	bad "cleanup k8s namespace wait (rc $crc)"
	cat "$tmp/nsok.out"
fi
echo admin/m1 >"$tmp/fake.models"
fakens m1 stuck m1
cleanup_run nsstuck LAB_SUBSTRATE=k8s LAB_CLEANUP_TIMEOUT=3
if ((crc == 1)) && grep -q 'cleanup: still present after 3s: m1' "$tmp/nsstuck.out"; then
	pass "cleanup k8s: a namespace still there when the shared budget runs out -> exit 1"
else
	bad "cleanup k8s stuck namespace (rc $crc)"
	cat "$tmp/nsstuck.out"
fi
echo admin/m1 >"$tmp/fake.models"
fakens m1 stuck m1
cleanup_run nslxd LAB_SUBSTRATE=lxd LAB_CLEANUP_TIMEOUT=3
if ((crc == 0)) && ! grep -q kubectl "$tmp/fake.log"; then pass "cleanup lxd: no namespace wait"; else bad "cleanup lxd (rc $crc)"; cat "$tmp/nslxd.out"; fi
# All users' models, by qualified name: another user's model with the same
# short name is destroyed too, and separately.
printf '%s\n' admin/m1 bob/m1 bob/controller >"$tmp/fake.models"
cleanup_run allusers LAB_SUBSTRATE=lxd LAB_CLEANUP_TIMEOUT=3
if ((crc == 0)) && grep -qx 'destroy destroy-model --no-prompt --force --no-wait --destroy-storage lab:admin/m1' "$tmp/fake.log" &&
	grep -qx 'destroy destroy-model --no-prompt --force --no-wait --destroy-storage lab:bob/m1' "$tmp/fake.log" &&
	grep -qx 'destroy destroy-model --no-prompt --force --no-wait --destroy-storage lab:bob/controller' "$tmp/fake.log" &&
	! grep -q 'lab:admin/controller' "$tmp/fake.log" && [[ ! -s $tmp/fake.models ]]; then
	pass "cleanup: models --all, every user's model destroyed by qualified name (bob/controller too, never admin/controller)"
else
	bad "cleanup all users (rc $crc)"
	cat "$tmp/allusers.out" "$tmp/fake.log"
fi

# bootstrap.sh watchdog: a hung bootstrap is dumped (k8s) before juju is killed.
fb="$tmp/fake-boot"
mkdir -p "$fb"
cat >"$fb/juju" <<'FAKE'
#!/usr/bin/env bash
case $1 in
clouds) echo '{"microk8s":{"type":"k8s"}}' ;;
bootstrap) [[ -n ${FAKE_BOOT_OK:-} ]] && exit 0; echo "$$" >"$FAKE_PID"; exec sleep 60 ;;
switch) exit 0 ;;
show-controller) echo '{"lab":{"details":{"agent-version":"4.0.15"}}}' ;;
esac
FAKE
cat >"$fb/snap" <<'FAKE'
#!/usr/bin/env bash
[[ -n ${FAKE_NO_SNAP:-} ]] && exit 1
printf '%s\n' 'Interface Plug Slot Notes' 'content[microk8s] juju:peers microk8s:microk8s -'
FAKE
printf '#!/usr/bin/env bash\n"$@"\n' >"$fb/sudo"
printf '#!/usr/bin/env bash\necho journal "$@"\n' >"$fb/journalctl"
chmod +x "$fb"/*
fakens m1 stuck m1
for cl in microk8s localhost; do
	b="$tmp/boot-$cl"
	mkdir -p "$b.state"
	brc=0
	env -i PATH="$fb:$fk:$PATH" HOME="$tmp" LAB_CONTROLLER=lab LAB_CLOUD=$cl LAB_JUJU_SOURCE=snap LAB_BOOTSTRAP_TIMEOUT=3 LAB_ARTIFACT_DIR="$b" \
		LAB_STATE_DIR="$b.state" FAKE_PID="$b.pid" FAKE_LOG="$tmp/fake.log" FAKE_NS_DIR="$nsd" \
		bash scripts/bootstrap.sh >"$b.out" 2>&1 || brc=$?
	sleep 1
	if ((brc == 2)) && grep -q "timed out after 3s" "$b.state/setup-error.txt" && grep -qx bootstrap_failed=1 "$b.state/juju.env" &&
		! kill -0 "$(cat "$b.pid")" 2>/dev/null; then
		if [[ $cl == microk8s ]]; then
			if [[ -s $b/collect/k8s-bootstrap-timeout/get-all.txt && -s $b/collect/k8s-bootstrap-timeout/journal-microk8s.txt ]] &&
				grep -q 'dumped to collect/k8s-bootstrap-timeout/ before teardown' "$b.out"; then
				pass "bootstrap watchdog (microk8s): k8s state dumped, then juju killed -> setup-error"
			else
				bad "bootstrap watchdog: no k8s dump"
				cat "$b.out"
			fi
		elif [[ ! -e $b/collect/k8s-bootstrap-timeout ]]; then
			pass "bootstrap watchdog (localhost): juju killed -> setup-error, no k8s dump"
		else
			bad "bootstrap watchdog (localhost) dumped k8s"
		fi
	else
		bad "bootstrap watchdog ($cl, rc $brc)"
		cat "$b.out" "$b.state/setup-error.txt"
	fi
done
# boot_ok <name> [VAR=value...]: a successful fake bootstrap on microk8s.
boot_ok() {
	local n=$1
	shift
	b="$tmp/boot-$n"
	rm -rf "$b" "$b.state" && mkdir -p "$b.state"
	brc=0
	env -i PATH="$fb:$fk:$PATH" HOME="$tmp" LAB_CONTROLLER=lab LAB_CLOUD=microk8s LAB_ARTIFACT_DIR="$b" LAB_STATE_DIR="$b.state" \
		FAKE_BOOT_OK=1 FAKE_LOG="$tmp/fake.log" FAKE_NS_DIR="$nsd" "$@" bash scripts/bootstrap.sh >"$b.out" 2>&1 || brc=$?
}
boot_ok snapok LAB_JUJU_SOURCE=snap
if ((brc == 0)) && grep -qx agent_source=packaged "$b.state/juju.env" &&
	jq -e 'length == 3 and (map(.name) == ["charm-init", "charm", "api-server"]) and .[2].imageID == "ghcr.io/juju/jujud-operator@sha256:aa"' \
		<<<"$(sed -n 's/^controller_images=//p' "$b.state/juju.env")" >/dev/null; then
	pass "bootstrap k8s: controller_images recorded, api-server = default jujud-operator:<agent> -> packaged"
else
	bad "bootstrap k8s images (rc $brc)"
	cat "$b.out" "$b.state/juju.env"
fi
boot_ok otherimg LAB_JUJU_SOURCE=snap FAKE_API_IMAGE=example.com/x/jujud-operator:4.0.15
if ((brc == 0)) && grep -qx agent_source=unknown "$b.state/juju.env"; then pass "bootstrap k8s: other image repo -> agent_source unknown"; else bad "bootstrap k8s other repo (rc $brc)"; cat "$b.out"; fi
boot_ok snapnoplug LAB_JUJU_SOURCE=snap FAKE_NO_SNAP=1
if ((brc == 2)) && grep -q 'juju:peers is not connected' "$b.state/setup-error.txt"; then pass "bootstrap k8s snap mode: unconnected juju:peers -> setup-error"; else bad "bootstrap snap no plug (rc $brc)"; cat "$b.out"; fi

# Bootstrap step budget (design §2): LAB_BOOTSTRAP_TIMEOUT + preflight 60 +
# timeout dump 155 + post-bootstrap 60 must fit the step's timeout-minutes.
n_boot=0
for name in "Bootstrap" "Bootstrap (LXD build mode)"; do
	step=$(awk -v n="      - name: $name" '/^      - name: /{p = ($0 == n)} p' .github/workflows/_run.yml)
	bt=$(sed -n 's/^ *LAB_BOOTSTRAP_TIMEOUT: *"*\([0-9][0-9]*\)"* *$/\1/p' <<<"$step")
	tm=$(sed -n 's/^ *timeout-minutes: *\([0-9]*\) *$/\1/p' <<<"$step")
	if [[ -n $bt && -n $tm ]] && ((bt + 60 + 155 + 60 <= tm * 60)); then
		pass "budget: '$name' step LAB_BOOTSTRAP_TIMEOUT=$bt + 275 <= timeout-minutes $tm x 60"
		n_boot=$((n_boot + 1))
	else
		bad "budget: '$name' step LAB_BOOTSTRAP_TIMEOUT='$bt' + 275 > timeout-minutes '$tm' x 60 (or not set)"
	fi
done
# Every step that runs bootstrap.sh is one of the two checked above.
n_calls=$(grep -c 'scripts/bootstrap.sh"*$' .github/workflows/_run.yml)
if [[ $n_calls == 3 && $n_boot == 2 ]]; then pass "budget: all bootstrap.sh steps checked"; else bad "budget: $n_calls bootstrap.sh call lines, $n_boot steps checked"; fi

# Job backstop (design §2): the worst-case sum of step timeouts on each path
# must fit the job's timeout-minutes, so a job cancel never eats collect/upload.
# The scenario step's timeout is an expression capped by validate.sh at
# BUDGET_MAX (120). Every step must have its own timeout-minutes.
wf=.github/workflows/_run.yml
steps_tm=$(awk '
	/^      - name: / { if (n != "") print n "\t" (t == "" ? "MISSING" : t); n = substr($0, 15); t = ""; next }
	/^        timeout-minutes: / && n != "" { t = $2; if (t !~ /^[0-9]+$/) t = 120 }
	END { if (n != "") print n "\t" (t == "" ? "MISSING" : t) }' "$wf")
job_tm=$(awk '/^    timeout-minutes: / {print $2; exit}' "$wf")
if grep -q $'\tMISSING$' <<<"$steps_tm"; then
	bad "budget: steps without timeout-minutes: $(grep $'\tMISSING$' <<<"$steps_tm" | cut -f1 | tr '\n' ';')"
fi
# path_sum <excluded step names, |-separated>: sum over the other steps.
path_sum() { awk -F'\t' -v ex="$1" 'BEGIN { split(ex, e, "|"); for (i in e) x[e[i]] = 1 } !($1 in x) { s += $2 } END { print s }' <<<"$steps_tm"; }
bm='Free disk (build mode)|Checkout juju/juju at ref_sha (build mode)|Set up Go (build mode)|Build juju (build mode)|Bootstrap (LXD build mode)'
declare -A paths=(
	[lxd-build]='Set up MicroK8s|Install juju snap|Bootstrap'
	[k8s-build]='Set up LXD|Wait for LXD|Install juju snap|Bootstrap (LXD build mode)'
	[lxd-snap]="Set up MicroK8s|$bm"
	[k8s-snap]="Set up LXD|Wait for LXD|$bm"
)
worst=0
for pth in lxd-build k8s-build lxd-snap k8s-snap; do
	sum=$(path_sum "${paths[$pth]}")
	((sum > worst)) && worst=$sum
	if [[ $job_tm =~ ^[0-9]+$ ]] && ((sum <= job_tm)); then :; else bad "budget: $pth step timeouts sum to $sum min > job timeout-minutes ${job_tm:-unset}"; fi
done
if [[ $job_tm =~ ^[0-9]+$ ]] && ((worst <= job_tm)) && ((job_tm <= 360)); then
	pass "budget: worst-case step timeout sum $worst min <= job timeout-minutes $job_tm (<= 360)"
fi
# Fail closed (design §8): every step that fetches or runs juju/juju code is
# gated on the trust step having passed with a SHA, not only on
# source == build and the implicit success().
guard="steps.trust.outcome == 'success' && steps.trust.outputs.ref_sha != ''"
nguard=0
for name in 'Free disk (build mode)' 'Checkout juju/juju at ref_sha (build mode)' 'Set up Go (build mode)' \
	'Build juju (build mode)'; do
	cond=$(awk -v n="      - name: $name" '$0 == n {f = 1; next} f && /^      - name: / {exit} f && /^        if: / {print; exit}' "$wf")
	if [[ $cond == *"$guard"* ]]; then nguard=$((nguard + 1)); else bad "trust gate: '$name' if: lacks the trust guard ($cond)"; fi
done
((nguard == 4)) && pass "trust gate: all 4 build-mode steps require the trust step's success and ref_sha"

# no-models-left.sh on k8s: a labelled model namespace left behind is a fail.
nml() { # nml <name> [VAR=value...]
	local n=$1
	shift
	nrc=0
	env -i PATH="$fk:$fj:$PATH" HOME="$tmp" LAB_CONTROLLER=lab FAKE_MODELS="$tmp/fake.models" FAKE_LOG="$tmp/fake.log" \
		FAKE_NS_DIR="$nsd" "$@" bash scripts/no-models-left.sh drill 3 >"$tmp/$n.out" 2>&1 || nrc=$?
}
: >"$tmp/fake.models"
fakens leftover stuck leftover controller-lab stuck controller
nml nmlstuck LAB_SUBSTRATE=k8s
if ((nrc == 1)) && grep -qx 'drill: suite passed but model namespace(s) left after 3s: leftover' "$tmp/nmlstuck.out"; then
	pass "no-models-left k8s: no models but a labelled namespace left -> exit 1 (fail)"
else
	bad "no-models-left k8s stuck (rc $nrc)"
	cat "$tmp/nmlstuck.out"
fi
fakens controller-lab stuck controller
nml nmlok LAB_SUBSTRATE=k8s
if ((nrc == 0)) && grep -qx 'drill: teardown ok, no models or model namespaces left' "$tmp/nmlok.out"; then pass "no-models-left k8s: only the controller namespace -> ok"; else bad "no-models-left k8s ok (rc $nrc)"; cat "$tmp/nmlok.out"; fi
fakens leftover stuck leftover
nml nmllxd LAB_SUBSTRATE=lxd
if ((nrc == 0)); then pass "no-models-left lxd: namespaces not checked"; else bad "no-models-left lxd (rc $nrc)"; cat "$tmp/nmllxd.out"; fi
echo bob/left >"$tmp/fake.models"
fakens controller-lab stuck controller
nml nmlother LAB_SUBSTRATE=lxd
if ((nrc == 1)) && grep -qx 'drill: suite passed but its teardown left models after 3s: bob/left' "$tmp/nmlother.out"; then
	pass "no-models-left: another user's leftover model (only visible with --all) -> fail"
else
	bad "no-models-left other user (rc $nrc)"
	cat "$tmp/nmlother.out"
fi
# Only the controller model itself is excluded: another user's model named
# "controller" is a leftover like any other.
echo bob/controller >"$tmp/fake.models"
nml nmlbobctl LAB_SUBSTRATE=lxd
if ((nrc == 1)) && grep -qx 'drill: suite passed but its teardown left models after 3s: bob/controller' "$tmp/nmlbobctl.out"; then
	pass "no-models-left: bob/controller is not the controller model -> fail"
else
	bad "no-models-left bob/controller (rc $nrc)"
	cat "$tmp/nmlbobctl.out"
fi
: >"$tmp/fake.models"

b="$tmp/boot-bad"
mkdir -p "$b.state"
brc=0
env -i PATH="$fb:$PATH" LAB_CONTROLLER=lab LAB_CLOUD=aws LAB_JUJU_SOURCE=snap LAB_ARTIFACT_DIR="$b" LAB_STATE_DIR="$b.state" bash scripts/bootstrap.sh >"$b.out" 2>&1 || brc=$?
if ((brc == 2)) && grep -q 'LAB_CLOUD: unexpected value' "$b.state/setup-error.txt"; then pass "bootstrap: LAB_CLOUD outside localhost|microk8s -> setup-error"; else bad "bootstrap bad cloud"; fi

# --- ref-trust.sh (design §8): resolve, reachability, version file, flavour gate ---
# Fake gh: A = v4.0.15 (4.0 tree), M = main (4.2, controller snap), F = fork-only,
# T = v3.6.29 (3.6 only), O = pre-June 3.6 SHA (reachable from 4.0, 3.6 version file).
A=$(printf 'a%.0s' {1..40}) M=$(printf 'b%.0s' {1..40}) F=$(printf 'c%.0s' {1..40})
T=$(printf 'd%.0s' {1..40}) O=$(printf 'e%.0s' {1..40})
fg2="$tmp/fake-gh-trust"
mkdir -p "$fg2"
cat >"$fg2/gh" <<FAKE
#!/usr/bin/env bash
A=$A M=$M F=$F T=$T O=$O
FAKE
cat >>"$fg2/gh" <<'FAKE'
p=""
for a in "$@"; do [[ $a == repos/* ]] && p=$a; done
echo "$p" >>"$FAKE_LOG"
nf() { echo '{"message":"Not Found","status":"404"}'; echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
[[ -n ${FAKE_SLEEP:-} ]] && sleep "$FAKE_SLEEP"
[[ -n ${FAKE_FAIL:-} && $p == *"$FAKE_FAIL"* ]] && { echo "${FAKE_FAIL_MSG:-gh: Server Error (HTTP 502)}" >&2; exit 1; }
[[ -n ${FAKE_COMPARE_404:-} && $p == */compare/* ]] && nf
case $p in
*/commits/v4.0.15) echo "$A" ;;
*/commits/main) echo "$M" ;;
*/commits/fork) echo "$F" ;;
*/commits/v3.6.29) echo "$T" ;;
*/commits/old36) echo "$O" ;;
*/commits/garbage) echo "<html>" ;;
*/commits/*) echo "gh: No commit found for SHA: x (HTTP 422)" >&2; exit 1 ;;
*/compare/*)
	s=${p#*/compare/}; s=${s%%...*}; b=${p#*...}; b=${b%%\?*}
	case "$s $b" in
	"$A main" | "$O "*) echo ahead ;;
	"$M main") echo identical ;;
	"$T 3.6") echo ahead ;;
	"$A "* | "$M "*) echo behind ;;
	*) echo diverged ;;
	esac ;;
*/contents/core/version/version.go\?ref=$A) echo 'const version = "4.0.15"' ;;
*/contents/core/version/version.go\?ref=$M) echo 'const version = "4.2-beta1"' ;;
*/contents/version/version.go\?ref=$O) echo 'const version = "3.6.26"' ;;
*/contents/Makefile\?ref=$A) printf 'go-install: $(INSTALL_TARGETS)\n' ;;
*/contents/Makefile\?ref=$M) printf 'jujud-snap-build:\n' ;;
*) nf ;;
esac
FAKE
chmod +x "$fg2/gh"
# trust <name> <want rc> <want substring (setup-error.txt for rc 2, output for rc 0)> [VAR=value...]
trust() {
	local n=$1 want_rc=$2 want=$3 trc=0
	shift 3
	rm -rf "$tmp/tr-$n" && mkdir -p "$tmp/tr-$n"
	: >"$tmp/tr-$n.gh"
	env -i PATH="$fg2:$PATH" LAB_STATE_DIR="$tmp/tr-$n" GITHUB_OUTPUT="$tmp/tr-$n/out" FAKE_LOG="$tmp/tr-$n.gh" "$@" \
		bash scripts/ref-trust.sh >"$tmp/tr-$n.log" 2>&1 || trc=$?
	local f="$tmp/tr-$n/out"
	((want_rc == 2)) && f="$tmp/tr-$n/setup-error.txt"
	if ((trc == want_rc)) && grep -qF -- "$want" "$f"; then
		pass "ref-trust: $n -> exit $trc ($want)"
	else
		bad "ref-trust: $n: exit $trc, want $want_rc with '$want'"
		cat "$tmp/tr-$n.log" "$f" 2>/dev/null
	fi
}
trust tag 0 "ref_sha=$A" LAB_REF=v4.0.15
if grep -qx 'ref_line=4.0' "$tmp/tr-tag/out" && grep -qx 'ref_version=4.0.15' "$tmp/tr-tag/out" && grep -qx "ref_sha=$A" "$tmp/tr-tag/juju.env"; then
	pass "ref-trust: tag outputs ref_line/ref_version, records ref_sha"
else
	bad "ref-trust tag outputs"
	cat "$tmp/tr-tag/out"
fi
trust main 2 "controller-snap builds not supported in v1" LAB_REF=main
trust fork 2 "not reachable from juju/juju main, 4.1 or 4.0 (fork-only or unknown commit), not trusted" LAB_REF=fork
trust v36tag 2 "3.6 ref builds not supported (reachable only from 3.6" LAB_REF=v3.6.29
trust old36 2 "3.6 ref builds not supported (version/version.go says 3.6.26)" LAB_REF=old36
trust unknown 2 "ref 'nope': no such commit, tag or branch in juju/juju" LAB_REF=nope
trust api-resolve 2 "trust check could not complete (resolve ref: gh: Server Error (HTTP 502))" LAB_REF=v4.0.15 FAKE_FAIL=commits/
trust api-compare 2 "trust check could not complete (compare with main" LAB_REF=v4.0.15 FAKE_FAIL=compare/
trust api-version 2 "trust check could not complete (read core/version/version.go" LAB_REF=v4.0.15 FAKE_FAIL=version.go
trust api-makefile 2 "trust check could not complete (read Makefile" LAB_REF=v4.0.15 FAKE_FAIL=Makefile
trust malformed 2 "trust check could not complete (resolve ref: malformed response)" LAB_REF=garbage
trust tests-ref-36 0 "tests_ref_sha=$T" LAB_TESTS_REF=v3.6.29
trust tests-ref-fork 2 "tests_ref 'fork' ($F): not reachable from juju/juju main, 4.1, 4.0 or 3.6" LAB_TESTS_REF=fork
# An API failure on the 3.6 probe after a failed reachability check is still
# "could not complete", never a plain rejection.
trust api-36probe 2 "trust check could not complete (compare with 3.6" LAB_REF=fork FAKE_FAIL=...3.6
if ! grep -q 'version.go' "$tmp/tr-fork.gh"; then pass "ref-trust: fork SHA rejected before any file read"; else bad "ref-trust fork read files"; fi
# Only 404/422 mean "absent": a 403 rate limit or a 429 is "could not complete".
trust api-403 2 "trust check could not complete (resolve ref: gh: API rate limit exceeded for installation ID 1. (HTTP 403))" \
	LAB_REF=v4.0.15 FAKE_FAIL=commits/ "FAKE_FAIL_MSG=gh: API rate limit exceeded for installation ID 1. (HTTP 403)"
trust api-429 2 "trust check could not complete (compare with main: gh: Too Many Requests (HTTP 429))" \
	LAB_REF=v4.0.15 FAKE_FAIL=compare/ "FAKE_FAIL_MSG=gh: Too Many Requests (HTTP 429)"
# compare 404 on every branch (no common history anywhere) is a rejection, never trust.
trust compare-404 2 "not reachable from juju/juju main, 4.1 or 4.0 (fork-only or unknown commit), not trusted" LAB_REF=v4.0.15 FAKE_COMPARE_404=1
# ref + tests_ref in one run: two resolves, $via reused.
trust both 0 "tests_ref_sha=$T" LAB_REF=v4.0.15 LAB_TESTS_REF=v3.6.29
if grep -qx "ref_sha=$A" "$tmp/tr-both/out" && grep -qx 'ref_line=4.0' "$tmp/tr-both/out"; then pass "ref-trust: ref + tests_ref -> both SHAs, ref_line from ref"; else bad "ref-trust both outputs"; cat "$tmp/tr-both/out"; fi
# A slow API ends with the script's own reason inside the step timeout.
trust deadline 2 "trust check could not complete (resolve ref: timed out after 1s)" LAB_REF=v4.0.15 LAB_TRUST_DEADLINE_S=1 FAKE_SLEEP=3
trc=0
env -i PATH="$PATH" LAB_STATE_DIR="$tmp/tr-none" bash scripts/ref-trust.sh >/dev/null 2>&1 || trc=$?
if ((trc == 2)); then pass "ref-trust: nothing to check -> exit 2"; else bad "ref-trust empty: rc $trc"; fi

# --- bootstrap.sh build mode: identity before, agent identity after ----------------
gp="$tmp/gopath"
mkdir -p "$gp/bin" "$tmp/fake-go" "$tmp/fake-snap-b" "$tmp/jsrc"
# shellcheck disable=SC2016 # fake script text
printf '#!/usr/bin/env bash\n[[ $1 == env && $2 == GOPATH ]] && echo "%s"\n' "$gp" >"$tmp/fake-go/go"
cat >"$gp/bin/juju" <<'FAKE'
#!/usr/bin/env bash
case $1 in
version) printf 'version: %s-ubuntu-amd64\ngit-commit: %s\ngit-tree-state: %s\n' "$FAKE_VERSION" "${FAKE_COMMIT:-}" "${FAKE_TREE-clean}" ;;
clouds) echo '{"microk8s":{"type":"k8s"}}' ;;
bootstrap) echo "$PWD $*" >>"$FAKE_LOG"; printf '%s\n' "${FAKE_BOOT_OUT:-}"; exit 0 ;;
switch) exit 0 ;;
show-controller) printf '{"lab":{"details":{"agent-version":"%s"}}}\n' "$FAKE_AGENT" ;;
esac
FAKE
# shellcheck disable=SC2016 # fake script text
cat >"$tmp/fake-snap-b/snap" <<'FAKE'
#!/usr/bin/env bash
[[ $1 == list && -n ${FAKE_JUJU_SNAP:-} ]] && { echo juju; exit 0; }
[[ -n ${FAKE_SNAP_RC:-} ]] && { echo "error: cannot communicate with server" >&2; exit "$FAKE_SNAP_RC"; }
echo "error: no matching snaps installed" >&2
exit 1
FAKE
chmod +x "$gp/bin/juju" "$tmp/fake-go/go" "$tmp/fake-snap-b/snap"
cfg="sha256:$(printf '1%.0s' {1..64})" tgt="sha256:$(printf '2%.0s' {1..64})"
# boot_build <name> <cloud> [VAR=value...]: bootstrap.sh in build mode with a
# built juju 4.0.14 at ref_sha $A.
boot_build() {
	local n=$1 cl=$2
	shift 2
	b="$tmp/bb-$n"
	rm -rf "$b" "$b.state" && mkdir -p "$b.state"
	printf '%s\n' juju_version=4.0.14 "operator_image=ghcr.io/juju/jujud-operator:4.0.14" "operator_image_config=$cfg" "operator_image_target=$tgt" >"$b.state/juju.env"
	: >"$tmp/bb.log"
	brc=0
	env -i PATH="$gp/bin:$tmp/fake-go:$tmp/fake-snap-b:$fk:$PATH" HOME="$tmp" LAB_CONTROLLER=lab LAB_CLOUD="$cl" LAB_JUJU_SOURCE=build \
		LAB_REF_SHA="$A" LAB_SRC="$tmp/jsrc" LAB_ARTIFACT_DIR="$b" LAB_STATE_DIR="$b.state" FAKE_LOG="$tmp/bb.log" FAKE_NS_DIR="$nsd" \
		FAKE_VERSION=4.0.14 FAKE_COMMIT="$A" "$@" bash scripts/bootstrap.sh >"$b.out" 2>&1 || brc=$?
}
bline='Building local Juju agent binary version <nil> for amd64'
boot_build lxdok localhost FAKE_AGENT=4.0.14.1 "FAKE_BOOT_OUT=$bline"
if ((brc == 0)) && grep -qx agent_source=local "$b.state/juju.env" && grep -qx "$tmp/jsrc bootstrap localhost lab --debug --build-agent" "$tmp/bb.log"; then
	pass "bootstrap build LXD: --build-agent from LAB_SRC, agent 4.0.14.1 + build line -> local"
else
	bad "bootstrap build LXD ok (rc $brc)"
	cat "$b.out" "$tmp/bb.log"
fi
boot_build lxdpub localhost FAKE_AGENT=4.0.15 "FAKE_BOOT_OUT=$bline"
if ((brc == 2)) && grep -q "controller agent is 4.0.15 (expected 4.0.14.1" "$b.state/setup-error.txt" && grep -qx agent_source=unknown "$b.state/juju.env"; then
	pass "bootstrap build LXD: newest published agent 4.0.15 for a v4.0.14 build -> setup-error"
else
	bad "bootstrap build LXD published (rc $brc)"
	cat "$b.out"
fi
boot_build lxdnoline localhost FAKE_AGENT=4.0.14.1 "FAKE_BOOT_OUT=Looking for packaged Juju agent version 4.0"
if ((brc == 2)) && grep -q "the build wasn't used" "$b.state/setup-error.txt"; then pass "bootstrap build LXD: agent .1 without the build line -> setup-error"; else bad "bootstrap build LXD no line (rc $brc)"; cat "$b.out"; fi
boot_build snapjuju localhost FAKE_AGENT=4.0.14.1 FAKE_JUJU_SNAP=1
if ((brc == 2)) && grep -q "a juju snap is installed" "$b.state/setup-error.txt" && [[ ! -s $tmp/bb.log ]]; then
	pass "bootstrap build: juju snap installed -> setup-error before bootstrap"
else
	bad "bootstrap build snap installed (rc $brc)"
	cat "$b.out"
fi
boot_build snaperr localhost FAKE_AGENT=4.0.14.1 FAKE_SNAP_RC=124
if ((brc == 2)) && grep -q "could not check for a juju snap (snap list rc 124)" "$b.state/setup-error.txt" && [[ ! -s $tmp/bb.log ]]; then
	pass "bootstrap build: snap list timeout/error -> setup-error (fails closed)"
else
	bad "bootstrap build snap error (rc $brc)"
	cat "$b.out"
fi
boot_build dirtytree localhost FAKE_AGENT=4.0.14.1 FAKE_TREE=dirty
if ((brc == 2)) && grep -q "git-tree-state 'dirty', expected clean" "$b.state/setup-error.txt" && [[ ! -s $tmp/bb.log ]]; then pass "bootstrap build: git-tree-state dirty -> setup-error before bootstrap"; else bad "bootstrap build dirty (rc $brc)"; cat "$b.out"; fi
boot_build wrongcommit localhost FAKE_COMMIT="$M"
if ((brc == 2)) && grep -q "git-commit '$M', expected ref_sha $A" "$b.state/setup-error.txt" && [[ ! -s $tmp/bb.log ]]; then pass "bootstrap build: git-commit != ref_sha -> setup-error before bootstrap"; else bad "bootstrap build commit (rc $brc)"; cat "$b.out"; fi
# juju first on PATH is not the built one.
mkdir -p "$tmp/other-bin" && cp "$gp/bin/juju" "$tmp/other-bin/juju"
b="$tmp/bb-path" && rm -rf "$b" "$b.state" && mkdir -p "$b.state" && echo juju_version=4.0.14 >"$b.state/juju.env"
brc=0
env -i PATH="$tmp/other-bin:$gp/bin:$tmp/fake-go:$tmp/fake-snap-b:$PATH" HOME="$tmp" LAB_CONTROLLER=lab LAB_CLOUD=localhost LAB_JUJU_SOURCE=build \
	LAB_REF_SHA="$A" LAB_SRC="$tmp/jsrc" LAB_ARTIFACT_DIR="$b" LAB_STATE_DIR="$b.state" FAKE_LOG="$tmp/bb.log" FAKE_VERSION=4.0.14 FAKE_COMMIT="$A" \
	bash scripts/bootstrap.sh >"$b.out" 2>&1 || brc=$?
if ((brc == 2)) && grep -q "juju on PATH is '$tmp/other-bin/juju', expected the built $gp/bin/juju" "$b.state/setup-error.txt"; then
	pass "bootstrap build: juju on PATH is not GOPATH/bin/juju -> setup-error"
else
	bad "bootstrap build PATH (rc $brc)"
	cat "$b.out"
fi
boot_build k8sok microk8s FAKE_AGENT=4.0.14 FAKE_API_IMAGE=ghcr.io/juju/jujud-operator:4.0.14 FAKE_API_ID="$cfg"
if ((brc == 0)) && grep -qx agent_source=local "$b.state/juju.env" && grep -qx "$PWD bootstrap microk8s lab --debug --agent-version=4.0.14" "$tmp/bb.log" &&
	! grep -q 'juju:peers' "$b.out"; then
	pass "bootstrap build k8s: --agent-version, api-server imageID = imported config digest -> local"
else
	bad "bootstrap build k8s ok (rc $brc)"
	cat "$b.out" "$tmp/bb.log"
fi
boot_build k8stgt microk8s FAKE_AGENT=4.0.14 FAKE_API_ID="ghcr.io/juju/jujud-operator@$tgt"
if ((brc == 0)) && grep -qx agent_source=local "$b.state/juju.env"; then pass "bootstrap build k8s: imageID repo@<target digest> -> local"; else bad "bootstrap build k8s target (rc $brc)"; cat "$b.out"; fi
boot_build k8spub microk8s FAKE_AGENT=4.0.14 FAKE_API_ID="ghcr.io/juju/jujud-operator@sha256:$(printf '3%.0s' {1..64})"
if ((brc == 2)) && grep -q "is not the imported operator image" "$b.state/setup-error.txt" && grep -qx agent_source=unknown "$b.state/juju.env" &&
	grep -q '^controller_images=' "$b.state/juju.env"; then
	pass "bootstrap build k8s: public image digest -> setup-error, images still recorded"
else
	bad "bootstrap build k8s public (rc $brc)"
	cat "$b.out"
fi
boot_build k8sagent microk8s FAKE_AGENT=4.0.15 FAKE_API_ID="$cfg"
if ((brc == 2)) && grep -q "controller agent is 4.0.15, expected the built 4.0.14" "$b.state/setup-error.txt"; then pass "bootstrap build k8s: agent version != built -> setup-error"; else bad "bootstrap build k8s agent (rc $brc)"; cat "$b.out"; fi

# --- build-juju.sh: identity inputs and timings (fake go/make) ---------------------
bj="$tmp/bj"
mkdir -p "$bj/src/core/version" "$bj/fake" "$bj/gp/bin"
printf 'go-install:\n' >"$bj/src/Makefile"
echo 'const version = "4.0.15"' >"$bj/src/core/version/version.go"
git -C "$bj/src" init -q && git -C "$bj/src" add -A && git -C "$bj/src" -c user.name=t -c user.email=t@t commit -qm t
bj_sha=$(git -C "$bj/src" rev-parse HEAD)
cat >"$bj/fake/go" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in
"env GOPATH") echo "$FAKE_GP" ;;
"env GOMODCACHE") echo "$FAKE_GP/pkg/mod" ;;
"mod download") echo downloaded ;;
esac
FAKE
cat >"$bj/fake/make" <<'FAKE'
#!/usr/bin/env bash
printf '#!/usr/bin/env bash\nprintf "version: 4.0.15-ubuntu-amd64\\ngit-commit: %s\\ngit-tree-state: %s\\n"\n' "$(git rev-parse HEAD)" "${FAKE_BJ_TREE:-clean}" >"$FAKE_GP/bin/juju"
chmod +x "$FAKE_GP/bin/juju"
FAKE
chmod +x "$bj/fake/go" "$bj/fake/make"
bjrun() { # bjrun <name> [VAR=value...]
	o="$tmp/bj-$1"
	shift
	rm -rf "$o" && mkdir -p "$o/state"
	bjrc=0
	env -i PATH="$bj/fake:$PATH" HOME="$tmp" FAKE_GP="$bj/gp" LAB_SRC="$bj/src" LAB_REF_SHA="$bj_sha" LAB_SUBSTRATE=lxd \
		LAB_ARTIFACT_DIR="$o" LAB_STATE_DIR="$o/state" GITHUB_OUTPUT="$o/out" GITHUB_PATH="$o/path" "$@" bash scripts/build-juju.sh >"$o/log" 2>&1 || bjrc=$?
}
bjrun ok
if ((bjrc == 0)) && grep -q '^gomod_download_s=[0-9]' "$o/state/juju.env" && grep -q '^build_go_install_s=[0-9]' "$o/state/juju.env" &&
	grep -qx "juju_git_commit=$bj_sha" "$o/state/juju.env"; then
	pass "build-juju: clean tree -> gomod_download_s and build_go_install_s recorded separately"
else
	bad "build-juju ok (rc $bjrc)"
	cat "$o/log"
fi
bjrun gitcommit GIT_COMMIT="$bj_sha"
if ((bjrc == 2)) && grep -q "GIT_COMMIT must be unset" "$o/state/setup-error.txt"; then pass "build-juju: GIT_COMMIT in the environment -> setup-error (even with the right value)"; else bad "build-juju GIT_COMMIT (rc $bjrc)"; cat "$o/log"; fi
bjrun treestate GIT_TREE_STATE=clean
if ((bjrc == 2)) && grep -q "GIT_TREE_STATE must be unset" "$o/state/setup-error.txt"; then pass "build-juju: GIT_TREE_STATE in the environment -> setup-error"; else bad "build-juju GIT_TREE_STATE (rc $bjrc)"; cat "$o/log"; fi
bjrun builtdirty FAKE_BJ_TREE=dirty
if ((bjrc == 2)) && grep -q "git-tree-state 'dirty', expected clean" "$o/state/setup-error.txt"; then pass "build-juju: built juju reports a dirty tree -> setup-error"; else bad "build-juju built dirty (rc $bjrc)"; cat "$o/log"; fi
touch "$bj/src/stray"
bjrun dirty
rm -f "$bj/src/stray"
if ((bjrc == 2)) && grep -q "is not clean before the build" "$o/state/setup-error.txt" && ! grep -q '^gomod_download_s=' "$o/state/juju.env" 2>/dev/null; then
	pass "build-juju: untracked file in the checkout -> setup-error before any build"
else
	bad "build-juju dirty (rc $bjrc)"
	cat "$o/log"
fi

# --- resolve-tests.sh: build mode and explicit tests_ref ------------------------------
rt() { # rt <name> [VAR=value...]
	local n=$1
	shift
	rm -rf "$tmp/rtb-$n" && mkdir -p "$tmp/rtb-$n"
	rc=0
	env -i PATH="$PATH" LAB_STATE_DIR="$tmp/rtb-$n" GITHUB_OUTPUT="$tmp/rtb-$n/out" "$@" bash scripts/resolve-tests.sh >"$tmp/log" 2>&1 || rc=$?
}
rt build LAB_JUJU_SOURCE=build LAB_REF_SHA="$A"
if ((rc == 0)) && grep -qx "tests_sha=$A" "$tmp/rtb-build/out" && grep -qx tests_checkout=0 "$tmp/rtb-build/out" && grep -qx tests_source=ref "$tmp/rtb-build/juju.env"; then
	pass "resolve-tests: build mode -> ref_sha from the build checkout (tests_source ref, no sparse checkout)"
else
	bad "resolve-tests build (rc $rc)"
	cat "$tmp/log"
fi
rt explicit LAB_JUJU_SOURCE=build LAB_REF_SHA="$A" LAB_TESTS_REF_SHA="$T"
if ((rc == 0)) && grep -qx "tests_sha=$T" "$tmp/rtb-explicit/out" && grep -qx tests_checkout=1 "$tmp/rtb-explicit/out" && grep -qx tests_source=explicit "$tmp/rtb-explicit/juju.env"; then
	pass "resolve-tests: explicit tests_ref wins (tests_source explicit, sparse checkout)"
else
	bad "resolve-tests explicit (rc $rc)"
	cat "$tmp/log"
fi

# --- verdict.sh: build-mode fields --------------------------------------------------
art="$tmp/art-build"
pipeline "$art" scenarios selftest 1
printf '%s\n' "juju_version=4.0.14" "juju_git_commit=$A" source=build "ref_sha=$A" ref_version=4.0.14 build_go_install_s=600 build_s=700 gomodcache_mb=1500 gomod_download_s=55 \
	build_operator_image_s=100 "operator_image=ghcr.io/juju/jujud-operator:4.0.14" "operator_image_config=$cfg" "operator_image_target=$tgt" \
	"operator_image_base=public.ecr.aws/ubuntu/ubuntu:24.04@sha256:$(printf 'b%.0s' {1..64})" \
	controller_agent_version=4.0.14.1 agent_source=local >"$art.state/juju.env"
sed -i 's/^needs_juju=0$/needs_juju=1/' "$art.state/valid.env"
echo ref=v4.0.14 >>"$art.state/valid.env"
env -i PATH="$PATH" LAB_STATE_DIR="$art.state" LAB_ARTIFACT_DIR="$art" LAB_SUBSTRATE=lxd \
	VALIDATE_OUTCOME=success READY_OUTCOME=success SCENARIO_OUTCOME=success bash scripts/verdict.sh >"$tmp/log" 2>&1
check "verdict: build mode -> source build, ref_sha, juju_channel null, build{timings, operator_image incl. base}, no cache fields" "$art" \
	".source == \"build\" and .ref_sha == \"$A\" and .ref == \"v4.0.14\" and .juju_channel == null and .juju_snap_revision == null and .build.build_s == 700 and .build.go_install_s == 600 and .build.gomod_download_s == 55 and .build.gomodcache_mb == 1500 and (.build | has(\"gomod_cache\") | not) and .build.operator_image.config_digest == \"$cfg\" and (.build.operator_image.base | endswith(\"@sha256:$(printf 'b%.0s' {1..64})\")) and .controller_agent_version == \"4.0.14.1\""
art="$tmp/art-buildmin"
pipeline "$art" scenarios selftest 1
printf '%s\n' source=build >"$art.state/juju.env"
env -i PATH="$PATH" LAB_STATE_DIR="$art.state" LAB_ARTIFACT_DIR="$art" LAB_SUBSTRATE=lxd \
	VALIDATE_OUTCOME=success READY_OUTCOME=success SCENARIO_OUTCOME=success bash scripts/verdict.sh >"$tmp/log" 2>&1
check "verdict: build mode with no timings recorded -> null fields, operator_image null" "$art" '.build.build_s == null and .build.gomod_download_s == null and .build.operator_image == null'
art="$tmp/art-snapsrc"
pipeline "$art" scenarios selftest 1
check "verdict: snap/none runs have build null and ref_sha null" "$art" '.build == null and .ref_sha == null'

# --- verdict.sh: juju + scrub state -> verdict.json, job outputs ----------------------
art="$tmp/art-jujustate"
pipeline "$art" scenarios selftest 1
printf '%s\n' juju_version=4.0.1 juju_git_commit=0123456789abcdef0123456789abcdef01234567 juju_snap_revision=31000 source=snap \
	substrate_snap_name=lxd substrate_snap_channel=latest/candidate substrate_snap_revision=33000 \
	tests_sha=0123456789abcdef0123456789abcdef01234567 tests_source=git-commit \
	'controller_images=[{"name":"api-server","image":"ghcr.io/juju/jujud-operator:4.0.1","imageID":"ghcr.io/juju/jujud-operator@sha256:aa"}]' >"$art.state/juju.env"
echo 'snap_drift=microk8s rev 9064 -> 9100' >"$art.state/collect.env"
printf '%s\n' scrub_hits=2 upload_blocked=false upload_blocked_path= >"$art.state/scrub.env"
: >"$art.vout"
env -i PATH="$PATH" LAB_STATE_DIR="$art.state" LAB_ARTIFACT_DIR="$art" LAB_SUBSTRATE=lxd \
	VALIDATE_OUTCOME=success READY_OUTCOME=success SCENARIO_OUTCOME=success GITHUB_OUTPUT="$art.vout" \
	bash scripts/verdict.sh >"$tmp/log" 2>&1
check "verdict: juju.env + scrub.env fields" "$art" \
	'.juju_version == "4.0.1" and .juju_snap_revision == 31000 and .tests_source == "git-commit" and .substrate_snap.revision == 33000 and .scrub_hits == 2 and .upload_blocked == false and .upload_blocked_path == null and .controller_images[0].imageID == "ghcr.io/juju/jujud-operator@sha256:aa" and .snap_drift == "microk8s rev 9064 -> 9100"'
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

# Duplicate keys in harness state are rejected (no last-wins override).
art="$tmp/art-dup"
pipeline "$art" scenarios selftest 1
printf '%s\n' scrub_hits=0 upload_blocked=true upload_blocked_path=x upload_blocked=false >"$art.state/scrub.env"
: >"$art.vout"
env -i PATH="$PATH" LAB_STATE_DIR="$art.state" LAB_ARTIFACT_DIR="$art" LAB_SUBSTRATE=lxd \
	VALIDATE_OUTCOME=success READY_OUTCOME=success SCENARIO_OUTCOME=success GITHUB_OUTPUT="$art.vout" \
	bash scripts/verdict.sh >"$tmp/log" 2>&1
if jq -e '.verdict == "error" and (.reason | test("upload_blocked repeated")) and .upload_blocked == true' "$art/verdict.json" >/dev/null &&
	grep -qx 'upload_blocked=true' "$art.vout"; then
	pass "verdict: repeated state key -> error, upload reported blocked"
else
	bad "verdict duplicate key"
	cat "$art/verdict.json"
fi
# Agent, deps, branch warning, bootstrap excerpt.
art="$tmp/art-agent"
pipeline "$art" scenarios selftest 1
printf '%s\n' controller_agent_version=4.0.15 agent_source=packaged 'dep_charmcraft=4.x/stable 8265' \
	tests_sha=0123456789abcdef0123456789abcdef01234567 tests_source=branch bootstrap_failed=1 >"$art.state/juju.env"
printf '%s\n' scrub_hits=0 upload_blocked=false upload_blocked_path= scrub_dropped=0 scrub_withheld=0 >"$art.state/scrub.env"
mkdir -p "$art/collect" && printf 'boot line %s\n' 1 2 3 >"$art/collect/bootstrap.log"
: >"$art.summary"
env -i PATH="$PATH" LAB_STATE_DIR="$art.state" LAB_ARTIFACT_DIR="$art" LAB_UPLOAD_DIR="$art" LAB_SUBSTRATE=lxd \
	VALIDATE_OUTCOME=success READY_OUTCOME=skipped SCENARIO_OUTCOME=skipped GITHUB_STEP_SUMMARY="$art.summary" \
	bash scripts/verdict.sh >"$tmp/log" 2>&1
check "verdict: controller_agent_version, agent_source, deps [{name, channel, revision}]" "$art" \
	'.controller_agent_version == "4.0.15" and .agent_source == "packaged" and .deps == [{"name":"charmcraft","channel":"4.x/stable","revision":8265}] and .scrub_dropped == 0'
if grep -q '^\*\*Warning:\*\* tests/ came from the branch head' "$art.summary" && grep -q 'Last 30 lines of collect/bootstrap.log' "$art.summary" && grep -qx 'boot line 3' "$art.summary"; then
	pass "summary: branch tests warning and bootstrap log excerpt"
else
	bad "summary warning/bootstrap"
	cat "$art.summary"
fi

# --- lib.sh state_set: one write per key ----------------------------------------------
rc=0
mkdir -p "$tmp/lib-state"
env -i PATH="$PATH" LAB_STATE_DIR="$tmp/lib-state" bash -c '. scripts/lib.sh; state_set a 1; state_set a 2' >"$tmp/log" 2>&1 || rc=$?
if [[ $rc == 2 ]] && grep -q 'state_set: a already set' "$tmp/lib-state/setup-error.txt"; then pass "state_set: second write of a key -> setup-error"; else bad "state_set dup: rc $rc"; fi

# --- resolve-tests.sh: only HTTP 404 falls through --------------------------------------
fg="$tmp/fake-gh"
mkdir -p "$fg"
cat >"$fg/gh" <<'FAKE'
#!/usr/bin/env bash
case $2 in
*/commits/v*) echo "gh: Not Found (HTTP $FAKE_TAG_CODE)" >&2; exit 1 ;;
*/commits/4.0) echo 89abcdef0123456789abcdef0123456789abcdef ;;
esac
FAKE
chmod +x "$fg/gh"
rc_404="" rc_500=""
for code in 404 500; do
	rm -rf "$tmp/rt-$code" && mkdir -p "$tmp/rt-$code" && echo juju_version=4.0.99 >"$tmp/rt-$code/juju.env"
	rc=0
	env -i PATH="$fg:$PATH" FAKE_TAG_CODE=$code LAB_STATE_DIR="$tmp/rt-$code" GITHUB_OUTPUT="$tmp/rt-$code/out" bash scripts/resolve-tests.sh >"$tmp/log" 2>&1 || rc=$?
	printf -v "rc_$code" %s "$rc"
done
if [[ ${rc_404} == 0 ]] && grep -qx 'tests_source=branch' "$tmp/rt-404/juju.env" && [[ ${rc_500} == 2 ]] && grep -q 'API error on tag' "$tmp/rt-500/setup-error.txt"; then
	pass "resolve-tests: 404 -> branch fallback; 500 -> setup-error (fail closed)"
else
	bad "resolve-tests: 404 rc ${rc_404}, 500 rc ${rc_500}"
	cat "$tmp/log"
fi

# --- deps.sh -----------------------------------------------------------------------
rc=0
env -i PATH="$PATH" LAB_STATE_DIR="$tmp/deps-state" LAB_DEPS=nonexistent bash scripts/deps.sh >"$tmp/log" 2>&1 || rc=$?
if [[ $rc == 2 ]] && grep -q "unknown dependency 'nonexistent'" "$tmp/deps-state/setup-error.txt"; then pass "deps: unknown dep -> exit 2 with reason"; else bad "deps unknown: rc $rc"; cat "$tmp/log"; fi

# --- build-operator-image.sh: one retry on a registry 429 only -------------------------
fo="$tmp/fake-opimg"
mkdir -p "$fo" "$tmp/opsrc"
cat >"$fo/make" <<'FAKE'
#!/usr/bin/env bash
n=$(($(cat "$FAKE_DIR/make.n" 2>/dev/null || echo 0) + 1))
echo "$n" >"$FAKE_DIR/make.n"
if ((n <= FAKE_MAKE_FAILS)); then
	err=$FAKE_MAKE_ERR
	((n > 1)) && err=${FAKE_MAKE_ERR2:-$FAKE_MAKE_ERR}
	echo "ERROR: failed to solve: $err"
	exit 1
fi
[[ -n ${FAKE_NO_BASE:-} ]] || echo "#5 [1/4] FROM public.ecr.aws/ubuntu/ubuntu:24.04@sha256:$(printf 'b%.0s' {1..64})"
echo "built"
FAKE
cat >"$fo/docker" <<'FAKE'
#!/usr/bin/env bash
case $1 in
inspect | image) echo "sha256:$(printf 'c%.0s' {1..64})" ;;
save) echo image-tar ;;
esac
FAKE
cat >"$fo/sg" <<'FAKE'
#!/usr/bin/env bash
cat >/dev/null
case $3 in
*"images ls"*) echo "REF TYPE DIGEST"; echo "$LAB_OPERATOR_IMAGE application/x sha256:$(printf 'd%.0s' {1..64})" ;;
esac
FAKE
chmod +x "$fo/make" "$fo/docker" "$fo/sg"
opimg() { # opimg <name> <fails> <err> [VAR=value...]
	o="$tmp/op-$1"
	rm -rf "$o" && mkdir -p "$o/collect" "$o/state" "$o/fd"
	orc=0
	local f=$2 e=$3
	shift 3
	env -i PATH="$fo:$PATH" FAKE_DIR="$o/fd" FAKE_MAKE_FAILS="$f" FAKE_MAKE_ERR="$e" "$@" LAB_OPERATOR_RETRY_S=0 LAB_BUILT_VERSION=4.0.15 \
		LAB_SRC="$tmp/opsrc" LAB_ARTIFACT_DIR="$o" LAB_STATE_DIR="$o/state" bash scripts/build-operator-image.sh >"$o/out" 2>&1 || orc=$?
}
opimg r429 1 "429 Too Many Requests"
if ((orc == 0)) && [[ $(cat "$o/fd/make.n") == 2 ]] && grep -q "^operator_image_target=sha256:d" "$o/state/juju.env" &&
	grep -qx "operator_image_base=public.ecr.aws/ubuntu/ubuntu:24.04@sha256:$(printf 'b%.0s' {1..64})" "$o/state/juju.env" &&
	grep -q '^=== make operator-image attempt 2 (rc 0)' "$o/collect/build-operator-image.log"; then
	pass "operator image: one 429 -> retried once, imported, base digest recorded, both attempts in the log"
else
	bad "operator image 429 retry (rc $orc)"
	cat "$o/out"
fi
opimg r429x2 2 "429 Too Many Requests"
if ((orc == 2)) && [[ $(cat "$o/fd/make.n") == 2 ]] && grep -q "rate-limited (429) after 2 attempts" "$o/state/setup-error.txt"; then
	pass "operator image: 429 twice -> setup-error naming the rate limit, no third attempt"
else
	bad "operator image 429 twice (rc $orc)"
	cat "$o/out"
fi
opimg r429other 2 "429 Too Many Requests" FAKE_MAKE_ERR2="some compile error"
if ((orc == 2)) && [[ $(cat "$o/fd/make.n") == 2 ]] && grep -qx "make operator-image failed (see collect/build-operator-image.log in the artifact)" "$o/state/setup-error.txt"; then
	pass "operator image: 429 then a real failure on the retry -> generic reason, not rate-limited"
else
	bad "operator image 429 then other (rc $orc)"
	cat "$o/out" "$o/state/setup-error.txt"
fi
opimg nobase 0 "" FAKE_NO_BASE=1
if ((orc == 2)) && grep -q "could not read the operator base image digest" "$o/state/setup-error.txt"; then pass "operator image: no resolved base digest in the log -> setup-error"; else bad "operator image no base (rc $orc)"; cat "$o/out"; fi
opimg other 1 "some compile error"
if ((orc == 2)) && [[ $(cat "$o/fd/make.n") == 1 ]] && grep -qx "make operator-image failed (see collect/build-operator-image.log in the artifact)" "$o/state/setup-error.txt"; then
	pass "operator image: other make failure -> setup-error, no retry"
else
	bad "operator image other failure (rc $orc)"
	cat "$o/out"
fi

exit "$status"
