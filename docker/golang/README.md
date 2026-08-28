# Golang Images

Go development images with the full toolchain plus a curated set of CI/dev tools. Intended for build pipelines and local development containers.

## Variants

| Variant | Tag | Based on |
|---------|-----|----------|
| Alpine | `golang:alpine` | our [base](../base/README.md) (Alpine) + `golang:<golang_version>-alpine<alpine_version>` |
| Debian | `golang:debian` | our [base](../base/README.md) (Debian) + `golang:<golang_version>-<debian_release>` |

Current versions are pinned in [`buildargs.conf`](../../buildargs.conf) (`GOLANG_VERSION`, `ALPINE_VERSION`, `DEBIAN_RELEASE`). Both variants ship the same Go toolchain, tools, and environment - only the underlying distro differs.

## Tags

### Alpine tags

| Tag | Description |
|-----|-------------|
| `golang:latest` | Most recent Go on Alpine |
| `golang:alpine` | Most recent Go on Alpine |
| `golang:alpine-<alpine_version>` | Exact Alpine version this build was made from |
| `golang:<major>` | Major Go alias |
| `golang:<major>.<minor>` | Minor Go alias |
| `golang:<version>` | Exact Go version |
| `golang:<major>-alpine` | Major Go alias on Alpine |
| `golang:<major>.<minor>-alpine` | Minor Go alias on Alpine |
| `golang:<version>-alpine` | Exact Go version on Alpine |

### Debian tags

| Tag | Description |
|-----|-------------|
| `golang:debian` | Most recent Go on Debian |
| `golang:debian-<release>` | Debian release name this build was made from |
| `golang:<major>-debian` | Major Go alias on Debian |
| `golang:<major>.<minor>-debian` | Minor Go alias on Debian |
| `golang:<version>-debian` | Exact Go version on Debian |

## What is included

### Go toolchain

The Go toolchain is copied from the official `golang` image into `/usr/local/go`. Only the toolchain is copied - the GOPATH and module cache are not pre-populated.

### Tools

| Tool | Binary | Alpine | Debian | Source |
|------|--------|--------|--------|--------|
| [Delve](https://github.com/go-delve/delve) | `dlv` | ✅ | ✅ | `go install`, `DELVE_VERSION` |
| [go-arch-lint](https://github.com/fe3dback/go-arch-lint) | `go-arch-lint` | ✅ | ✅ | GitHub release, `GOARCHLINT_VERSION` |
| [golangci-lint](https://github.com/golangci/golangci-lint) | `golangci-lint` | ✅ | ✅ | GitHub release, `GOLANGCILINT_VERSION` |
| [gotestsum](https://github.com/gotestyourself/gotestsum) | `gotestsum` | ✅ | ✅ | GitHub release, `GOTESTSUM_VERSION` |

All tools are present in both Alpine and Debian variants and support `linux/amd64` and `linux/arm64`.

### Environment

| Variable | Value | Description |
|----------|-------|--------------|
| `GOPATH` | `/go` | Standard Go workspace |
| `PATH` | prepends `/usr/local/go/bin:/go/bin` | `go` and installed binaries on PATH |
| `GOCACHE` | `/var/cache/go/` | Build cache; mount as a volume in CI |
| `GOMODCACHE` | `/go/pkg/mod/` | Module cache; mount as a volume in CI |
| `GOPROXY` | `https://go.pyck.cloud,direct` | Internal Go module proxy with fallback to direct |
| `CGO_ENABLED` | `0` | Statically-linked builds by default; set to `1` explicitly for cgo |

The Debian variant also inherits `DEBIAN_FRONTEND` from [base](../base/README.md).

### Default user

**Build image, not a hardened runtime base** — if you `FROM` this for a deployment image, set `USER` in your final stage (same as the official `golang`/`python` images).

Runs as **root (uid 0) by default**. A `nonroot` account (uid/gid 1001) still exists, and `/go`, `/go/bin`, `/go/pkg/mod`, and `/var/cache/go` are all nonroot-owned, so `go build` and `go install` also work under `--user 1001`. `WORKDIR` is `/app`.

## Usage

### As a build stage

```dockerfile
FROM ghcr.io/pyck-ai/baseimages/golang:latest AS build
WORKDIR /app
COPY . .
RUN go build -o /app/mybinary ./cmd/server
```

Run unprivileged instead of the root default:

```sh
docker run --rm --user 1001 ghcr.io/pyck-ai/baseimages/golang:latest go version
```

### Mounting caches in CI

```sh
docker run --rm \
  -v go-cache:/var/cache/go \
  -v go-mod:/go/pkg/mod \
  ghcr.io/pyck-ai/baseimages/golang:latest \
  go test ./...
```

## Build

```sh
task build -- golang          # build both alpine and debian variants
task build -- golang-alpine   # alpine only
task build -- golang-debian   # debian only
```
