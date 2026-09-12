#!/bin/sh
# Verifies the assembled rover image, run INSIDE the image as its default
# user (root). Invoked as:
#   docker run --rm --env-file buildargs.conf -e TARGET=rover-debian \
#     -v $PWD/docker/rover/verify.sh:/verify.sh:ro --entrypoint /bin/sh <ref> /verify.sh

fails=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }

check_user() {
    if [ "$(id -u)" = "$1" ]; then ok "runs as uid $1"; else bad "runs as uid $(id -u), want $1"; fi
}

check_workdir() {
    if [ "$(pwd)" = "$1" ]; then ok "workdir is $1"; else bad "workdir is $(pwd), want $1"; fi
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

check_user 0
check_workdir /app
check_cmd rover
check_version "rover --version" "$ROVER_VERSION"

exit $((fails > 0))
