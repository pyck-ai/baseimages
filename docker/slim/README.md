# Base Images

Two hardened base images providing a consistent foundation for all other images in this repo.

## Variants

| Image | Based on |
|-------|----------|
| Alpine | `alpine:<ALPINE_VERSION>` |
| Debian | `debian:<DEBIAN_RELEASE>` |

Current versions are defined in [`buildargs.conf`](../../buildargs.conf).

## Tags

### Alpine

| Tag | Description |
|-----|-------------|
| `slim:latest` | Most recent Alpine build |
| `slim:alpine` | Most recent Alpine build |
| `slim:alpine-<major>` | Major Alpine version, e.g. `slim:alpine-3` |
| `slim:alpine-<version>` | Exact Alpine version, e.g. `slim:alpine-3.22` |

### Debian

| Tag | Description |
|-----|-------------|
| `slim:debian` | Most recent Debian build |
| `slim:debian-<release>` | Debian release name, e.g. `slim:debian-bookworm` |

## What is included

Both variants provide the same set of tools and conventions so downstream images can be written identically regardless of which distro they target.

### System packages

| Package | Alpine name | Debian name |
|---------|-------------|-------------|
| Bash | `bash` | `bash` |
| Build toolchain | `build-base`, `gcc`, `musl-dev`, `musl` | `build-essential`, `gcc` |
| CA certificates | `ca-certificates` | `ca-certificates` |
| Core utils | `coreutils` | `coreutils` |
| curl | `curl` | `curl` |
| gawk | `gawk` | `gawk` |
| gcompat (glibc shim) | `gcompat`, `libgcc`, `libstdc++` | _(built in)_ |
| gettext / envsubst | `gettext-envsubst` | `gettext` |
| git | `git` | `git` |
| GnuPG | `gnupg` | `gnupg` |
| jq | `jq` | `jq` |
| Linux headers | `linux-headers` | `linux-headers-<arch>` |
| make | `make` | `make` |
| OpenSSH client | `openssh-client` | `openssh-client` |
| patch | `patch` | `patch` |
| ripgrep | `ripgrep` | `ripgrep` |
| rsync | `rsync` | `rsync` |
| tar | `tar` | `tar` |
| tzdata | `tzdata` | `tzdata` |
| unzip | `unzip` | `unzip` |
| wget | `wget` | `wget` |
| xz | `xz` | `xz-utils` |
| zip | `zip` | `zip` |
| zstd | `zstd` | `zstd` |

### Third-party tools

| Tool | Binary | Version source |
|------|--------|----------------|
| [Task](https://taskfile.dev) | `task` | `TASKFILE_VERSION` in `buildargs.conf` |
| [flyctl](https://fly.io/docs/flyctl/) | `flyctl` | `FLYCTL_VERSION` in `buildargs.conf` |
| [GitHub CLI](https://cli.github.com) | `gh` | `GHCLI_VERSION` in `buildargs.conf` |
| [Helm](https://helm.sh) | `helm` | `HELM_VERSION` in `buildargs.conf` |
| [kubectl](https://kubernetes.io/docs/reference/kubectl/) | `kubectl` | `KUBECTL_VERSION` in `buildargs.conf` |
| [kustomize](https://kustomize.io) | `kustomize` | `KUSTOMIZE_VERSION` in `buildargs.conf` |
| [watchexec](https://github.com/watchexec/watchexec) | `watchexec` | `WATCHEXEC_VERSION` in `buildargs.conf` |

### Conventions applied

- **CA certificates** refreshed via `update-ca-certificates`.
- **Timezone** set to UTC.
- **`download.sh`** installed at `/usr/local/sbin/download.sh` — a content-addressed binary download helper with checksum verification, used by all downstream images to install third-party tools.
- **`nonroot` user** created with UID/GID 65532 (matches Google distroless convention).
- **`WORKDIR /app`** set as the default working directory.

## Usage

These images are not meant to be used directly in production. They serve as the base for downstream images in this repo (`static`, `golang`, etc.) and can be used as build stages in application Dockerfiles:

```dockerfile
FROM ghcr.io/pyck-ai/baseimages/slim:alpine AS build
RUN ...

FROM ghcr.io/pyck-ai/baseimages/slim:debian AS build
RUN ...
```

## Build

```sh
task build -- slim          # build both alpine and debian
task build -- slim-alpine   # alpine only
task build -- slim-debian   # debian only
```
