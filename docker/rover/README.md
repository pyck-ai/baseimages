# Rover Image

Apollo GraphQL tooling image providing the [Rover CLI](https://www.apollographql.com/docs/rover/) for schema management and supergraph operations.

## Variants

| Image | Based on | Tags |
|-------|----------|------|
| Debian | our [debian base](../slim/README.md) | see below |

Rover only publishes glibc binaries, so no Alpine variant is provided.

Current version is defined in [`buildargs.conf`](../../buildargs.conf).

### Tags

| Tag | Description |
|-----|-------------|
| `rover:latest` | Most recent Rover version |
| `rover:debian` | Most recent Rover version on Debian |
| `rover:<major>` | Major-version alias, e.g. `rover:0` |
| `rover:<major.minor>` | Minor-version alias, e.g. `rover:0.38` |
| `rover:<version>` | Exact pinned version, e.g. `rover:0.38.0` |
| `rover:<major>-debian` | Major alias on Debian, e.g. `rover:0-debian` |
| `rover:<major.minor>-debian` | Minor alias on Debian, e.g. `rover:0.38-debian` |
| `rover:<version>-debian` | Exact version on Debian, e.g. `rover:0.38.0-debian` |

## What is included

### Rover CLI

| Binary | Path | Description |
|--------|------|-------------|
| `rover` | `/usr/local/bin/rover` | Apollo Rover CLI for schema registry and supergraph operations |

Downloaded with checksum verification via `download.sh`. Supports `linux/amd64` and `linux/arm64`.

### Default user

Runs as `nonroot` (UID/GID 65532). `WORKDIR` is `/app`.

## Usage

```dockerfile
FROM ghcr.io/pyck-ai/baseimages/rover:latest
RUN rover graph check my-graph@current --schema ./schema.graphql
```

## Build

```sh
task build -- rover
```
