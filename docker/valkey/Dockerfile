# syntax=docker/dockerfile:1

ARG ALPINE_VERSION=3

FROM alpine:${ALPINE_VERSION} AS builder

RUN --mount=type=cache,id=apk-cache,target=/var/cache/apk/,sharing=locked\
    apk add --update --no-progress\
        ca-certificates\
        tzdata\
        valkey\
        valkey-cli &&\
    ln -fs /usr/share/zoneinfo/UTC /etc/localtime

# uid/gid 1001 matches this repo's nonroot convention (see docker/base).
RUN addgroup -g 1001 nonroot &&\
    adduser -D -u 1001 -G nonroot -s /bin/sh -h /data nonroot &&\
    grep -E '^(root|nonroot):' /etc/passwd > /etc/passwd.min &&\
    grep -E '^(root|nonroot):' /etc/group  > /etc/group.min

# Collect the minimal runtime closure for the final scratch image: the
# binaries we actually ship, plus every shared library they link against —
# discovered mechanically via ldd rather than hand-picked, so an
# Alpine/Valkey update that changes the dependency set fails this build
# loudly (missing binary/lib) instead of silently shipping a broken image.
RUN <<EOF
set -eu
mkdir -p /rootfs

BINARIES="/usr/bin/valkey-server /usr/bin/valkey-cli"
for b in $BINARIES; do
    install -D "$b" "/rootfs$b"
done

# Symlinked aliases upstream also ships, pointing at the copied valkey-server.
for alias in valkey-check-aof valkey-check-rdb valkey-sentinel; do
    ln -s valkey-server "/rootfs/usr/bin/$alias"
done

LIBS=$(for b in $BINARIES; do
    ldd "$b" 2>/dev/null | awk '{print $(NF-1)}' | grep '^/'
done | sort -u)
for l in $LIBS; do
    install -D "$l" "/rootfs$l"
done
# Belt-and-suspenders: the musl dynamic linker itself, in case ldd's output
# format ever changes in a way the loop above stops catching.
install -D /lib/ld-musl-*.so.1 -t /rootfs/lib/
EOF

RUN install -d -o nonroot -g nonroot -m 1777 /rootfs/data &&\
    install -d -o nonroot -g nonroot -m 1777 /rootfs/run/valkey


FROM scratch

# Minimal user/group database (root + nonroot only)
COPY --from=builder /etc/passwd.min /etc/passwd
COPY --from=builder /etc/group.min  /etc/group

COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /usr/share/zoneinfo /usr/share/zoneinfo
COPY --from=builder /etc/localtime /etc/localtime

COPY --from=builder --chown=1001:1001 /rootfs/data /data
COPY --from=builder --chown=1001:1001 /rootfs/run/valkey /run/valkey
COPY --from=builder /rootfs/lib /lib
COPY --from=builder /rootfs/usr/lib /usr/lib
COPY --from=builder /rootfs/usr/bin /usr/bin

COPY valkey.conf /etc/valkey/valkey.conf

EXPOSE 6379
VOLUME ["/data"]

# Numeric because a scratch image has no guarantee /etc/passwd is consulted
# to resolve a name — same reasoning as docker/static.
USER 1001
WORKDIR /data
ENTRYPOINT ["valkey-server"]
CMD ["/etc/valkey/valkey.conf"]
