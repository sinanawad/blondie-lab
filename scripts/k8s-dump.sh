#!/usr/bin/env bash
# k8s-dump.sh <dir> <log>: MicroK8s state for the artifact (design §7), best
# effort, every command under timeout and logged to <log>:
# get all,events,pvc,pv -A -o wide; describe pods -A; logs --all-containers
# (+ --previous) for every pod in the controller and juju model namespaces;
# journalctl -u 'snap.microk8s.*' -n 500. Needs snap_microk8s (run under sg).
# No secrets objects are read; logs go through scrub.sh like everything else.
set -uo pipefail
export LC_ALL=C

d=${1:?} log=${2:?}
here=$(cd "$(dirname "$0")" && pwd)
k="$here/lab-kubectl"
mkdir -p "$d"
c() {
	local t=$1 f=$2 rc=0
	shift 2
	timeout "$t" "$@" >"$d/$f" 2>&1 || rc=$?
	echo "$(date -u +%H:%M:%SZ) rc=$rc k8s/$f: ${*#"$here/"}" >>"$log"
}
c 60 get-all.txt "$k" get all,events,pvc,pv -A -o wide
c 60 namespaces.txt "$k" get ns --show-labels
c 120 describe-pods.txt "$k" describe pods -A
c 60 journal-microk8s.txt sudo journalctl -u 'snap.microk8s.*' -n 500 --no-pager
# Controller namespace (controller-<name>) and juju model namespaces.
nss=$(timeout 60 "$k" get ns -o json 2>>"$log" |
	jq -r '.items[] | select((.metadata.name | startswith("controller-")) or (.metadata.labels["model.juju.is/name"] != null)) | .metadata.name' 2>>"$log" | sort -u)
for ns in $nss; do
	[[ $ns =~ ^[a-z0-9-]{1,63}$ ]] || continue
	pods=$(timeout 60 "$k" get pods -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>>"$log")
	for p in $pods; do
		[[ $p =~ ^[a-z0-9.-]{1,253}$ ]] || continue
		mkdir -p "$d/logs/$ns"
		c 60 "logs/$ns/$p.log" "$k" logs -n "$ns" "$p" --all-containers --timestamps
		c 60 "logs/$ns/$p.previous.log" "$k" logs -n "$ns" "$p" --all-containers --timestamps --previous
	done
done
exit 0
