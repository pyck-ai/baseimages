# syntax=docker/dockerfile:1

ARG ALPINE_VERSION=3

FROM alpine:${ALPINE_VERSION} AS builder

RUN --mount=type=cache,id=apk-cache,target=/var/cache/apk/,sharing=locked\
    apk add --update --no-progress\
        valkey\
        valkey-cli

# Collect the minimal runtime closure for the final image: the binaries we
# actually ship, plus every shared library they link against — discovered
# mechanically via ldd rather than hand-picked, so an Alpine/Valkey update
# that changes the dependency set fails this build loudly (missing
# binary/lib) instead of silently shipping a broken image.
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

# Numeric owners: this builder stage never creates a "nonroot" user of its
# own — the uid/gid 1001 convention (and /etc/passwd entry to resolve it)
# comes from `static`, which the final stage below builds on.
RUN install -d -o 1001 -g 1001 -m 1777 /rootfs/data &&\
    install -d -o 1001 -g 1001 -m 1777 /rootfs/run/valkey


# `static` already provides everything a hand-rolled `FROM scratch` stage
# would otherwise have to re-derive: /etc/passwd+group (root/nonroot only),
# a writable sticky /tmp, CA certs, timezone data, and the nonroot uid/gid
# 1001 convention itself. This stage only adds what's actually specific to
# valkey: the traced binaries/libs above and its own data directories.
FROM static

COPY --from=builder --chown=1001:1001 /rootfs/data /data
COPY --from=builder --chown=1001:1001 /rootfs/run/valkey /run/valkey
COPY --from=builder /rootfs/lib /lib
COPY --from=builder /rootfs/usr/lib /usr/lib
COPY --from=builder /rootfs/usr/bin /usr/bin

COPY valkey.conf /etc/valkey/valkey.conf

EXPOSE 6379
VOLUME ["/data"]

USER 1001
WORKDIR /data
ENTRYPOINT ["valkey-server"]
CMD ["/etc/valkey/valkey.conf"]
