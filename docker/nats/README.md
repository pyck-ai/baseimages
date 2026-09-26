# NATS Image

A hardened, unprivileged [NATS](https://nats.io/) server image for CI and local development.

## Based on

This repo's own [`static`](../static/README.md) image, not this repo's `base` image (which bundles a large, irrelevant CLI toolchain) and not the official `nats`/`nats:alpine` images — see "Why not an upstream hardened image" below. `nats-server` is a single, statically-linked Go binary with zero libc dependencies (confirmed via `file`/`ldd` against the actual release binary — `ldd` reports "not a dynamic executable"), so unlike `postgresql`/`valkey` there is no shared-library closure to trace at all: this image is just the binary itself plus `static`'s already-hardened rootfs (nonroot uid/gid 1001, `/etc/passwd`+`group`, writable sticky `/tmp`, CA certs, timezone data).

Current version is pinned in [`buildargs.conf`](../../buildargs.conf) (`NATS_VERSION`), downloaded from `nats-io/nats-server`'s GitHub releases and checksum-verified via `download.sh` — the same pattern this repo already uses for `kubectl`/`helm`/`watchexec` in `docker/base`.

## Tags

| Tag | Description |
|-----|-------------|
| `nats:latest` | Most recent build |

## What is included

### Binary

| Binary | Source |
|--------|--------|
| `nats-server` | GitHub release, `NATS_VERSION` |

### Configuration

| File | Destination | Purpose |
|------|-------------|---------|
| `nats-server.conf` | `/etc/nats/nats-server.conf` | Monitoring endpoint on 8222, JetStream enabled with file storage at `/data`. **No authentication configured by default** — same as the official `nats` image. Add an `authorization` block (or mount your own config override) before exposing this beyond a trusted network. |

### Ports

| Port | Protocol | Description |
|------|----------|--------------|
| 4222 | TCP | Client connections |
| 6222 | TCP | Cluster routing |
| 8222 | TCP | HTTP monitoring endpoint |

### Default user

Runs as `nonroot` (uid/gid 1001, this repo's standard convention) by default, inherited from `static`. `WORKDIR` is `/home/nonroot`. `/data` (the JetStream storage directory, declared as a `VOLUME`) is pre-owned by `nonroot`. Unlike `postgresql`/`valkey`, there is no privilege-drop dance to reason about at all — `nats-server` never forks, chowns, or re-execs; it just runs directly as whichever uid launches the container.

### Why not an upstream hardened image

Unlike `nginxinc/nginx-unprivileged` for `nginx`:

- The official `nats`/`nats:alpine` images both default to **root**, and there is no official unprivileged variant — a community PR proposing one was closed by the maintainers, who suggested `docker run --user`/a Kubernetes security context instead. The default `nats:latest` (`scratch`-based) additionally ships with no `/tmp` and no CA certificates at all, so it fails outright if JetStream is enabled under a non-root uid (`mkdir /tmp: permission denied`) and can't do outbound TLS.
- Chainguard's `nats` image is non-root by default, but is fully paywalled — every tag, including `:latest`, returns `403 Forbidden` without an enterprise subscription (confirmed via a direct registry probe, not just the tag list).
- Bitnami's `nats` image was non-root, but Broadcom's August 2025 catalog restructuring removed it from the public catalog entirely (`bitnami/nats` has zero tags on Docker Hub; the frozen legacy copy receives no security updates).

Since `nats-server` is a single static binary, building it ourselves on `static` avoids all three problems at once: free, version-pinned, non-root, and about as small as this gets (binary size plus `static`'s negligible rootfs).

## Usage

```sh
docker run -p 4222:4222 -p 8222:8222 -v natsdata:/data ghcr.io/pyck-ai/baseimages/nats:latest
```

Override the config:

```dockerfile
FROM ghcr.io/pyck-ai/baseimages/nats:latest
COPY my-nats-server.conf /etc/nats/nats-server.conf
```

## Build

```sh
task build -- nats
```
