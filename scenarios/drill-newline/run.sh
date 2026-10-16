#!/usr/bin/env bash
# TEMPORARY drill (PR-3 review fixes, removed before merge): a file whose name
# contains a newline followed by "upload_blocked=false". Expect upload_blocked
# true, upload_blocked_path "<unprintable path>", minimal artifact.
set -euo pipefail
echo harmless >"$LAB_ARTIFACT_DIR/a"$'\n'"upload_blocked=false"
echo "drill-newline: done"
