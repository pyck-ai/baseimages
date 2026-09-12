#!/bin/sh
# Verifies the assembled typescript image, run INSIDE the image as its default
# user (root). Invoked as:
#   docker run --rm --env-file buildargs.conf -e TARGET=typescript-alpine|typescript-debian \
#     -v $PWD/docker/typescript/verify.sh:/verify.sh:ro --entrypoint /bin/sh <ref> /verify.sh

fails=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }

check_user() {
    if [ "$(id -u)" = "$1" ]; then ok "runs as uid $1"; else bad "runs as uid $(id -u), want $1"; fi
}

check_workdir() {
    if [ "$(pwd)" = "$1" ]; then ok "workdir is $1"; else bad "workdir is $(pwd), want $1"; fi
}

check_env() {
    if [ "$(printenv "$1")" = "$2" ]; then ok "$1=$2"; else bad "$1=$(printenv "$1"), want $2"; fi
}

check_cmd() {
    missing=
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
    done
    if [ -z "$missing" ]; then ok "on PATH: $*"; else bad "not on PATH:$missing"; fi
}

# Runs a command and looks for a substring, so a version bump in buildargs.conf
# fails the check instead of silently passing.
check_version() {
    out=$(sh -c "$1" 2>&1)
    case "$out" in
        *"$2"*) ok "$1 reports $2" ;;
        *)      bad "$1 does not report $2: $out" ;;
    esac
}

check_writable_as() {
    u=$1
    shift
    missing=
    for d in "$@"; do
        su "$u" -s /bin/sh -c "mkdir -p '$d/.verify' && rmdir '$d/.verify'" 2>/dev/null || missing="$missing $d"
    done
    if [ -z "$missing" ]; then ok "writable by $u: $*"; else bad "not writable by $u:$missing"; fi
}

check_user 0
check_workdir /app
check_env BUN_INSTALL /bun

if case "$PATH" in *"/bun/bin"*) true ;; *) false ;; esac; then
    ok "PATH contains /bun/bin"
else
    bad "PATH contains /bun/bin"
fi

check_cmd bun
check_version "bun --version" "$BUN_VERSION"

check_writable_as nonroot /bun /bun/bin /bun/install/global

# The install can succeed while the binary stays invisible because /bun/bin is
# not on PATH — assert both halves.
if su -s /bin/sh -c 'bun add -g --ignore-scripts cowsay && command -v cowsay >/dev/null 2>&1' nonroot; then
    ok "bun add -g installs a binary that resolves on PATH"
else
    bad "bun add -g installs a binary that resolves on PATH"
fi

# This image deliberately does not provide a node symlink (agent/all-in-one
# do); assert its absence so the distinction does not silently erode.
if ! command -v node >/dev/null 2>&1; then
    ok "node is absent"
else
    bad "node is absent"
fi

exit $((fails > 0))
