#!/usr/bin/env bash
# Installs the juju snap from the validated channel (snap mode) and asserts the
# snap tracks exactly that channel. Records version, git-commit and revisions in
# $LAB_STATE_DIR/juju.env and as step outputs. Substrate-independent: the
# substrate setup step records substrate_snap_*. Exit 2 (setup-error) on failure.
set -euo pipefail
export LC_ALL=C
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

channel=${LAB_JUJU_CHANNEL:?}
OUT=${GITHUB_OUTPUT:-/dev/stdout}
[[ $channel =~ ^(latest|[0-9]+\.[0-9]+)/(stable|candidate|beta|edge)$ ]] || setup_fail "juju_channel: unexpected value (workflow bug)"

timeout 300 sudo snap install juju --channel="$channel" || setup_fail "snap install juju --channel=$channel failed"
tracking=$(snap info juju | sed -n 's/^tracking: *//p')
[[ $tracking == "$channel" ]] || setup_fail "juju snap tracks '$tracking', requested '$channel'"
hold_refresh juju
rev=$(snap list juju | awk 'NR == 2 {print $3}')
# Juju's strictly confined snap keeps its data here.
mkdir -p "$HOME/.local/share/juju"

all=$(juju version --all) || setup_fail "juju version --all failed"
printf '%s\n' "$all"
full=$(sed -n 's/^version: *//p' <<<"$all")
git_commit=$(sed -n 's/^git-commit: *//p' <<<"$all")
# 4.0.1-ubuntu-amd64 -> 4.0.1 (os/arch suffix dropped; 4.0-beta4 style kept).
version=$(sed -E 's/-[a-z]+-[a-z0-9]+$//' <<<"$full")
[[ $version =~ ^[0-9]+\.[0-9]+([.-][a-z0-9.]+)?$ ]] || setup_fail "could not parse juju version from '$full'"
[[ -z $git_commit || $git_commit =~ ^[0-9a-f]{40}$ ]] || setup_fail "unexpected git-commit '$git_commit'"
[[ $rev =~ ^[0-9]+$ ]] || setup_fail "could not read the juju snap revision ('$rev')"

state_set juju_version "$version"
state_set juju_git_commit "$git_commit"
state_set juju_snap_revision "$rev"
state_set source snap
{
	echo "juju_version=$version"
	echo "juju_git_commit=$git_commit"
} >>"$OUT"
echo "juju $version (git-commit ${git_commit:-none}, snap rev $rev, tracking $tracking)"
