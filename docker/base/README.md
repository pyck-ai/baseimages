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
| `base:latest` | Most recent Alpine build |
| `base:alpine` | Most recent Alpine build |
| `base:alpine-<major>` | Major Alpine version, e.g. `base:alpine-3` |
| `base:alpine-<version>` | Exact Alpine version, e.g. `base:alpine-3.22` |

### Debian

| Tag | Description |
|-----|-------------|
| `base:debian` | Most recent Debian build |
| `base:debian-<release>` | Debian release name, e.g. `base:debian-bookworm` |

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
| file | `file` | `file` |
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
| rclone | `rclone` | `rclone` |
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

| Tool | Binary | Alpine | Debian | Version source |
|------|--------|--------|--------|----------------|
| [Task](https://taskfile.dev) | `task` | ✅ | ✅ | `TASKFILE_VERSION` in `buildargs.conf` |
| [flyctl](https://fly.io/docs/flyctl/) | `flyctl` | ✅ | ✅ | `FLYCTL_VERSION` in `buildargs.conf` |
| [GitHub CLI](https://cli.github.com) | `gh` | ✅ | ✅ | `GHCLI_VERSION` in `buildargs.conf` |
| [Helm](https://helm.sh) | `helm` | ✅ | ✅ | `HELM_VERSION` in `buildargs.conf` |
| [kubectl](https://kubernetes.io/docs/reference/kubectl/) | `kubectl` | ✅ | ✅ | `KUBECTL_VERSION` in `buildargs.conf` |
| [kustomize](https://kustomize.io) | `kustomize` | ✅ | ✅ | `KUSTOMIZE_VERSION` in `buildargs.conf` |
| [watchexec](https://github.com/watchexec/watchexec) | `watchexec` | ✅ | ✅ | `WATCHEXEC_VERSION` in `buildargs.conf` |

All third-party tools are present in both variants. System packages are listed per-distro by name above; a name in the Alpine or Debian column means the package is present in that variant.

### Conventions applied

- **CA certificates** refreshed via `update-ca-certificates`.
- **Timezone** set to UTC.
- **`download.sh`** installed at `/usr/local/sbin/download.sh` — a content-addressed binary download helper with checksum verification, used by all downstream images to install third-party tools.
- **`nonroot` user** created with UID/GID 65532 (matches Google distroless convention).
- **`WORKDIR /app`** set as the default working directory.

## Usage

These images are not meant to be used directly in production. They serve as the base for downstream images in this repo (`static`, `golang`, etc.) and can be used as build stages in application Dockerfiles:

```dockerfile
FROM ghcr.io/pyck-ai/baseimages/base:alpine AS build
RUN ...

FROM ghcr.io/pyck-ai/baseimages/base:debian AS build
RUN ...
```

## Build

```sh
task build -- base          # build both alpine and debian
task build -- base-alpine   # alpine only
task build -- base-debian   # debian only
```
