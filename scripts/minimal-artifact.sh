#!/usr/bin/env bash
# Stages the minimal artifact (design §7/§8) used when the full upload is not
# allowed (private key found, or scrub didn't succeed): verdict.json and
# collect.log only. collect.log is left out if it holds key material itself.
set -euo pipefail
export LC_ALL=C
ART=${LAB_ARTIFACT_DIR:?}
MIN=${LAB_MINIMAL_DIR:?}
rm -rf "$MIN"
mkdir -p "$MIN"
if [[ -f $ART/verdict.json ]]; then
	cp "$ART/verdict.json" "$MIN/"
else
	jq -n --arg r "verdict.json missing when staging the minimal artifact" '{schema_version: 1, verdict: "error", reason: $r}' >"$MIN/verdict.json"
fi
if [[ -f $ART/collect.log ]]; then
	if grep -aqE -- '-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----' "$ART/collect.log"; then
		echo "collect.log withheld: it contains private key material" >"$MIN/collect.log"
	else
		cp "$ART/collect.log" "$MIN/"
	fi
fi
ls -la "$MIN"
