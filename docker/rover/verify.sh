#!/bin/bash
# Verifies the assembled rover image. See docker/verify-lib.sh for the helpers.
# Run via `task verify -- rover`.

. "$(dirname "$0")/../verify-lib.sh"

IMG=$1
VARIANT=$2

check_user    "$IMG" root 0
check_workdir "$IMG" /app

check_cmd     "$IMG" rover
check_version "$IMG" "rover --version" "${ROVER_VERSION}"

verify_summary
