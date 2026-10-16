#!/usr/bin/env bash
# Sets up strictly confined MicroK8s from a pinned channel with plain snap
# commands (design §9: no balchua/microk8s-actions), asserts the tracked channel,
# adds the runner user to snap_microk8s (later steps use `sg snap_microk8s`),
# enables the addons juju/juju smoke.yml enables (dns, hostpath-storage, rbac)
# and waits until they serve. Records substrate_snap_* in $LAB_STATE_DIR/juju.env.
# Exit 2 (setup-error) on failure.
set -euo pipefail
export LC_ALL=C
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

channel=${LAB_MICROK8S_CHANNEL:?}
[[ $channel =~ ^[0-9]+\.[0-9]+-strict/stable$ ]] || setup_fail "microk8s channel: unexpected value (workflow bug)"

timeout 300 sudo snap install microk8s --channel="$channel" || setup_fail "snap install microk8s --channel=$channel failed"
tracking=$(snap info microk8s | sed -n 's/^tracking: *//p')
[[ $tracking == "$channel" ]] || setup_fail "microk8s snap tracks '$tracking', requested '$channel'"
sudo usermod -a -G snap_microk8s "$USER" || setup_fail "usermod -a -G snap_microk8s failed"
timeout 300 sudo microk8s status --wait-ready --timeout 280 >/dev/null || setup_fail "microk8s did not become ready within 5 min"
for a in dns hostpath-storage rbac; do
	timeout 240 sudo microk8s enable "$a" || setup_fail "microk8s enable $a failed"
done
timeout 180 sudo microk8s kubectl -n kube-system rollout status deployment/coredns --timeout=170s ||
	setup_fail "coredns not ready within 3 min"
timeout 180 sudo microk8s kubectl -n kube-system rollout status deployment/hostpath-provisioner --timeout=170s ||
	setup_fail "hostpath-provisioner not ready within 3 min"
sudo microk8s status --format short || true
record_substrate microk8s
