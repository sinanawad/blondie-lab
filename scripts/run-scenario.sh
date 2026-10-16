#!/usr/bin/env bash
# Runs scenarios/$LAB_SCENARIO/run.sh LAB_REPEAT times. Each iteration is a fresh
# bash process under `timeout -k <grace> <TIMEOUT_MIN>m`, so no exported state
# leaks between iterations and one hang can't eat the step. Appends one JSON line
# per iteration to $LAB_STATE_DIR/results.jsonl (harness-owned; verdict.sh copies
# it into the artifact) and stops after an infra error (2) or an error (any exit
# other than 0/1/2/3). Always exits 0: verdict.sh decides.
#
# With LAB_NEEDS_JUJU=1, every non-controller model is destroyed between
# iterations (cleanup-models.sh, one 5 min budget; cleanup_s records it). A
# cleanup that doesn't finish stops the loop as setup-error ($LAB_STATE_DIR/stop.env).
# suite.sh reports a matched infra signature through $LAB_SIGNAL_FILE; it is
# accepted only with exit 2 and recorded in $LAB_STATE_DIR/infra-signature.txt.
#
# Isolation: the scenario gets no GITHUB_ENV/OUTPUT/PATH/STATE/STEP_SUMMARY and no
# LAB_STATE_DIR, and its output is replayed into the step log between
# ::stop-commands:: markers, so it can't issue workflow commands.
# The step log is public and outlives the artifact, so the replay goes through
# scripts/redact.pl (the scrub's rules) and is withheld entirely when the log
# holds private key material. After each iteration, every process still
# carrying that iteration's LAB_ITER_TOKEN is killed, so nothing keeps writing
# into the artifact dir (scrub.sh also works on a snapshot).
# (Same OS user, so this is integrity against accidents and naive output, not a
# sandbox.)
set -euo pipefail
export LC_ALL=C

: "${LAB_SCENARIO:?}" "${LAB_REPEAT:?}" "${LAB_TIMEOUT_MIN:?}" "${LAB_ARTIFACT_DIR:?}" "${LAB_STATE_DIR:?}"
# Test-only knobs (test-harness.sh); the workflow never sets them.
iter_timeout=${LAB_ITER_TIMEOUT:-${LAB_TIMEOUT_MIN}m}
kill_grace=${LAB_KILL_GRACE:-60}
[[ $iter_timeout =~ ^[0-9]+[sm]$ ]] || { echo "::error::bad LAB_ITER_TIMEOUT"; exit 0; }
[[ $kill_grace =~ ^[0-9]+$ ]] || { echo "::error::bad LAB_KILL_GRACE"; exit 0; }

dir="${LAB_SCENARIOS_DIR:-scenarios}/$LAB_SCENARIO"
# juju/juju smoke.yml sets MODEL_ARCH for the suites (design §3); snap mode has no Go.
if [[ ${LAB_NEEDS_JUJU:-0} == 1 && -z ${MODEL_ARCH:-} ]]; then
	MODEL_ARCH=$(dpkg --print-architecture 2>/dev/null || true)
	export MODEL_ARCH
fi
results="$LAB_STATE_DIR/results.jsonl"
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$LAB_ARTIFACT_DIR" "$LAB_STATE_DIR"
: >"$results"
rm -f "$LAB_STATE_DIR/stop.env" "$LAB_STATE_DIR/infra-signature.txt"
sigdir=$(mktemp -d)
trap 'rm -rf "$sigdir"' EXIT

# reap <token>: SIGKILL every process whose environment carries LAB_ITER_TOKEN=<token>.
reap() {
	local tok=$1 n=0 found p pid
	for _ in 1 2 3 4 5; do
		found=0
		for p in /proc/[0-9]*; do
			pid=${p#/proc/}
			[[ $pid == "$$" || $pid == "$BASHPID" ]] && continue
			if tr '\0' '\n' 2>/dev/null <"$p/environ" | grep -qxF "LAB_ITER_TOKEN=$tok"; then
				kill -KILL "$pid" 2>/dev/null && found=$((found + 1))
			fi
		done
		n=$((n + found))
		((found == 0)) && break
		sleep 1
	done
	echo "$n"
}

verdict_of() {
	case $1 in
	0) echo pass ;;
	1) echo fail ;;
	2) echo setup-error ;;
	3) echo inconclusive ;;
	*) echo error ;;
	esac
}

for ((i = 1; i <= LAB_REPEAT; i++)); do
	log="$LAB_ARTIFACT_DIR/iteration-$i.log"
	echo "::group::iteration $i/$LAB_REPEAT"
	start=$(date +%s)
	rc=0
	sig="$sigdir/signal-$i"
	itok=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
	env -u GITHUB_ENV -u GITHUB_OUTPUT -u GITHUB_PATH -u GITHUB_STATE -u GITHUB_STEP_SUMMARY \
		-u LAB_STATE_DIR LAB_ITERATION="$i" LAB_SCENARIO_DIR="$dir" LAB_SIGNAL_FILE="$sig" LAB_ITER_TOKEN="$itok" \
		timeout -k "$kill_grace" "$iter_timeout" bash "$dir/run.sh" >"$log" 2>&1 </dev/null || rc=$?
	duration=$(($(date +%s) - start))
	reaped=$(reap "$itok")
	tok=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
	echo "::stop-commands::$tok"
	pk=0
	"$here/redact.pl" --pk "$log" || pk=$?
	if ((pk != 1)); then
		echo "iteration $i log withheld from the step log (private key material, or unreadable)"
	else
		"$here/redact.pl" <"$log" || echo "iteration $i: redaction failed; rest of the log withheld"
	fi
	echo "::$tok::"
	echo "::endgroup::"
	((reaped == 0)) || echo "iteration $i: killed $reaped leftover process(es)"
	v=$(verdict_of "$rc")
	if [[ $rc == 2 && -s $sig && ! -s $LAB_STATE_DIR/infra-signature.txt ]]; then
		head -n 1 "$sig" | cut -c1-500 >"$LAB_STATE_DIR/infra-signature.txt"
		echo "iteration $i: infra signature: $(cat "$LAB_STATE_DIR/infra-signature.txt")"
	fi
	stop=""
	[[ $v == setup-error || $v == error ]] && stop=$v
	cleanup_s=0
	if [[ -z $stop && $i -lt $LAB_REPEAT && ${LAB_NEEDS_JUJU:-0} == 1 ]]; then
		c0=$(date +%s)
		if ! timeout -k 10 "${LAB_CLEANUP_TIMEOUT:-300}" "$here/cleanup-models.sh" >"$LAB_ARTIFACT_DIR/cleanup-$i.log" 2>&1; then
			stop=cleanup
			printf 'stop=cleanup\niteration=%s\n' "$i" >"$LAB_STATE_DIR/stop.env"
		fi
		cleanup_s=$(($(date +%s) - c0))
		echo "cleanup after iteration $i: ${cleanup_s}s${stop:+ (did not finish)}"
	fi
	jq -cn --argjson i "$i" --argjson rc "$rc" --arg v "$v" \
		--argjson d "$duration" --argjson c "$cleanup_s" \
		'{iteration: $i, exit_code: $rc, verdict: $v, duration_s: $d, cleanup_s: $c}' >>"$results"
	echo "iteration $i: exit $rc -> $v (${duration}s)"
	if [[ -n $stop ]]; then
		echo "stopping after iteration $i ($stop)"
		break
	fi
done
exit 0
