#!/usr/bin/env bash
# TEMPORARY drill (plan PR-3 acceptance, removed before merge): one key/value
# hit and one bare-word line that must not hit.
set -euo pipefail
printf '%s\n' '{"password": "x"}' 'password reset requested' >"$LAB_ARTIFACT_DIR/drill-scrub.txt"
echo "drill-scrub: wrote drill-scrub.txt"
