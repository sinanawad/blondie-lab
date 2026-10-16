#!/usr/bin/env bash
# smoke: juju/juju tests/ smoke suite (test_deploy: CharmHub deploy) against the
# lab controller. test_build is skipped (it runs make go-build on the full tree).
set -euo pipefail
exec "$LAB_ROOT/scripts/suite.sh" -s test_build smoke
