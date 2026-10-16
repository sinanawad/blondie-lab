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
bypass_case 'macaroon-<id>= cookie' 'macaroon-abc_12-z=<redacted> Path=/' 'macaroon-abc_12-z=eyJhYmMi; Path=/'
rm -rf "$tmp/bp" && mkdir -p "$tmp/bp" && printf '%s\n' 'admin-secret: |' '    line one' 'next: 1' >"$tmp/bp/f.txt" && scrub_run bp
if grep -qx 'next: 1' "$tmp/bp.up/f.txt" && ! grep -q 'line one' "$tmp/bp.up/f.txt"; then pass "scrub: YAML block ends at the next key"; else bad "scrub block end"; cat "$tmp/bp.up/f.txt"; fi
art="$tmp/clean"
rm -rf "$art" && mkdir -p "$art"
printf '%s\n' 'password reset requested' 'juju add-model --password-stdin' 'cert: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t' >"$art/c.txt"
scrub_run clean
if sx clean scrub_hits=0 && sx clean upload_blocked=false; then pass "scrub: no key/value form, base64 certificate -> 0 hits, not blocked"; else bad "scrub clean"; cat "$art.st/scrub.env"; fi
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
echo m1 >"$tmp/fake.models"
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
echo m1 >"$tmp/fake.models"
fakens m1 stuck m1
cleanup_run nsstuck LAB_SUBSTRATE=k8s LAB_CLEANUP_TIMEOUT=3
if ((crc == 1)) && grep -q 'cleanup: still present after 3s: m1' "$tmp/nsstuck.out"; then
	pass "cleanup k8s: a namespace still there when the shared budget runs out -> exit 1"
else
	bad "cleanup k8s stuck namespace (rc $crc)"
	cat "$tmp/nsstuck.out"
fi
echo m1 >"$tmp/fake.models"
fakens m1 stuck m1
cleanup_run nslxd LAB_SUBSTRATE=lxd LAB_CLEANUP_TIMEOUT=3
if ((crc == 0)) && ! grep -q kubectl "$tmp/fake.log"; then pass "cleanup lxd: no namespace wait"; else bad "cleanup lxd (rc $crc)"; cat "$tmp/nslxd.out"; fi

# bootstrap.sh watchdog: a hung bootstrap is dumped (k8s) before juju is killed.
fb="$tmp/fake-boot"
mkdir -p "$fb"
cat >"$fb/juju" <<'FAKE'
#!/usr/bin/env bash
case $1 in
clouds) echo '{"microk8s":{"type":"k8s"}}' ;;
bootstrap) echo "$$" >"$FAKE_PID"; exec sleep 60 ;;
esac
FAKE
cat >"$fb/snap" <<'FAKE'
#!/usr/bin/env bash
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
	env -i PATH="$fb:$fk:$PATH" HOME="$tmp" LAB_CONTROLLER=lab LAB_CLOUD=$cl LAB_BOOTSTRAP_TIMEOUT=3 LAB_ARTIFACT_DIR="$b" \
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
b="$tmp/boot-bad"
mkdir -p "$b.state"
brc=0
env -i PATH="$fb:$PATH" LAB_CONTROLLER=lab LAB_CLOUD=aws LAB_ARTIFACT_DIR="$b" LAB_STATE_DIR="$b.state" bash scripts/bootstrap.sh >"$b.out" 2>&1 || brc=$?
if ((brc == 2)) && grep -q 'LAB_CLOUD: unexpected value' "$b.state/setup-error.txt"; then pass "bootstrap: LAB_CLOUD outside localhost|microk8s -> setup-error"; else bad "bootstrap bad cloud"; fi

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

exit "$status"
