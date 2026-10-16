#!/usr/bin/env bash
# Stages the minimal artifact (design §7/§8) used when the full upload is not
# allowed or failed (private key found, scrub didn't succeed, upload error):
# verdict.json and collect.log only. verdict.json comes from $LAB_UPLOAD_DIR
# (where verdict.sh wrote it). collect.log comes from the scrubbed snapshot if
# it is there, else from $LAB_ARTIFACT_DIR, and is always passed through
# redact.pl; it is withheld if it holds key material.
set -euo pipefail
export LC_ALL=C
ART=${LAB_ARTIFACT_DIR:?}
UP=${LAB_UPLOAD_DIR:-$ART}
MIN=${LAB_MINIMAL_DIR:?}
here=$(cd "$(dirname "$0")" && pwd)
rm -rf "$MIN"
mkdir -p "$MIN"
if [[ -f $UP/verdict.json && ! -L $UP/verdict.json ]]; then
	cp "$UP/verdict.json" "$MIN/"
else
	jq -n --arg r "verdict.json missing when staging the minimal artifact" '{schema_version: 1, verdict: "error", reason: $r}' >"$MIN/verdict.json"
fi
src=""
for c in "$UP/collect.log" "$ART/collect.log"; do
	[[ -f $c && ! -L $c ]] && { src=$c; break; }
done
if [[ -n $src ]]; then
	pk=0
	"$here/redact.pl" --pk "$src" || pk=$?
	if ((pk != 1)); then
		echo "collect.log withheld: it contains private key material (or could not be read)" >"$MIN/collect.log"
	else
		"$here/redact.pl" <"$src" >"$MIN/collect.log"
	fi
fi
ls -la "$MIN"
