#!/usr/bin/env bash
# TEMPORARY DRILL (PR-4 review): a juju model namespace left behind with no
# model must make the post-suite teardown check score fail.
set -euo pipefail
lab-kubectl create namespace drill-leftover
lab-kubectl label namespace drill-leftover model.juju.is/name=drill-leftover
exec "$LAB_ROOT/scripts/no-models-left.sh" drill-leftover 60
