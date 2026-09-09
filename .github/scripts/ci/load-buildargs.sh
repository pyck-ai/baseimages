#!/usr/bin/env bash
# Loads buildargs.conf into $GITHUB_ENV so subsequent steps in the job see
# the build args as plain environment variables.
#
# Backs: build-images.yml, job `build`, step "Load build args".
#
# Expects env:
#   GITHUB_ENV - path to the GitHub Actions step environment file
set -euo pipefail

: "${GITHUB_ENV:?GITHUB_ENV is required}"

grep -v '^#' buildargs.conf | grep -v '^\s*$' >> "$GITHUB_ENV"
