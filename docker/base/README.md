# Base Images

Two hardened base images providing a consistent foundation for all other images in this repo.

## Variants

| Variant | Tag | Based on |
|---------|-----|----------|
| Alpine | `base:alpine` | `alpine:<alpine_version>` |
| Debian | `base:debian` | `debian:<debian_release>` |

Current versions are pinned in [`buildargs.conf`](../../buildargs.conf) (`ALPINE_VERSION`, `DEBIAN_RELEASE`).

## Tags

### Alpine tags

| Tag | Description |
|-----|-------------|
| `base:latest` | Most recent Alpine build |
| `base:alpine` | Most recent Alpine build |
| `base:alpine-<alpine_version>` | Exact Alpine version this build was made from |
| `base:alpine-<major>` | Latest build on that Alpine major |

### Debian tags

| Tag | Description |
|-----|-------------|
| `base:debian` | Most recent Debian build |
| `base:debian-<release>` | Debian release name this build was made from |

## What is included

Both variants provide the same set of tools and conventions so downstream images can be written identically regardless of which distro they target. CA certificates are refreshed via `update-ca-certificates`, the timezone is set to UTC, `download.sh` is installed at `/usr/local/sbin/download.sh` (a checksum-verified binary download helper used by all downstream images to install third-party tools), and `git config --system --add safe.directory "*"` is set so git works inside any bind-mounted repository regardless of file ownership.

### Packages

| Package | Alpine | Debian | Purpose |
|---------|--------|--------|---------|
| Bash | `bash` | `bash` | POSIX-plus shell |
| Build toolchain | `build-base`, `gcc`, `musl-dev`, `musl` | `build-essential`, `gcc` | C compiler and toolchain |
| CA certificates | `ca-certificates` | `ca-certificates` | TLS trust store |
| Core utils | `coreutils` | `coreutils` | GNU core utilities |
| curl | `curl` | `curl` | HTTP client |
| fd | `fd` | `fd-find` | Fast file finder — Debian ships the binary as `fdfind`; the Dockerfile symlinks it to `fd`, so the command is `fd` on both variants |
| file | `file` | `file` | File type detection |
| gawk | `gawk` | `gawk` | AWK implementation |
| gcompat (glibc shim) | `gcompat`, `libgcc`, `libstdc++` | _(built in)_ | glibc compatibility for prebuilt binaries |
| gettext / envsubst | `gettext-envsubst` | `gettext` | `envsubst` template substitution |
| git | `git` | `git` | Version control |
| GnuPG | `gnupg` | `gnupg` | GPG signing/verification |
| jq | `jq` | `jq` | JSON processor |
| Linux headers | `linux-headers` | `linux-headers-<arch>` | Kernel headers for native builds |
| make | `make` | `make` | Build automation |
| OpenSSH client | `openssh-client` | `openssh-client` | SSH client |
| patch | `patch` | `patch` | Apply diffs |
| rclone | `rclone` | `rclone` | Cloud storage sync |
| ripgrep | `ripgrep` | `ripgrep` | Fast recursive search |
| rsync | `rsync` | `rsync` | File sync |
| tar | `tar` | `tar` | Archive tool |
| tzdata | `tzdata` | `tzdata` | Timezone database |
| unzip | `unzip` | `unzip` | Zip extraction |
| wget | `wget` | `wget` | HTTP downloader |
| xz | `xz` | `xz-utils` | LZMA compression |
| zip | `zip` | `zip` | Zip archiving |
| zstd | `zstd` | `zstd` | Zstandard compression |

### Tools

| Tool | Binary | Alpine | Debian | Source |
|------|--------|--------|--------|--------|
| [Task](https://taskfile.dev) | `task` | ✅ | ✅ | GitHub release, `TASKFILE_VERSION` |
| [flyctl](https://fly.io/docs/flyctl/) | `flyctl` | ✅ | ✅ | GitHub release, `FLYCTL_VERSION` |
| [GitHub CLI](https://cli.github.com) | `gh` | ✅ | ✅ | GitHub release, `GHCLI_VERSION` |
| [Helm](https://helm.sh) | `helm` | ✅ | ✅ | upstream release, `HELM_VERSION` |
| [kubectl](https://kubernetes.io/docs/reference/kubectl/) | `kubectl` | ✅ | ✅ | dl.k8s.io release, `KUBECTL_VERSION` |
| [kustomize](https://kustomize.io) | `kustomize` | ✅ | ✅ | GitHub release, `KUSTOMIZE_VERSION` |
| [watchexec](https://github.com/watchexec/watchexec) | `watchexec` | ✅ | ✅ | GitHub release, `WATCHEXEC_VERSION` |

### Environment

| Variable | Value | Description |
|----------|-------|--------------|
| `DEBIAN_FRONTEND` | `noninteractive` | Debian only — suppresses interactive `apt-get`/`dpkg-reconfigure` prompts. Not set on Alpine. |

### Default user

**Build image, not a hardened runtime base** — if you `FROM` this for a deployment image, set `USER` in your final stage (same as the official `golang`/`python` images).

Runs as **root (uid 0) by default**. A `nonroot` account (uid/gid 65532, matching the Google distroless convention) still exists, and `/app` is nonroot-owned, so `--user 65532` drops privileges cleanly. `WORKDIR` is `/app`.

## Usage

These images are not meant to be used directly in production. They serve as the base for downstream images in this repo (`static`, `golang`, etc.) and can be used as build stages in application Dockerfiles:

```dockerfile
FROM ghcr.io/pyck-ai/baseimages/base:alpine AS build
RUN ...

FROM ghcr.io/pyck-ai/baseimages/base:debian AS build
RUN ...
```

Run unprivileged instead of the root default:

```sh
docker run --rm --user 65532 ghcr.io/pyck-ai/baseimages/base:alpine id
```

## Build

```sh
task build -- base          # build both alpine and debian
task build -- base-alpine   # alpine only
task build -- base-debian   # debian only
```
