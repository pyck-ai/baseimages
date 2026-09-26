# syntax=docker/dockerfile:1

FROM base AS builder
ARG TARGETPLATFORM TARGETARCH NATS_VERSION
RUN --mount=type=cache,id=downloads,target=/var/cache/downloads,sharing=shared\
    download.sh\
    --var "version=${NATS_VERSION}"\
    --platform-arch "linux/amd64=amd64"\
    --platform-arch "linux/arm64=arm64"\
    --url "https://github.com/nats-io/nats-server/releases/download/v{version}/nats-server-v{version}-linux-{arch}.tar.gz"\
    --checksum-url "https://github.com/nats-io/nats-server/releases/download/v{version}/SHA256SUMS"\
    --install-paths "nats-server-v{version}-linux-{arch}/nats-server"\
    --install-to "/usr/local/bin/"\
    --verify "nats-server --version | grep -qF '{version}'"

# JetStream's default storage location. nats-server is a single statically
# linked Go binary that never forks/chowns/drops privileges — unlike
# postgres or redis, there is no root-then-privilege-drop dance to replicate,
# so the only thing this image needs beyond the binary itself is a writable
# directory for JetStream file storage, pre-owned by the nonroot uid.
RUN install -d -o nonroot -g nonroot /data


# `static` already provides everything a hand-rolled `FROM scratch` stage
# would otherwise have to re-derive: the nonroot uid/gid 1001 convention and
# its /etc/passwd+group entries, a writable sticky /tmp (used by JetStream if
# no explicit store_dir is configured), CA certs, and timezone data. This
# stage only adds what's actually specific to nats: the binary above, its
# JetStream storage directory, and a default config.
FROM static

COPY --from=builder /usr/local/bin/nats-server /usr/local/bin/nats-server
COPY --from=builder --chown=1001:1001 /data /data
COPY nats-server.conf /etc/nats/nats-server.conf

EXPOSE 4222 6222 8222
VOLUME ["/data"]

USER 1001
WORKDIR /home/nonroot
ENTRYPOINT ["/usr/local/bin/nats-server"]
CMD ["--config", "/etc/nats/nats-server.conf"]
