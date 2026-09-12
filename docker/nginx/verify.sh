#!/bin/sh
# Verifies the assembled nginx image, run INSIDE the image as its default
# user (nginx, uid 101 — nginxinc/nginx-unprivileged). Invoked as:
#   docker run --rm --env-file buildargs.conf -e TARGET=nginx \
#     -v $PWD/docker/nginx/verify.sh:/verify.sh:ro --entrypoint /bin/sh <ref> /verify.sh
#
# NOTE: the manifest's `exposedPort port=8080` check is dropped here — the
# `http` check below starts nginx and requests it for real, which proves
# strictly more than an EXPOSE metadata check.

fails=0
ck() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

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

ck "runs as nginx (uid 101)" '[ "$(id -u)" = 101 ]'
ck "WORKDIR is /app" '[ "$(pwd)" = /app ]'
ck "present: /etc/nginx/nginx.conf /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/otel.conf /app/index.html" '
    [ -e /etc/nginx/nginx.conf ] &&
    [ -e /etc/nginx/conf.d/default.conf ] &&
    [ -e /etc/nginx/conf.d/otel.conf ] &&
    [ -e /app/index.html ]
'
ck "shipped nginx.conf parses (nginx -t)" 'nginx -t'
ck "serves the placeholder page over HTTP" serves_placeholder_page

exit $((fails > 0))
