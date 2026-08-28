#!/bin/bash
# Verifies the assembled nginx image. See docker/verify-lib.sh for the helpers.
# Run via `task verify -- nginx`.

. "$(dirname "$0")/../verify-lib.sh"

IMG=$1

# Built on upstream nginxinc/nginx-unprivileged, which runs as `nginx` (uid
# 101) rather than the nonroot (uid 1001) convention used elsewhere in this
# repo — that is the whole point of the unprivileged image, not a bug.
check_user    "$IMG" nginx 101
check_workdir "$IMG" /app

check_file "$IMG" \
    /etc/nginx/nginx.conf \
    /etc/nginx/conf.d/default.conf \
    /etc/nginx/conf.d/otel.conf \
    /app/index.html

check_host "EXPOSE 8080" \
    'port=$(docker inspect -f "{{.Config.ExposedPorts}}" "'"$IMG"'") && case "$port" in *8080/tcp*) exit 0;; *) exit 1;; esac'

check_shell_cmd "$IMG" "shipped nginx.conf parses (nginx -t)" 'nginx -t'

# End-to-end: 8080 rather than 80 only matters if a client can actually reach
# it, so publish a random host port and request it for real.
check_host "serves the placeholder page over HTTP" '
    cid=$(docker run -d -P "'"$IMG"'") || exit 1
    trap "docker rm -f \"$cid\" >/dev/null 2>&1" EXIT
    port=$(docker port "$cid" 8080/tcp | head -1 | cut -d: -f2)
    [ -n "$port" ] || exit 1
    for i in 1 2 3 4 5; do
        code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$port/" 2>/dev/null)
        [ "$code" = "200" ] && exit 0
        sleep 1
    done
    exit 1
'

verify_summary
