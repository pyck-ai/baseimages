#!/bin/bash
# Verifies the assembled agent image. See docker/verify-lib.sh for the helpers.
# Run via `task verify -- agent`.

. "$(dirname "$0")/../verify-lib.sh"

IMG=$1
VARIANT=$2

check_user    "$IMG" root 0
check_workdir "$IMG" /app

check_env          "$IMG" BUN_INSTALL /bun
check_env_contains "$IMG" PATH /bun/bin

check_cmd "$IMG" bun node pi claude opencode

check_version "$IMG" "bun --version"      "${BUN_VERSION}"
check_version "$IMG" "claude --version"   "${CLAUDE_VERSION}"
check_version "$IMG" "opencode --version" "${OPENCODE_VERSION}"
check_version "$IMG" "pi --version"       "${PI_VERSION}"

# node is a symlink to bun, not a real Node.js — pi's launcher is a `#!/usr/bin/env
# node` script. Both node and pi were silently missing from this image before, so
# prove the symlink resolves to bun AND that it executes in Node-compat mode.
# `node --version` is not usable here: bun's wrapper rejects it as a repl.
check_shell_cmd "$IMG" "node resolves to bun and runs in Node-compat mode" \
    '[ "$(readlink -f "$(command -v node)")" = /usr/local/bin/bun ] && node -e "process.exit(0)"'

if [ "$VARIANT" = "alpine" ]; then
    # The official Claude binaries are musl-incompatible without this shim.
    check_env  "$IMG" LD_PRELOAD /usr/local/lib/claude_fix.so
    check_file "$IMG" /usr/local/lib/claude_fix.so
else
    # Debian uses the native glibc build and ships no shim; assert its absence so
    # the two variants cannot silently converge.
    check_shell_cmd "$IMG" "no LD_PRELOAD shim on debian" '[ -z "${LD_PRELOAD:-}" ]'
    check_shell_cmd "$IMG" "claude_fix.so absent on debian" '[ ! -e /usr/local/lib/claude_fix.so ]'
fi

check_writable_as 65532 "$IMG" /bun /bun/bin /bun/install/global

check_shell_cmd_as 65532 "$IMG" "bun add -g installs a binary that resolves on PATH" \
    'bun add -g --ignore-scripts cowsay && command -v cowsay >/dev/null 2>&1'

verify_summary
