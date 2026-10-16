#!/usr/bin/env bash
# TEMPORARY drill (PR-3 review fixes, removed before merge): a symlinked file
# (to a dummy secret outside the artifact dir), a symlinked directory, a FIFO,
# never-collect names, and two background writers (one in its own session).
# Expect: scrub_dropped=3, scrub_withheld=3, nothing of the dummy secret in the
# upload, "killed N leftover process(es)" (N >= 2: each loop and its sleep), full upload.
set -euo pipefail
out=$(mktemp -d)
echo 'statepassword: drill-outside-secret' >"$out/secret.txt"
mkdir "$out/dir" && echo 'apipassword: drill-outside-dir' >"$out/dir/x.txt"
ln -s "$out/secret.txt" "$LAB_ARTIFACT_DIR/link-file"
ln -s "$out/dir" "$LAB_ARTIFACT_DIR/link-dir"
mkfifo "$LAB_ARTIFACT_DIR/fifo"
mkdir -p "$LAB_ARTIFACT_DIR/jujudata/ssh"
echo dummy >"$LAB_ARTIFACT_DIR/jujudata/accounts.yaml"
echo dummy >"$LAB_ARTIFACT_DIR/jujudata/ssh/juju_id_rsa"
echo dummy >"$LAB_ARTIFACT_DIR/jujudata/client.key"
echo kept >"$LAB_ARTIFACT_DIR/jujudata/kept.txt"
(while :; do date >>"$LAB_ARTIFACT_DIR/late-writer.txt"; sleep 1; done) >/dev/null 2>&1 &
# shellcheck disable=SC2016 # expanded by the inner bash
setsid bash -c 'while :; do date >>"$0/late-setsid.txt"; sleep 1; done' "$LAB_ARTIFACT_DIR" >/dev/null 2>&1 &
sleep 2
echo "drill-links: done"
