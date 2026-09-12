#!/bin/sh
# Verifies the assembled static image. This is FROM scratch: no shell exists
# in the shipped image, so this script has to be run against a derived image
# that adds one, e.g.:
#   printf 'FROM %s\nCOPY --from=busybox:musl /bin /bin\n' <static-ref> | \
#     docker build -f - -t static-verify .
#   docker run --rm --env-file buildargs.conf -e TARGET=static \
#     -v $PWD/docker/static/verify.sh:/verify.sh:ro --entrypoint /bin/sh static-verify /verify.sh
#
# The Dockerfile deliberately uses the numeric uid form for USER: a scratch
# image has no guarantee /etc/passwd is consulted, so the name form could
# silently fail to resolve. The uid check here (id -u) only proves the
# derived image's shell process starts as 1001, which is what actually
# matters for consumers.

fails=0
ck() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

ck "runs as uid 1001" '[ "$(id -u)" = 1001 ]'
ck "WORKDIR is /home/nonroot" '[ "$(pwd)" = /home/nonroot ]'
ck "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt" '[ "$SSL_CERT_FILE" = /etc/ssl/certs/ca-certificates.crt ]'
ck "HOME=/home/nonroot" '[ "$HOME" = /home/nonroot ]'
ck "present: /etc/passwd /etc/group /etc/ssl/certs/ca-certificates.crt /etc/localtime /usr/share/zoneinfo /tmp /home/nonroot" '
    [ -e /etc/passwd ] &&
    [ -e /etc/group ] &&
    [ -e /etc/ssl/certs/ca-certificates.crt ] &&
    [ -e /etc/localtime ] &&
    [ -e /usr/share/zoneinfo ] &&
    [ -e /tmp ] &&
    [ -e /home/nonroot ]
'

exit $((fails > 0))
