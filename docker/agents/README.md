# Agents Image

A container image bundling coding-agent CLIs — [Claude Code](https://claude.ai/code) and [opencode](https://opencode.ai) — pre-installed and ready to run as autonomous agents in CI pipelines or developer tooling.

## Variants

| Image | Based on | Tags |
|-------|----------|------|
| Alpine | our [alpine base](../slim/README.md) | see below |
| Debian | our [debian base](../slim/README.md) | see below |

The Alpine variant uses the musl Claude build with a `posix_getdents` compatibility shim, and the native musl opencode build. The Debian variant uses the standard glibc builds with no shim required.

Current versions are defined in [`buildargs.conf`](../../buildargs.conf) (`CLAUDE_VERSION`, `OPENCODE_VERSION`).

## Tags

Because the image ships more than one tool, version tags are namespaced per tool (`claude-…` and `opencode-…`), each with major.minor and major aliases. The floating `latest`/`alpine`/`debian` tags always track the most recent build of both.

### Alpine tags

| Tag | Description |
|-----|-------------|
| `agents:latest` | Most recent build (Alpine) |
| `agents:alpine` | Most recent build (Alpine) |
| `agents:claude-<version>` | Pinned Claude Code version, e.g. `agents:claude-2.1.195` (also `claude-<major>` / `claude-<major.minor>` aliases) |
| `agents:opencode-<version>` | Pinned opencode version, e.g. `agents:opencode-1.17.11` (also `opencode-<major>` / `opencode-<major.minor>` aliases) |
| `agents:claude-<version>-alpine` | Pinned Claude Code version on Alpine |
| `agents:opencode-<version>-alpine` | Pinned opencode version on Alpine |

### Debian tags

| Tag | Description |
|-----|-------------|
| `agents:debian` | Most recent build (Debian) |
| `agents:claude-<version>-debian` | Pinned Claude Code version on Debian (also major / major.minor aliases) |
| `agents:opencode-<version>-debian` | Pinned opencode version on Debian (also major / major.minor aliases) |

## What is included

### Software installed

| Binary | Path | Description |
|--------|------|-------------|
| `claude` | `/usr/local/bin/claude` | [Claude Code](https://claude.ai/code) CLI |
| `opencode` | `/usr/local/bin/opencode` | [opencode](https://opencode.ai) CLI |

### Alpine compatibility shim

The official Claude Code binaries reference `posix_getdents`, a symbol not provided by musl libc. A small C shim (`claude_fix.so`) is compiled and loaded via `LD_PRELOAD` to satisfy this dependency without requiring glibc. opencode ships a native musl build and needs no shim.

| File | Purpose |
|------|---------|
| `/usr/local/lib/claude_fix.so` | `posix_getdents` shim (Alpine only) |

### Environment variables

| Variable | Value | Description |
|----------|-------|-------------|
| `LD_PRELOAD` | `/usr/local/lib/claude_fix.so` | Alpine only: loads the musl compatibility shim for Claude |

### Default user

Runs as `nonroot` (UID/GID 65532). `WORKDIR` is `/app`.

## Usage

```sh
docker run --rm -it \
  -v $(pwd):/app \
  ghcr.io/pyck-ai/baseimages/agents:latest \
  claude --help
```

```sh
docker run --rm -it \
  -v $(pwd):/app \
  ghcr.io/pyck-ai/baseimages/agents:latest \
  opencode --help
```

To run Claude Code as an agent with an API key:

```sh
docker run --rm \
  -e ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}" \
  -v $(pwd):/app \
  ghcr.io/pyck-ai/baseimages/agents:latest \
  claude -p "describe this repo"
```

## Build

```sh
task build -- agents            # both alpine and debian variants
task build -- agents-alpine     # alpine only
task build -- agents-debian     # debian only
```
