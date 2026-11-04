#!/usr/bin/env bash
# repro-23717: juju/juju#23717. add-credential --region is used while the
# credential is created and then dropped, so show-credential cannot report it.
# Exit 0 not_reproduced, 1 reproduced, 2 setup-error, 3 inconclusive.
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

CTRL=$LAB_CONTROLLER
CLOUD="fakemaas-i${LAB_ITERATION}"
CRED="cred23717-i${LAB_ITERATION}"
OUT="$LAB_ARTIFACT_DIR/repro-23717/i${LAB_ITERATION}"
mkdir -p "$OUT" || exit 2

TMP=
CLEANED=0
CLOUD_TYPE=
AUTH_TYPE=
REGION_SEEN=
CRED_ON_CONTROLLER=
RESULT=error
REASON="unexpected exit"
RESULT_SAVED=0
IN_ON_EXIT=0

log() {
	local line
	line="$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"
	# stderr: command substitutions only capture the document, and the harness
	# still records stderr in the iteration log.
	printf '%s\n' "$line" | tee -a "$OUT/timeline.log" >&2
}

# stdout+stderr. Used for commands whose text is the evidence.
run_log() {
	local dest=$1
	shift
	log "cmd: juju $*"
	timeout -k 5 90 juju "$@" >"$dest" 2>&1 </dev/null
}

# stdout is the document; stderr stays beside it so it cannot break JSON/YAML.
run_doc() {
	local dest=$1
	shift
	log "cmd: juju $*"
	timeout -k 5 90 juju "$@" >"$dest" 2>"$dest.err" </dev/null
}

write_result() {
	local tmp
	[[ -n ${OUT:-} && -d ${OUT:-} ]] || return 1
	tmp=$(mktemp "$OUT/result.json.XXXXXX")
	if ! jq -n \
		--arg issue "23717" \
		--arg iteration "${LAB_ITERATION:-}" \
		--arg result "$RESULT" \
		--arg reason "$REASON" \
		--arg phase "$PHASE" \
		--arg cloud_type "$CLOUD_TYPE" \
		--arg region_requested "r-two" \
		--arg region_seen "$REGION_SEEN" \
		--arg cred_on "$CRED_ON_CONTROLLER" \
		--arg juju_version "$LAB_JUJU_VERSION" \
		--arg juju_git_commit "$LAB_JUJU_GIT_COMMIT" \
		--argjson exit_code "$RC" \
		'def s($v): if $v == "" then null else $v end;
		 def b($v): if $v == "1" then true elif $v == "0" then false else null end;
		 {
		   issue: $issue,
		   iteration: (if ($iteration | test("^[0-9]+$")) then ($iteration | tonumber) else null end),
		   result: $result,
		   exit_code: $exit_code,
		   reason: $reason,
		   phase: $phase,
		   cloud_type: s($cloud_type),
		   region_requested: $region_requested,
		   region_seen: s($region_seen),
		   credential_on_controller: b($cred_on),
		   juju_version: s($juju_version),
		   juju_git_commit: s($juju_git_commit)
		 }' >"$tmp"; then
		rm -f "$tmp"
		return 1
	fi
	mv "$tmp" "$OUT/result.json" || return 1
	RESULT_SAVED=1
}

# remove-credential, then remove-cloud, then the temp dir. The credential
# file lives only under TMP and is never copied into the artifact dir.
cleanup() {
	if [[ ${CLEANED:-0} == 1 ]]; then
		return 0
	fi
	CLEANED=1
	if [[ -n ${OUT:-} ]]; then
		mkdir -p "$OUT" || true
	fi
	if [[ -n ${CLOUD:-} && -n ${CRED:-} && -n ${CTRL:-} && -n ${OUT:-} ]]; then
		log "cleanup: remove-credential $CRED"
		run_log "$OUT/remove-credential.log" remove-credential "$CLOUD" "$CRED" --controller "$CTRL" ||
			log "cleanup: remove-credential returned non-zero"
		log "cleanup: remove-cloud $CLOUD"
		run_log "$OUT/remove-cloud.log" remove-cloud "$CLOUD" --controller "$CTRL" ||
			log "cleanup: remove-cloud returned non-zero"
	fi
	if [[ -n ${TMP:-} && -d ${TMP:-} ]]; then
		rm -rf -- "$TMP" || true
	fi
	return 0
}

# EXIT wrapper. Bash keeps the status that entered the trap if the trap returns
# or dies, and an unbound variable enters as 1, which the harness reads as
# "reproduced". Always end in exit "$RC": a finish() decision is kept; anything
# earlier is 2 during setup and 3 after.
# shellcheck disable=SC2317
on_exit() {
	local trap_rc=$?
	trap '' EXIT TERM INT HUP
	set +u
	set +e
	if [[ ${IN_ON_EXIT:-0} == 1 ]]; then
		exit "${RC:-3}"
	fi
	IN_ON_EXIT=1
	if [[ ${LOCKED:-0} == 0 && ${FINISHING:-0} == 0 && ${REASON:-} == "unexpected exit" ]]; then
		if [[ ${PHASE:-setup} == setup ]]; then
			RC=2
		else
			RC=3
		fi
		if [[ -n ${OUT:-} && -d ${OUT:-} ]]; then
			log "on_exit: unexpected exit status ${trap_rc} -> $RC"
		fi
	fi
	if [[ ${CLEANED:-0} == 0 ]]; then
		cleanup || true
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
	if [[ ${RESULT_SAVED:-0} != 1 ]]; then
		write_result || true
	fi
	exit "$RC"
}

# shellcheck disable=SC2317
on_term() {
	trap '' TERM INT HUP
	if [[ ${PHASE:-setup} == setup ]]; then
		finish 2 error "terminated"
	fi
	finish 3 error "terminated"
}

finish() {
	local rc=$1 result=$2 reason=$3
	if [[ ${FINISHING:-0} == 1 ]]; then
		exit "$RC"
	fi
	RC=$rc
	RESULT=$result
	REASON=$reason
	LOCKED=1
	FINISHING=1
	log "finish: rc=$RC result=$RESULT phase=$PHASE reason=$REASON"
	write_result || log "finish: result.json failed"
	cleanup
	write_result || log "finish: result.json after cleanup failed"
	exit "$RC"
}

write_maas_cloud() {
	cat >"$TMP/cloud.yaml" <<EOF
clouds:
  ${CLOUD}:
    type: maas
    auth-types: [oauth1]
    endpoint: http://192.0.2.1/MAAS
    regions:
      r-one:
        endpoint: http://192.0.2.1/MAAS
      r-two:
        endpoint: http://192.0.2.2/MAAS
EOF
}

write_openstack_cloud() {
	cat >"$TMP/cloud.yaml" <<EOF
clouds:
  ${CLOUD}:
    type: openstack
    auth-types: [userpass]
    regions:
      r-one:
        endpoint: http://192.0.2.1:5000/v3
      r-two:
        endpoint: http://192.0.2.2:5000/v3
EOF
}

write_cred() {
	local dest=$TMP/credential-def.yaml
	if [[ $AUTH_TYPE == oauth1 ]]; then
		cat >"$dest" <<EOF
credentials:
  ${CLOUD}:
    ${CRED}:
      auth-type: oauth1
      maas-oauth: "lab:lab:lab"
EOF
	else
		cat >"$dest" <<EOF
credentials:
  ${CLOUD}:
    ${CRED}:
      auth-type: userpass
      username: lab
      password: lab-password
      tenant-name: lab
      domain-name: labdom
      version: "3"
EOF
	fi
	chmod 600 "$dest" || finish 2 error "credential file mode failed"
}

# add-cloud exits 0 without adding the cloud when the controller reports an
# incompatible type and the client prints the "--force" hint. Treat that text
# as a failed attempt. --force is still passed; the hint means the server refused.
cloud_attempt_ok() {
	local dest=$1 rc=$2
	[[ $rc -eq 0 ]] || return 1
	if grep -qF 'use --force.' "$dest"; then
		return 1
	fi
	if grep -qF 'Could not upload cloud' "$dest"; then
		return 1
	fi
	return 0
}

try_add_cloud() {
	local kind=$1
	local dest=$OUT/add-cloud-$kind.log
	local rc=0
	if [[ $kind == maas ]]; then
		write_maas_cloud
	else
		write_openstack_cloud
	fi
	run_log "$dest" add-cloud --controller "$CTRL" "$CLOUD" -f "$TMP/cloud.yaml" --force || rc=$?
	if cloud_attempt_ok "$dest" "$rc"; then
		return 0
	fi
	log "add-cloud $kind failed (rc=$rc)"
	# Exit 0 plus the incompatible-cloud hint means the client did not add the
	# cloud, but a previous partial add can still own the name. A non-zero
	# exit left nothing to remove; cleanup still drops the name at the end.
	if [[ $rc -eq 0 ]]; then
		run_log "$OUT/remove-cloud-before-fallback.log" remove-cloud "$CLOUD" --controller "$CTRL" ||
			log "remove-cloud before fallback returned non-zero"
	fi
	return 1
}

# yq when it returns this credential only; otherwise the same block by indent.
# A dump of the whole document (client-credentials included) is rejected so a
# region on another credential cannot decide the verdict.
extract_block() {
	local f=$1 out
	if command -v yq >/dev/null 2>&1; then
		if out=$(yq -r ".[\"controller-credentials\"][\"${CLOUD}\"][\"${CRED}\"]" "$f" 2>/dev/null); then
			if [[ -n $out && $out != null && $out != *client-credentials:* && $out == *auth-type* ]]; then
				log "parser=yq"
				printf '%s\n' "$out"
				return 0
			fi
			log "parser=yq-rejected"
		else
			log "parser=yq-failed"
		fi
	fi
	out=$(awk -v cloud="$CLOUD" -v cred="$CRED" '
		function spaces(s) {
			match(s, /^ */)
			return RLENGTH
		}
		/^[[:space:]]*$/ {
			if (state == 3) print
			next
		}
		{
			i = spaces($0)
			if (state == 0) {
				if ($0 == "controller-credentials:") state = 1
				next
			}
			if (state == 1) {
				if (i == 0) exit
				if (i == 2 && $0 == "  " cloud ":") state = 2
				next
			}
			if (state == 2) {
				if (i <= 2) exit
				if (i == 4 && $0 == "    " cred ":") state = 3
				next
			}
			if (i <= 4) exit
			print
		}
	' "$f") || return 1
	if [[ -z ${out//[[:space:]]/} || $out == *client-credentials:* ]]; then
		return 1
	fi
	log "parser=awk"
	printf '%s\n' "$out"
}

# First "region:" value in the credential block, YAML or one-line JSON.
region_value() {
	local block=$1 line v
	line=$(printf '%s\n' "$block" | grep -E '^[[:space:]]*region:[[:space:]]*[^[:space:]#]' | head -n 1 || true)
	if [[ -z $line ]]; then
		line=$(printf '%s\n' "$block" | sed -n 's/.*"region"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1 || true)
		printf '%s\n' "$line"
		return 0
	fi
	v=${line#*:}
	v=${v#"${v%%[![:space:]]*}"}
	v=${v%%#*}
	v=${v%"${v##*[![:space:]]}"}
	v=${v#\"}
	v=${v%\"}
	v=${v#\'}
	v=${v%\'}
	printf '%s\n' "$v"
}

block_has_rtwo() {
	printf '%s\n' "$1" | grep -Eq '(^|[^A-Za-z0-9_-])r-two([^A-Za-z0-9_-]|$)'
}

main() {
	local rc=0 auth block
	log "start cloud=$CLOUD cred=$CRED timeout_min=$LAB_TIMEOUT_MIN"
	TMP=$(mktemp -d) || finish 2 error "mktemp failed"
	[[ -n $TMP && -d $TMP ]] || finish 2 error "mktemp failed"
	chmod 700 "$TMP" || finish 2 error "mktemp failed"

	if try_add_cloud maas; then
		CLOUD_TYPE=maas
		AUTH_TYPE=oauth1
	else
		log "retrying add-cloud as openstack"
		if try_add_cloud openstack; then
			CLOUD_TYPE=openstack
			AUTH_TYPE=userpass
		else
			CLOUD_TYPE=
			AUTH_TYPE=
			finish 2 error "add-cloud failed"
		fi
	fi
	log "cloud_type=$CLOUD_TYPE"
	write_cred

	rc=0
	run_log "$OUT/add-credential.log" add-credential "$CLOUD" -f "$TMP/credential-def.yaml" --region r-two --controller "$CTRL" || rc=$?
	if grep -qF 'not uploaded' "$OUT/add-credential.log"; then
		finish 2 error "credential not uploaded"
	fi
	if [[ $rc -ne 0 ]]; then
		finish 2 error "add-credential failed"
	fi

	if ! run_doc "$OUT/show-cloud.json" show-cloud "$CLOUD" --controller "$CTRL" --format json; then
		finish 2 error "show-cloud failed"
	fi
	if ! jq -e 'any(.[]; (.regions // {}) | has("r-one") and has("r-two"))' "$OUT/show-cloud.json" >/dev/null 2>&1; then
		finish 2 error "show-cloud missing r-one or r-two"
	fi

	if ! run_doc "$OUT/controller-credentials.json" credentials --controller "$CTRL" --format json; then
		finish 2 error "credentials list failed"
	fi
	auth=$(jq -r --arg cloud "$CLOUD" --arg cred "$CRED" '
		.["controller-credentials"][$cloud] as $group
		| ($group["cloud-credentials"][$cred]["auth-type"]
		   // $group[$cred]["auth-type"]
		   // $group[$cred].content["auth-type"]
		   // empty)
	' "$OUT/controller-credentials.json" 2>/dev/null) || auth=
	if [[ -n $auth ]]; then
		CRED_ON_CONTROLLER=1
	else
		CRED_ON_CONTROLLER=0
	fi
	if [[ $auth != "$AUTH_TYPE" ]]; then
		finish 2 error "controller credential auth-type ${auth:-absent}"
	fi

	PHASE=repro
	if ! run_doc "$OUT/show-credential.yaml" show-credential "$CLOUD" "$CRED" --controller "$CTRL" --format yaml; then
		finish 3 error "show-credential failed"
	fi
	if ! block=$(extract_block "$OUT/show-credential.yaml"); then
		finish 3 error "credential block missing"
	fi
	REGION_SEEN=$(region_value "$block")
	if block_has_rtwo "$block"; then
		[[ -n $REGION_SEEN ]] || REGION_SEEN=r-two
		finish 0 not_reproduced "region r-two present on controller credential"
	fi
	finish 1 reproduced "region r-two absent from controller credential"
}

trap on_exit EXIT
trap on_term TERM INT HUP

case $LAB_ITERATION in
'' | *[!0-9]*) finish 2 error "bad LAB_ITERATION" ;;
esac
case $LAB_TIMEOUT_MIN in
'' | *[!0-9]*) finish 2 error "bad LAB_TIMEOUT_MIN" ;;
esac
if ((LAB_TIMEOUT_MIN < 1)); then
	finish 2 error "bad LAB_TIMEOUT_MIN"
fi

main
# shellcheck disable=SC2317  # backstop if main returns
finish 3 error "fell off the end"
