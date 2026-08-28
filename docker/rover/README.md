# Rover Image

Apollo GraphQL tooling image providing the [Rover CLI](https://www.apollographql.com/docs/rover/) for schema management and supergraph operations.

## Based on

Our [debian base](../base/README.md): `base:debian`. Rover only publishes glibc binaries, so no Alpine variant is provided.

Current version is defined in [`buildargs.conf`](../../buildargs.conf) (`ROVER_VERSION`).

## Tags

| Tag | Description |
|-----|-------------|
| `rover:latest` | Most recent Rover version |
| `rover:<major>` | Major-version alias |
| `rover:<major.minor>` | Minor-version alias |
| `rover:<version>` | Exact pinned version |

## What is included

### Tools

| Tool | Binary | Source |
|------|--------|--------|
| [Rover](https://www.apollographql.com/docs/rover/) | `rover` | GitHub release, `ROVER_VERSION`, checksum-verified via `download.sh` |

Supports `linux/amd64` and `linux/arm64`. Installs no packages and sets no environment variables of its own beyond the [base image](../base/README.md).

### Default user

**Build image, not a hardened runtime base** — if you `FROM` this for a deployment image, set `USER` in your final stage (same as the official `golang`/`python` images).

Runs as **root (uid 0) by default**. A `nonroot` account (uid/gid 1001) still exists, reachable via `--user 1001`. `WORKDIR` is `/app`.

## Usage

```sh
docker run --rm -e APOLLO_KEY -v "$PWD:/app" \
  ghcr.io/pyck-ai/baseimages/rover:latest \
  rover graph check my-graph@current --schema ./schema.graphql
```

Run unprivileged instead of the root default:

```sh
docker run --rm --user 1001 ghcr.io/pyck-ai/baseimages/rover:latest rover --version
```

## Build

```sh
task build -- rover
```
