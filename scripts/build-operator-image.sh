#!/usr/bin/env bash
# Build mode on k8s, run by build-juju.sh under `sg snap_microk8s`: builds the
# jujud-operator image from $LAB_SRC and imports it into MicroK8s'
# containerd (juju/juju smoke.yml recipe: `make microk8s-operator-update`).
# Records the imported image's ref, config digest (docker image id) and
# containerd target digest, which bootstrap.sh compares with the controller
# pod's api-server imageID (design §3: for a tag the local image has the same
# tag as the public one, so only the digest tells them apart). Exit 2 on failure.
set -euo pipefail
export LC_ALL=C
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/lib.sh
. "$here/lib.sh"

C="${LAB_ARTIFACT_DIR:?}/collect"
log="$C/build-operator-image.log"
cd "${LAB_SRC:?}"
start=$SECONDS
echo "make microk8s-operator-update (output: collect/build-operator-image.log)"
if ! make microk8s-operator-update >"$log" 2>&1; then
	tail -n 40 "$log" | "$here/redact.pl" || true
	setup_fail "make microk8s-operator-update failed (see collect/build-operator-image.log in the artifact)"
fi
state_set build_operator_image_s "$((SECONDS - start))"
image=$(sed -n 's/^Uploading image \([^ ]*\) to microk8s$/\1/p' "$log" | tail -n 1)
[[ $image =~ ^[a-z0-9./-]+/jujud-operator:[A-Za-z0-9._-]+$ ]] || setup_fail "could not find the imported operator image name in the build log ('$image')"
config=$(docker image inspect --format '{{.Id}}' "$image") || setup_fail "docker image inspect $image failed"
target=$(timeout 60 microk8s ctr --namespace k8s.io images ls "name==$image" | awk -v i="$image" '$1 == i {print $3}') || target=""
[[ $config =~ ^sha256:[0-9a-f]{64}$ ]] || setup_fail "operator image config digest '$config' is not a sha256 digest"
[[ $target =~ ^sha256:[0-9a-f]{64}$ ]] || setup_fail "operator image $image not found in microk8s containerd (target digest '$target')"
state_set operator_image "$image"
state_set operator_image_config "$config"
state_set operator_image_target "$target"
echo "operator image $image imported: config $config, target $target ($((SECONDS - start))s)"
