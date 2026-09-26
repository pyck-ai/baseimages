# Valkey Image

A hardened, unprivileged [Valkey](https://valkey.io/) image — Redis-protocol-compatible, for CI and local development.

## Why Valkey, not Redis

Redis moved off pure open source starting with 7.4 (RSALv2/SSPLv1 dual-licensed), and Redis 8 added an AGPLv3 option. None of those licenses are a comfortable fit for a multi-tenant CI/build platform that hosts this service on behalf of tenants — RSALv2 restricts offering it as a competing managed service, SSPLv1's Section 13 has a broad "publish your whole service's source" trigger, and AGPLv3 has its own network-copyleft obligations. Valkey is the Linux Foundation-backed continuation of pre-7.4 Redis under the original permissive BSD-3-Clause license, backed by AWS/Google Cloud/Oracle/others, and is a drop-in protocol-compatible replacement (same RESP2/RESP3 protocol, commands, RDB format, and `valkey-cli`/`redis-cli` are interchangeable).

## Based on

`scratch`, populated with only `valkey-server`/`valkey-cli` and their actual traced shared-library closure from a fresh `alpine:<alpine_version>` builder stage (the same Alpine major pinned in [`buildargs.conf`](../../buildargs.conf)) — not this repo's own `base` image (which bundles a large, irrelevant CLI toolchain), and not a plain "alpine + `apk add`" image either, which would still ship the package manager, its cache, docs, and the rest of Alpine's default userland. The library closure is discovered mechanically via `ldd` at build time, not hand-picked, so an Alpine/Valkey update that changes the dependency set fails the build loudly instead of silently shipping a broken image. Same pattern as this repo's [`static`](../static/README.md) image.

There is no free, officially-maintained, non-root Valkey/Redis base image to build on the way `nginx` builds on `nginxinc/nginx-unprivileged` — see "Why not an upstream hardened image" below.

Being `scratch`-based, this image has **no shell, no package manager, and no `docker exec` convenience** beyond directly running one of the two shipped binaries.

## Tags

| Tag | Description |
|-----|-------------|
| `valkey:latest` | Most recent build |

Valkey's version tracks whatever Alpine's `valkey` package ships for the pinned `ALPINE_VERSION` — there is no independent `VALKEY_VERSION` build arg, since Alpine packages one Valkey build per Alpine release, not multiple pinnable majors the way it does for PostgreSQL.

## What is included

### Packages

Installed in the (discarded) builder stage only, to let `apk` resolve the real dependency set; only the binaries below and their traced library closure make it into the shipped image.

| Package | Purpose |
|---------|---------|
| `valkey` | Valkey server (`valkey-server`, plus `valkey-check-aof`/`valkey-check-rdb`/`valkey-sentinel` symlinks) |
| `valkey-cli` | Valkey/Redis CLI client (a separate Alpine package from `valkey` itself) |
| `ca-certificates`, `tzdata` | TLS trust store, timezone database (UTC) — files copied into the final image, not the packages |

### Configuration

| File | Destination | Purpose |
|------|-------------|---------|
| `valkey.conf` | `/etc/valkey/valkey.conf` | Listens on all interfaces, Unix socket at `/run/valkey/valkey.sock`, data dir `/data`, logs to stdout. **No authentication configured by default** — same as upstream `valkey/valkey`/`redis` images. Set `requirepass` (or an ACL file) via your own config override before exposing this beyond a trusted network. |

### Ports

| Port | Protocol | Description |
|------|----------|--------------|
| 6379 | TCP | Valkey/Redis wire protocol |

### Default user

Runs as `nonroot` (uid/gid 1001, this repo's standard convention) by default, not Alpine's own `valkey` package uid — kept consistent with every other image here. `WORKDIR` and the persistence directory (`dir`) are both `/data`, declared as a `VOLUME`. `--user 0` can be used for a root shell to debug or install extra tooling.

### Why not an upstream hardened image

Unlike `nginxinc/nginx-unprivileged` for `nginx`:

- The official `docker.io/library/redis` and `docker.io/valkey/valkey` images both default to root and drop privileges via `gosu`/`setpriv` at runtime; neither publishes an official unprivileged variant.
- Chainguard's `redis`/`valkey` images run non-root by default, but all version-pinned tags are paywalled behind an enterprise subscription — only a floating `:latest` is public.
- Bitnami's `redis` image is non-root by default, but Broadcom's August 2025 catalog restructuring removed every free version-pinned tag, leaving only an unpinned `:latest`.

Building on `scratch` with only the traced runtime closure of Alpine's own `valkey`/`valkey-cli` packages gives a free, non-root, genuinely minimal (~11MB) image without depending on a third party that may paywall or discontinue it — smaller than Chainguard's `valkey:latest` (~34.7MB, image inspected directly) and far smaller than `valkey/valkey:8` (~112MB uncompressed).

## Usage

```sh
docker run -p 6379:6379 -v valkeydata:/data ghcr.io/pyck-ai/baseimages/valkey:latest
```

Run `valkey-cli` against it — `ENTRYPOINT` is fixed to `valkey-server` (there is no shell to dispatch on `argv[0]` the way upstream's entrypoint script does), so invoke the client via `docker exec` or an explicit `--entrypoint` override:

```sh
docker exec <container> valkey-cli PING
# or, standalone:
docker run --rm --network container:<container> --entrypoint valkey-cli ghcr.io/pyck-ai/baseimages/valkey:latest -h 127.0.0.1 PING
```

Override the config (e.g. to set `requirepass`):

```dockerfile
FROM ghcr.io/pyck-ai/baseimages/valkey:latest
COPY my-valkey.conf /etc/valkey/valkey.conf
```

## Build

```sh
task build -- valkey
```
