#!/usr/bin/env bash
# TEMPORARY drill (PR-3 review fixes, removed before merge): a fake private key
# (assembled at runtime) in a file and on stdout. The full upload must be
# blocked and the iteration log withheld from the step log.
set -euo pipefail
{
	printf -- '-----BEGIN %s PRIVATE KEY-----\n' OPENSSH
	echo "not-a-real-key"
	printf -- '-----END %s PRIVATE KEY-----\n' OPENSSH
} >"$LAB_ARTIFACT_DIR/drill-fake-key.txt"
cat "$LAB_ARTIFACT_DIR/drill-fake-key.txt"
echo "drill-pk: wrote drill-fake-key.txt"
