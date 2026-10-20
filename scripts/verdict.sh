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

# In the workflow this runs after scrub.sh with LAB_UPLOAD_DIR set: verdict.json
# then goes into the scrubbed snapshot (the tree that is uploaded), and job
# summary excerpts are read only from there, only after a completed scrub.
# collect.sh's provisional call leaves LAB_UPLOAD_DIR unset.
ARTIFACT_DIR=${LAB_UPLOAD_DIR:-${LAB_ARTIFACT_DIR:?}}
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
# Harness-written key=value state from setup (juju.env), scrub (scrub.env),
# collect (collect.env) and the loop (stop.env); parsed, never sourced. A key seen twice (in any of them)
# makes the state untrustworthy: the verdict becomes error and the upload is
# reported as blocked.
declare -A st=()
state_error=""
for f in juju.env scrub.env stop.env collect.env; do
	[[ -f $STATE_DIR/$f ]] || continue
	while IFS= read -r line; do
		[[ $line =~ ^([a-z_]+)=(.*)$ ]] || continue
		if [[ -n ${st[${BASH_REMATCH[1]}]+x} ]]; then
			[[ -n $state_error ]] || state_error="harness state: key ${BASH_REMATCH[1]} repeated ($f)"
			continue
		fi
		st[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
	done <"$STATE_DIR/$f"
done
s_() { printf '%s' "${st[$1]:-}"; }
infra_signature=""
[[ -s $STATE_DIR/infra-signature.txt ]] && infra_signature=$(head -n 1 "$STATE_DIR/infra-signature.txt")
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
	if [[ -s $STATE_DIR/setup-error.txt ]]; then
		reason=$(head -n 1 "$STATE_DIR/setup-error.txt")
	else
		reason="setup did not complete (ready step: ${READY_OUTCOME:-unknown})"
	fi
	: >"$results"
elif [[ ! -s $results ]]; then
	verdict=error
	reason="no iteration result recorded (scenario step: ${SCENARIO_OUTCOME:-unknown})"
else
	# Design §4 aggregation: fail beats everything; else a stop (setup-error or
	# error) wins; else inconclusive; else pass. Fewer results than requested
	# without a recorded stop means the step was cut short (timeout/cancel).
	cleanup_stop=false
	[[ ${st[stop]:-} == cleanup ]] && cleanup_stop=true
	verdict=$(jq -rs --argjson n "$repeat" --argjson cleanup_stop "$cleanup_stop" '
		(map(.verdict)) as $v
		| if any($v[]; . == "fail") then "fail"
		  elif any($v[]; . == "setup-error") or $cleanup_stop then "setup-error"
		  elif any($v[]; . == "error") then "error"
		  elif length < $n then "error"
		  elif any($v[]; . == "inconclusive") then "inconclusive"
		  else "pass" end' "$results")
	n_done=$(jq -s length "$results")
	if [[ $verdict == setup-error && $cleanup_stop == true ]] && ! jq -se 'any(.[]; .verdict == "setup-error")' "$results" >/dev/null; then
		reason="model cleanup after iteration ${st[iteration]:-?} did not finish within the budget"
	elif [[ $verdict == setup-error && -n $infra_signature ]]; then
		reason="infra signature in the suite setup phase: $infra_signature"
	fi
	if [[ $verdict == error && $n_done -lt $repeat ]] && ! jq -se 'any(.[]; .verdict == "error")' "$results" >/dev/null; then
		reason="only $n_done of $repeat iterations recorded (scenario step: ${SCENARIO_OUTCOME:-unknown})"
	fi
fi
if [[ -n $state_error ]]; then
	verdict=error reason=$state_error
	st[upload_blocked]=true
fi
# controller_images: a JSON array written by bootstrap.sh (k8s); anything else is null.
images_json=$(jq -ce 'if type == "array" and all(.[]; type == "object") then . else null end' <<<"$(s_ controller_images)" 2>/dev/null) || images_json=null
[[ -n $images_json ]] || images_json=null
deps_json=$(for k in "${!st[@]}"; do if [[ $k == dep_* ]]; then printf '%s %s\n' "${k#dep_}" "${st[$k]}"; fi; done |
	sort | jq -Rsc 'split("\n") | map(select(length > 0) | split(" ") | {name: .[0], channel: .[1], revision: (.[2] | tonumber? // null)})')

# Build mode (design §3): build timings (module download and go-install
# separately), GOMODCACHE size, and on k8s the imported operator image with
# its resolved base image.
src_=$(s_ source)
[[ -n $src_ ]] || src_=${val[source]:-}
num() { if [[ $1 =~ ^[0-9]+$ ]]; then printf '%s' "$1"; else printf null; fi; }
build_json=null
if [[ $src_ == build ]]; then
	build_json=$(jq -nc --arg ref_version "$(s_ ref_version)" \
		--argjson build_s "$(num "$(s_ build_s)")" --argjson go_install_s "$(num "$(s_ build_go_install_s)")" \
		--argjson gomod_download_s "$(num "$(s_ gomod_download_s)")" \
		--argjson operator_image_s "$(num "$(s_ build_operator_image_s)")" --argjson gomodcache_mb "$(num "$(s_ gomodcache_mb)")" \
		--arg img "$(s_ operator_image)" --arg cfg "$(s_ operator_image_config)" --arg tgt "$(s_ operator_image_target)" --arg base "$(s_ operator_image_base)" '
		def v(x): if x != "" then x else null end;
		{ref_version: v($ref_version), build_s: $build_s, gomod_download_s: $gomod_download_s, go_install_s: $go_install_s,
		 operator_image_s: $operator_image_s, gomodcache_mb: $gomodcache_mb,
		 operator_image: (if $img == "" then null else {image: $img, base: v($base), config_digest: v($cfg), target_digest: v($tgt)} end)}')
fi

# Harness state goes into the artifact as written by the harness.
cp "$results" "$ARTIFACT_DIR/results.jsonl"
[[ -f $STATE_DIR/validate-error.txt ]] && cp "$STATE_DIR/validate-error.txt" "$ARTIFACT_DIR/validate-error.txt"

scrub_ran=false
[[ -n ${st[scrub_hits]+x} ]] && scrub_ran=true
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
	--arg juju_version "$(s_ juju_version)" --arg juju_git_commit "$(s_ juju_git_commit)" \
	--arg juju_snap_revision "$(s_ juju_snap_revision)" --arg source "$src_" \
	--arg ref_sha "$(s_ ref_sha)" --arg ref_repo "$(s_ ref_repo)" --argjson build "$build_json" \
	--arg tests_sha "$(s_ tests_sha)" --arg tests_source "$(s_ tests_source)" \
	--arg sub_name "$(s_ substrate_snap_name)" --arg sub_channel "$(s_ substrate_snap_channel)" \
	--arg sub_rev "$(s_ substrate_snap_revision)" \
	--arg infra_signature "$infra_signature" \
	--argjson scrub_ran "$scrub_ran" --arg scrub_hits "$(s_ scrub_hits)" \
	--arg upload_blocked "$(s_ upload_blocked)" --arg upload_blocked_path "$(s_ upload_blocked_path)" \
	--arg scrub_dropped "$(s_ scrub_dropped)" --arg scrub_withheld "$(s_ scrub_withheld)" \
	--arg agent "$(s_ controller_agent_version)" --arg agent_source "$(s_ agent_source)" \
	--argjson deps "$deps_json" --argjson images "$images_json" --arg snap_drift "$(s_ snap_drift)" \
	--arg bootstrap_args "$(s_ bootstrap_args)" \
	--slurpfile results "$results" '
	def v(x): if x != "" then x else null end;
	{
		schema_version: 1,
		scenario: v($scenario), substrate: $substrate, verdict: $verdict,
		reason: v($reason),
		juju_version: v($juju_version), juju_git_commit: v($juju_git_commit),
		juju_snap_revision: (if $juju_snap_revision == "" then null else ($juju_snap_revision | tonumber) end),
		juju_channel: (if $no_juju or $source == "build" then null else v($channel) end),
		controller_agent_version: v($agent), agent_source: v($agent_source),
		controller_images: $images,
		bootstrap_args: v($bootstrap_args),
		source: (if $no_juju then "none" else v($source) end),
		ref: v($ref), ref_repo: v($ref_repo), ref_sha: v($ref_sha), build: $build,
		tests_ref: v($tests_ref), tests_sha: v($tests_sha), tests_source: v($tests_source),
		lab_sha: $lab_sha, runner_image: $runner_image,
		deps: $deps,
		snap_drift: v($snap_drift),
		substrate_snap: (if $sub_name == "" then null else {name: $sub_name, channel: v($sub_channel), revision: (if $sub_rev == "" then null else ($sub_rev | tonumber) end)} end),
		iterations: (if $repeat == "" then null else ($repeat | tonumber) end),
		failed: ($results | map(select(.verdict == "fail")) | length),
		results: $results,
		infra_signature: v($infra_signature),
		scrub_hits: (if $scrub_ran then ($scrub_hits | tonumber) else null end),
		upload_blocked: ($upload_blocked == "true"),
		upload_blocked_path: v($upload_blocked_path),
		scrub_dropped: (if $scrub_dropped == "" then null else ($scrub_dropped | tonumber) end),
		scrub_withheld: (if $scrub_withheld == "" then null else ($scrub_withheld | tonumber) end),
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
	echo "scrub_hits=$(jq -r '.scrub_hits // "none"' "$out")"
	echo "upload_blocked=$(jq -r .upload_blocked "$out")"
} >>"$OUT"

# Job summary. Backticks are replaced so no value can close the code fence.
n_fail=$(jq .failed "$out")
n_done=$(jq '.results | length' "$out")
{
	echo "## lab verdict: \`$verdict\`"
	echo
	[[ -n $reason ]] && echo "Reason: $(printf '%s' "$reason" | tr '`' "'")" && echo
	[[ -n $infra_signature ]] && echo "Infra signature (setup phase, reclassified to setup-error): $(printf '%s' "$infra_signature" | tr '`' "'")" && echo
	if [[ ${st[upload_blocked]:-} == true ]]; then
		echo "**Upload blocked:** private key material in \`$(printf '%s' "${st[upload_blocked_path]:-?}" | tr '`' "'")\`; only verdict.json + collect.log were uploaded." && echo
	elif [[ $scrub_ran == true && ${st[scrub_hits]:-0} != 0 ]]; then
		echo "**Scrub:** ${st[scrub_hits]} value(s) redacted; the job is red so a human looks." && echo
	fi
	if [[ -n ${st[snap_drift]:-} ]]; then
		echo "**Warning:** snap refreshed during the job despite the hold ($(printf '%s' "${st[snap_drift]}" | tr '`' "'")); recorded revisions don't describe the whole run." && echo
	fi
	if [[ ${st[tests_source]:-} == branch ]]; then
		echo "**Warning:** tests/ came from the branch head \`$(printf '%s' "${st[tests_sha]:-?}" | tr '`' "'")\`, not from the binary's commit or tag; tests may not match the binary." && echo
	fi
	echo "Failed iterations: $n_fail/$n_done recorded (requested: ${repeat:-?})"
	echo
	echo '```json'
	tr '`' "'" <"$out"
	echo '```'
	# Design §7: show the first failing iteration, else the first non-pass one.
	first_bad=$(jq -r '([.results[] | select(.verdict == "fail")][0] // [.results[] | select(.verdict != "pass")][0]).iteration // empty' "$out")
	# Excerpts only from the scrubbed snapshot, after a completed scrub, and none
	# when the upload was blocked (the log may hold the key material).
	excerpt_ok=false
	[[ -n ${LAB_UPLOAD_DIR:-} && $scrub_ran == true && ${st[upload_blocked]:-} == false ]] && excerpt_ok=true
	if [[ $excerpt_ok == true && ${st[bootstrap_failed]:-} == 1 && -f $ARTIFACT_DIR/collect/bootstrap.log ]]; then
		echo
		echo "Last 30 lines of collect/bootstrap.log (scrubbed):"
		echo '```'
		tail -n 30 "$ARTIFACT_DIR/collect/bootstrap.log" | tr '`' "'"
		echo '```'
	fi
	if [[ $excerpt_ok == true && -n $first_bad && -f $ARTIFACT_DIR/iteration-$first_bad.log ]]; then
		echo
		echo "Last 50 lines of iteration $first_bad:"
		echo '```'
		tail -n 50 "$ARTIFACT_DIR/iteration-$first_bad.log" | tr '`' "'"
		echo '```'
	fi
} >>"$SUMMARY"
echo "verdict: $verdict ${reason:+($reason)}"
