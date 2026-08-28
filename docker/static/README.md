# Static Image

A minimal `scratch`-based image for running statically-compiled binaries in production. Zero OS packages, no shell, no package manager.

## Based on

`scratch` (empty base), populated with selected files from our [alpine base image](../base/README.md).

## Tags

| Tag | Description |
|-----|-------------|
| `static:latest` | Multi-arch (amd64 + arm64) |

## What is included

`static` ships **no installed tools** — it is a bare `scratch` image with no shell or package manager. It is published as a single multi-arch image (`static:latest`, amd64 + arm64), not as separate Alpine/Debian variants, so there is no per-variant tool coverage to list. The table below is the set of files provisioned into the image (sourced from the Alpine base):

| Path | Source | Purpose |
|------|--------|---------|
| `/etc/passwd`, `/etc/group` | alpine base | `root` and `nonroot` entries only |
| `/tmp` | `tmp.tar` | World-writable with sticky bit (1777) |
| `/etc/ssl/certs/ca-certificates.crt` | alpine base | TLS root certificates |
| `/usr/share/zoneinfo` | alpine base | Timezone database |
| `/etc/localtime` | alpine base | Default timezone (UTC) |
| `/root` | alpine base | Root home directory (owned root:root) |
| `/home/nonroot` | alpine base | nonroot home directory (owned 1001:1001) |

### /tmp handling

The sticky bit on `/tmp` cannot be set via a `COPY` or `RUN` in a scratch image, so `/tmp` is provisioned from a pre-built `tmp.tar` archive via `ADD`. The archive contains a single empty directory with permissions `1777`.

### Environment

| Variable | Value | Description |
|----------|-------|--------------|
| `SSL_CERT_FILE` | `/etc/ssl/certs/ca-certificates.crt` | TLS trust store path |
| `HOME` | `/home/nonroot` | Home directory |

### Default user

Runs as `nonroot` (UID/GID 1001) by default, declared numerically as `USER 1001` — a scratch image has no `/etc/passwd` for a name to resolve against. `WORKDIR` is `/home/nonroot`.

`--user 0` can override the runtime uid to root, but since this is a scratch image with no shell or package manager, there is nothing to install — it only changes which uid the entrypoint binary runs as.

## Usage

Use as the final stage for a statically-compiled binary:

```dockerfile
FROM ghcr.io/pyck-ai/baseimages/static:latest
COPY --from=build /app/mybinary /mybinary
ENTRYPOINT ["/mybinary"]
```

The binary must be statically linked. For Go binaries, ensure `CGO_ENABLED=0`.

## Build

```sh
task build -- static
```
