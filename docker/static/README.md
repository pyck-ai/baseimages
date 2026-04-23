# Static Image

A minimal `scratch`-based image for running statically-compiled binaries in production. Zero OS packages, no shell, no package manager.

## Based on

`scratch` (empty base), populated with selected files from our [alpine base image](../slim/README.md).

## Tags

| Tag | Description |
|-----|-------------|
| `static:latest` | Multi-arch (amd64 + arm64) |

## What is included

| Path | Source | Purpose |
|------|--------|---------|
| `/etc/passwd`, `/etc/group` | alpine base | `root` and `nonroot` entries only |
| `/tmp` | `tmp.tar` | World-writable with sticky bit (1777) |
| `/etc/ssl/certs/ca-certificates.crt` | alpine base | TLS root certificates |
| `/usr/share/zoneinfo` | alpine base | Timezone database |
| `/etc/localtime` | alpine base | Default timezone (UTC) |
| `/root` | alpine base | Root home directory (owned root:root) |
| `/home/nonroot` | alpine base | nonroot home directory (owned 65532:65532) |

### Environment variables

| Variable | Value |
|----------|-------|
| `SSL_CERT_FILE` | `/etc/ssl/certs/ca-certificates.crt` |
| `HOME` | `/home/nonroot` |

### Default user

Runs as `nonroot` (UID/GID 65532). `WORKDIR` is `/home/nonroot`.

## Usage

Use as the final stage for a statically-compiled binary:

```dockerfile
FROM ghcr.io/pyck-ai/baseimages/static:latest
COPY --from=build /app/mybinary /mybinary
ENTRYPOINT ["/mybinary"]
```

The binary must be statically linked. For Go binaries, ensure `CGO_ENABLED=0`.

## /tmp handling

The sticky bit on `/tmp` cannot be set via a `COPY` or `RUN` in a scratch image, so `/tmp` is provisioned from a pre-built `tmp.tar` archive via `ADD`. The archive contains a single empty directory with permissions `1777`.

## Build

```sh
task build -- static
```
