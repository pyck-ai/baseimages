#!/usr/bin/env bash
# Extracts the per-target pushed digests from bake's metadata output and
# writes them as a small JSON map for the current component.
#
# Backs: build-images.yml, job `build`, step "Export digests".
#
# Expects env:
#   METADATA     - the JSON metadata produced by `docker buildx bake`
#   COMPONENT    - the current matrix component name, used as the output
#                  file name
#   RUNNER_TEMP  - GitHub Actions runner temp directory
set -euo pipefail

: "${METADATA:?METADATA is required}"
: "${COMPONENT:?COMPONENT is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"

mkdir -p "$RUNNER_TEMP/digests"
printf '%s' "$METADATA" > "$RUNNER_TEMP/meta.json"

# A component builds multiple targets in one bake call, so metadata now
# has one entry per target (unlike the old single-target stage jobs).
# `buildx.build.warnings` is a sibling key of the target entries in bake
# metadata, not a target itself, and must be filtered out.
jq -e 'to_entries
       | map(select(.key != "buildx.build.warnings"
                    and (.value["containerimage.digest"]? != null)))
       | map({key: .key, value: .value["containerimage.digest"]})
       | from_entries
       | if length == 0 then error("no digests in bake metadata") else . end' \
  "$RUNNER_TEMP/meta.json" > "$RUNNER_TEMP/digests/$COMPONENT.json"
