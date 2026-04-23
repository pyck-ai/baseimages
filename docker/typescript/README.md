# TypeScript Images

TypeScript/JavaScript runtime images powered by [Bun](https://bun.sh). Bun is used as the runtime, package manager, bundler, and test runner — it also executes TypeScript directly with no separate compile step.

## Variants

| Image | Based on | Tags |
|-------|----------|------|
| Alpine | our [alpine base](../slim/README.md) | see below |
| Debian | our [debian base](../slim/README.md) | see below |

The Alpine variant uses the musl-compatible Bun build. The Debian variant uses the standard glibc build.

Current version is defined in [`buildargs.conf`](../../buildargs.conf).

### Alpine tags

| Tag | Description |
|-----|-------------|
| `typescript:latest` | Most recent Bun on Alpine |
| `typescript:alpine` | Most recent Bun on Alpine |
| `typescript:<major>` | Major-version alias, e.g. `typescript:1` |
| `typescript:<major.minor>` | Minor-version alias, e.g. `typescript:1.2` |
| `typescript:<version>` | Exact pinned version, e.g. `typescript:1.2.3` |
| `typescript:<major>-alpine` | Major alias on Alpine, e.g. `typescript:1-alpine` |
| `typescript:<major.minor>-alpine` | Minor alias on Alpine, e.g. `typescript:1.2-alpine` |
| `typescript:<version>-alpine` | Exact version on Alpine, e.g. `typescript:1.2.3-alpine` |

### Debian tags

| Tag | Description |
|-----|-------------|
| `typescript:debian` | Most recent Bun on Debian |
| `typescript:<major>-debian` | Major alias on Debian, e.g. `typescript:1-debian` |
| `typescript:<major.minor>-debian` | Minor alias on Debian, e.g. `typescript:1.2-debian` |
| `typescript:<version>-debian` | Exact pinned version on Debian, e.g. `typescript:1.2.3-debian` |

## What is included

### Bun

| Binary | Path | Description |
|--------|------|-------------|
| `bun` | `/usr/local/bin/bun` | Runtime, package manager, bundler, and test runner |

Bun runs TypeScript, JavaScript, JSX, and TSX files directly.

### Environment

| Variable | Value | Description |
|----------|-------|-------------|
| `BUN_INSTALL` | `/bun` | Bun global install prefix; `bun install -g` puts binaries here |
| `PATH` | prepends `/bun/bin` | Global Bun-installed binaries on PATH |

### Default user

Runs as `nonroot` (UID/GID 65532). `WORKDIR` is `/app`.

## Usage

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
