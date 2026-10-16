#!/usr/bin/env bash
# selftest-hang: never finishes on its own; the per-iteration timeout must cut it.
echo "selftest-hang: iteration ${LAB_ITERATION}, sleeping past TIMEOUT_MIN"
sleep 600
echo "selftest-hang: per-iteration timeout did not fire"
exit 0
