#!/usr/bin/env bash
# repro-23659: juju/juju#23659. Deletion protection on machine 0's LXD container
# fails that removal; machine 1's container can still be deleted while its Juju
# record stays. Exit 0 not_reproduced, 1 reproduced, 2 setup-error, 3 inconclusive.
# result.json times are integer seconds since this process started.
set -uo pipefail
export LC_ALL=C

# ${var:?} below exits 1 before on_exit exists. Normalize that so a missing
# input is a setup error, not the harness's "reproduced".
PHASE=setup
LOCKED=0
FINISHING=0
RC=3
# shellcheck disable=SC2317  # trap handler; shellcheck misses it once main exits
early_exit() {
	ec=$?
	trap '' EXIT
	set +u
	set +e
	if [[ ${LOCKED:-0} == 0 && ${FINISHING:-0} == 0 ]]; then
		if [[ ${PHASE:-setup} == setup ]]; then
			ec=2
		else
			ec=3
		fi
	fi
	exit "$ec"
}
trap early_exit EXIT

: "${LAB_CONTROLLER:?}"
: "${LAB_ITERATION:?}"
: "${LAB_ARTIFACT_DIR:?}"
: "${LAB_TIMEOUT_MIN:?}"

# Present for a real lab run; empty when the caller did not set them.
LAB_JUJU_VERSION=${LAB_JUJU_VERSION:-}
LAB_JUJU_GIT_COMMIT=${LAB_JUJU_GIT_COMMIT:-}
LAB_JUJU_SOURCE=${LAB_JUJU_SOURCE:-}
LAB_REF_SHA=${LAB_REF_SHA:-}

CTRL=$LAB_CONTROLLER
M="repro-23659-i${LAB_ITERATION}"
Q="$CTRL:$M"
OUT="$LAB_ARTIFACT_DIR/repro-23659/i${LAB_ITERATION}"
mkdir -p "$OUT"

T0=$SECONDS
END=$T0
CLEANED=0
FINISHING=0
LOCKED=0
PROTECTED=0
UNPROTECTED_DONE=0
IN_UNPROTECT=0
# Test-only knobs (REPRO_STALE_S, REPRO_POLL_S, REPRO_BACKOFF_POLL_S).
# The workflow never sets them; same precedent as run-scenario.sh.
BACKOFF_EXITS=12
EXITS=0
EXITS_AT_REMOVE1=
STALE_S=${REPRO_STALE_S:-120}
POLL_S=${REPRO_POLL_S:-10}
BPOLL_S=${REPRO_BACKOFF_POLL_S:-2}
RC=3
RESULT=error
REASON="unexpected exit"
RESULT_SAVED=0
RESULT_SAVED_RC=
RESULT_SAVED_RESULT=
RESULT_SAVED_REASON=
RESULT_SAVED_PHASE=
IN_ON_EXIT=0
PHASE=setup
C0=
C1=
T_REMOVE0=
T_GATE=
T_REMOVE1=
T_C1_GONE=
T_C1_GONE_AT=
T_DECIDED=
OBS_M0=
OBS_M1=
OBS_C0=
OBS_C1=
BATCHED=
RELEASE_CONVERGED=
RELEASE_S=
trap_rc=0

log() {
	local line
	line="$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"
	printf '%s\n' "$line" | tee -a "$OUT/timeline.log"
}

# Seconds of scenario budget still available, floored at 0.
left() {
	local n=$((END - SECONDS))
	if ((n < 0)); then
		n=0
	fi
	printf '%s\n' "$n"
}

status_json() {
	timeout -k 5 60 juju status -m "$Q" --format json
}

lxc_names() {
	timeout -k 5 30 lxc list --project default --format json | jq -r '.[].name'
}

# lxc_snapshot <file>: instance name, status and the delete-protection flag only.
# Raw `lxc list` JSON carries cloud-init secrets and key material (scrub blocks the upload).
lxc_snapshot() {
	local f=$1
	if (
		set -o pipefail
		timeout -k 5 30 lxc list --project default --format json |
			jq -c '[.[] | {name, status, protection_delete: (.config["security.protection.delete"] // null)}]'
	) >"$f.tmp"; then
		mv "$f.tmp" "$f"
	else
		rm -f "$f.tmp"
		return 1
	fi
}

has_machine() {
	local id=$1 st
	st=$(status_json) || return 2
	jq -e --arg i "$id" '.machines | has($i)' >/dev/null <<<"$st"
}

has_ct() {
	local name=$1 names
	names=$(lxc_names) || return 2
	# -F: instance ids are matched as text, not as a regex.
	grep -qxF -- "$name" <<<"$names"
}

# Plan check is `dlog | grep -F … | grep -qF …`. pipefail is off in that
# subshell so grep -q closing the pipe cannot turn a real match into SIGPIPE.
# The debug-log pipeline is its own subshell so this pipefail does not change
# the caller's options (the batch check runs with pipefail off).
# Stdout only: juju's stderr must not enter debug-log.txt or those greps.
# No `|| true`: a failed debug-log keeps `dlog >file || log "… failed"` live.
dlog() {
	(
		set -o pipefail
		timeout -k 5 60 juju debug-log -m "$Q" --replay --no-tail | head -c 20M
	)
}

# One counted line per failed provisioner run: the exit log names C0.
exit_count() {
	local txt
	txt=$(dlog) || return 2
	EXITS=$(grep -F "exiting provisioner task loop" <<<"$txt" | grep -F "failed to remove containers" | grep -cF -- "$C0" || true)
}

record_batched() {
	BATCHED=0
	if [[ -z $C0 || -z $C1 ]]; then
		return 0
	fi
	if (
		set +o pipefail
		dlog | grep -F "stopping known instances" | grep -F "$C0" | grep -qF "$C1"
	); then
		BATCHED=1
	fi
}

write_result() {
	local tmp
	tmp=$(mktemp "$OUT/result.json.XXXXXX")
	if ! jq -n \
		--arg issue "23659" \
		--arg iteration "$LAB_ITERATION" \
		--arg model "$M" \
		--arg result "$RESULT" \
		--arg reason "$REASON" \
		--arg phase "$PHASE" \
		--arg juju_version "$LAB_JUJU_VERSION" \
		--arg juju_git_commit "$LAB_JUJU_GIT_COMMIT" \
		--arg juju_source "$LAB_JUJU_SOURCE" \
		--arg ref_sha "$LAB_REF_SHA" \
		--arg c0 "$C0" \
		--arg c1 "$C1" \
		--arg t_remove0 "$T_REMOVE0" \
		--arg t_gate "$T_GATE" \
		--arg t_remove1 "$T_REMOVE1" \
		--arg t_c1_gone "$T_C1_GONE" \
		--arg t_decided "$T_DECIDED" \
		--arg m0 "$OBS_M0" \
		--arg m1 "$OBS_M1" \
		--arg oc0 "$OBS_C0" \
		--arg oc1 "$OBS_C1" \
		--arg batched "$BATCHED" \
		--arg release_converged "$RELEASE_CONVERGED" \
		--arg release_s "$RELEASE_S" \
		--arg exits_before_remove1 "$EXITS_AT_REMOVE1" \
		--argjson exit_code "$RC" \
		'def s($v): if $v == "" then null else $v end;
		 def n($v): if $v == "" then null else ($v | tonumber) end;
		 def b($v): if $v == "" then null elif $v == "1" then true else false end;
		 {
		   issue: $issue,
		   iteration: (if ($iteration | test("^[0-9]+$")) then ($iteration | tonumber) else null end),
		   model: $model,
		   result: $result,
		   exit_code: $exit_code,
		   reason: $reason,
		   phase: $phase,
		   juju_version: s($juju_version),
		   juju_git_commit: s($juju_git_commit),
		   juju_source: s($juju_source),
		   ref_sha: s($ref_sha),
		   containers: {c0: s($c0), c1: s($c1)},
		   t: {
		     remove0: n($t_remove0),
		     gate: n($t_gate),
		     remove1: n($t_remove1),
		     c1_gone: n($t_c1_gone),
		     decided: n($t_decided)
		   },
		   observed: {m0: b($m0), m1: b($m1), c0: b($oc0), c1: b($oc1)},
		   batched: b($batched),
		   exits_before_remove1: n($exits_before_remove1),
		   backoff_exits_required: 12,
		   release_converged: b($release_converged),
		   release_s: n($release_s)
		 }' >"$tmp"; then
		rm -f "$tmp"
		return 1
	fi
	mv "$tmp" "$OUT/result.json" || return 1
	RESULT_SAVED=1
	RESULT_SAVED_RC=$RC
	RESULT_SAVED_RESULT=$RESULT
	RESULT_SAVED_REASON=$REASON
	RESULT_SAVED_PHASE=$PHASE
}

# True when result.json already records the RC/result/reason/phase we will exit with.
# shellcheck disable=SC2317  # called only from the EXIT trap
result_is_final() {
	[[ ${RESULT_SAVED:-0} == 1 ]] || return 1
	[[ ${RESULT_SAVED_RC:-} == "$RC" ]] || return 1
	[[ ${RESULT_SAVED_RESULT:-} == "$RESULT" ]] || return 1
	[[ ${RESULT_SAVED_REASON:-} == "$REASON" ]] || return 1
	[[ ${RESULT_SAVED_PHASE:-} == "$PHASE" ]] || return 1
	[[ -n ${OUT:-} && -f "$OUT/result.json" ]]
}

unprotect() {
	local json names name
	if [[ $IN_UNPROTECT == 1 || $UNPROTECTED_DONE == 1 ]]; then
		return 0
	fi
	IN_UNPROTECT=1
	if [[ $PROTECTED == 1 && -n $C0 ]]; then
		log "cleanup: unset protection on $C0"
		timeout -k 5 30 lxc config unset "$C0" security.protection.delete --project default ||
			log "cleanup: unset $C0 failed"
		PROTECTED=0
	fi
	json=$(timeout -k 5 30 lxc list --project default --format json 2>/dev/null) || json=
	if [[ -z $json ]]; then
		log "cleanup: lxc list for protection backstop failed"
	else
		names=$(jq -r '.[]? | select(.config["security.protection.delete"] == "true") | .name' <<<"$json" 2>/dev/null) || names=
		while IFS= read -r name; do
			[[ -n $name ]] || continue
			log "cleanup: backstop unset protection on $name"
			timeout -k 5 30 lxc config unset "$name" security.protection.delete --project default ||
				log "cleanup: unset $name failed"
		done <<<"$names"
	fi
	UNPROTECTED_DONE=1
	IN_UNPROTECT=0
	return 0
}

model_absent() {
	local st present
	st=$(timeout -k 5 60 juju models -c "$CTRL" --format json) || return 1
	present=$(jq -r --arg m "$M" --arg am "admin/$M" \
		'[.models[]? | select(."short-name" == $m or .name == $m or .name == $am)] | length' <<<"$st") || return 1
	[[ $present == 0 ]]
}

cleanup() {
	# Teardown only. The process status is on_exit's decision; exiting here
	# would re-enter that handler with a status this function does not own.
	local start elapsed
	if [[ ${CLEANED:-0} == 1 ]]; then
		return 0
	fi
	CLEANED=1
	# (a) protection before anything else, on every exit path.
	unprotect || true
	# (b) diagnostics before destroy. collect.sh only sees models that still exist.
	log "cleanup: diagnostics"
	dlog >"$OUT/debug-log.txt" || log "cleanup: debug-log failed"
	grep -E 'stopping known instances|failed to remove containers|shutting down pool|exiting provisioner task loop|entering provisioner task loop|removing dead machine' \
		"$OUT/debug-log.txt" >"$OUT/provisioner-lines.txt" || true
	status_json >"$OUT/status-final.json" || log "cleanup: final status failed"
	lxc_snapshot "$OUT/lxc-final.json" || log "cleanup: final lxc list failed"
	# (c) destroy. Failures are logged and do not change RC.
	log "cleanup: destroy-model $Q"
	timeout -k 5 120 juju destroy-model --no-prompt --destroy-storage --force --no-wait "$Q" ||
		log "cleanup: destroy-model returned non-zero"
	start=$SECONDS
	while :; do
		if model_absent; then
			log "cleanup: model gone"
			break
		fi
		elapsed=$((SECONDS - start))
		if ((elapsed >= 120)); then
			log "cleanup: model still present after 120s"
			break
		fi
		sleep 10
	done
	return 0
}

# EXIT wrapper. Bash keeps the status that entered the trap if the trap returns
# or dies, and an unbound variable enters as 1, which the harness reads as
# "reproduced". Always end in exit "$RC": a conclude()/finish() decision is
# kept; anything earlier is 2 during setup and 3 after. result.json is written
# for that final state when the file does not already record it. A second
# nounset in teardown cannot replace the process status.
# shellcheck disable=SC2317  # trap handler; shellcheck misses it once main exits
on_exit() {
	trap_rc=$?
	trap '' EXIT TERM INT HUP
	set +u
	set +e
	if [[ ${IN_ON_EXIT:-0} == 1 ]]; then
		exit "${RC:-3}"
	fi
	IN_ON_EXIT=1
	# No conclude() and no finish() has stored a decision yet.
	if [[ ${LOCKED:-0} == 0 && ${FINISHING:-0} == 0 && ${REASON:-} == "unexpected exit" ]]; then
		if [[ ${PHASE:-setup} == setup ]]; then
			RC=2
		else
			RC=3
		fi
		if [[ -z ${T_DECIDED:-} ]]; then
			T_DECIDED=$((SECONDS - T0))
		fi
		log "on_exit: unexpected exit status ${trap_rc} -> $RC"
	elif [[ ${trap_rc} != "$RC" ]]; then
		log "on_exit: status ${trap_rc} discarded; keeping decided rc=$RC"
	fi
	# Retry protection removal in this shell. cleanup may have died inside
	# unprotect and left IN_UNPROTECT=1, which would skip the backstop.
	IN_UNPROTECT=0
	unprotect || true
	if [[ ${CLEANED:-0} == 0 ]]; then
		( set -u; cleanup ) || true
		CLEANED=1
	fi
	case ${RC:-} in
	'' | *[!0-9]*)
		if [[ ${PHASE:-setup} == setup ]]; then
			RC=2
		else
			RC=3
		fi
		;;
	esac
	if ! result_is_final; then
		write_result || true
	fi
	exit "$RC"
}

finish() {
	local rc=$1 result=$2 reason=$3
	if [[ $FINISHING == 1 ]]; then
		# A signal during unprotect leaves IN_UNPROTECT=1, which would skip the
		# backstop sweep. Clear it so this call still removes protection.
		IN_UNPROTECT=0
		unprotect || true
		write_result || true
		exit "$RC"
	fi
	# A 0/1/3 decision locked before release must survive a signal during teardown.
	if [[ $LOCKED == 0 ]]; then
		RC=$rc
		RESULT=$result
		REASON=$reason
		if [[ -z $T_DECIDED ]]; then
			T_DECIDED=$((SECONDS - T0))
		fi
	fi
	FINISHING=1
	log "finish: rc=$RC result=$RESULT phase=$PHASE reason=$REASON"
	# Write before cleanup so a crash during teardown still leaves the decision.
	write_result || log "finish: result.json before cleanup failed"
	cleanup
	write_result || log "finish: result.json failed"
	exit "$RC"
}

release() {
	local start=$SECONDS limit remain elapsed budget nap wait_start
	local hm0 hm1 hc0 hc1
	log "release: unset protection on ${C0:-}"
	if [[ -n $C0 ]]; then
		timeout -k 5 30 lxc config unset "$C0" security.protection.delete --project default ||
			log "release: unset failed"
	fi
	PROTECTED=0
	remain=$(left)
	limit=180
	if ((remain < limit)); then
		limit=$remain
	fi
	RELEASE_CONVERGED=0
	wait_start=$SECONDS
	while :; do
		elapsed=$((SECONDS - wait_start))
		if ((elapsed >= limit)); then
			break
		fi
		has_machine 0
		hm0=$?
		has_machine 1
		hm1=$?
		if [[ -n $C0 ]]; then
			has_ct "$C0"
			hc0=$?
		else
			hc0=1
		fi
		if [[ -n $C1 ]]; then
			has_ct "$C1"
			hc1=$?
		else
			hc1=1
		fi
		if ((hm0 == 1 && hm1 == 1 && hc0 == 1 && hc1 == 1)); then
			RELEASE_CONVERGED=1
			break
		fi
		budget=$((limit - elapsed))
		nap=10
		if ((budget < nap)); then
			nap=$budget
		fi
		if ((nap > 0)); then
			sleep "$nap"
		else
			break
		fi
	done
	RELEASE_S=$((SECONDS - start))
	log "release: converged=$RELEASE_CONVERGED release_s=$RELEASE_S"
}

conclude() {
	local rc=$1 result=$2 reason=$3
	RC=$rc
	RESULT=$result
	REASON=$reason
	T_DECIDED=$((SECONDS - T0))
	LOCKED=1
	if [[ $rc == 0 || $rc == 1 || $rc == 3 ]]; then
		release || log "release: failed"
	fi
	finish "$rc" "$result" "$reason"
}

# Every 10s until machines_ready returns 0 or min(480, left) is spent.
# A non-zero check (including a read failure) is retried.
wait_machines() {
	local limit=480 start=$SECONDS
	while :; do
		local elapsed remain phase_left budget nap
		elapsed=$((SECONDS - start))
		remain=$(left)
		phase_left=$((limit - elapsed))
		if ((phase_left < 0)); then
			phase_left=0
		fi
		budget=$phase_left
		if ((remain < budget)); then
			budget=$remain
		fi
		if ((budget <= 0)); then
			return 1
		fi
		if machines_ready; then
			return 0
		fi
		nap=10
		if ((budget < nap)); then
			nap=$budget
		fi
		if ((nap > 0)); then
			sleep "$nap"
		fi
	done
}

machines_ready() {
	local st names id0 id1
	st=$(status_json) || return 1
	id0=$(jq -r '.machines["0"]["instance-id"] // empty' <<<"$st") || return 1
	id1=$(jq -r '.machines["1"]["instance-id"] // empty' <<<"$st") || return 1
	jq -e '
		.machines["0"]["juju-status"].current == "started" and
		.machines["1"]["juju-status"].current == "started"
	' >/dev/null <<<"$st" || return 1
	[[ -n $id0 && $id0 != pending && $id0 != null && -n $id1 && $id1 != pending && $id1 != null ]] || return 1
	names=$(lxc_names) || return 1
	grep -qxF -- "$id0" <<<"$names" || return 1
	grep -qxF -- "$id1" <<<"$names" || return 1
	C0=$id0
	C1=$id1
	return 0
}

# Restart delay is 3s × 1.2^(k−1), so after 12 failing exits the provisioner
# is down for ≥ 20s. Poll debug-log until a fresh exit count reaches that,
# then remove-machine 1 while the task is still down. No presence checks here.
wait_backoff() {
	local limit=420 start=$SECONDS
	local prev_ok=0 prev_exits=0 prev_end=$SECONDS
	while :; do
		local elapsed remain phase_left budget nap age
		elapsed=$((SECONDS - start))
		remain=$(left)
		phase_left=$((limit - elapsed))
		if ((phase_left < 0)); then
			phase_left=0
		fi
		budget=$phase_left
		if ((remain < budget)); then
			budget=$remain
		fi
		if ((budget <= 0)); then
			return 1
		fi
		if exit_count; then
			if [[ -z $T_GATE ]] && ((EXITS >= 1)); then
				T_GATE=$((SECONDS - T0))
			fi
			if ((prev_ok == 1 && EXITS >= BACKOFF_EXITS && EXITS > prev_exits)); then
				age=$((SECONDS - prev_end))
				if ((age <= BPOLL_S + 4)); then
					EXITS_AT_REMOVE1=$EXITS
					return 0
				fi
			fi
			prev_ok=1
			prev_exits=$EXITS
			prev_end=$SECONDS
		else
			prev_ok=0
		fi
		remain=$(left)
		elapsed=$((SECONDS - start))
		phase_left=$((limit - elapsed))
		if ((phase_left < 0)); then
			phase_left=0
		fi
		budget=$phase_left
		if ((remain < budget)); then
			budget=$remain
		fi
		nap=$BPOLL_S
		if ((budget < nap)); then
			nap=$budget
		fi
		if ((nap > 0)); then
			sleep "$nap"
		else
			return 1
		fi
	done
}

read_obs() {
	local st names
	st=$(status_json) || return 1
	names=$(lxc_names) || return 1
	jq -e '.machines | type == "object"' >/dev/null <<<"$st" || return 1
	if jq -e --arg i 0 '.machines | has($i)' >/dev/null <<<"$st"; then
		OBS_M0=1
	else
		OBS_M0=0
	fi
	if jq -e --arg i 1 '.machines | has($i)' >/dev/null <<<"$st"; then
		OBS_M1=1
	else
		OBS_M1=0
	fi
	if grep -qxF -- "$C0" <<<"$names"; then
		OBS_C0=1
	else
		OBS_C0=0
	fi
	if grep -qxF -- "$C1" <<<"$names"; then
		OBS_C1=1
	else
		OBS_C1=0
	fi
	return 0
}

classify() {
	local ended=$1
	if [[ ${OBS_M0:-} == 0 || ${OBS_C0:-} == 0 ]]; then
		record_batched
		conclude 3 error "machine 0 unblocked"
	fi
	if [[ ${OBS_M1:-} == 0 && ${OBS_C1:-} == 1 ]]; then
		record_batched
		conclude 3 error "record gone, container present"
	fi
	if [[ ${OBS_M1:-} == 1 && ${OBS_C1:-} == 0 ]]; then
		if [[ -z $T_C1_GONE_AT ]]; then
			T_C1_GONE_AT=$SECONDS
			T_C1_GONE=$((T_C1_GONE_AT - T0))
			log "observe: container 1 gone at t=${T_C1_GONE}s"
		fi
		if ((SECONDS - T_C1_GONE_AT >= STALE_S)); then
			record_batched
			conclude 1 reproduced "machine 1 record remained ${STALE_S}s after its container was removed"
		fi
		if [[ $ended == 1 ]]; then
			record_batched
			conclude 3 error "deleted late"
		fi
		return 0
	fi
	if [[ ${OBS_M1:-} == 0 && ${OBS_C1:-} == 0 ]]; then
		record_batched
		if [[ $BATCHED == 1 ]]; then
			conclude 0 not_reproduced "stopping known instances batched both containers"
		fi
		conclude 3 error "bug path not exercised"
	fi
	if [[ $ended == 1 ]]; then
		record_batched
		if [[ ${OBS_M1:-} == 1 && ${OBS_C1:-} == 1 ]]; then
			conclude 3 error "different symptom: container not deleted"
		fi
		conclude 3 error "observation window ended"
	fi
	return 0
}

observe() {
	local start=$SECONDS limit=300
	if [[ -z $C0 || -z $C1 ]]; then
		conclude 3 error "containers unknown"
	fi
	while :; do
		local elapsed remain phase_left budget nap
		elapsed=$((SECONDS - start))
		remain=$(left)
		phase_left=$((limit - elapsed))
		if ((phase_left < 0)); then
			phase_left=0
		fi
		budget=$phase_left
		if ((remain < budget)); then
			budget=$remain
		fi
		if ((budget <= 0)); then
			read_obs || log "observe: final read failed"
			classify 1
			conclude 3 error "observation window ended"
		fi
		if read_obs; then
			log "observe: m0=$OBS_M0 m1=$OBS_M1 c0=$OBS_C0 c1=$OBS_C1 left=${remain}s"
			classify 0
		else
			log "observe: read failed"
		fi
		nap=$POLL_S
		if ((budget < nap)); then
			nap=$budget
		fi
		if ((nap > 0)); then
			sleep "$nap"
		fi
	done
}

main() {
	local got i
	log "start model=$M timeout_min=$LAB_TIMEOUT_MIN left=$(left)s"
	log "add-model $M"
	if ! timeout -k 5 90 juju add-model "$M" localhost --controller "$CTRL" --no-switch \
		--config project=default \
		--config enable-os-upgrade=false \
		--config enable-os-refresh-update=false; then
		finish 2 error "add-model failed"
	fi
	for i in 1 2; do
		log "add-machine $i"
		if ! timeout -k 5 90 juju add-machine -m "$Q" --base ubuntu@24.04; then
			finish 2 error "add-machine failed"
		fi
	done
	log "wait for machines 0 and 1"
	if ! wait_machines; then
		finish 2 error "machines did not start"
	fi
	log "machines ready c0=$C0 c1=$C1"
	log "protect $C0"
	if ! timeout -k 5 30 lxc config set "$C0" security.protection.delete=true --project default; then
		finish 2 error "lxc config set protection failed"
	fi
	PROTECTED=1
	got=$(timeout -k 5 30 lxc config get "$C0" security.protection.delete --project default 2>/dev/null) || true
	got=${got//$'\r'/}
	got=${got//$'\n'/}
	if [[ $got != true ]]; then
		finish 2 error "protection not confirmed"
	fi
	status_json >"$OUT/status-before.json" || finish 2 error "status snapshot failed"
	lxc_snapshot "$OUT/lxc-before.json" || finish 2 error "lxc snapshot failed"
	if (($(left) <= 0)); then
		finish 2 error "budget exhausted before repro"
	fi
	PHASE=repro
	log "remove-machine 0"
	if ! timeout -k 5 90 juju remove-machine -m "$Q" --no-prompt 0; then
		conclude 3 error "remove-machine 0 failed"
	fi
	T_REMOVE0=$((SECONDS - T0))
	log "remove-machine 0 accepted at t=${T_REMOVE0}s"
	log "wait for provisioner backoff (exits>=$BACKOFF_EXITS)"
	if wait_backoff; then
		log "backoff: exits=$EXITS at t=$((SECONDS - T0))s"
	else
		conclude 3 error "precondition not reached (exits=$EXITS)"
	fi
	log "remove-machine 1"
	if ! timeout -k 5 90 juju remove-machine -m "$Q" --no-prompt 1; then
		conclude 3 error "remove-machine 1 failed"
	fi
	T_REMOVE1=$((SECONDS - T0))
	log "remove-machine 1 accepted at t=${T_REMOVE1}s"
	observe
	conclude 3 error "fell off the end"
}

trap on_exit EXIT
trap 'finish 124 error "terminated"' TERM INT HUP

case $LAB_TIMEOUT_MIN in
'' | *[!0-9]*) finish 2 error "bad LAB_TIMEOUT_MIN" ;;
esac
case $LAB_ITERATION in
'' | *[!0-9]*) finish 2 error "bad LAB_ITERATION" ;;
esac
case $STALE_S in
'' | *[!0-9]*) finish 2 error "bad REPRO_* knob" ;;
esac
case $POLL_S in
'' | *[!0-9]*) finish 2 error "bad REPRO_* knob" ;;
esac
case $BPOLL_S in
'' | *[!0-9]*) finish 2 error "bad REPRO_* knob" ;;
esac
if ((STALE_S < 1 || POLL_S < 1 || BPOLL_S < 1)); then
	finish 2 error "bad REPRO_* knob"
fi
END=$((T0 + LAB_TIMEOUT_MIN * 60 - 360))

main
