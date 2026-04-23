# Claude Code Image

A container image with [Claude Code](https://claude.ai/code) (the Anthropic CLI) pre-installed, ready to run as an autonomous agent in CI pipelines or developer tooling.

## Based on

Our [alpine base image](../slim/README.md).

Current version is defined in [`buildargs.conf`](../../buildargs.conf).

## Tags

| Tag | Description |
|-----|-------------|
| `claude:latest` | Latest Claude Code version |
| `claude:<version>` | Pinned version |

## What is included

### Software installed

| Binary | Path | Description |
|--------|------|-------------|
| `claude` | `/usr/local/bin/claude` | Claude Code CLI |

### Alpine compatibility shim

The official Claude Code binaries reference `posix_getdents`, a symbol not provided by musl libc. A small C shim (`claude_fix.so`) is compiled and loaded via `LD_PRELOAD` to satisfy this dependency without requiring glibc.

| File | Purpose |
|------|---------|
| `/usr/local/lib/claude_fix.so` | `posix_getdents` shim |

### Environment variables

| Variable | Value | Description |
|----------|-------|-------------|
| `LD_PRELOAD` | `/usr/local/lib/claude_fix.so` | Loads the musl compatibility shim |

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
task build -- claude
```
