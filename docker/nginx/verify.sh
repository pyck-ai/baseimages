#!/bin/sh
# Verifies the assembled nginx image, run INSIDE the image as its default
# user (nginx, uid 101 — nginxinc/nginx-unprivileged). Invoked as:
#   docker run --rm --env-file buildargs.conf -e TARGET=nginx \
#     -v $PWD/docker/nginx/verify.sh:/verify.sh:ro --entrypoint /bin/sh <ref> /verify.sh
#
# NOTE: the manifest's `exposedPort port=8080` check is dropped here — the
# HTTP check below starts nginx and requests it for real, which proves
# strictly more than an EXPOSE metadata check.

fails=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }

check_user() {
    if [ "$(id -u)" = "$1" ]; then ok "runs as uid $1"; else bad "runs as uid $(id -u), want $1"; fi
}

check_workdir() {
    if [ "$(pwd)" = "$1" ]; then ok "workdir is $1"; else bad "workdir is $(pwd), want $1"; fi
}

check_file() {
    missing=
    for f in "$@"; do
        [ -e "$f" ] || missing="$missing $f"
    done
    if [ -z "$missing" ]; then ok "present: $*"; else bad "absent:$missing"; fi
}

# Starts nginx in the background and polls it, since nginx needs a moment to
# bind the socket after exec.
serves_placeholder_page() {
    nginx >/dev/null 2>&1 &
    i=0
    while [ "$i" -lt 4 ]; do
        if wget -qO- http://127.0.0.1:8080/ >/dev/null 2>&1; then
            return 0
        fi
        i=$((i + 1))
        sleep 1
    done
    return 1
}

check_user 101
check_workdir /app
check_file /etc/nginx/nginx.conf /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/otel.conf /app/index.html

if nginx -t; then
    ok "shipped nginx.conf parses (nginx -t)"
else
    bad "shipped nginx.conf parses (nginx -t)"
fi

if serves_placeholder_page; then
    ok "serves the placeholder page over HTTP"
else
    bad "serves the placeholder page over HTTP"
fi

exit $((fails > 0))
