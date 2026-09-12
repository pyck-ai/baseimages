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

check_file() {
    missing=
    for f in "$@"; do
        [ -e "$f" ] || missing="$missing $f"
    done
    if [ -z "$missing" ]; then ok "present: $*"; else bad "absent:$missing"; fi
}

check_user 1001
check_workdir /home/nonroot
check_env SSL_CERT_FILE /etc/ssl/certs/ca-certificates.crt
check_env HOME /home/nonroot
check_file /etc/passwd /etc/group /etc/ssl/certs/ca-certificates.crt /etc/localtime /usr/share/zoneinfo /tmp /home/nonroot

exit $((fails > 0))
