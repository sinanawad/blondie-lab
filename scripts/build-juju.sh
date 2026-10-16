#!/usr/bin/env bash
# Build mode (design §3): builds juju from the trusted ref_sha checkout in
# $LAB_SRC with `make go-install` (static musl/dqlite on 4.0/4.1), and on k8s
# also the operator image, imported into MicroK8s (build-operator-image.sh).
# Puts
# $(go env GOPATH)/bin first on PATH for the later steps ($GITHUB_PATH).
# Records juju_version, juju_git_commit, source=build, build_s (and on k8s
# operator_image*) in $LAB_STATE_DIR/juju.env. Full make output goes to
# $LAB_ARTIFACT_DIR/collect/build.log (scrubbed before upload); df -h before
# and after the build to collect/df-{before,after}-build.txt.
# Exit 2 (setup-error) on any failure, including the flavour gate.
set -euo pipefail
export LC_ALL=C
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/lib.sh
. "$here/lib.sh"

src=${LAB_SRC:?}
ref_sha=${LAB_REF_SHA:?}
substrate=${LAB_SUBSTRATE:?}
[[ $ref_sha =~ ^[0-9a-f]{40}$ ]] || setup_fail "LAB_REF_SHA: unexpected value (workflow bug)"
C="${LAB_ARTIFACT_DIR:?}/collect"
mkdir -p "$C"
log="$C/build.log"
cd "$src"

# The checkout must be exactly the trusted SHA.
head=$(git rev-parse HEAD) || setup_fail "juju source: git rev-parse HEAD failed"
[[ $head == "$ref_sha" ]] || setup_fail "juju source checkout is $head, trusted ref_sha is $ref_sha"
# Flavour gate (design §3), again on the checked-out tree (ref-trust.sh read
# the same files through the API).
if grep -qE '^jujud-snap-build:' Makefile; then
	setup_fail "controller-snap builds not supported in v1 (Makefile has jujud-snap-build)"
fi
grep -qE '^const version = "4\.' core/version/version.go || setup_fail "core/version/version.go is not 4.x at $ref_sha"
# Never an official build: the agent must upload as <x.y.z>.1 (bootstrap check).
[[ -z ${JUJU_BUILD_NUMBER:-} ]] || setup_fail "JUJU_BUILD_NUMBER must be unset in build mode"
command -v go >/dev/null || setup_fail "go not on PATH (setup-go failed?)"
gobin="$(go env GOPATH)/bin"

df -h >"$C/df-before-build.txt" 2>&1 || true
start=$SECONDS
echo "make go-install (output: collect/build.log)"
if ! make go-install >"$log" 2>&1; then
	tail -n 40 "$log" | "$here/redact.pl" || true
	setup_fail "make go-install failed at $ref_sha (see collect/build.log in the artifact)"
fi
go_install_s=$((SECONDS - start))
state_set build_go_install_s "$go_install_s"
echo "make go-install: ${go_install_s}s"

[[ -x $gobin/juju ]] || setup_fail "make go-install produced no $gobin/juju"
all=$("$gobin/juju" version --all) || setup_fail "$gobin/juju version --all failed"
printf '%s\n' "$all"
full=$(sed -n 's/^version: *//p' <<<"$all")
git_commit=$(sed -n 's/^git-commit: *//p' <<<"$all")
version=$(sed -E 's/-[a-z]+-[a-z0-9]+$//' <<<"$full")
[[ $version =~ ^4\.[0-9]+([.-][a-z0-9.]+)?$ ]] || setup_fail "could not parse a 4.x juju version from '$full'"
[[ $git_commit == "$ref_sha" ]] || setup_fail "built juju reports git-commit '${git_commit:-none}', expected $ref_sha"
if [[ $substrate == k8s ]]; then
	LAB_BUILT_VERSION=$version "$here/build-operator-image.sh"
fi
state_set build_s "$((SECONDS - start))"
df -h >"$C/df-after-build.txt" 2>&1 || true
gomod=$(go env GOMODCACHE)
mb=$(du -sm "$gomod" 2>/dev/null | awk '{print $1}') || mb=""
if [[ $mb =~ ^[0-9]+$ ]]; then state_set gomodcache_mb "$mb"; fi
state_set juju_version "$version"
state_set juju_git_commit "$git_commit"
state_set source build
{
	echo "juju_version=$version"
	echo "juju_git_commit=$git_commit"
} >>"${GITHUB_OUTPUT:-/dev/stdout}"
# Later steps find the built juju first (bootstrap.sh asserts it).
echo "$gobin" >>"${GITHUB_PATH:-/dev/null}"
echo "built juju $version at $ref_sha in $((SECONDS - start))s; $gobin first on PATH for later steps"
