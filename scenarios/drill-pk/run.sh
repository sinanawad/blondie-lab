#!/usr/bin/env bash
# TEMPORARY drill (plan PR-3 acceptance, removed before merge): fake private key
# header (assembled at runtime, never echoed) must block the full upload.
set -euo pipefail
{
	printf -- '-----BEGIN %s PRIVATE KEY-----\n' OPENSSH
	echo "not-a-real-key"
	printf -- '-----END %s PRIVATE KEY-----\n' OPENSSH
} >"$LAB_ARTIFACT_DIR/drill-fake-key.txt"
echo "drill-pk: wrote drill-fake-key.txt"
