# Golang Images

Go development images with the full toolchain plus a curated set of CI/dev tools. Intended for build pipelines and local development containers.

## Variants

| Image | Based on | Tags |
|-------|----------|------|
| Alpine | our [alpine base](../base/README.md) + `golang:<GO_VERSION>-alpine<ALPINE_VERSION>` | see below |
| Debian | our [debian base](../base/README.md) + `golang:<GO_VERSION>-<DEBIAN_RELEASE>` | see below |

Current versions are defined in [`buildargs.conf`](../../buildargs.conf).

### Alpine tags

| Tag | Description |
|-----|-------------|
| `golang:latest` | Most recent Go on Alpine |
| `golang:alpine` | Most recent Go on Alpine |
| `golang:alpine-<alpine_version>` | Alpine version, e.g. `golang:alpine-3.22` |
| `golang:<major>` | Major Go alias, e.g. `golang:1` |
| `golang:<major.minor>` | Minor Go alias, e.g. `golang:1.26` |
| `golang:<version>` | Exact Go version, e.g. `golang:1.26.1` |
| `golang:<major>-alpine` | Major Go alias on Alpine, e.g. `golang:1-alpine` |
| `golang:<major.minor>-alpine` | Minor Go alias on Alpine, e.g. `golang:1.26-alpine` |
| `golang:<version>-alpine` | Exact Go version on Alpine, e.g. `golang:1.26.1-alpine` |

### Debian tags

| Tag | Description |
|-----|-------------|
| `golang:debian` | Most recent Go on Debian |
| `golang:debian-<release>` | Debian release name, e.g. `golang:debian-bookworm` |
| `golang:<major>-debian` | Major Go alias on Debian, e.g. `golang:1-debian` |
| `golang:<major.minor>-debian` | Minor Go alias on Debian, e.g. `golang:1.26-debian` |
| `golang:<version>-debian` | Exact Go version on Debian, e.g. `golang:1.26.1-debian` |

## What is included

### Go toolchain

The Go toolchain is copied from the official `golang` image into `/usr/local/go`. Only the toolchain is copied — the GOPATH and module cache are not pre-populated.

### Additional tools

| Tool | Binary | Alpine | Debian | Purpose |
|------|--------|--------|--------|---------|
| [Delve](https://github.com/go-delve/delve) | `dlv` | ✅ | ✅ | Go debugger |
| [go-arch-lint](https://github.com/fe3dback/go-arch-lint) | `go-arch-lint` | ✅ | ✅ | Architecture linter |
| [golangci-lint](https://github.com/golangci/golangci-lint) | `golangci-lint` | ✅ | ✅ | Meta linter |
| [gotestsum](https://github.com/gotestyourself/gotestsum) | `gotestsum` | ✅ | ✅ | Test runner with better output |

All tools are present in both Alpine and Debian variants, downloaded with checksum verification via `download.sh`, and support `linux/amd64` and `linux/arm64`. The Go toolchain itself (`go`, `gofmt`) is likewise identical in both variants.

### Environment

| Variable | Value | Notes |
|----------|-------|-------|
| `GOPATH` | `/go` | Standard Go workspace |
| `GOCACHE` | `/var/cache/go/` | Build cache; mount as a volume in CI |
| `GOMODCACHE` | `/go/pkg/mod/` | Module cache; mount as a volume in CI |
| `GOPROXY` | `https://go.pyck.cloud,direct` | Internal proxy with fallback to direct |
| `CGO_ENABLED` | `0` | Statically-linked builds by default |
| `PATH` | prepends `/usr/local/go/bin:/go/bin` | `go` and installed binaries on PATH |

### Default user

Runs as `nonroot` (UID/GID 65532). `WORKDIR` is `/app`.

## Usage

### As a build stage

```dockerfile
FROM ghcr.io/pyck-ai/baseimages/golang:latest AS build
WORKDIR /app
COPY . .
RUN go build -o /app/mybinary ./cmd/server
```

### Mounting caches in CI

```yaml
- uses: docker/build-push-action@v6
  with:
    cache-from: type=gha
    build-args: |
      GOCACHE=/var/cache/go
      GOMODCACHE=/go/pkg/mod
```

Or with Task:

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
