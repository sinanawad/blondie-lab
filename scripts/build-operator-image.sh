#!/usr/bin/env bash
# Build mode on k8s, called by build-juju.sh: builds the jujud-operator image
# from $LAB_SRC with docker (`make operator-image OCI_BUILDER=docker`) and
# imports it into MicroK8s' containerd. Same result as juju/juju smoke.yml's
# `sg snap_microk8s 'make microk8s-operator-update'` (host-install +
# operator-image + `docker save | microk8s.ctr image import`), split because
# the hosted runner has podman, which the Makefile prefers and which can't
# run rootless under `sg`; here docker builds as the runner user and only the
# import runs under `sg snap_microk8s`.
# Records the image's ref, config digest (docker image id) and containerd
# target digest, which bootstrap.sh compares with the controller pod's
# api-server imageID (design §3: for a tag the local image has the same tag
# as the public one, so only the digest tells them apart). Exit 2 on failure.
set -euo pipefail
export LC_ALL=C
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/lib.sh
. "$here/lib.sh"

version=${LAB_BUILT_VERSION:?}
C="${LAB_ARTIFACT_DIR:?}/collect"
log="$C/build-operator-image.log"
cd "${LAB_SRC:?}"
start=$SECONDS
image="ghcr.io/juju/jujud-operator:$version"
[[ $image =~ ^ghcr\.io/juju/jujud-operator:4\.[0-9]+[A-Za-z0-9.-]*$ ]] || setup_fail "unexpected operator image name '$image'"
echo "make operator-image OCI_BUILDER=docker (output: collect/build-operator-image.log)"
# The Dockerfile's base image comes from public.ecr.aws, which answers 429
# ("Data limit exceeded") now and then on shared runner IPs (run 38891822632).
# Retry that one case once; anything else fails at once.
attempt=1
until make operator-image OCI_BUILDER=docker >>"$log" 2>&1; do
	rate_limited=0
	grep -q '429 Too Many Requests' "$log" && rate_limited=1
	if [ "$rate_limited" = 1 ] && [ "$attempt" -lt 2 ]; then
		attempt=$((attempt + 1))
		echo "base image registry rate-limited (429); retrying make operator-image in ${LAB_OPERATOR_RETRY_S:-60}s" | tee -a "$log"
		sleep "${LAB_OPERATOR_RETRY_S:-60}"
		continue
	fi
	tail -n 40 "$log" | "$here/redact.pl" || true
	[ "$rate_limited" = 1 ] && setup_fail "make operator-image failed: base image registry rate-limited (429) after $attempt attempts (see collect/build-operator-image.log)"
	setup_fail "make operator-image failed (see collect/build-operator-image.log in the artifact)"
done
config=$(docker image inspect --format '{{.Id}}' "$image" 2>>"$log") || setup_fail "the build produced no $image (docker image inspect failed)"
[[ $config =~ ^sha256:[0-9a-f]{64}$ ]] || setup_fail "operator image config digest '$config' is not a sha256 digest"
# Fixed strings under sg; the image name travels via env.
export LAB_OPERATOR_IMAGE=$image
# shellcheck disable=SC2016 # expanded by the sg shell
if ! docker save "$image" | sg snap_microk8s -c 'microk8s ctr --namespace k8s.io image import -' >>"$log" 2>&1; then
	setup_fail "importing $image into microk8s failed (see collect/build-operator-image.log)"
fi
# shellcheck disable=SC2016 # expanded by the sg shell
target=$(timeout 60 sg snap_microk8s -c 'microk8s ctr --namespace k8s.io images ls "name==$LAB_OPERATOR_IMAGE"' | awk -v i="$image" '$1 == i {print $3}') || target=""
[[ $target =~ ^sha256:[0-9a-f]{64}$ ]] || setup_fail "operator image $image not found in microk8s containerd (target digest '$target')"
state_set build_operator_image_s "$((SECONDS - start))"
state_set operator_image "$image"
state_set operator_image_config "$config"
state_set operator_image_target "$target"
echo "operator image $image imported: config $config, target $target ($((SECONDS - start))s)"
