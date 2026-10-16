#!/usr/bin/env bash
# Writes $LAB_ARTIFACT_DIR/verdict.json (schema v1, design §4) and the job summary
# from the step outcomes and the harness state in $LAB_STATE_DIR. Runs with
# if: always(), so it must work whatever happened earlier. Outputs verdict= and
# artifact_name= to $GITHUB_OUTPUT. Exits 0; the workflow's last step turns the
# verdict into the job colour.
#
# Echoed values come only from $LAB_STATE_DIR/valid.env (fields that passed their
# own check in validate.sh); a field that didn't pass is null. Raw inputs are
# never read here.
set -euo pipefail
export LC_ALL=C

ARTIFACT_DIR=${LAB_ARTIFACT_DIR:?}
STATE_DIR=${LAB_STATE_DIR:?}
mkdir -p "$ARTIFACT_DIR" "$STATE_DIR"
results="$STATE_DIR/results.jsonl"
out="$ARTIFACT_DIR/verdict.json"
OUT=${GITHUB_OUTPUT:-/dev/null}
SUMMARY=${GITHUB_STEP_SUMMARY:-/dev/null}
[[ -f $results ]] || : >"$results"

# Parse (never source) valid.env into ok_<field> / val_<field>.
declare -A val=()
if [[ -f $STATE_DIR/valid.env ]]; then
	while IFS= read -r line; do
		[[ $line =~ ^([a-z_]+)=(.*)$ ]] && val[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
	done <"$STATE_DIR/valid.env"
fi
has() { [[ -n ${val[$1]+x} ]]; }
repeat=${val[repeat]:-}
reason=""

if [[ ${VALIDATE_OUTCOME:-} != success ]]; then
	verdict=setup-error
	reason=$(cat "$STATE_DIR/validate-error.txt" 2>/dev/null || echo "input validation did not complete (${VALIDATE_OUTCOME:-unknown})")
	: >"$results"
elif [[ ${READY_OUTCOME:-} != success ]]; then
	# A step between validate and ready (substrate setup, bootstrap: PR-3/PR-4)
	# failed or was skipped: design §4 maps this to setup-error before the scenario runs.
	verdict=setup-error
	reason="setup did not complete (ready step: ${READY_OUTCOME:-unknown})"
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

# Harness state goes into the artifact as written by the harness.
cp "$results" "$ARTIFACT_DIR/results.jsonl"
[[ -f $STATE_DIR/validate-error.txt ]] && cp "$STATE_DIR/validate-error.txt" "$ARTIFACT_DIR/validate-error.txt"

no_juju=false
[[ ${val[needs_juju]:-} == 0 ]] && no_juju=true
j() { if has "$1"; then printf '%s' "${val[$1]}"; fi; }
jq -n \
	--arg verdict "$verdict" --arg reason "$reason" \
	--arg scenario "$(j scenario)" --arg substrate "${LAB_SUBSTRATE:-}" \
	--arg channel "$(j juju_channel)" --arg ref "$(j ref)" \
	--arg tests_ref "$(j tests_ref)" --arg request_id "$(j request_id)" \
	--arg repeat "$repeat" --argjson no_juju "$no_juju" \
	--arg lab_sha "${GITHUB_SHA:-}" \
	--arg runner_image "${ImageOS:-unknown}/${ImageVersion:-unknown}" \
	--arg run_url "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}" \
	--slurpfile results "$results" '
	def v(x): if x != "" then x else null end;
	{
		schema_version: 1,
		scenario: v($scenario), substrate: $substrate, verdict: $verdict,
		reason: v($reason),
		juju_version: null, juju_git_commit: null, juju_snap_revision: null,
		juju_channel: (if $no_juju then null else v($channel) end),
		source: (if $no_juju then "none" else null end),
		ref: v($ref), ref_sha: null,
		tests_ref: v($tests_ref), tests_sha: null, tests_source: null,
		lab_sha: $lab_sha, runner_image: $runner_image, substrate_snap: null,
		iterations: (if $repeat == "" then null else ($repeat | tonumber) end),
		failed: ($results | map(select(.verdict == "fail")) | length),
		results: $results,
		infra_signature: null, scrub_hits: null,
		upload_blocked: false, upload_blocked_path: null,
		request_id: v($request_id), run_url: $run_url
	}' >"$out"

# Named by scenario whenever the scenario name passed its own check (design §6:
# the dispatcher downloads by run id with -p 'lab-logs-*').
if has scenario; then
	artifact_name="lab-logs-${val[scenario]}-${GITHUB_RUN_ID:-local}"
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
	# Design §7: show the first failing iteration, else the first non-pass one.
	first_bad=$(jq -r '([.results[] | select(.verdict == "fail")][0] // [.results[] | select(.verdict != "pass")][0]).iteration // empty' "$out")
	if [[ -n $first_bad && -f $ARTIFACT_DIR/iteration-$first_bad.log ]]; then
		echo
		echo "Last 50 lines of iteration $first_bad:"
		echo '```'
		tail -n 50 "$ARTIFACT_DIR/iteration-$first_bad.log" | tr '`' "'"
		echo '```'
	fi
} >>"$SUMMARY"
echo "verdict: $verdict ${reason:+($reason)}"
