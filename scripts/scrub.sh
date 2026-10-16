#!/usr/bin/env bash
# Scrubs a snapshot of $LAB_ARTIFACT_DIR into a fresh $LAB_UPLOAD_DIR, which is
# the only tree that is uploaded (design §8: redact, don't drop).
# - Snapshot: regular files and directories only. Symlinks, FIFOs, sockets and
#   devices are dropped (the uploader follows symlinks), so nothing reaches the
#   upload unscanned, and writes to $LAB_ARTIFACT_DIR after the copy don't count.
# - Never collected (design §8), enforced by name for every producer: dropped
#   and counted: accounts.yaml, credentials.yaml, agent.conf, cookies/, ssh/,
#   *.key, *kubeconfig*.
# - Key/value redaction in place with scripts/redact.pl (same rules as the step
#   log replay).
# - Private key material (clear PEM or base64 "-----BEGIN" that isn't a
#   certificate or public key) blocks the full upload; so does a path with a
#   control character. The path is recorded only if it is in a safe charset.
# Writes scrub_hits / upload_blocked / upload_blocked_path / scrub_dropped /
# scrub_withheld to $LAB_STATE_DIR/scrub.env and as step outputs. Exits non-zero
# if it couldn't finish (the workflow then uploads only the minimal artifact).
set -euo pipefail
export LC_ALL=C

ART=${LAB_ARTIFACT_DIR:?}
UP=${LAB_UPLOAD_DIR:?}
STATE=${LAB_STATE_DIR:?}
OUT=${GITHUB_OUTPUT:-/dev/null}
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$ART" "$STATE"
rm -f "$STATE/scrub.env"
rm -rf "$UP"
mkdir -p "$UP"

safe_path() { # prints the path if it is in a safe charset, else a placeholder
	if [[ $1 =~ ^[A-Za-z0-9._/@+-]+$ ]]; then printf '%s' "$1"; else printf '%s' '<unprintable path>'; fi
}

blocked=false blocked_path="" dropped=0 withheld=0
block() { [[ $blocked == true ]] || { blocked=true blocked_path=$(safe_path "$1"); }; }

# 1. Snapshot. find -P never follows links; pruned dirs are not descended.
while IFS= read -r -d '' rec; do
	kind=${rec%% *} rel=${rec#* }
	if [[ $rel == *[[:cntrl:]]* ]]; then
		echo "scrub: path with a control character -> upload blocked"
		block "$rel"
	fi
	case $kind in
	D) mkdir -p "$UP/$rel" ;;
	F)
		mkdir -p "$(dirname "$UP/$rel")"
		cp -P --preserve=mode,timestamps -- "$ART/$rel" "$UP/$rel"
		;;
	W)
		withheld=$((withheld + 1))
		echo "scrub: withheld (never collected): $(safe_path "$rel")"
		;;
	*)
		dropped=$((dropped + 1))
		echo "scrub: dropped non-regular file ($kind): $(safe_path "$rel")"
		;;
	esac
done < <(find -P "$ART" -mindepth 1 \
	\( -type d \( -name cookies -o -name ssh \) -prune -printf 'W %P\0' \) -o \
	\( -type f \( -name accounts.yaml -o -name credentials.yaml -o -name agent.conf -o -name '*.key' -o -name '*kubeconfig*' \) -printf 'W %P\0' \) -o \
	\( -type f -printf 'F %P\0' \) -o \( -type d -printf 'D %P\0' \) -o \( -type l -printf 'L %P\0' \) -o -printf 'O %P\0' | sort -z)
# A file swapped for a link mid-copy is copied as a link (cp -P): drop those too.
while IFS= read -r -d '' x; do
	dropped=$((dropped + 1))
	echo "scrub: dropped non-regular file in the snapshot: $(safe_path "${x#"$UP"/}")"
	rm -f -- "$x"
done < <(find -P "$UP" -mindepth 1 ! -type f ! -type d -print0)

# 2. Scan and redact the snapshot.
hits=0
while IFS= read -r -d '' f; do
	rel=${f#"$UP"/}
	pk=0
	"$here/redact.pl" --pk "$f" || pk=$?
	case $pk in
	0) block "$rel" ;;
	1) ;;
	*) echo "scrub: cannot read $(safe_path "$rel")"; exit 1 ;;
	esac
	n=$("$here/redact.pl" -i "$f")
	[[ $n =~ ^[0-9]+$ ]] || { echo "scrub: redact failed on $(safe_path "$rel")"; exit 1; }
	if ((n > 0)); then
		echo "scrub: $n value(s) redacted in $(safe_path "$rel")"
		hits=$((hits + n))
	fi
done < <(find -P "$UP" -type f -print0 | sort -z)

# Only validated values are written (no file name can add an output line).
[[ $blocked_path =~ ^[A-Za-z0-9._/@+\<\>\ -]*$ ]] || blocked_path='<unprintable path>'
{
	echo "scrub_hits=$hits"
	echo "upload_blocked=$blocked"
	echo "upload_blocked_path=$blocked_path"
	echo "scrub_dropped=$dropped"
	echo "scrub_withheld=$withheld"
} | tee "$STATE/scrub.env" >>"$OUT"
echo "scrub: hits=$hits upload_blocked=$blocked${blocked_path:+ ($blocked_path)} dropped=$dropped withheld=$withheld"
