#!/usr/bin/env bash
# FIXTURE: must fail shellcheck (SC2086, unquoted variable). Not run anywhere.
target=$1
rm -rf $target
