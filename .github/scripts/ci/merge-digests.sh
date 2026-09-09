#!/usr/bin/env bash
# Merges all downloaded per-component digest JSON files into a single
# digests.json in the working directory. Used identically by both the
# `verify` and `publish` jobs, so it must not assume or reference either
# job's name.
#
# Backs: build-images.yml, jobs `verify` and `publish`, step "Merge digests".
#
# Expects: the `digests/*.json` files already downloaded into the working
# directory (via actions/download-artifact with merge-multiple: true).
set -euo pipefail

jq -s 'add' digests/*.json > digests.json
