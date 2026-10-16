#!/usr/bin/env bash
# Runs scenarios/$LAB_SCENARIO/run.sh LAB_REPEAT times. Each iteration is a fresh
# bash process under `timeout -k 60 <TIMEOUT_MIN>m`, so no exported state leaks
# between iterations and one hang can't eat the step. Appends one JSON line per
# iteration to $LAB_ARTIFACT_DIR/results.jsonl and stops after an infra error (2)
# or an error (any exit other than 0/1/2/3). Always exits 0: verdict.sh decides.
set -euo pipefail
export LC_ALL=C

: "${LAB_SCENARIO:?}" "${LAB_REPEAT:?}" "${LAB_TIMEOUT_MIN:?}" "${LAB_ARTIFACT_DIR:?}"
dir="${LAB_SCENARIOS_DIR:-scenarios}/$LAB_SCENARIO"
results="$LAB_ARTIFACT_DIR/results.jsonl"
mkdir -p "$LAB_ARTIFACT_DIR"
: >"$results"

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
	LAB_ITERATION=$i LAB_SCENARIO_DIR=$dir \
		timeout -k 60 "${LAB_TIMEOUT_MIN}m" bash "$dir/run.sh" >"$log" 2>&1 || rc=$?
	duration=$(($(date +%s) - start))
	cat "$log"
	echo "::endgroup::"
	v=$(verdict_of "$rc")
	# Cleanup between iterations (destroy models, wait for k8s namespaces) lands
	# with the Juju substrates in PR-3/PR-4; cleanup_s is 0 until then.
	cleanup_s=0
	jq -cn --argjson i "$i" --argjson rc "$rc" --arg v "$v" \
		--argjson d "$duration" --argjson c "$cleanup_s" \
		'{iteration: $i, exit_code: $rc, verdict: $v, duration_s: $d, cleanup_s: $c}' >>"$results"
	echo "iteration $i: exit $rc -> $v (${duration}s)"
	if [[ $v == setup-error || $v == error ]]; then
		echo "stopping after iteration $i ($v)"
		break
	fi
done
exit 0
