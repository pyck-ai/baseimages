# All-in-One Image

Image bundling the complete developer-tooling set into a single image, available in Alpine and Debian flavours. Intended for local development where pulling and layering many individual images isn't worth it — **not** for CI, due to its size and attack surface.

Prefer the individual images (`golang`, `typescript`, `rover`, `agent`, etc.) when only a subset of tools is needed — they are smaller and have cleaner dependency boundaries. Use this image when the overhead of that separation outweighs its benefits.

## Based on

Our [base image](../base/README.md): `base:alpine` for the Alpine variant (`latest`/`alpine`), `base:debian` for the Debian variant (`debian`). Each bundled tool is copied in from its dedicated image (`golang`, `typescript`, `agent`, and on Debian also `rover` and `python`) rather than inherited through a parent image.

## Tags

### Distro tags

| Tag | Description |
|-----|-------------|
| `all-in-one:latest` | Full toolset on Alpine (musl) |
| `all-in-one:alpine` | Full toolset on Alpine (musl) |
| `alpine:latest` | Alias for `all-in-one:alpine` (the whole toolset published under the bare `alpine` repo name) |
| `all-in-one:debian` | Full toolset on Debian (glibc) |
| `debian:latest` | Alias for `all-in-one:debian` (the whole toolset published under the bare `debian` repo name) |

### Per-tool version tags

Each included tool gets version tags of the form `<distro>-<tool>-<version>`, and **every version comes in three forms** — the full version, the `<major.minor>` alias, and the `<major>` alias — so you can pin as loosely or tightly as you like. For example, pi on Alpine produces all three of:

- `all-in-one:alpine-3-pi-0.80.10` — exact version
- `all-in-one:alpine-3-pi-0.80` — latest `0.80.x`
- `all-in-one:alpine-3-pi-0` — latest `0.x`

The per-tool tag patterns are below; `<version>` in each stands for any of those three forms:

| Tag pattern | Example |
|-------------|---------|
| `all-in-one:alpine-<major>-golang-<version>` | `all-in-one:alpine-3-golang-1.26.1` |
| `all-in-one:alpine-<major>-bun-<version>` | `all-in-one:alpine-3-bun-1.2.3` |
| `all-in-one:alpine-<major>-claude-<version>` | `all-in-one:alpine-3-claude-1.2.3` |
| `all-in-one:alpine-<major>-opencode-<version>` | `all-in-one:alpine-3-opencode-1.2.3` |
| `all-in-one:alpine-<major>-pi-<version>` | `all-in-one:alpine-3-pi-0.80.10` |
| `all-in-one:alpine-<major>-python-<version>` | `all-in-one:alpine-3-python-3.14` |

The Debian variant also tags by Rover version:

| Tag pattern | Example |
|-------------|---------|
| `all-in-one:debian-<release>-golang-<version>` | `all-in-one:debian-trixie-golang-1.26.1` |
| `all-in-one:debian-<release>-rover-<version>` | `all-in-one:debian-trixie-rover-0.38.0` |
| `all-in-one:debian-<release>-bun-<version>` | `all-in-one:debian-trixie-bun-1.2.3` |
| `all-in-one:debian-<release>-claude-<version>` | `all-in-one:debian-trixie-claude-1.2.3` |
| `all-in-one:debian-<release>-opencode-<version>` | `all-in-one:debian-trixie-opencode-1.2.3` |
| `all-in-one:debian-<release>-pi-<version>` | `all-in-one:debian-trixie-pi-0.80.10` |
| `all-in-one:debian-<release>-python-<version>` | `all-in-one:debian-trixie-python-3.13` |

## What is included

The complete developer-tooling set, each copied in from its dedicated image on top of the `base` image:

| Tool | Binary | Alpine | Debian | Source |
|------|--------|--------|--------|--------|
| [Go](https://go.dev) toolchain (+ delve, golangci-lint, gotestsum, go-arch-lint) | `go`, `gofmt`, `dlv`, `golangci-lint`, `gotestsum`, `go-arch-lint` | ✅ | ✅ | Copied from the `golang` image; `GOLANG_VERSION` + per-tool versions in `buildargs.conf` |
| [Bun](https://bun.sh) | `bun` | ✅ | ✅ | Binary copied from the `typescript` image, `BUN_VERSION` in `buildargs.conf` |
| [Rover](https://www.apollographql.com/docs/rover/) | `rover` | ❌ ¹ | ✅ | Binary copied from the `rover` image, `ROVER_VERSION` in `buildargs.conf` |
| [Claude Code](https://claude.ai/code) | `claude` | ✅ | ✅ | Binary copied from the `agent` image, `CLAUDE_VERSION` in `buildargs.conf` |
| [opencode](https://opencode.ai) | `opencode` | ✅ | ✅ | Binary copied from the `agent` image, `OPENCODE_VERSION` in `buildargs.conf` |
| [pi](https://github.com/earendil-works/pi) | `pi` | ✅ | ✅ | Bun global install copied from the `agent` image, `PI_VERSION` in `buildargs.conf` |
| [Python](https://www.python.org) (+ [uv](https://github.com/astral-sh/uv), [Ruff](https://github.com/astral-sh/ruff)) | `python`, `uv`, `uvx`, `ruff` | ✅ | ✅ | Copied from the `python` image, `PYTHON_VERSION` / `UV_VERSION` / `RUFF_VERSION` in `buildargs.conf` |

Go, Bun, Claude Code, opencode, pi, and Python are present in both variants (on Alpine, Claude Code runs via the `posix_getdents` shim — see [Notes](#notes)).

> ¹ Rover only publishes glibc binaries, so it is absent from the Alpine (musl) variant.

The Go environment (`GOPATH`, `GOPROXY`, `CGO_ENABLED=0`, `GOCACHE`, `GOMODCACHE`) is set identically to the [`golang` image](../golang/README.md). See the [base README](../base/README.md) for the inherited base toolset and environment, and each tool's own image README (linked in the table above) for tool-specific details.

### Additional environment variables

| Variable | Value | Description |
|----------|-------|-------------|
| `BUN_INSTALL` | `/bun` | Bun global install prefix |
| `PATH` | prepends `/bun/bin` | Global Bun-installed binaries on PATH |
| `LD_PRELOAD` | `/usr/local/lib/claude_fix.so` | Alpine only: `posix_getdents` shim for Claude |
| `UV_PYTHON_INSTALL_DIR` | `/usr/local/python` | Debian only: where uv's managed Python lives |
| `UV_PYTHON_PREFERENCE` | `only-managed` | Debian only: always use the uv-managed Python |
| `PYTHONDONTWRITEBYTECODE` | `1` | Debian only: suppress `.pyc` generation |
| `PYTHONUNBUFFERED` | `1` | Debian only: unbuffered stdout/stderr |

### Default user

Runs as `root` (UID 0). `WORKDIR` is `/app`.

## Notes

- **Claude on Alpine**: Uses the musl build with a `posix_getdents` shim (`LD_PRELOAD=/usr/local/lib/claude_fix.so`). This is the same approach as the `agent` image.
- **Claude on Debian**: Uses the native glibc build — no `LD_PRELOAD` shim needed.
- **pi**: A JavaScript CLI copied from the `agent` image as a Bun global install under `/bun`. Its binary is a `#!/usr/bin/env node` script, so `node` is symlinked to `bun` (which runs it in Node-compatibility mode); no separate Node.js runtime is installed.

## Build

```sh
task build -- all-in-one          # both variants
task build -- all-in-one-alpine
task build -- all-in-one-debian
```
