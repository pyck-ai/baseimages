#!/bin/sh
# Verifies the assembled typescript image, run INSIDE the image as its default
# user (root). Invoked as:
#   docker run --rm --env-file buildargs.conf -e TARGET=typescript-alpine|typescript-debian \
#     -v $PWD/docker/typescript/verify.sh:/verify.sh:ro --entrypoint /bin/sh <ref> /verify.sh

fails=0
ck() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

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
ck "on PATH: bun" 'command -v bun >/dev/null 2>&1'
ck "bun --version reports $BUN_VERSION" 'bun --version 2>&1 | grep -qF "$BUN_VERSION"'
ck "writable by uid 1001: /bun /bun/bin /bun/install/global" writable_bun
ck "bun add -g installs a binary that resolves on PATH" bun_cowsay

# This image deliberately does not provide a node symlink (agent/all-in-one
# do); assert its absence so the distinction does not silently erode.
ck "node is absent" '! command -v node >/dev/null 2>&1'

exit $((fails > 0))
