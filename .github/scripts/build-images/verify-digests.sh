#!/usr/bin/env bash
# Runs verify.sh against the exact digests the build jobs pushed.
#
# Backs: build-images.yml, job `verify`, step "Verify pushed images". Lives
# at .github/scripts/build-images/verify-digests.sh.
#
# Expects env:
#   REGISTRY - registry/repo prefix passed to verify.sh
set -euo pipefail

: "${REGISTRY:?REGISTRY is required}"

set -a
source buildargs.conf
set +a

REGISTRY="$REGISTRY" ./verify.sh --digests digests.json
