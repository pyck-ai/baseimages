# PostgreSQL Image

A hardened, unprivileged PostgreSQL image for CI and local development.

## Based on

This repo's own [`static`](../static/README.md) image, not a fresh `alpine:<alpine_version>` and not this repo's `base` image (which bundles a large, irrelevant CLI toolchain). `static` already provides everything a from-scratch stage would otherwise have to re-derive — the nonroot uid/gid 1001 convention and its `/etc/passwd`/`/etc/group` entries, a writable sticky `/tmp`, CA certs, and timezone data — so this image only adds what's actually specific to postgres: a builder stage installs Alpine's `postgresqlNN` package (the same Alpine major pinned in [`buildargs.conf`](../../buildargs.conf)) purely to let `apk` resolve the real dependency set, then only the binaries this image ships and their *actual* shared-library closure — traced mechanically via `ldd` at build time, not hand-picked — are copied on top of `static`. An Alpine/PostgreSQL update that changes the dependency set fails this build loudly (missing binary/lib) instead of silently shipping a broken image.

There is no free, officially-maintained, non-root PostgreSQL base image to build on the way `nginx` builds on `nginxinc/nginx-unprivileged` — see the "Why not an upstream hardened image" section below.

Current versions are pinned in [`buildargs.conf`](../../buildargs.conf) (`ALPINE_VERSION`, `POSTGRESQL_VERSION`).

Being built on `static`, this image ships only the busybox applets its own entrypoint needs (`sh`, `id`, `mktemp`, `rm`) — not a general-purpose shell environment.

## Tags

| Tag | Description |
|-----|-------------|
| `postgresql:latest` | Most recent build |
| `postgresql:<major>` | PostgreSQL major version (e.g. `postgresql:17`) |

## What is included

### Packages

Installed in the (discarded) builder stage only, to let `apk` resolve the real dependency set; only the binaries below, their traced library closure, and two data directories they load by path at runtime (`/usr/lib/postgresql<major>/` loadable modules, `/usr/share/postgresql<major>/` initdb bootstrap catalog data, `/usr/share/icu/` ICU locale data) make it into the shipped image. CA certs/timezone come from `static`, not from a package here.

| Package | Purpose |
|---------|---------|
| `postgresql<major>` | PostgreSQL server (Alpine's versioned package, e.g. `postgresql17`) |
| `postgresql<major>-client` | `psql`, `pg_dump`, `pg_restore`, etc. |
| `nss_wrapper` | Lets the server run under an arbitrary uid with no `/etc/passwd` entry (e.g. Kubernetes `runAsUser: <random>`) — the same technique Bitnami and Red Hat's UBI Postgres images use |
| `busybox` | Only `sh`/`id`/`mktemp`/`rm` are kept — the minimum `docker-entrypoint.sh` itself needs |

`POSTGRESQL_VERSION` selects the Alpine package major (`postgresql${POSTGRESQL_VERSION}`), not an upstream PostgreSQL point release — Alpine packages one build per major version, so there is no independent patch-level pin. Bumping it to track a new PostgreSQL major requires that Alpine's repos carry the corresponding `postgresql<major>` package first; this is a manual `buildargs.conf` edit, not Renovate-managed.

### Entrypoint

`docker-entrypoint.sh` is a simplified reimplementation of the official `docker.io/library/postgres` image's first-boot contract, adapted for always-non-root execution (no `gosu`/privilege-drop is needed, since the image's default uid already owns `$PGDATA`):

- On first start (`$PGDATA` empty), runs `initdb`, then executes every `*.sh`/`*.sql` file in `/docker-entrypoint-initdb.d/` (mount your own init scripts there).
- `POSTGRES_USER` (default `postgres`), `POSTGRES_PASSWORD` (required unless `POSTGRES_HOST_AUTH_METHOD=trust`), `POSTGRES_DB` (default: same as `POSTGRES_USER`).
- Listens on all interfaces (`listen_addresses = '*'`) with `scram-sha-256` host auth by default — set `POSTGRES_HOST_AUTH_METHOD=trust` only for throwaway/local use.

This is a subset of the official image's behavior (no `POSTGRES_INITDB_ARGS`, no replication helpers), not a byte-for-byte port.

### Ports

| Port | Protocol | Description |
|------|----------|--------------|
| 5432 | TCP | PostgreSQL wire protocol |

### Environment

| Variable | Value | Description |
|----------|-------|--------------|
| `PGDATA` | `/var/lib/postgresql/data` | Data directory (also the declared `VOLUME`) |
| `PATH` | includes `/usr/libexec/postgresql<major>` | Alpine ships server binaries (`postgres`, `initdb`, `pg_ctl`) under a versioned libexec dir, not directly on `PATH`; client tools (`psql`, ...) are already on `PATH` via `/usr/bin` |

### Default user

Runs as `nonroot` (uid/gid 1001, this repo's standard convention) by default, not Alpine's own `postgres` package uid — kept consistent with every other image here. `WORKDIR` is `/var/lib/postgresql`. `--user 0` can be used for a root shell to install extensions or debug; `nss_wrapper` also allows running under any other arbitrary uid (e.g. a Kubernetes-assigned random uid) without needing an `/etc/passwd` entry for it — the data directory (owned `nonroot:nonroot`) must still be writable by whichever uid runs the container, so `runAsGroup: 1001` or an equivalent `fsGroup` is required in that case.

### Why not an upstream hardened image

Unlike `nginxinc/nginx-unprivileged` for `nginx`, there is no free, non-root-by-default, version-pinned PostgreSQL base image to build on:

- The official `docker.io/library/postgres` image (Debian and Alpine variants) always starts as root and drops to the `postgres` user via `gosu` at runtime; there is no official unprivileged variant.
- Chainguard's `postgres` image also defaults to root (`gosu`-based), and all version-pinned tags are paywalled behind an enterprise subscription — only a floating `:latest` is public.
- Bitnami's `postgresql` image does run non-root by default, but Broadcom's August 2025 catalog restructuring removed all free version-pinned tags; only an unpinned `:latest` remains on the free tier.
- Red Hat's UBI-based `postgresql` images are non-root, but are RPM-based and 350–450MB+ uncompressed — a poor fit for this repo's Alpine-first, minimal-footprint convention.

Building on `static` with only the traced runtime closure of Alpine's own `postgresqlNN` package gives a free, version-pinned, non-root, genuinely minimal (~39MB) image without depending on a third party that may paywall or discontinue it — well under the official `postgres:alpine` image's footprint, and far below Red Hat UBI's 350–450MB+.

## Usage

```sh
docker run -p 5432:5432 \
  -e POSTGRES_PASSWORD=changeme \
  -v pgdata:/var/lib/postgresql/data \
  ghcr.io/pyck-ai/baseimages/postgresql:latest
```

Run init scripts on first boot:

```dockerfile
FROM ghcr.io/pyck-ai/baseimages/postgresql:latest
COPY init.sql /docker-entrypoint-initdb.d/
```

## Build

```sh
task build -- postgresql
```
