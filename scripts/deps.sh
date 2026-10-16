#!/usr/bin/env bash
# Preflights the tools juju/juju tests/main.sh needs (curl, yq, shellcheck) and
# installs the scenario's DEPS from scripts/deps-vocab.txt (pinned channel;
# channel and revision recorded as dep_<name>=<channel> <revision>). Any
# missing or failed dependency is exit 2 (setup-error), never 1.
set -euo pipefail
export LC_ALL=C
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

deps=${LAB_DEPS:-}
[[ $deps =~ ^[a-z0-9\ -]*$ ]] || setup_fail "DEPS: unexpected value (workflow bug)"
if [[ ${LAB_NEEDS_TESTS:-0} == 1 ]]; then
	missing=""
	for t in curl yq shellcheck; do command -v "$t" >/dev/null || missing+=" $t"; done
	[[ -z $missing ]] || setup_fail "preflight: missing tools for tests/main.sh:$missing"
	echo "preflight: curl yq shellcheck present"
fi
vocab="$(dirname "$0")/deps-vocab.txt"
for d in $deps; do
	channel=$(awk -v d="$d" '$1 == d { print $2 }' "$vocab")
	[[ -n $channel ]] || setup_fail "DEPS: unknown dependency '$d' (vocabulary: scripts/deps-vocab.txt)"
	case $d in
	charmcraft)
		timeout 300 sudo snap install charmcraft --classic --channel="$channel" || setup_fail "DEPS: snap install charmcraft --channel=$channel failed"
		charmcraft version || setup_fail "DEPS: charmcraft version failed"
		;;
	*) setup_fail "DEPS: '$d' is in the vocabulary but deps.sh can't install it" ;;
	esac
	rev=$(snap list "$d" | awk 'NR == 2 { print $3 }')
	[[ $rev =~ ^[0-9]+$ ]] || setup_fail "DEPS: no snap revision for $d"
	state_set "dep_$d" "$channel $rev"
done
echo "deps: ok (${deps:-none})"
