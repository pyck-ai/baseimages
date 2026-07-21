#!/bin/bash
# Verifies the assembled typescript image. See docker/verify-lib.sh for the helpers.
# Run via `task verify -- typescript`.

. "$(dirname "$0")/../verify-lib.sh"

IMG=$1
VARIANT=$2

check_user    "$IMG" root 0
check_workdir "$IMG" /app

check_env          "$IMG" BUN_INSTALL /bun
check_env_contains "$IMG" PATH /bun/bin

check_cmd     "$IMG" bun
check_version "$IMG" "bun --version" "${BUN_VERSION}"

check_writable_as 65532 "$IMG" /bun /bun/bin /bun/install/global

# The install can succeed while the binary stays invisible because /bun/bin is
# not on PATH — this has broken before, so assert both halves.
check_shell_cmd_as 65532 "$IMG" "bun add -g installs a binary that resolves on PATH" \
    'bun add -g --ignore-scripts cowsay && command -v cowsay >/dev/null 2>&1'

# This image deliberately does not provide a node symlink (agent/all-in-one do);
# assert its absence so the distinction does not silently erode.
check_shell_cmd "$IMG" "node is absent" '! command -v node >/dev/null 2>&1'

verify_summary
