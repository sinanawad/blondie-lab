#!/usr/bin/env bash
# Derives tests_sha for the juju/juju tests/ (design §4):
#   explicit tests_ref (trusted by ref-trust.sh): LAB_TESTS_REF_SHA, tests_source explicit;
#   build mode: ref_sha (tests come from the build checkout), tests_source ref;
#   snap mode: the snap's git-commit; else tag v<version>; else the
#   <major.minor> branch head (with a warning).
# Outputs tests_sha= and tests_checkout= (1: sparse checkout of tests/ needed,
# 0: use $LAB_SRC/tests); records tests_sha/tests_source.
set -euo pipefail
export LC_ALL=C
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

OUT=${GITHUB_OUTPUT:-/dev/stdout}
git_commit=$(state_get juju_git_commit)
version=$(state_get juju_version)
sha="" src="" checkout=1
if [[ -n ${LAB_TESTS_REF_SHA:-} ]]; then
	sha=$LAB_TESTS_REF_SHA src=explicit
elif [[ ${LAB_JUJU_SOURCE:-snap} == build ]]; then
	sha=${LAB_REF_SHA:-} src=ref checkout=0
elif [[ -n $git_commit ]]; then
	sha=$git_commit src=git-commit
else
	[[ $version =~ ^[0-9]+\.[0-9]+[.0-9A-Za-z-]*$ ]] || setup_fail "no git-commit and an unusable version '$version'"
	# Only HTTP 404 means "no such tag"; any other API failure (rate limit, 5xx,
	# timeout) fails closed instead of silently switching the tests tree.
	err=$(mktemp)
	if sha=$(timeout 60 gh api "repos/juju/juju/commits/v$version" --jq .sha 2>"$err") && [[ $sha =~ ^[0-9a-f]{40}$ ]]; then
		src=tag
	elif grep -q 'HTTP 404' "$err"; then
		track=$(grep -oE '^[0-9]+\.[0-9]+' <<<"$version")
		sha=$(timeout 60 gh api "repos/juju/juju/commits/$track" --jq .sha 2>/dev/null) || setup_fail "could not resolve tests ref (API error on branch $track)"
		src=branch
		echo "::warning::tests/ taken from the $track branch head ($sha): the snap has no git-commit and tag v$version doesn't exist, so tests may not match the binary"
	else
		setup_fail "could not resolve tests ref (API error on tag v$version)"
	fi
fi
[[ $sha =~ ^[0-9a-f]{40}$ ]] || setup_fail "resolved tests_sha '$sha' is not a SHA"
state_set tests_sha "$sha"
state_set tests_source "$src"
{
	echo "tests_sha=$sha"
	echo "tests_checkout=$checkout"
} >>"$OUT"
echo "tests: $sha ($src)"
