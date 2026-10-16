#!/usr/bin/env bash
# selftest: no Juju. Proves dispatch -> run -> verdict -> artifact -> download.
set -euo pipefail
echo "selftest iteration ${LAB_ITERATION}/${LAB_REPEAT} on substrate ${LAB_SUBSTRATE}"
printf 'selftest iteration %s ok\n' "$LAB_ITERATION" >"$LAB_ARTIFACT_DIR/selftest-$LAB_ITERATION.txt"
exit 0
