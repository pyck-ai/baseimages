#!/bin/sh
# Verifies the assembled agent image, run INSIDE the image as its default
# user (root). Invoked as:
#   docker run --rm --env-file buildargs.conf -e TARGET=agent-alpine|agent-debian \
#     -v $PWD/docker/agent/verify.sh:/verify.sh:ro --entrypoint /bin/sh <ref> /verify.sh

fails=0
ck() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

# node is a symlink to bun, not a real Node.js — pi's launcher is a `#!/usr/bin/env
# node` script. Prove the symlink resolves to bun AND that it executes in
# Node-compat mode (`node --version` is not usable: bun's wrapper rejects it).
node_is_bun() {
    [ "$(readlink -f "$(command -v node)")" = /usr/local/bin/bun ] && node -e "process.exit(0)"
}

writable_bun() {
    su -s /bin/sh -c '
        for d in /bun /bun/bin /bun/install/global; do
            mkdir -p "$d" && touch "$d/.wprobe" && rm -f "$d/.wprobe" || exit 1
        done
    ' nonroot
}

# The install can succeed while the binary stays invisible because /bun/bin is
# not on PATH — assert both halves.
bun_cowsay() {
    su -s /bin/sh -c 'bun add -g --ignore-scripts cowsay && command -v cowsay >/dev/null 2>&1' nonroot
}

ck "runs as root (uid 0)" '[ "$(id -u)" = 0 ]'
ck "WORKDIR is /app" '[ "$(pwd)" = /app ]'
ck "BUN_INSTALL=/bun" '[ "$BUN_INSTALL" = /bun ]'
ck "PATH contains /bun/bin" 'case "$PATH" in *"/bun/bin"*) true ;; *) false ;; esac'

ck "on PATH: bun node pi claude opencode" '
    for c in bun node pi claude opencode; do
        command -v "$c" >/dev/null 2>&1 || exit 1
    done
'

ck "bun --version reports $BUN_VERSION" 'bun --version 2>&1 | grep -qF "$BUN_VERSION"'
ck "claude --version reports $CLAUDE_VERSION" 'claude --version 2>&1 | grep -qF "$CLAUDE_VERSION"'
ck "opencode --version reports $OPENCODE_VERSION" 'opencode --version 2>&1 | grep -qF "$OPENCODE_VERSION"'
ck "pi --version reports $PI_VERSION" 'pi --version 2>&1 | grep -qF "$PI_VERSION"'

ck "node resolves to bun and runs in Node-compat mode" node_is_bun

case "$TARGET" in
    *-alpine)
        # The official Claude binaries are musl-incompatible without this shim.
        ck "LD_PRELOAD=/usr/local/lib/claude_fix.so" '[ "$LD_PRELOAD" = /usr/local/lib/claude_fix.so ]'
        ck "present: /usr/local/lib/claude_fix.so" '[ -e /usr/local/lib/claude_fix.so ]'
        ;;
    *-debian)
        # Debian uses the native glibc build and ships no shim; assert its
        # absence so the two variants cannot silently converge.
        ck "no LD_PRELOAD shim on debian" '[ -z "${LD_PRELOAD:-}" ]'
        ck "claude_fix.so absent on debian" '[ ! -e /usr/local/lib/claude_fix.so ]'
        ;;
esac

ck "writable by uid 1001: /bun /bun/bin /bun/install/global" writable_bun
ck "bun add -g installs a binary that resolves on PATH" bun_cowsay

exit $((fails > 0))
