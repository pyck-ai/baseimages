# syntax=docker/dockerfile:1

ARG ALPINE_VERSION=3
ARG POSTGRESQL_VERSION=17

FROM alpine:${ALPINE_VERSION} AS builder

ARG POSTGRESQL_VERSION

RUN --mount=type=cache,id=apk-cache,target=/var/cache/apk/,sharing=locked\
    apk add --update --no-progress\
        busybox\
        nss_wrapper\
        postgresql${POSTGRESQL_VERSION}\
        postgresql${POSTGRESQL_VERSION}-client

# Collect the minimal runtime closure for the final image: the binaries we
# actually ship, plus every shared library they (transitively — ldd already
# flattens the whole tree, verified against this exact package set) link
# against, discovered mechanically rather than hand-picked, so an
# Alpine/PostgreSQL update that changes the dependency set fails this build
# loudly (missing binary/lib) instead of silently shipping a broken image.
#
# Three directories are copied wholesale rather than traced, because their
# contents are loaded at runtime by path/catalog state rather than linked at
# load time, so they never show up in any binary's ldd output:
#   - /usr/lib/postgresql<major>/  — loadable modules (plpgsql and friends;
#     a fresh cluster's default database registers the plpgsql language even
#     though nothing here exercises it, so it must be present regardless)
#   - /usr/share/postgresql<major>/ — initdb's bootstrap catalog data
#     (postgres.bki, information_schema.sql, ...), required to create a
#     cluster at all
#   - /usr/share/icu/ — ICU's locale data file (icudtNNl.dat), which
#     libicudata.so.76 itself only locates by path at runtime; without it,
#     initdb fails post-bootstrap with "could not open collator for locale
#     'und'" even though the .so linked fine
RUN <<EOF
set -eu
POSTGRESQL_VERSION="${POSTGRESQL_VERSION}"
mkdir -p /rootfs

BINARIES="
  /bin/busybox
  /usr/bin/psql
  /usr/bin/pg_dump
  /usr/bin/pg_dumpall
  /usr/bin/pg_restore
  /usr/bin/pg_isready
  /usr/bin/createdb
  /usr/bin/dropdb
  /usr/libexec/postgresql${POSTGRESQL_VERSION}/postgres
  /usr/libexec/postgresql${POSTGRESQL_VERSION}/initdb
  /usr/libexec/postgresql${POSTGRESQL_VERSION}/pg_ctl
"
for b in $BINARIES; do
    install -D "$b" "/rootfs$b"
done

LIBS=$(for b in $BINARIES; do
    ldd "$b" 2>/dev/null | awk '{print $(NF-1)}' | grep '^/'
done | sort -u)
for l in $LIBS; do
    install -D "$l" "/rootfs$l"
done
# Belt-and-suspenders: the musl dynamic linker itself.
install -D /lib/ld-musl-*.so.1 -t /rootfs/lib/

# nss_wrapper is LD_PRELOAD'd, never a link-time dependency of any binary
# above, so ldd never sees it — copy it explicitly.
install -D /usr/lib/libnss_wrapper.so -t /rootfs/usr/lib/

# Busybox applets docker-entrypoint.sh needs on PATH: a shell to interpret
# its own shebang, plus id/mktemp/rm.
for applet in sh id mktemp rm; do
    ln -sf busybox "/rootfs/bin/$applet"
done

mkdir -p "/rootfs/usr/lib/postgresql${POSTGRESQL_VERSION}" "/rootfs/usr/share/postgresql${POSTGRESQL_VERSION}" /rootfs/usr/share/icu
cp -a "/usr/lib/postgresql${POSTGRESQL_VERSION}/." "/rootfs/usr/lib/postgresql${POSTGRESQL_VERSION}/"
cp -a "/usr/share/postgresql${POSTGRESQL_VERSION}/." "/rootfs/usr/share/postgresql${POSTGRESQL_VERSION}/"
cp -a /usr/share/icu/. /rootfs/usr/share/icu/
EOF

# Numeric owners: this builder stage never creates a "nonroot" user of its
# own — the uid/gid 1001 convention (and /etc/passwd entry to resolve it)
# comes from `static`, which the final stage below builds on.
RUN install -d -o 1001 -g 1001 -m 0700 /rootfs/var/lib/postgresql/data &&\
    install -d -o 1001 -g 1001 -m 1777 /rootfs/run/postgresql &&\
    install -d -o 1001 -g 1001 /rootfs/docker-entrypoint-initdb.d


# `static` already provides everything a hand-rolled `FROM scratch` stage
# would otherwise have to re-derive: /etc/passwd+group (root/nonroot only),
# a writable sticky /tmp, CA certs, timezone data, and the nonroot uid/gid
# 1001 convention itself. This stage only adds what's actually specific to
# postgres: the traced binaries/libs above and its own data directories.
FROM static

ARG POSTGRESQL_VERSION
ENV POSTGRESQL_VERSION=${POSTGRESQL_VERSION}

COPY --from=builder --chown=1001:1001 /rootfs/var/lib/postgresql/data /var/lib/postgresql/data
COPY --from=builder --chown=1001:1001 /rootfs/run/postgresql /run/postgresql
COPY --from=builder --chown=1001:1001 /rootfs/docker-entrypoint-initdb.d /docker-entrypoint-initdb.d
COPY --from=builder /rootfs/bin /bin
COPY --from=builder /rootfs/lib /lib
COPY --from=builder /rootfs/usr/lib /usr/lib
COPY --from=builder /rootfs/usr/bin /usr/bin
COPY --from=builder /rootfs/usr/libexec /usr/libexec
COPY --from=builder /rootfs/usr/share/postgresql${POSTGRESQL_VERSION} /usr/share/postgresql${POSTGRESQL_VERSION}
COPY --from=builder /rootfs/usr/share/icu /usr/share/icu

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

# Alpine's postgresqlNN package installs server binaries (postgres, initdb,
# pg_ctl, ...) under a versioned libexec directory, not directly on PATH —
# only client tools (psql, pg_dump, ...) land in /usr/bin.
ENV PATH="/usr/libexec/postgresql${POSTGRESQL_VERSION}:/usr/bin:/bin"
ENV PGDATA=/var/lib/postgresql/data

EXPOSE 5432
VOLUME ["/var/lib/postgresql/data"]

USER 1001
WORKDIR /var/lib/postgresql
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["postgres"]
