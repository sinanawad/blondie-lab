#!/usr/bin/env bash
# Preflights the tools juju/juju tests/main.sh needs (curl, yq, shellcheck) and
# installs the scenario's DEPS (v1 vocabulary: charmcraft). Any missing or
# failed dependency is exit 2 (setup-error), never 1.
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
for d in $deps; do
	case $d in
	charmcraft)
		timeout 300 sudo snap install charmcraft --classic || setup_fail "DEPS: snap install charmcraft failed"
		charmcraft version || setup_fail "DEPS: charmcraft version failed"
		;;
	*) setup_fail "DEPS: unknown dependency '$d' (v1 vocabulary: charmcraft)" ;;
	esac
done
echo "deps: ok (${deps:-none})"
