#!/usr/bin/env bash
# Collects logs into $LAB_ARTIFACT_DIR (design §7). Runs with if: always().
# First action: a provisional verdict.json (verdict.sh, outputs discarded) and
# collect.log, so an upload never hides the real failure. Every later command
# is best effort, under timeout, logged to collect.log. Never collected:
# accounts.yaml, agent.conf, *.key, kubeconfigs, /var/lib/juju.
# On k8s (LAB_SUBSTRATE=k8s) the step runs under `sg snap_microk8s` and adds
# collect/k8s/ (scripts/k8s-dump.sh); it runs before Teardown, so a failed or
# timed-out bootstrap is dumped while its pods still exist.
set -uo pipefail
export LC_ALL=C

ART=${LAB_ARTIFACT_DIR:?}
here=$(cd "$(dirname "$0")" && pwd)
C="$ART/collect"
mkdir -p "$C"
LOG="$ART/collect.log"
: >"$LOG"
GITHUB_OUTPUT=/dev/null GITHUB_STEP_SUMMARY=/dev/null "$here/verdict.sh" >>"$LOG" 2>&1 ||
	echo "provisional verdict.sh failed ($?)" >>"$LOG"

# c <seconds> <output file under collect/> <command...>
c() {
	local t=$1 f=$2 rc=0
	shift 2
	mkdir -p "$(dirname "$C/$f")"
	timeout "$t" "$@" >"$C/$f" 2>&1 || rc=$?
	echo "$(date -u +%H:%M:%SZ) rc=$rc $f: $*" >>"$LOG"
}

c 30 host/df.txt df -h
c 30 host/free.txt free -m
c 30 host/snap-list.txt snap list

controller=${LAB_CONTROLLER:-}
if [[ ${LAB_NEEDS_JUJU:-0} != 1 ]]; then
	echo "no Juju for this scenario (NEEDS_JUJU=${LAB_NEEDS_JUJU:-unset}); host facts only" >>"$LOG"
	exit 0
fi

if command -v juju >/dev/null && [[ -n $controller ]] && timeout 30 juju show-controller "$controller" >/dev/null 2>&1; then
	c 60 juju/version.txt juju version --all
	c 60 juju/show-controller.yaml juju show-controller "$controller"
	c 60 juju/controller-config.yaml juju controller-config -c "$controller" --format=yaml
	models=$(timeout 60 juju models -c "$controller" --format=json 2>>"$LOG" | jq -r '.models // [] | .[] | ."short-name"' 2>>"$LOG")
	for m in $models; do
		[[ $m =~ ^[A-Za-z0-9._-]+$ ]] || { echo "skipping odd model name" >>"$LOG"; continue; }
		c 60 "juju/$m/model-config.yaml" juju model-config -m "$controller:$m" --format=yaml
		c 60 "juju/$m/status.yaml" juju status -m "$controller:$m" --format=yaml --relations --storage
		# debug-log capped at 20 MB per model.
		timeout 120 juju debug-log -m "$controller:$m" --replay --no-tail 2>&1 | head -c 20M >"$C/juju/$m/debug-log.txt"
		echo "$(date -u +%H:%M:%SZ) rc=${PIPESTATUS[0]} juju/$m/debug-log.txt (capped 20M)" >>"$LOG"
	done
else
	echo "juju or controller '$controller' not available; skipping juju collection" >>"$LOG"
fi

if [[ ${LAB_SUBSTRATE:-} == k8s ]]; then
	if command -v microk8s >/dev/null; then
		"$here/k8s-dump.sh" "$C/k8s" "$LOG"
	else
		echo "microk8s not installed; skipping k8s collection" >>"$LOG"
	fi
fi

if command -v lxc >/dev/null; then
	c 60 lxd/list.txt lxc list
	names=$(timeout 60 lxc list --format=json 2>>"$LOG" | jq -r '.[] | "\(.name) \(.status)"' 2>>"$LOG")
	while read -r name status; do
		[[ -n $name && $name =~ ^[A-Za-z0-9-]+$ ]] || continue
		[[ $status == Running ]] || c 60 "lxd/$name/info.txt" lxc info --show-log "$name"
		[[ $status == Running ]] || continue
		files=$(timeout 30 lxc exec "$name" -- sh -c 'ls /var/log/juju/*.log 2>/dev/null' 2>>"$LOG")
		for f in $files /var/log/cloud-init-output.log; do
			[[ $f =~ ^/var/log/[A-Za-z0-9/._-]+\.log$ ]] || continue
			mkdir -p "$C/lxd/$name"
			timeout 60 lxc file pull "$name$f" "$C/lxd/$name/$(basename "$f")" >>"$LOG" 2>&1 ||
				echo "pull $name$f failed" >>"$LOG"
		done
	done <<<"$names"
	c 60 lxd/journal-lxd-daemon.txt sudo journalctl -u snap.lxd.daemon -n 500 --no-pager
fi
echo "collect: done" >>"$LOG"
exit 0
