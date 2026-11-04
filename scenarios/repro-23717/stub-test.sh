#!/usr/bin/env bash
# Offline stand-in for repro-23717: fake juju with a private /tmp, scrub check.
# Run: bash scenarios/repro-23717/stub-test.sh
set -euo pipefail
export LC_ALL=C

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
tmp=$(mktemp -d)
trap 'chmod 755 "$tmp/priv-mkdir-fail/ro" 2>/dev/null || true; rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin"

cat >"$tmp/bin/juju" << 'EOF'
#!/usr/bin/env bash
set -u
state=${FAKE_STATE:?}
mode=${FAKE_MODE:?}
printf 'juju %s\n' "$*" >>"$state/calls.log"
cmd=$1
shift || true

file_arg() {
	local skip=0 a
	for a in "$@"; do
		if [[ $skip == 1 ]]; then
			printf '%s\n' "$a"
			return 0
		fi
		if [[ $a == -f || $a == --file ]]; then
			skip=1
		fi
	done
	return 1
}

# Stand-in for the snap's home interface: only paths under FAKE_READABLE
# (the mode dir, playing the role of $HOME) are visible.
readable() { [[ -f $1 ]] && case $1 in "$FAKE_READABLE"/*) true ;; *) false ;; esac; }

note_cloud_place() {
	case $1 in
	"$LAB_ARTIFACT_DIR" | "$LAB_ARTIFACT_DIR"/*)
		echo cloud-in-artifacts >>"$state/calls.log"
		;;
	*)
		echo cloud-outside-artifacts >>"$state/calls.log"
		;;
	esac
}

refuse_unreadable() {
	local f=$1
	if [[ -f $f ]]; then
		typ=$(sed -n 's/^[[:space:]]*type:[[:space:]]*//p' "$f" | head -n 1)
		printf 'add-cloud-type %s\n' "$typ" >>"$state/calls.log"
	fi
	echo "ERROR open $f: no such file or directory" >&2
	exit 1
}

case $cmd in
add-cloud)
	f=$(file_arg "$@") || {
		echo "fake juju: add-cloud without -f" >&2
		exit 99
	}
	note_cloud_place "$f"
	if [[ $mode == snap-unreadable ]] || ! readable "$f"; then
		refuse_unreadable "$f"
	fi
	typ=$(sed -n 's/^[[:space:]]*type:[[:space:]]*//p' "$f" | head -n 1)
	printf 'add-cloud-type %s\n' "$typ" >>"$state/calls.log"
	case $mode in
	addcloud-fail)
		echo "ERROR: refusing fake cloud" >&2
		exit 1
		;;
	fallback)
		if [[ $typ == maas ]]; then
			echo "ERROR: maas add-cloud failed" >&2
			exit 1
		fi
		;;
	esac
	printf '%s\n' "Cloud added to controller."
	exit 0
	;;
add-credential)
	f=$(file_arg "$@") || {
		echo "fake juju: add-credential without -f" >&2
		exit 99
	}
	readable "$f" || { echo "ERROR open $f: no such file or directory" >&2; exit 1; }
	case $f in
	"$LAB_ARTIFACT_DIR" | "$LAB_ARTIFACT_DIR"/*)
		echo cred-in-artifacts >>"$state/calls.log"
		;;
	*)
		echo cred-file-outside-artifacts >>"$state/calls.log"
		;;
	esac
	printf 'cred-dir %s\n' "$(dirname "$f")" >>"$state/calls.log"
	if grep -qE '^[[:space:]]*auth-type:[[:space:]]*oauth1[[:space:]]*$' "$f"; then
		echo cred-auth oauth1 >>"$state/calls.log"
	fi
	if grep -qE '^[[:space:]]*auth-type:[[:space:]]*userpass[[:space:]]*$' "$f"; then
		echo cred-auth userpass >>"$state/calls.log"
	fi
	if grep -qF 'maas-oauth' "$f"; then
		echo cred-has-maas-oauth-key >>"$state/calls.log"
	fi
	if [[ $mode == noupload ]]; then
		printf '%s\n' 'No cloud "fakemaas-i1" found on the controller "lab": credentials are not uploaded.'
		exit 0
	fi
	printf '%s\n' "Credential added to controller."
	exit 0
	;;
show-cloud)
	cat << 'JSON'
[
  {
    "type": "maas",
    "regions": {
      "r-one": {"endpoint": "http://192.0.2.1/MAAS"},
      "r-two": {"endpoint": "http://192.0.2.2/MAAS"}
    }
  }
]
JSON
	exit 0
	;;
credentials)
	auth=oauth1
	if [[ $mode == fallback ]]; then
		auth=userpass
	fi
	printf '{"controller-credentials":{"localhost":{"cloud-credentials":{"localhost":{"auth-type":"certificate"}}},"fakemaas-i1":{"cloud-credentials":{"cred23717-i1":{"auth-type":"%s"}}}}}\n' "$auth"
	exit 0
	;;
show-credential)
	case " $* " in
	*" --show-secrets "* | *" --format json "* | *" --format=json "*)
		echo "fake juju: forbidden show-credential flag" >&2
		exit 99
		;;
	esac
	region_line=""
	if [[ $mode == fixed ]]; then
		region_line="        region: r-two"
	fi
	cat << YAML
controller-credentials:
  fakemaas-i1:
    cred23717-i1:
      content:
        auth-type: oauth1
${region_line}
      models:
        controller: admin
    decoy:
      content:
        region: r-two
client-credentials:
  fakemaas-i1:
    cred23717-i1:
      region: r-two
YAML
	exit 0
	;;
remove-credential | remove-cloud)
	exit 0
	;;
*)
	echo "fake juju: unknown command: $cmd" >&2
	exit 99
	;;
esac
EOF

# fixed: yq returns only the named credential block.
# bug: yq dumps the whole document (decoy r-two included) and must be rejected.
# other modes: yq fails so run.sh uses the indent fallback.
cat >"$tmp/bin/yq" << 'EOF'
#!/usr/bin/env bash
set -u
mode=${FAKE_MODE:?}
file=${!#}
# bug: dump the whole document, including a decoy r-two, so run.sh must reject it.
if [[ $mode == bug ]]; then
	cat "$file"
	exit 0
fi
[[ $mode == fixed ]] || exit 1
expr=${2:-}
python3 - "$file" "$expr" << 'PY'
import sys
path, expr = sys.argv[1], sys.argv[2]
needle = '["controller-credentials"]["'
start = expr.find(needle)
if start < 0:
    sys.exit(1)
rest = expr[start + len(needle):]
cloud, _, rest = rest.partition('"]["')
cred, _, _ = rest.partition('"]')
if not cloud or not cred:
    sys.exit(1)
state = 0
out = []
for line in open(path):
    raw = line.rstrip("\n")
    if raw.strip() == "":
        if state == 3:
            out.append(raw)
        continue
    i = len(raw) - len(raw.lstrip(" "))
    if state == 0:
        if raw == "controller-credentials:":
            state = 1
        continue
    if state == 1:
        if i == 0:
            break
        if i == 2 and raw == "  " + cloud + ":":
            state = 2
        continue
    if state == 2:
        if i <= 2:
            break
        if i == 4 and raw == "    " + cred + ":":
            state = 3
        continue
    if i <= 4:
        break
    out.append(raw)
if not any(line.strip() for line in out):
    sys.exit(1)
sys.stdout.write("\n".join(out) + "\n")
PY
EOF
chmod 755 "$tmp/bin/juju" "$tmp/bin/yq"

die() {
	echo "FAIL: $*" >&2
	exit 1
}

run_mode() {
	local mode=$1
	local dir=$tmp/$mode
	mkdir -p "$dir/state" "$dir/art" "$dir/log"
	: >"$dir/state/calls.log"
	local ec=0
	set +e
	FAKE_STATE=$dir/state FAKE_MODE=$mode FAKE_READABLE=$dir PATH="$tmp/bin:$PATH" \
		LAB_CONTROLLER=lab LAB_ITERATION=1 LAB_ARTIFACT_DIR=$dir/art \
		LAB_TIMEOUT_MIN=20 LAB_JUJU_VERSION=4.0.0 LAB_JUJU_GIT_COMMIT=abc23717 \
		bash "$here/run.sh" >"$dir/log/stdout" 2>"$dir/log/stderr"
	ec=$?
	set -e
	printf '%s\n' "$ec" >"$dir/exit"
	echo "ran: $mode exit=$ec"
}

art_of() { printf '%s\n' "$tmp/$1/art/repro-23717/i1"; }

assert_cleanup() {
	local mode=$1
	python3 - "$tmp/$mode/state/calls.log" "$mode" << 'PY'
import sys
lines = open(sys.argv[1]).read().splitlines()
mode = sys.argv[2]
juju = [ln for ln in lines if ln.startswith("juju ")]
removes = [ln for ln in juju if ln.startswith("juju remove-credential ") or ln.startswith("juju remove-cloud ")]
if len(removes) != 2:
    raise SystemExit(f"{mode}: remove commands {removes}")
if not removes[0].startswith("juju remove-credential fakemaas-i1 cred23717-i1 --controller lab"):
    raise SystemExit(f"{mode}: remove-credential line {removes[0]}")
if removes[1] != "juju remove-cloud fakemaas-i1 --controller lab":
    raise SystemExit(f"{mode}: remove-cloud line {removes[1]}")
adds = [ln for ln in juju if ln.startswith("juju add-cloud ")]
if not adds or not all("--force" in ln and "fakemaas-i1" in ln for ln in adds):
    raise SystemExit(f"{mode}: add-cloud lines {adds}")
print(f"ok: {mode} cleanup remove-credential then remove-cloud")
PY
}

assert_cloud_files() {
	local mode=$1 art
	art=$(art_of "$mode")
	python3 - "$tmp/$mode/state/calls.log" "$mode" "$art" << 'PY'
import os, re, sys
lines = open(sys.argv[1]).read().splitlines()
mode, art = sys.argv[2], os.path.realpath(sys.argv[3])
if "cloud-in-artifacts" not in lines:
    raise SystemExit(f"{mode}: missing cloud-in-artifacts")
if "cloud-outside-artifacts" in lines:
    raise SystemExit(f"{mode}: cloud-outside-artifacts")
adds = [ln for ln in lines if ln.startswith("juju add-cloud ")]
if not adds:
    raise SystemExit(f"{mode}: no add-cloud")
for ln in adds:
    m = re.search(r'(?:^|\s)-f (\S+)', ln)
    if not m:
        raise SystemExit(f"{mode}: add-cloud without -f: {ln}")
    path = m.group(1)
    base = os.path.basename(path)
    kind_m = re.fullmatch(r"cloud-(maas|openstack)\.yaml", base)
    if not kind_m:
        raise SystemExit(f"{mode}: unexpected cloud file {path}")
    kind = kind_m.group(1)
    expect = os.path.join(art, "cloud-" + kind + ".yaml")
    if os.path.realpath(path) != os.path.realpath(expect):
        raise SystemExit(f"{mode}: add-cloud -f {path} != {expect}")
    if not os.path.isfile(path):
        raise SystemExit(f"{mode}: cloud file missing after run: {path}")
    typ = None
    for line in open(path):
        mm = re.match(r"^\s*type:\s*(\S+)\s*$", line)
        if mm:
            typ = mm.group(1)
            break
    if typ != kind:
        raise SystemExit(f"{mode}: {path} type {typ!r} != {kind}")
print(f"ok: {mode} cloud files in artifacts")
PY
	case $mode in
	bug | fixed | noupload | snap-unreadable)
		[[ -f $art/cloud-maas.yaml ]] || die "$mode: cloud-maas.yaml missing"
		[[ ! -e $art/cloud-openstack.yaml ]] || die "$mode: cloud-openstack.yaml present"
		;;
	fallback | addcloud-fail)
		[[ -f $art/cloud-maas.yaml ]] || die "$mode: cloud-maas.yaml missing"
		[[ -f $art/cloud-openstack.yaml ]] || die "$mode: cloud-openstack.yaml missing"
		;;
	*)
		die "$mode: no cloud-file expectation"
		;;
	esac
	grep -qF 'cloud definition (maas): -rw' "$art/timeline.log" || die "$mode: timeline missing cloud definition listing"
	case $mode in
	bug | fixed | noupload | fallback)
		grep -qF 'credential definition: -rw-------' "$art/timeline.log" || die "$mode: timeline missing credential listing"
		;;
	esac
}

assert_priv_gone() {
	local mode=$1 root art
	root=$tmp/$mode
	art=$root/art
	if find "$root" -maxdepth 1 -name 'art-repro-23717-priv.*' -print | grep -q .; then
		die "$mode: priv dir left beside artifacts"
	fi
	if find "$art" -name 'credential-def.yaml' -print | grep -q .; then
		die "$mode: credential-def.yaml under artifacts"
	fi
	python3 - "$tmp/$mode/state/calls.log" "$mode" "$root" "$art" << 'PY'
import os, re, sys
lines = open(sys.argv[1]).read().splitlines()
mode, root, art = sys.argv[2], os.path.realpath(sys.argv[3]), os.path.realpath(sys.argv[4])
creds = [ln for ln in lines if ln.startswith("juju add-credential ")]
if not creds:
    print(f"ok: {mode} no priv dir left")
    raise SystemExit(0)
if len(creds) != 1:
    raise SystemExit(f"{mode}: add-credential lines {creds}")
m = re.search(r"(?:^|\s)-f (\S+)", creds[0])
if not m:
    raise SystemExit(f"{mode}: add-credential without -f")
priv = os.path.dirname(m.group(1))
base = os.path.basename(priv)
if not re.fullmatch(r"art-repro-23717-priv\..+", base):
    raise SystemExit(f"{mode}: cred dir name {priv}")
if os.path.realpath(os.path.dirname(priv)) != root:
    raise SystemExit(f"{mode}: cred dir parent {os.path.dirname(priv)} != {root}")
if os.path.exists(priv):
    raise SystemExit(f"{mode}: priv dir still exists: {priv}")
abs_priv = os.path.abspath(priv)
if abs_priv == art or abs_priv.startswith(art + os.sep):
    raise SystemExit(f"{mode}: credential dir is inside artifacts: {priv}")
print(f"ok: {mode} priv dir removed")
PY
}

assert_artifacts_clean() {
	local mode=$1 art
	art=$(art_of "$mode")
	if find "$art" -name 'credentials.yaml' -print | grep -q .; then
		die "$mode: credentials.yaml in artifacts"
	fi
	if grep -R -F -e 'maas-oauth' -e 'lab:lab:lab' -e 'lab-password' "$art" >/dev/null; then
		die "$mode: secret material in artifacts"
	fi
	local f pk
	while IFS= read -r -d '' f; do
		pk=0
		"$repo/scripts/redact.pl" --pk "$f" || pk=$?
		[[ $pk -eq 1 ]] || die "redact.pl --pk on $f exited $pk"
	done < <(find "$art" -type f -print0)
	local st=$tmp/scrub-$mode up=$tmp/up-$mode
	mkdir -p "$st"
	# Scrub the artifact root so the upload keeps .../i1/cloud-maas.yaml.
	GITHUB_OUTPUT=$tmp/scrub-out-$mode \
		LAB_ARTIFACT_DIR=$tmp/$mode/art \
		LAB_UPLOAD_DIR=$up \
		LAB_STATE_DIR=$st \
		bash "$repo/scripts/scrub.sh" >"$tmp/scrub-$mode.txt"
	grep -q '^upload_blocked=false$' "$st/scrub.env" || die "$mode: upload_blocked $(cat "$st/scrub.env")"
	grep -q '^scrub_hits=0$' "$st/scrub.env" || die "$mode: scrub hits $(cat "$st/scrub.env")"
	grep -q '^scrub_withheld=0$' "$st/scrub.env" || die "$mode: scrub withheld $(cat "$st/scrub.env")"
	[[ -f $up/repro-23717/i1/cloud-maas.yaml ]] || die "$mode: scrubbed upload missing i1/cloud-maas.yaml"
	if find "$up" -name 'credential-def.yaml' -print | grep -q .; then
		die "$mode: credential-def.yaml in scrubbed upload"
	fi
	echo "ok: $mode redact.pl --pk clean, scrub_hits=0, cloud-maas.yaml kept"
}

assert_result() {
	local mode=$1 filter=$2
	local json
	json=$(art_of "$mode")/result.json
	[[ -f $json ]] || die "$mode result.json missing"
	jq -e "$filter" "$json" >/dev/null || die "$mode result.json $(jq -c . "$json")"
	jq -e '
		keys | sort == [
			"cloud_type", "credential_on_controller", "exit_code", "issue", "iteration",
			"juju_git_commit", "juju_version", "phase", "reason", "region_requested",
			"region_seen", "result"
		]
	' "$json" >/dev/null || die "$mode result keys $(jq -c 'keys' "$json")"
}

run_mode bug
run_mode fixed
run_mode noupload
run_mode addcloud-fail
run_mode fallback

# noenv: missing LAB_* is setup-error (2), and juju is not called.
mkdir -p "$tmp/noenv/state" "$tmp/noenv/art" "$tmp/noenv/log"
: >"$tmp/noenv/state/calls.log"
noenv_ec=0
set +e
FAKE_STATE=$tmp/noenv/state FAKE_MODE=bug FAKE_READABLE=$tmp/noenv PATH="$tmp/bin:$PATH" \
	env -u LAB_CONTROLLER -u LAB_ITERATION -u LAB_ARTIFACT_DIR -u LAB_TIMEOUT_MIN \
	-u LAB_JUJU_VERSION -u LAB_JUJU_GIT_COMMIT \
	bash "$here/run.sh" >"$tmp/noenv/log/stdout" 2>"$tmp/noenv/log/stderr"
noenv_ec=$?
set -e
printf '%s\n' "$noenv_ec" >"$tmp/noenv/exit"
echo "ran: noenv exit=$noenv_ec"
[[ $noenv_ec -eq 2 ]] || die "noenv exit $noenv_ec (want 2)"
[[ ! -s $tmp/noenv/state/calls.log ]] || die "noenv invoked juju: $(cat "$tmp/noenv/state/calls.log")"
echo "ok: noenv exit 2"

bug_ec=$(<"$tmp/bug/exit")
[[ $bug_ec -eq 1 ]] || die "bug exit $bug_ec (want 1)"
assert_result bug '
	.result == "reproduced" and .exit_code == 1 and .phase == "repro" and
	.issue == "23717" and .iteration == 1 and .cloud_type == "maas" and
	.region_requested == "r-two" and .region_seen == null and
	.credential_on_controller == true and .juju_version == "4.0.0" and
	.juju_git_commit == "abc23717"
'
grep -q 'client-credentials:' "$(art_of bug)/show-credential.yaml" || die "bug decoy missing from show-credential.yaml"
grep -q 'parser=yq-rejected' "$(art_of bug)/timeline.log" || die "bug accepted an unscoped yq dump"
grep -q 'parser=awk' "$(art_of bug)/timeline.log" || die "bug did not use awk"
grep -q 'parser=yq$' "$(art_of bug)/timeline.log" && die "bug used yq output"
python3 - "$tmp/bug/state/calls.log" << 'PY'
import sys
text = open(sys.argv[1]).read().splitlines()
if "add-cloud-type maas" not in text or "add-cloud-type openstack" in text:
    raise SystemExit(f"bug cloud types: {text}")
if "cred-auth oauth1" not in text or "cred-has-maas-oauth-key" not in text:
    raise SystemExit("bug credential file was not oauth1")
if "cred-file-outside-artifacts" not in text or "cred-in-artifacts" in text:
    raise SystemExit("bug credential file was not kept out of artifacts")
adds = [ln for ln in text if ln.startswith("juju add-credential ")]
if len(adds) != 1 or "--region r-two" not in adds[0]:
    raise SystemExit(f"bug add-credential {adds}")
shows = [ln for ln in text if ln.startswith("juju show-credential ")]
if len(shows) != 1 or "--format yaml" not in shows[0] or "--show-secrets" in shows[0] or "--format json" in shows[0]:
    raise SystemExit(f"bug show-credential {shows}")
print("ok: bug maas oauth1, scoped awk, show-credential yaml")
PY
assert_cleanup bug
assert_cloud_files bug
assert_priv_gone bug
assert_artifacts_clean bug
echo "ok: bug exit 1 reproduced"

fixed_ec=$(<"$tmp/fixed/exit")
[[ $fixed_ec -eq 0 ]] || die "fixed exit $fixed_ec (want 0)"
assert_result fixed '
	.result == "not_reproduced" and .exit_code == 0 and .phase == "repro" and
	.cloud_type == "maas" and .region_seen == "r-two" and
	.credential_on_controller == true and .region_requested == "r-two"
'
grep -q 'parser=yq$' "$(art_of fixed)/timeline.log" || die "fixed did not use yq: $(grep parser= "$(art_of fixed)/timeline.log")"
grep -q 'parser=awk' "$(art_of fixed)/timeline.log" && die "fixed fell back to awk"
# The saved document still has r-two on a different credential. The verdict
# used the yq block, which is the only way region_seen is r-two while awk was skipped.
grep -q 'client-credentials:' "$(art_of fixed)/show-credential.yaml" || die "fixed decoy missing"
assert_cleanup fixed
assert_cloud_files fixed
assert_priv_gone fixed
assert_artifacts_clean fixed
echo "ok: fixed exit 0 not_reproduced"

noupload_ec=$(<"$tmp/noupload/exit")
[[ $noupload_ec -eq 2 ]] || die "noupload exit $noupload_ec (want 2)"
assert_result noupload '
	.result == "error" and .exit_code == 2 and .phase == "setup" and
	.reason == "credential not uploaded" and .cloud_type == "maas" and
	.credential_on_controller == null and .region_seen == null
'
grep -q 'not uploaded' "$(art_of noupload)/add-credential.log" || die "noupload log missing the phrase"
assert_cleanup noupload
assert_cloud_files noupload
assert_priv_gone noupload
assert_artifacts_clean noupload
echo "ok: noupload exit 2"

fail_ec=$(<"$tmp/addcloud-fail/exit")
[[ $fail_ec -eq 2 ]] || die "addcloud-fail exit $fail_ec (want 2)"
assert_result addcloud-fail '
	.result == "error" and .exit_code == 2 and .phase == "setup" and
	.reason == "add-cloud failed" and .cloud_type == null and
	.credential_on_controller == null
'
python3 - "$tmp/addcloud-fail/state/calls.log" << 'PY'
import sys
text = open(sys.argv[1]).read().splitlines()
types = [ln for ln in text if ln.startswith("add-cloud-type ")]
if types != ["add-cloud-type maas", "add-cloud-type openstack"]:
    raise SystemExit(f"addcloud-fail types {types}")
if any(ln.startswith("juju add-credential ") for ln in text):
    raise SystemExit("addcloud-fail still added a credential")
print("ok: addcloud-fail retried openstack")
PY
assert_cleanup addcloud-fail
assert_cloud_files addcloud-fail
assert_priv_gone addcloud-fail
assert_artifacts_clean addcloud-fail
echo "ok: addcloud-fail exit 2"

fb_ec=$(<"$tmp/fallback/exit")
[[ $fb_ec -eq 1 ]] || die "fallback exit $fb_ec (want 1)"
assert_result fallback '
	.result == "reproduced" and .exit_code == 1 and .phase == "repro" and
	.cloud_type == "openstack" and .region_seen == null and
	.credential_on_controller == true and .region_requested == "r-two"
'
python3 - "$tmp/fallback/state/calls.log" << 'PY'
import sys
text = open(sys.argv[1]).read().splitlines()
types = [ln for ln in text if ln.startswith("add-cloud-type ")]
if types != ["add-cloud-type maas", "add-cloud-type openstack"]:
    raise SystemExit(f"fallback types {types}")
if "cred-auth userpass" not in text or "cred-has-maas-oauth-key" in text:
    raise SystemExit(f"fallback cred markers missing: {text}")
print("ok: fallback openstack userpass")
PY
assert_cleanup fallback
assert_cloud_files fallback
assert_priv_gone fallback
assert_artifacts_clean fallback
echo "ok: fallback exit 1 reproduced"

run_mode snap-unreadable
snap_ec=$(<"$tmp/snap-unreadable/exit")
[[ $snap_ec -eq 2 ]] || die "snap-unreadable exit $snap_ec (want 2)"
assert_result snap-unreadable '
	.result == "error" and .exit_code == 2 and .phase == "setup" and
	.reason == "juju could not open cloud definition" and .cloud_type == null and
	.credential_on_controller == null and .region_seen == null
'
python3 - "$tmp/snap-unreadable/state/calls.log" << 'PY'
import sys
text = open(sys.argv[1]).read().splitlines()
types = [ln for ln in text if ln.startswith("add-cloud-type ")]
if types != ["add-cloud-type maas"]:
    raise SystemExit(f"snap-unreadable types {types}")
if any(ln.startswith("juju add-credential ") for ln in text):
    raise SystemExit("snap-unreadable added a credential")
print("ok: snap-unreadable maas only, no add-credential")
PY
assert_cleanup snap-unreadable
assert_cloud_files snap-unreadable
assert_priv_gone snap-unreadable
assert_artifacts_clean snap-unreadable
echo "ok: snap-unreadable exit 2"

if [[ $(id -u) -eq 0 ]]; then
	echo "skip: priv-mkdir-fail (uid 0 ignores directory modes)"
else
	dir=$tmp/priv-mkdir-fail
	mkdir -p "$dir/state" "$dir/ro/art" "$dir/log"
	: >"$dir/state/calls.log"
	chmod 555 "$dir/ro"
	priv_ec=0
	set +e
	FAKE_STATE=$dir/state FAKE_MODE=bug FAKE_READABLE=$dir PATH="$tmp/bin:$PATH" \
		LAB_CONTROLLER=lab LAB_ITERATION=1 LAB_ARTIFACT_DIR=$dir/ro/art \
		LAB_TIMEOUT_MIN=20 LAB_JUJU_VERSION=4.0.0 LAB_JUJU_GIT_COMMIT=abc23717 \
		bash "$here/run.sh" >"$dir/log/stdout" 2>"$dir/log/stderr"
	priv_ec=$?
	set -e
	chmod 755 "$dir/ro"
	printf '%s\n' "$priv_ec" >"$dir/exit"
	echo "ran: priv-mkdir-fail exit=$priv_ec"
	[[ $priv_ec -eq 2 ]] || die "priv-mkdir-fail exit $priv_ec (want 2)"
	[[ ! -s $dir/state/calls.log ]] || die "priv-mkdir-fail invoked juju: $(cat "$dir/state/calls.log")"
	jq -e '
		.result == "error" and .exit_code == 2 and .phase == "setup" and
		.reason == "private dir failed"
	' "$dir/ro/art/repro-23717/i1/result.json" >/dev/null || die "priv-mkdir-fail result $(jq -c . "$dir/ro/art/repro-23717/i1/result.json")"
	if find "$dir/ro" -maxdepth 1 -name 'art-repro-23717-priv.*' -print | grep -q .; then
		die "priv-mkdir-fail left a priv dir"
	fi
	echo "ok: priv-mkdir-fail exit 2"
fi

echo "stub-test: ok"
