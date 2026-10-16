#!/usr/bin/env bash
# TEMPORARY drill (PR-3 review fixes, removed before merge): one line per
# key/value form (5 hits in the file), bare words that must not hit, and one
# key/value line on stdout (1 hit in iteration-1.log, redacted in the step log).
set -euo pipefail
printf '%s\n' '{"password": "x"}' '{\"password\":\"hunter2\",\"n\":1}' 'password: "two words" tail' \
	'macaroon-abc123=eyJhYmMi; Path=/' 'admin-secret: |' '    block-line' 'next: 1' \
	'password reset requested' 'juju add-model --password-stdin' >"$LAB_ARTIFACT_DIR/drill-scrub.txt"
echo "statepassword: drill-stdout-value"
echo "drill-scrub: wrote drill-scrub.txt"
