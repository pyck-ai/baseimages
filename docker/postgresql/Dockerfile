# syntax=docker/dockerfile:1

ARG ALPINE_VERSION=3
ARG POSTGRESQL_VERSION=17

FROM alpine:${ALPINE_VERSION}

ARG POSTGRESQL_VERSION
ENV POSTGRESQL_VERSION=${POSTGRESQL_VERSION}

RUN --mount=type=cache,id=apk-cache,target=/var/cache/apk/,sharing=locked\
    apk add --update --no-progress\
        ca-certificates\
        nss_wrapper\
        postgresql${POSTGRESQL_VERSION}\
        postgresql${POSTGRESQL_VERSION}-client\
        tzdata &&\
    ln -fs /usr/share/zoneinfo/UTC /etc/localtime

# uid/gid 1001 matches this repo's nonroot convention (see docker/base),
# reused here as the postgres runtime user instead of Alpine's package uid,
# so it stays consistent with every other image in this repo.
RUN addgroup -g 1001 nonroot &&\
    adduser -D -u 1001 -G nonroot -s /bin/sh -h /var/lib/postgresql nonroot &&\
    install -d -o nonroot -g nonroot -m 0700 /var/lib/postgresql/data &&\
    install -d -o nonroot -g nonroot -m 1777 /run/postgresql &&\
    install -d -o nonroot -g nonroot /docker-entrypoint-initdb.d

# Alpine's postgresqlNN package installs server binaries (postgres, initdb,
# pg_ctl, ...) under a versioned libexec directory, not directly on PATH —
# only client tools (psql, pg_dump, ...) land in /usr/bin.
ENV PATH="/usr/libexec/postgresql${POSTGRESQL_VERSION}:${PATH}"
ENV PGDATA=/var/lib/postgresql/data

COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 5432
VOLUME ["/var/lib/postgresql/data"]

USER nonroot
WORKDIR /var/lib/postgresql
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["postgres"]
