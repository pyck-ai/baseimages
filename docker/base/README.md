# Base Images

Three hardened base images providing a consistent foundation for all other images in this repo.

## Variants

| Variant | Tag | Based on |
|---------|-----|----------|
| Alpine | `base:alpine` | `alpine:<alpine_version>` |
| Debian | `base:debian` | `debian:<debian_release>` |
| Wolfi | `base:wolfi` | `cgr.dev/chainguard/wolfi-base@<digest>` |

Current versions are pinned in [`buildargs.conf`](../../buildargs.conf) (`ALPINE_VERSION`, `DEBIAN_RELEASE`, `WOLFI_BASE_DIGEST`).

[Wolfi](https://github.com/wolfi-dev) is Chainguard's "undistro": `apk`-based like Alpine, but **glibc**-based like Debian, aimed at zero-CVE, minimal, cloud-native images. It has no dated/semver release tags on its free tier (only `cgr.dev/chainguard/wolfi-base:latest`), so unlike `ALPINE_VERSION`/`DEBIAN_RELEASE` this pins an immutable digest rather than a version string, tracked by Renovate's `docker-digest` datasource. Packages are pulled from `packages.wolfi.dev` (Wolfi's own free, unauthenticated CDN), not `apk.cgr.dev` (Chainguard's own proxy in front of the identical package set, but severely rate-limited for unauthenticated pulls: measured directly at ~5.5s per package installed, vs. no such throttle on `packages.wolfi.dev`).

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

| Package | Alpine | Debian | Wolfi | Purpose |
|---------|--------|--------|-------|---------|
| age | `age` | `age` | `age` | File encryption tool |
| Bash | `bash` | `bash` | `bash` | POSIX-plus shell |
| Build toolchain | `build-base`, `gcc`, `musl-dev`, `musl` | `build-essential`, `gcc` | `build-base`, `gcc` | C compiler and toolchain |
| CA certificates | `ca-certificates` | `ca-certificates` | `ca-certificates` | TLS trust store |
| Core utils | `coreutils` | `coreutils` | `coreutils` | GNU core utilities |
| curl | `curl` | `curl` | `curl` | HTTP client |
| DNS lookup | `bind-tools` | `dnsutils` | `bind-tools` | dig/nslookup: Alpine and Wolfi both ship `bind-tools`, Debian ships `dnsutils`; all three provide the `dig` command |
| fd | `fd` | `fd-find` | `fd` | Fast file finder: Debian ships the binary as `fdfind`; the Dockerfile symlinks it to `fd`, so the command is `fd` on all three variants |
| file | `file` | `file` | `file` | File type detection |
| gawk | `gawk` | `gawk` | `gawk` | AWK implementation |
| gcompat (glibc shim) | `gcompat`, `libgcc`, `libstdc++` | _(built in)_ | _(built in, glibc-based)_ | glibc compatibility for prebuilt binaries |
| gettext / envsubst | `gettext-envsubst` | `gettext` | `gettext-envsubst` | `envsubst` template substitution |
| git | `git` | `git` | `git` | Version control |
| GnuPG | `gnupg` | `gnupg` | `gnupg` | GPG signing/verification |
| iputils (ping) | `iputils` | `iputils-ping` | `iputils` | ICMP ping |
| jq | `jq` | `jq` | `jq` | JSON processor |
| Linux headers | `linux-headers` | `linux-headers-<arch>` | `linux-headers` | Kernel headers for native builds |
| make | `make` | `make` | `make` | Build automation |
| netcat | `netcat-openbsd` | `netcat-openbsd` | `netcat-openbsd` | Port/health checks in CI scripts (`nc`) |
| OpenSSH client | `openssh-client` | `openssh-client` | `openssh-client` | SSH client |
| OpenSSL | `openssl` | `openssl` | `openssl` | TLS/cert CLI tooling |
| patch | `patch` | `patch` | `patch` | Apply diffs |
| PostgreSQL client | `postgresql-client` | `postgresql-client` | `postgresql-17-client` | psql/pg_dump/pg_isready for DB access in CI: Wolfi streams client packages per major version (`postgresql-16-client`, `-17-client`, `-18-client`, ...), pinned here to 17 to match the other two variants |
| rclone | `rclone` | `rclone` | `rclone` | Cloud storage sync |
| ripgrep | `ripgrep` | `ripgrep` | `ripgrep` | Fast recursive search |
| rsync | `rsync` | `rsync` | `rsync` | File sync |
| shellcheck | `shellcheck` | `shellcheck` | _(GitHub release, see Tools)_ | Shell script linting; not packaged in Wolfi at all (needs Haskell GHC/Cabal, which Wolfi doesn't carry) |
| SQLite | `sqlite` | `sqlite3` | `sqlite` | Local DB inspection: Alpine and Wolfi both name the package `sqlite`, Debian's is `sqlite3`; all three provide the `sqlite3` command |
| tar | `tar` | `tar` | `gnutar` | Archive tool: Wolfi's base tar is busybox's; GNU tar is the separate `gnutar` package |
| tzdata | `tzdata` | `tzdata` | `tzdata` | Timezone database |
| unzip | `unzip` | `unzip` | `unzip` | Zip extraction |
| wget | `wget` | `wget` | `wget` | HTTP downloader |
| xz | `xz` | `xz-utils` | `xz` | LZMA compression |
| zip | `zip` | `zip` | `zip` | Zip archiving |
| zstd | `zstd` | `zstd` | `zstd` | Zstandard compression |
| shadow (useradd/usermod/groupmod) | _(built in, busybox)_ | _(built in)_ | `shadow` | Only Wolfi needs this as a separate package; see "Default user" below for why it's used here even though no new account is created |

### Tools

| Tool | Binary | Alpine | Debian | Wolfi | Source |
|------|--------|--------|--------|-------|--------|
| [Task](https://taskfile.dev) | `task` | ✅ | ✅ | ✅ | GitHub release, `TASKFILE_VERSION` |
| [flyctl](https://fly.io/docs/flyctl/) | `flyctl` | ✅ | ✅ | ✅ | GitHub release, `FLYCTL_VERSION` |
| [GitHub CLI](https://cli.github.com) | `gh` | ✅ | ✅ | ✅ | GitHub release, `GHCLI_VERSION` |
| [Helm](https://helm.sh) | `helm` | ✅ | ✅ | ✅ | upstream release, `HELM_VERSION` |
| [kubectl](https://kubernetes.io/docs/reference/kubectl/) | `kubectl` | ✅ | ✅ | ✅ | dl.k8s.io release, `KUBECTL_VERSION` |
| [kustomize](https://kustomize.io) | `kustomize` | ✅ | ✅ | ✅ | GitHub release, `KUSTOMIZE_VERSION` |
| [SOPS](https://github.com/getsops/sops) | `sops` | ✅ | ✅ | ✅ | GitHub release on Alpine/Debian (`SOPS_VERSION`); **native Wolfi package** (`sops`) on Wolfi; no download stage needed there |
| [shellcheck](https://www.shellcheck.net) | `shellcheck` | _(apk package)_ | _(apt package)_ | ✅ | Alpine/Debian install it as a plain distro package; Wolfi doesn't package it at all, so it's the one tool on Wolfi installed via GitHub release + `download.sh` instead, same pattern as the tools below |
| [watchexec](https://github.com/watchexec/watchexec) | `watchexec` | ✅ | ✅ | ✅ | GitHub release, `WATCHEXEC_VERSION` |

### Environment

| Variable | Value | Description |
|----------|-------|--------------|
| `DEBIAN_FRONTEND` | `noninteractive` | Debian only: suppresses interactive `apt-get`/`dpkg-reconfigure` prompts. Not set on Alpine or Wolfi. |

### Default user

**Build image, not a hardened runtime base** — if you `FROM` this for a deployment image, set `USER` in your final stage (same as the official `golang`/`python` images).

Runs as **root (uid 0) by default**. A `nonroot` account (uid/gid 1001, matching the uid our GitHub Actions runners execute as, so bind-mounted workspaces stay writable) still exists, and `/app` is nonroot-owned, so `--user 1001` drops privileges cleanly. `WORKDIR` is `/app`.

On Wolfi specifically: `wolfi-base` already ships its own `nonroot` account (the Chainguard/distroless convention), but at uid/gid 65532 with a correctly pre-created home directory. Rather than creating a second, differently-named account at 1001 (the name collision makes `useradd` fail outright, and a different name would break the `-o nonroot -g nonroot` convention every other Dockerfile in this repo relies on), the existing account is renumbered in place via `groupmod`/`usermod`; hence `shadow` being a real package dependency on this variant alone.

## Usage

These images are not meant to be used directly in production. They serve as the base for downstream images in this repo (`static`, `golang`, etc.) and can be used as build stages in application Dockerfiles:

```dockerfile
FROM ghcr.io/pyck-ai/baseimages/base:alpine AS build
RUN ...

FROM ghcr.io/pyck-ai/baseimages/base:debian AS build
RUN ...

FROM ghcr.io/pyck-ai/baseimages/base:wolfi AS build
RUN ...
```

Run unprivileged instead of the root default:

```sh
docker run --rm --user 1001 ghcr.io/pyck-ai/baseimages/base:alpine id
```

## Build

```sh
task build -- base          # build alpine, debian, and wolfi
task build -- base-alpine   # alpine only
task build -- base-debian   # debian only
task build -- base-wolfi    # wolfi only
```
