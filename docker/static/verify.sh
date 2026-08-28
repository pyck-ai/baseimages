#!/bin/bash
# Verifies the assembled static image. See docker/verify-lib.sh for the helpers.
# Run via `task verify -- static`.
#
# This is FROM scratch: there is no shell, no coreutils, nothing `docker run
# --entrypoint sh` could exec. check_cmd, check_writable, check_shell_cmd and
# run() all require a shell and therefore cannot work here — only the
# inspect-only helpers (docker inspect / docker export) apply. Do not "fix"
# this by adding a check_cmd call.

. "$(dirname "$0")/../verify-lib.sh"

IMG=$1

# The Dockerfile deliberately uses the numeric uid form for USER: a scratch
# image has no guarantee /etc/passwd is consulted, so the name form could
# silently fail to resolve.
check_user_inspect "$IMG" 1001
check_workdir      "$IMG" /home/nonroot

check_env "$IMG" SSL_CERT_FILE /etc/ssl/certs/ca-certificates.crt
check_env "$IMG" HOME /home/nonroot

check_image_file "$IMG" \
    /etc/passwd \
    /etc/group \
    /etc/ssl/certs/ca-certificates.crt \
    /etc/localtime \
    /usr/share/zoneinfo \
    /tmp \
    /home/nonroot

verify_summary
