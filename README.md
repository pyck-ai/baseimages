# Base Images

Hardened, multi-arch Docker base images for the pyck.ai platform. All images are published to `ghcr.io/pyck-ai/baseimages/` and support `linux/amd64` and `linux/arm64`.

## Images

The images fall into a few kinds:

- **Base** — a hardened Alpine + Debian foundation with common tooling. Other images may build on it, but single-purpose images are not required to.
- **Developer tooling** — single-purpose language toolchains, package managers, and coding-agent CLIs. Each targets one kind of project, and all are bundled into `all-in-one`.
- **All-in-one** — the full developer-tooling set in one image, for local development where juggling many images isn't worth it. Not intended for CI (size and attack surface).
- **Runtime & deployment** — single-purpose images that run or serve an application rather than build one. Consumed standalone and intentionally excluded from `all-in-one`.

### Base

| Image | Description |
|-------|-------------|
| [`base`](docker/base/README.md) | Hardened Alpine + Debian foundation with common tooling; an optional base for the other images |

### Developer tooling

Single-purpose tooling images, all bundled into `all-in-one`.

| Image | Description |
|-------|-------------|
| [`agent`](docker/agent/README.md) | Claude Code + opencode + pi coding-agent CLIs |
| [`golang`](docker/golang/README.md) | Go toolchain + CI tools (delve, golangci-lint, gotestsum, go-arch-lint) |
| [`python`](docker/python/README.md) | Python runtime with uv + Ruff |
| [`rover`](docker/rover/README.md) | Apollo Rover CLI for schema registry and supergraph operations (Debian only) |
| [`typescript`](docker/typescript/README.md) | TypeScript/JS runtime powered by Bun |

### All-in-one

| Image | Description |
|-------|-------------|
| [`all-in-one`](docker/all-in-one/README.md) | Every developer-tooling image combined for local development; excludes the runtime & deployment images (nginx, flutter, static) |

### Runtime & deployment

Single-purpose, consumed standalone, and intentionally excluded from `all-in-one`.

| Image | Description |
|-------|-------------|
| [`flutter`](docker/flutter/README.md) | Flutter + Dart SDK/runtime with RFW validator |
| [`nginx`](docker/nginx/README.md) | Unprivileged nginx for SPAs with OTel support |
| [`static`](docker/static/README.md) | Minimal scratch image for running static binaries |


## Deprecated tags

> [!WARNING]
> The images and tags below are **no longer built** and are **scheduled for
> removal without further announcement**. Migrate to the replacement — for the
> renamed repositories keep the tag and only change the name (e.g.
> `slim:alpine` → `base:alpine`).

| Deprecated | Replacement |
|------------|-------------|
| `slim` | `base` |
| `agents` | `agent` |
| `alpine:latest` | `all-in-one:alpine` |
| `debian:latest` | `all-in-one:debian` |
| `rover:debian` | `rover:latest` |
| `rover:<version>-debian` | `rover:<version>` |

## Versioning

All tool and base image versions are pinned in [`buildargs.conf`](buildargs.conf) and kept up to date by [Renovate](https://docs.renovatebot.com/).

## Building

### Prerequisites

```sh
task setup    # create the buildx builder (once)
```

### Build all images

```sh
task build
```

### Build a specific group or target

```sh
task build -- static            # scratch/static image
task build -- base              # alpine + debian base images
task build -- base-alpine       # alpine base only
task build -- golang            # both golang variants
task build -- golang-debian     # Go debian only
task build -- all-in-one        # all-in-one image (both variants)
```

### Build a specific arch only

```sh
task build ARCH=amd64 -- base-alpine
```

## Dependency graph

The arrows show current build dependencies. Building on `base` is optional by design — a single-purpose image may start from any suitable upstream instead (e.g. `golang` also pulls the official `golang` toolchain image, `nginx` builds on `nginxinc/nginx-unprivileged`).

```mermaid
graph LR
  base-alpine["base:alpine"]
  base-debian["base:debian"]
  nginx-base["nginxinc/nginx-unprivileged"]

  base-alpine --> static
  base-alpine --> golang-alpine["golang:alpine"]
  base-alpine --> agent-alpine["agent:alpine"]
  base-alpine --> typescript-alpine["typescript:alpine"]
  base-alpine --> flutter-alpine["flutter:alpine"]
  base-alpine --> python-alpine["python:alpine"]

  base-debian --> golang-debian["golang:debian"]
  base-debian --> agent-debian["agent:debian"]
  base-debian --> typescript-debian["typescript:debian"]
  base-debian --> flutter-debian["flutter:debian"]
  base-debian --> python-debian["python:debian"]
  base-debian --> rover

  golang-alpine --> aio-alpine["all-in-one:alpine"]
  agent-alpine --> aio-alpine
  typescript-alpine --> aio-alpine
  python-alpine --> aio-alpine

  golang-debian --> aio-debian["all-in-one:debian"]
  agent-debian --> aio-debian
  typescript-debian --> aio-debian
  rover --> aio-debian
  python-debian --> aio-debian

  nginx-base --> nginx
```
