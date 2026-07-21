# TypeScript Images

TypeScript/JavaScript runtime images powered by [Bun](https://bun.sh). Bun is used as the runtime, package manager, bundler, and test runner - it also executes TypeScript directly with no separate compile step.

## Variants

| Variant | Tag | Based on |
|---------|-----|----------|
| Alpine | `typescript:alpine` | our [base](../base/README.md) (Alpine) + musl-compatible Bun build |
| Debian | `typescript:debian` | our [base](../base/README.md) (Debian) + standard glibc Bun build |

Current version is pinned in [`buildargs.conf`](../../buildargs.conf) (`BUN_VERSION`).

## Tags

### Alpine tags

| Tag | Description |
|-----|-------------|
| `typescript:latest` | Most recent Bun on Alpine |
| `typescript:alpine` | Most recent Bun on Alpine |
| `typescript:<major>` | Major-version alias |
| `typescript:<major>.<minor>` | Minor-version alias |
| `typescript:<version>` | Exact pinned version |
| `typescript:<major>-alpine` | Major alias on Alpine |
| `typescript:<major>.<minor>-alpine` | Minor alias on Alpine |
| `typescript:<version>-alpine` | Exact version on Alpine |

### Debian tags

| Tag | Description |
|-----|-------------|
| `typescript:debian` | Most recent Bun on Debian |
| `typescript:<major>-debian` | Major alias on Debian |
| `typescript:<major>.<minor>-debian` | Minor alias on Debian |
| `typescript:<version>-debian` | Exact pinned version on Debian |

## What is included

### Tools

| Tool | Binary | Alpine | Debian | Source |
|------|--------|--------|--------|--------|
| [Bun](https://bun.sh) | `bun` | ✅ | ✅ | GitHub release, `BUN_VERSION` |

Bun runs TypeScript, JavaScript, JSX, and TSX files directly. This image does not create a `node` symlink to `bun` (the `agent` and `all-in-one` images do).

### Environment

| Variable | Value | Description |
|----------|-------|--------------|
| `BUN_INSTALL` | `/bun` | Bun global install prefix; `bun install -g` puts binaries here |
| `PATH` | prepends `/bun/bin` | Global Bun-installed binaries on PATH |

The Debian variant also inherits `DEBIAN_FRONTEND` from [base](../base/README.md).

### Default user

**Build image, not a hardened runtime base** — if you `FROM` this for a deployment image, set `USER` in your final stage (same as the official `golang`/`python` images).

Runs as **root (uid 0) by default**. A `nonroot` account (uid/gid 65532) still exists, and `/bun` is nonroot-owned, so `bun add -g` also works under `--user 65532`, landing the installed binary on PATH. `WORKDIR` is `/app`.

## Usage

Run unprivileged instead of the root default:

```sh
docker run --rm --user 65532 ghcr.io/pyck-ai/baseimages/typescript:latest bun --version
```

### As a build stage

```dockerfile
FROM ghcr.io/pyck-ai/baseimages/typescript:latest AS build
COPY package.json bun.lockb ./
RUN bun install --frozen-lockfile
COPY . .
RUN bun run build

FROM ghcr.io/pyck-ai/baseimages/static:latest
COPY --from=build /app/dist /app/dist
```

### Run a TypeScript file directly

```sh
docker run --rm \
  -v $(pwd):/app \
  ghcr.io/pyck-ai/baseimages/typescript:latest \
  bun run src/index.ts
```

### Run tests

```sh
docker run --rm \
  -v $(pwd):/app \
  ghcr.io/pyck-ai/baseimages/typescript:latest \
  bun test
```

## Build

```sh
task build -- typescript          # build both alpine and debian variants
task build -- typescript-alpine   # alpine only
task build -- typescript-debian   # debian only
```
