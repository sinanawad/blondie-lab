#!/usr/bin/env bash
# Derives tests_sha for the juju/juju tests/ checkout (design §4, snap mode):
# the snap's git-commit; else tag v<version>; else the <major.minor> branch head
# (with a warning). Outputs tests_sha=; records tests_sha/tests_source.
set -euo pipefail
export LC_ALL=C
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

OUT=${GITHUB_OUTPUT:-/dev/stdout}
git_commit=$(state_get juju_git_commit)
version=$(state_get juju_version)
sha="" src=""
if [[ -n $git_commit ]]; then
	sha=$git_commit src=git-commit
else
	if sha=$(timeout 60 gh api "repos/juju/juju/commits/v$version" --jq .sha 2>/dev/null) && [[ $sha =~ ^[0-9a-f]{40}$ ]]; then
		src=tag
	else
		track=$(grep -oE '^[0-9]+\.[0-9]+' <<<"$version") || setup_fail "no git-commit and no track in version '$version'"
		sha=$(timeout 60 gh api "repos/juju/juju/commits/$track" --jq .sha 2>/dev/null) || setup_fail "could not resolve tests ref (no git-commit, no tag v$version, branch $track failed)"
		src=branch
		echo "::warning::tests/ taken from the $track branch head ($sha): the snap has no git-commit and tag v$version doesn't exist, so tests may not match the binary"
	fi
fi
[[ $sha =~ ^[0-9a-f]{40}$ ]] || setup_fail "resolved tests_sha '$sha' is not a SHA"
state_set tests_sha "$sha"
state_set tests_source "$src"
echo "tests_sha=$sha" >>"$OUT"
echo "tests: $sha ($src)"
