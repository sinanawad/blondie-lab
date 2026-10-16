#!/usr/bin/env bash
# Writes $LAB_ARTIFACT_DIR/verdict.json (schema v1, design §4) and the job summary
# from the validate outcome and results.jsonl. Runs with if: always(), so it must
# work whatever happened earlier. Outputs verdict= and artifact_name= to
# $GITHUB_OUTPUT. Exits 0; the workflow's last step turns the verdict into the
# job colour.
set -euo pipefail
export LC_ALL=C

ARTIFACT_DIR=${LAB_ARTIFACT_DIR:?}
mkdir -p "$ARTIFACT_DIR"
results="$ARTIFACT_DIR/results.jsonl"
out="$ARTIFACT_DIR/verdict.json"
OUT=${GITHUB_OUTPUT:-/dev/null}
SUMMARY=${GITHUB_STEP_SUMMARY:-/dev/null}
repeat=${LAB_IN_REPEAT:-}
reason=""

if [[ ${VALIDATE_OUTCOME:-} != success ]]; then
	verdict=setup-error
	reason=$(cat "$ARTIFACT_DIR/validate-error.txt" 2>/dev/null || echo "input validation did not complete (${VALIDATE_OUTCOME:-unknown})")
	: >"$results"
elif [[ ! -s $results ]]; then
	verdict=error
	reason="no iteration result recorded (scenario step: ${SCENARIO_OUTCOME:-unknown})"
else
	# Design §4 aggregation: fail beats everything; else a stop (setup-error or
	# error) wins; else inconclusive; else pass. Fewer results than requested
	# without a recorded stop means the step was cut short (timeout/cancel).
	verdict=$(jq -rs --argjson n "$repeat" '
		(map(.verdict)) as $v
		| if any($v[]; . == "fail") then "fail"
		  elif any($v[]; . == "setup-error") then "setup-error"
		  elif any($v[]; . == "error") then "error"
		  elif length < $n then "error"
		  elif any($v[]; . == "inconclusive") then "inconclusive"
		  else "pass" end' "$results")
	n_done=$(jq -s length "$results")
	if [[ $verdict == error && $n_done -lt $repeat ]] && ! jq -se 'any(.[]; .verdict == "error")' "$results" >/dev/null; then
		reason="only $n_done of $repeat iterations recorded (scenario step: ${SCENARIO_OUTCOME:-unknown})"
	fi
fi

# A value is only echoed as-is once validated; otherwise it is recorded as null.
valid() { [[ ${VALIDATE_OUTCOME:-} == success ]]; }
jq -n \
	--arg verdict "$verdict" --arg reason "$reason" \
	--arg scenario "${LAB_IN_SCENARIO:-}" --arg substrate "${LAB_SUBSTRATE:-}" \
	--arg channel "${LAB_IN_JUJU_CHANNEL:-}" --arg ref "${LAB_IN_REF:-}" \
	--arg tests_ref "${LAB_IN_TESTS_REF:-}" --arg request_id "${LAB_IN_REQUEST_ID:-}" \
	--arg repeat "$repeat" --arg needs_juju "${LAB_NEEDS_JUJU:-}" \
	--arg lab_sha "${GITHUB_SHA:-}" \
	--arg runner_image "${ImageOS:-unknown}/${ImageVersion:-unknown}" \
	--arg run_url "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}" \
	--argjson valid "$(valid && echo true || echo false)" \
	--slurpfile results "$results" '
	def v(x): if $valid and x != "" then x else null end;
	{
		schema_version: 1,
		scenario: v($scenario), substrate: $substrate, verdict: $verdict,
		reason: (if $reason == "" then null else $reason end),
		juju_version: null, juju_git_commit: null, juju_snap_revision: null,
		juju_channel: v($channel),
		source: (if $valid and $needs_juju == "0" then "none" else null end),
		ref: v($ref), ref_sha: null,
		tests_ref: v($tests_ref), tests_sha: null, tests_source: null,
		lab_sha: $lab_sha, runner_image: $runner_image, substrate_snap: null,
		iterations: (if $valid then ($repeat | tonumber) else null end),
		failed: ($results | map(select(.verdict == "fail")) | length),
		results: $results,
		infra_signature: null, scrub_hits: null,
		upload_blocked: false, upload_blocked_path: null,
		request_id: v($request_id), run_url: $run_url
	}' >"$out"

if valid; then
	artifact_name="lab-logs-${LAB_IN_SCENARIO}-${GITHUB_RUN_ID:-local}"
else
	artifact_name="lab-logs-invalid-${GITHUB_RUN_ID:-local}"
fi
{
	echo "verdict=$verdict"
	echo "artifact_name=$artifact_name"
} >>"$OUT"

# Job summary. Backticks are replaced so no value can close the code fence.
n_fail=$(jq .failed "$out")
n_done=$(jq '.results | length' "$out")
{
	echo "## lab verdict: \`$verdict\`"
	echo
	[[ -n $reason ]] && echo "Reason: $(printf '%s' "$reason" | tr '`' "'")" && echo
	echo "Failed iterations: $n_fail/$n_done recorded (requested: ${repeat:-?})"
	echo
	echo '```json'
	tr '`' "'" <"$out"
	echo '```'
	first_bad=$(jq -r '[.results[] | select(.verdict != "pass")][0].iteration // empty' "$out")
	if [[ -n $first_bad && -f $ARTIFACT_DIR/iteration-$first_bad.log ]]; then
		echo
		echo "Last 50 lines of iteration $first_bad:"
		echo '```'
		tail -n 50 "$ARTIFACT_DIR/iteration-$first_bad.log" | tr '`' "'"
		echo '```'
	fi
} >>"$SUMMARY"
echo "verdict: $verdict ${reason:+($reason)}"
