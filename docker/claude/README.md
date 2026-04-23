# Claude Code Image

A container image with [Claude Code](https://claude.ai/code) (the Anthropic CLI) pre-installed, ready to run as an autonomous agent in CI pipelines or developer tooling.

## Variants

| Image | Based on | Tags |
|-------|----------|------|
| Alpine | our [alpine base](../slim/README.md) | see below |
| Debian | our [debian base](../slim/README.md) | see below |

The Alpine variant uses the musl Claude build with a `posix_getdents` compatibility shim. The Debian variant uses the standard glibc build with no shim required.

Current version is defined in [`buildargs.conf`](../../buildargs.conf).

### Alpine tags

| Tag | Description |
|-----|-------------|
| `claude:latest` | Most recent Claude Code version (Alpine) |
| `claude:alpine` | Most recent Claude Code version (Alpine) |
| `claude:<major>` | Major-version alias, e.g. `claude:1` |
| `claude:<major.minor>` | Minor-version alias, e.g. `claude:1.2` |
| `claude:<version>` | Exact pinned version, e.g. `claude:1.2.3` |
| `claude:<major>-alpine` | Major alias on Alpine, e.g. `claude:1-alpine` |
| `claude:<major.minor>-alpine` | Minor alias on Alpine, e.g. `claude:1.2-alpine` |
| `claude:<version>-alpine` | Exact version on Alpine, e.g. `claude:1.2.3-alpine` |

### Debian tags

| Tag | Description |
|-----|-------------|
| `claude:debian` | Most recent Claude Code version (Debian) |
| `claude:<major>-debian` | Major alias on Debian, e.g. `claude:1-debian` |
| `claude:<major.minor>-debian` | Minor alias on Debian, e.g. `claude:1.2-debian` |
| `claude:<version>-debian` | Exact pinned version on Debian, e.g. `claude:1.2.3-debian` |

## What is included

### Software installed

| Binary | Path | Description |
|--------|------|-------------|
| `claude` | `/usr/local/bin/claude` | Claude Code CLI |

### Alpine compatibility shim

The official Claude Code binaries reference `posix_getdents`, a symbol not provided by musl libc. A small C shim (`claude_fix.so`) is compiled and loaded via `LD_PRELOAD` to satisfy this dependency without requiring glibc.

| File | Purpose |
|------|---------|
| `/usr/local/lib/claude_fix.so` | `posix_getdents` shim (Alpine only) |

### Environment variables

| Variable | Value | Description |
|----------|-------|-------------|
| `LD_PRELOAD` | `/usr/local/lib/claude_fix.so` | Alpine only: loads the musl compatibility shim |

### Default user

Runs as `nonroot` (UID/GID 65532). `WORKDIR` is `/app`.

## Usage

```sh
docker run --rm -it \
  -v $(pwd):/app \
  ghcr.io/pyck-ai/baseimages/claude:latest \
  claude --help
```

To run as an agent with API key:

```sh
docker run --rm \
  -e ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}" \
  -v $(pwd):/app \
  ghcr.io/pyck-ai/baseimages/claude:latest \
  claude -p "describe this repo"
```

## Build

```sh
task build -- claude            # both alpine and debian variants
task build -- claude-alpine     # alpine only
task build -- claude-debian     # debian only
```
