#!/usr/bin/env bash
# smoke: juju/juju tests/ smoke suite (test_deploy: CharmHub deploy of 3 charms
# to idle) against the lab controller. test_build is skipped (it runs make
# go-build on the full tree). The suite's own teardown falls back to
# `destroy-model ... || true` on a reused controller, so this checks it: after
# a pass, every non-controller model must be gone within 10 min, else fail.
set -euo pipefail
rc=0
"$LAB_ROOT/scripts/suite.sh" -s test_build smoke || rc=$?
((rc == 0)) || exit "$rc"
deadline=$((SECONDS + 600))
while :; do
	left=$(timeout 60 juju models -c "$LAB_CONTROLLER" --format=json |
		jq -r '.models // [] | .[] | select(((."is-controller") | tostring) != "true" and ."short-name" != "controller") | ."short-name"') ||
		left="(juju models failed)"
	[[ -z $left ]] && { echo "smoke: teardown ok, no models left"; exit 0; }
	((SECONDS < deadline)) || break
	sleep 10
done
echo "smoke: suite passed but its teardown left models after 600s: ${left//$'\n'/ }"
exit 1
