# Agent Image

A container image bundling coding-agent CLIs — [Claude Code](https://claude.ai/code), [opencode](https://opencode.ai), and [pi](https://github.com/earendil-works/pi) — pre-installed and ready to run as autonomous agents in CI pipelines or developer tooling.

## Variants

| Variant | Tag | Based on |
|---------|-----|----------|
| Alpine | `agent:alpine` | our [base](../base/README.md) (Alpine) — musl Claude build with a `posix_getdents` compatibility shim, native musl opencode build |
| Debian | `agent:debian` | our [base](../base/README.md) (Debian) — glibc Claude and opencode builds, no shim required |

Both variants install the Bun runtime that powers pi (see [Bun runtime and Node compatibility](#bun-runtime-and-node-compatibility)). Current versions are defined in [`buildargs.conf`](../../buildargs.conf) (`CLAUDE_VERSION`, `OPENCODE_VERSION`, `PI_VERSION`, `BUN_VERSION`).

## Tags

Because the image ships more than one tool, version tags are namespaced per tool (`claude-…`, `opencode-…`, and `pi-…`), each with major.minor and major aliases. The floating `latest`/`alpine`/`debian` tags always track the most recent build of all three.

### Alpine tags

| Tag | Description |
|-----|-------------|
| `agent:latest` | Most recent build (Alpine) |
| `agent:alpine` | Most recent build (Alpine) |
| `agent:claude-<version>` | Pinned Claude Code version (also `claude-<major>` / `claude-<major.minor>` aliases) |
| `agent:opencode-<version>` | Pinned opencode version (also `opencode-<major>` / `opencode-<major.minor>` aliases) |
| `agent:pi-<version>` | Pinned pi version (also `pi-<major>` / `pi-<major.minor>` aliases) |
| `agent:claude-<version>-alpine` | Pinned Claude Code version on Alpine |
| `agent:opencode-<version>-alpine` | Pinned opencode version on Alpine |
| `agent:pi-<version>-alpine` | Pinned pi version on Alpine |

### Debian tags

| Tag | Description |
|-----|-------------|
| `agent:debian` | Most recent build (Debian) |
| `agent:claude-<version>-debian` | Pinned Claude Code version on Debian (also major / major.minor aliases) |
| `agent:opencode-<version>-debian` | Pinned opencode version on Debian (also major / major.minor aliases) |
| `agent:pi-<version>-debian` | Pinned pi version on Debian (also major / major.minor aliases) |

## What is included

### Alpine compatibility shim

The official Claude Code binaries reference `posix_getdents`, a symbol not provided by musl libc. A small C shim (`claude_fix.so`) is compiled and loaded via `LD_PRELOAD` to satisfy this dependency without requiring glibc. opencode ships a native musl build and needs no shim.

| File | Purpose |
|------|---------|
| `/usr/local/lib/claude_fix.so` | `posix_getdents` shim (Alpine only) |

### Bun runtime and Node compatibility

pi is a JavaScript CLI installed with `bun add -g --ignore-scripts` into `/bun` (`BUN_INSTALL`), which places its binary on `PATH` at `/bun/bin/pi` (also symlinked to `/usr/local/bin/pi`). That binary is a `#!/usr/bin/env node` script, and the image ships no separate Node.js runtime — so `node` is symlinked to `bun`, which runs the script in Node-compatibility mode. Both variants use the same Bun build as the [`typescript`](../typescript/README.md) image.

### Tools

| Tool | Binary | Alpine | Debian | Source |
|------|--------|--------|--------|--------|
| [Claude Code](https://claude.ai/code) | `claude` | ✅ | ✅ | GCS release, `CLAUDE_VERSION` |
| [opencode](https://opencode.ai) | `opencode` | ✅ | ✅ | GitHub release, `OPENCODE_VERSION` |
| [pi](https://github.com/earendil-works/pi) | `pi` | ✅ | ✅ | Bun global install (`/bun/bin/pi`, symlinked to `/usr/local/bin/pi`), `PI_VERSION` |
| [Bun](https://bun.sh) | `bun` | ✅ | ✅ | GitHub release, `BUN_VERSION` |
| Node compatibility | `node` → `bun` | ✅ | ✅ | Symlink so pi's `#!/usr/bin/env node` entrypoint runs under Bun |

### Environment

| Variable | Value | Description |
|----------|-------|--------------|
| `LD_PRELOAD` | `/usr/local/lib/claude_fix.so` | Alpine only: loads the musl compatibility shim for Claude |
| `BUN_INSTALL` | `/bun` | Bun global install prefix; `bun add -g` binaries land in `/bun/bin` |
| `PATH` | prepends `/bun/bin` | Global Bun-installed binaries (e.g. `pi`) on PATH |

The Debian variant also inherits `DEBIAN_FRONTEND` from [base](../base/README.md).

### Default user

**Build image, not a hardened runtime base** — if you `FROM` this for a deployment image, set `USER` in your final stage (same as the official `golang`/`python` images).

Runs as **root (uid 0) by default**. A `nonroot` account (uid/gid 1001) still exists, and `/bun` is nonroot-owned, so `bun add -g` also works under `--user 1001`, landing the resulting binary on `PATH`. `WORKDIR` is `/app`.

## Usage

Run unprivileged instead of the root default:

```sh
docker run --rm --user 1001 ghcr.io/pyck-ai/baseimages/agent:latest claude --version
```

```sh
docker run --rm -it \
  -v $(pwd):/app \
  ghcr.io/pyck-ai/baseimages/agent:latest \
  claude --help
```

```sh
docker run --rm -it \
  -v $(pwd):/app \
  ghcr.io/pyck-ai/baseimages/agent:latest \
  opencode --help
```

```sh
docker run --rm -it \
  -v $(pwd):/app \
  ghcr.io/pyck-ai/baseimages/agent:latest \
  pi --help
```

To run Claude Code as an agent with an API key:

```sh
docker run --rm \
  -e ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}" \
  -v $(pwd):/app \
  ghcr.io/pyck-ai/baseimages/agent:latest \
  claude -p "describe this repo"
```

## Build

```sh
task build -- agent            # both alpine and debian variants
task build -- agent-alpine     # alpine only
task build -- agent-debian     # debian only
```
