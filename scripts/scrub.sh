#!/usr/bin/env bash
# Scrubs $LAB_ARTIFACT_DIR before upload (design §8: redact, don't drop).
# - Key/value forms only, case-insensitive, YAML and JSON:
#   (password|apipassword|statepassword|oldpassword|admin-secret|macaroons?)["']?\s*[:=]\s*\S+
#   Only the value is rewritten in place to <redacted>; a bare word is no hit.
# - BEGIN ... PRIVATE KEY anywhere blocks the full upload (first file recorded,
#   path only); a minimal artifact (verdict.json + collect.log) is staged in
#   $LAB_MINIMAL_DIR instead.
# Writes scrub_hits / upload_blocked / upload_blocked_path to
# $LAB_STATE_DIR/scrub.env and as step outputs. Exits 0 unless it couldn't scan.
set -euo pipefail
export LC_ALL=C

ART=${LAB_ARTIFACT_DIR:?}
STATE=${LAB_STATE_DIR:?}
OUT=${GITHUB_OUTPUT:-/dev/null}
mkdir -p "$ART" "$STATE"
rm -f "$STATE/scrub.env"

key_re='(?i)((?:password|apipassword|statepassword|oldpassword|admin-secret|macaroons?)["\x27]?\s*[:=]\s*)\S+'
pk_re='-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----'

hits=0 blocked=false blocked_path=""
while IFS= read -r -d '' f; do
	rel=${f#"$ART"/}
	if [[ $blocked == false ]] && grep -aqE -- "$pk_re" "$f"; then
		blocked=true blocked_path=$rel
	fi
	n=$(KEY_RE=$key_re perl -ne 'BEGIN { $re = $ENV{KEY_RE}; $n = 0 } $n += () = /$re/g; END { print $n }' "$f")
	if ((n > 0)); then
		KEY_RE=$key_re perl -i -pe 'my $re = $ENV{KEY_RE}; s/$re/${1}<redacted>/g' "$f"
		echo "scrub: $n value(s) redacted in $rel"
		hits=$((hits + n))
	fi
done < <(find "$ART" -type f -print0 | sort -z)

{
	echo "scrub_hits=$hits"
	echo "upload_blocked=$blocked"
	echo "upload_blocked_path=$blocked_path"
} | tee "$STATE/scrub.env" >>"$OUT"
echo "scrub: hits=$hits upload_blocked=$blocked${blocked_path:+ ($blocked_path)}"
