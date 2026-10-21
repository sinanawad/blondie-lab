#!/usr/bin/env bash
# Offline stand-in for repro-23659: fake juju/lxc, three modes, scrub check.
# Run: bash scenarios/repro-23659/stub-test.sh
set -euo pipefail
export LC_ALL=C

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin"

cat >"$tmp/bin/juju" << 'EOF'
#!/usr/bin/env bash
set -u
state=${FAKE_STATE:?}
mode=${FAKE_MODE:?}
printf 'juju %s\n' "$*" >>"$state/calls.log"
cmd=$1
shift || true
case $cmd in
add-model)
	touch "$state/model"
	exit 0
	;;
add-machine)
	exit 0
	;;
status)
	if [[ -f $state/cleared ]]; then
		echo '{"machines":{}}'
	elif [[ $mode == nobatch && -f $state/removed1 ]]; then
		echo '{"machines":{"0":{"juju-status":{"current":"started"},"instance-id":"juju-abc123-0"}}}'
	else
		echo '{"machines":{"0":{"juju-status":{"current":"started"},"instance-id":"juju-abc123-0"},"1":{"juju-status":{"current":"started"},"instance-id":"juju-abc123-1"}}}'
	fi
	exit 0
	;;
remove-machine)
	id=${!#}
	if [[ $id == 0 && ! -f $state/remove0_at ]]; then
		date +%s >"$state/remove0_at"
	fi
	if [[ $id == 1 ]]; then
		touch "$state/removed1"
	fi
	exit 0
	;;
models)
	if [[ -f $state/destroyed || ! -f $state/model ]]; then
		echo '{"models":[]}'
	else
		echo '{"models":[{"name":"admin/repro-23659-i1","short-name":"repro-23659-i1"}]}'
	fi
	exit 0
	;;
destroy-model)
	touch "$state/destroyed"
	exit 0
	;;
debug-log)
	n=0
	if [[ $mode != nofail && -f $state/remove0_at ]]; then
		now=$(date +%s)
		start=$(<"$state/remove0_at")
		n=$((now - start))
		if ((n < 0)); then
			n=0
		fi
		if ((n > 30)); then
			n=30
		fi
	fi
	printf 'served_exits=%s\n' "$n" >>"$state/calls.log"
	i=0
	while ((i < n)); do
		echo "exiting provisioner task loop; err: stopping instances: failed to remove containers: juju-abc123-0"
		i=$((i + 1))
	done
	if [[ $mode == bug && -f $state/removed1 ]]; then
		echo "stopping known instances [juju-abc123-0 juju-abc123-1]"
	fi
	exit 0
	;;
*)
	echo "fake juju: unknown command: $cmd" >&2
	exit 99
	;;
esac
EOF

cat >"$tmp/bin/lxc" << 'EOF'
#!/usr/bin/env bash
set -u
state=${FAKE_STATE:?}
mode=${FAKE_MODE:?}
printf 'lxc %s\n' "$*" >>"$state/calls.log"
cmd=$1
shift || true
case $cmd in
list)
	FAKE_STATE=$state FAKE_MODE=$mode python3 - << 'PY'
import json, os, sys
state = os.environ["FAKE_STATE"]
mode = os.environ["FAKE_MODE"]
ud = (
    "apipassword: s3cret\n"
    "-----BEGIN RSA PRIVATE KEY-----\n"
    "MIIEowIBAAKCAQEA\n"
    "-----END RSA PRIVATE KEY-----\n"
)
def inst(name, prot):
    cfg = {"user.user-data": ud}
    if prot:
        cfg["security.protection.delete"] = "true"
    return {"name": name, "status": "Running", "config": cfg}
protected = os.path.exists(os.path.join(state, "protected"))
cleared = os.path.exists(os.path.join(state, "cleared"))
removed1 = os.path.exists(os.path.join(state, "removed1"))
items = []
if not cleared:
    items.append(inst("juju-abc123-0", protected))
    drop_c1 = removed1 and mode in ("bug", "nobatch")
    if not drop_c1:
        items.append(inst("juju-abc123-1", False))
items.append(inst("juju-controller", False))
json.dump(items, sys.stdout)
print()
PY
	exit 0
	;;
config)
	action=$1
	name=$2
	case $action in
	set)
		touch "$state/protected"
		;;
	get)
		if [[ -f $state/protected ]]; then
			echo true
		else
			echo false
		fi
		;;
	unset)
		rm -f "$state/protected"
		# Release polls until every instance is gone. Drop them on unset so
		# that wait finishes inside the stub's minute, after the call is logged.
		touch "$state/cleared"
		;;
	*)
		echo "fake lxc: unknown config $action" >&2
		exit 99
		;;
	esac
	exit 0
	;;
*)
	echo "fake lxc: unknown command: $cmd" >&2
	exit 99
	;;
esac
EOF
chmod 755 "$tmp/bin/juju" "$tmp/bin/lxc"

die() {
	echo "FAIL: $*" >&2
	exit 1
}

# Meaningful fixture: the raw list really contains key material.
fix=$tmp/fixture
mkdir -p "$fix"
: >"$fix/calls.log"
raw=$(FAKE_STATE=$fix FAKE_MODE=bug "$tmp/bin/lxc" list --format json)
pk=0
printf '%s\n' "$raw" | "$repo/scripts/redact.pl" --pk || pk=$?
[[ $pk -eq 0 ]] || die "raw lxc list did not trip redact.pl --pk (status $pk)"
echo "ok: fixture redact.pl --pk exits 0"

run_mode() {
	local mode=$1
	local dir=$tmp/$mode
	mkdir -p "$dir/state" "$dir/art" "$dir/log"
	: >"$dir/state/calls.log"
	local ec=0
	set +e
	FAKE_STATE=$dir/state FAKE_MODE=$mode PATH="$tmp/bin:$PATH" \
		LAB_CONTROLLER=lab LAB_ITERATION=1 LAB_ARTIFACT_DIR=$dir/art \
		LAB_TIMEOUT_MIN=7 REPRO_STALE_S=3 REPRO_POLL_S=1 REPRO_BACKOFF_POLL_S=1 \
		bash "$here/run.sh" >"$dir/log/stdout" 2>"$dir/log/stderr"
	ec=$?
	set -e
	printf '%s\n' "$ec" >"$dir/exit"
	echo "ran: $mode exit=$ec"
}

run_mode bug
run_mode nobatch
run_mode nofail

art_of() { printf '%s\n' "$tmp/$1/art/repro-23659/i1"; }

# bug
bug_ec=$(<"$tmp/bug/exit")
[[ $bug_ec -eq 1 ]] || die "bug exit $bug_ec (want 1)"
bug_json=$(art_of bug)/result.json
[[ -f $bug_json ]] || die "bug result.json missing"
jq -e '.result == "reproduced" and .batched == true and .exits_before_remove1 >= 12' "$bug_json" >/dev/null \
	|| die "bug result.json $(jq -c '{result,batched,exits_before_remove1}' "$bug_json")"
python3 - "$tmp/bug/state/calls.log" << 'PY'
import re, sys
lines = open(sys.argv[1]).read().splitlines()
idx = next(i for i, line in enumerate(lines) if re.search(r"remove-machine\b.*\b1$", line))
before = lines[:idx]
served = [line for line in before if "served_exits=" in line]
if not served:
    raise SystemExit("no served_exits before remove-machine 1")
n = int(served[-1].split("served_exits=", 1)[1])
if n < 12:
    raise SystemExit(f"last served_exits before remove-machine 1 is {n}")
if any(re.search(r"remove-machine\b.*\b1$", line) for line in before):
    raise SystemExit("remove-machine 1 appears before its served_exits line")
print(f"ok: calls.log served_exits={n} before remove-machine 1")
PY
grep -F 'config unset juju-abc123-0' "$tmp/bug/state/calls.log" >/dev/null \
	|| die "bug did not unset protection on juju-abc123-0"
echo "ok: bug exit 1 reproduced batched exits>=12 unset"

keys_ok='type=="array" and all(.[]; (keys|sort)==["name","protection_delete","status"])'
for snap in lxc-before.json lxc-final.json; do
	f="$(art_of bug)/$snap"
	[[ -f $f ]] || die "missing $f"
	jq -e "$keys_ok" "$f" >/dev/null || die "$snap keys: $(cat "$f")"
	if grep -F -e BEGIN -e apipassword -e user-data "$f" >/dev/null; then
		die "$snap still has raw lxc config"
	fi
done
echo "ok: lxc snapshots are name/status/protection_delete only"

while IFS= read -r -d '' f; do
	pk=0
	"$repo/scripts/redact.pl" --pk "$f" || pk=$?
	[[ $pk -eq 1 ]] || die "redact.pl --pk on $f exited $pk"
done < <(find "$tmp/bug/art" -type f -print0)
echo "ok: redact.pl --pk exits 1 for every bug artifact"

mkdir -p "$tmp/up" "$tmp/st"
GITHUB_OUTPUT=$tmp/scrub-out \
	LAB_ARTIFACT_DIR=$tmp/bug/art \
	LAB_UPLOAD_DIR=$tmp/up \
	LAB_STATE_DIR=$tmp/st \
	bash "$repo/scripts/scrub.sh" >"$tmp/scrub.txt"
grep -q '^upload_blocked=false$' "$tmp/st/scrub.env" || die "scrub upload_blocked $(cat "$tmp/st/scrub.env")"
grep -q '^scrub_hits=0$' "$tmp/st/scrub.env" || die "scrub hits $(cat "$tmp/st/scrub.env")"
echo "ok: scrub upload_blocked=false scrub_hits=0"

# nobatch
nob_ec=$(<"$tmp/nobatch/exit")
[[ $nob_ec -eq 3 ]] || die "nobatch exit $nob_ec (want 3)"
nob_json=$(art_of nobatch)/result.json
jq -e '.reason == "bug path not exercised"' "$nob_json" >/dev/null \
	|| die "nobatch reason $(jq -r '.reason' "$nob_json")"
echo "ok: nobatch exit 3 bug path not exercised"

# nofail
nf_ec=$(<"$tmp/nofail/exit")
[[ $nf_ec -eq 3 ]] || die "nofail exit $nf_ec (want 3)"
nf_json=$(art_of nofail)/result.json
[[ -f $nf_json ]] || die "nofail result.json missing"
jq -e '.reason | startswith("precondition not reached (exits=0)")' "$nf_json" >/dev/null \
	|| die "nofail reason $(jq -r '.reason' "$nf_json")"
grep -F 'config unset juju-abc123-0' "$tmp/nofail/state/calls.log" >/dev/null \
	|| die "nofail did not unset protection"
echo "ok: nofail exit 3 precondition not reached (exits=0), protection unset"

echo "stub-test: ok"
