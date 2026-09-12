#!/bin/sh
# Verifies the assembled rover image, run INSIDE the image as its default
# user (root). Invoked as:
#   docker run --rm --env-file buildargs.conf -e TARGET=rover-debian \
#     -v $PWD/docker/rover/verify.sh:/verify.sh:ro --entrypoint /bin/sh <ref> /verify.sh

fails=0
ck() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

ck "runs as root (uid 0)" '[ "$(id -u)" = 0 ]'
ck "WORKDIR is /app" '[ "$(pwd)" = /app ]'
ck "on PATH: rover" 'command -v rover >/dev/null 2>&1'
ck "rover --version reports $ROVER_VERSION" 'rover --version 2>&1 | grep -qF "$ROVER_VERSION"'

exit $((fails > 0))
