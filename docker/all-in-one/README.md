# All-in-One Image

Image bundling the complete developer-tooling set into a single image, available in Alpine and Debian flavours. Intended for local development where pulling and layering many individual images isn't worth it — **not** for CI, due to its size and attack surface.

Prefer the individual images (`golang`, `typescript`, `rover`, `agent`, etc.) when only a subset of tools is needed — they are smaller and have cleaner dependency boundaries. Use this image when the overhead of that separation outweighs its benefits.

## Variants

| Variant | Tag | Based on |
|---------|-----|----------|
| Alpine | `all-in-one:latest` / `all-in-one:alpine` | our [base](../base/README.md) (Alpine) |
| Debian | `all-in-one:debian` | our [base](../base/README.md) (Debian) |

## Tags

### Distro tags

| Tag | Description |
|-----|-------------|
| `all-in-one:latest` | Full toolset on Alpine (musl) |
| `all-in-one:alpine` | Full toolset on Alpine (musl) |
| `all-in-one:debian` | Full toolset on Debian (glibc) |

### Per-tool version tags

Each included tool gets version tags of the form `<distro>-<tool>-<version>`, and **every version comes in up to three forms** — the full version, the `<major>.<minor>` alias, and the `<major>` alias (for two-part versions such as Python's, the first two coincide) — so you can pin as loosely or tightly as you like. For example, pi on Alpine produces all three of:

- `all-in-one:alpine-<major>-pi-<version>` — exact version
- `all-in-one:alpine-<major>-pi-<major.minor>` — latest `<major.minor>.x`
- `all-in-one:alpine-<major>-pi-<major>` — latest `<major>.x`

The per-tool tag patterns are below; `<version>` in each stands for any of those forms:

| Tag pattern |
|-------------|
| `all-in-one:alpine-<major>-golang-<version>` |
| `all-in-one:alpine-<major>-bun-<version>` |
| `all-in-one:alpine-<major>-claude-<version>` |
| `all-in-one:alpine-<major>-opencode-<version>` |
| `all-in-one:alpine-<major>-pi-<version>` |
| `all-in-one:alpine-<major>-python-<version>` |

The Debian variant also tags by Rover version:

| Tag pattern |
|-------------|
| `all-in-one:debian-<release>-golang-<version>` |
| `all-in-one:debian-<release>-rover-<version>` |
| `all-in-one:debian-<release>-bun-<version>` |
| `all-in-one:debian-<release>-claude-<version>` |
| `all-in-one:debian-<release>-opencode-<version>` |
| `all-in-one:debian-<release>-pi-<version>` |
| `all-in-one:debian-<release>-python-<version>` |

## What is included

The complete developer-tooling set, each copied in from its dedicated image on top of the `base` image (`golang`, `typescript`, `agent`, `python`, and on Debian also `rover`) rather than inherited through a parent image. `rover` is Debian-only, so it is the only tool absent from the Alpine variant.

### Tools

| Tool | Binary | Alpine | Debian | Source |
|------|--------|--------|--------|--------|
| [Go](https://go.dev) toolchain (+ delve, golangci-lint, gotestsum, go-arch-lint) | `go`, `gofmt`, `dlv`, `golangci-lint`, `gotestsum`, `go-arch-lint` | ✅ | ✅ | Copied from the `golang` image; `GOLANG_VERSION` + per-tool versions in `buildargs.conf` |
| [Bun](https://bun.sh) | `bun` | ✅ | ✅ | Binary copied from the `typescript` image, `BUN_VERSION` in `buildargs.conf` |
| Node compatibility | `node` → `bun` | ✅ | ✅ | Symlink so pi's `#!/usr/bin/env node` entrypoint runs under Bun |
| [Claude Code](https://claude.ai/code) | `claude` | ✅ | ✅ | Binary copied from the `agent` image, `CLAUDE_VERSION` in `buildargs.conf` |
| [opencode](https://opencode.ai) | `opencode` | ✅ | ✅ | Binary copied from the `agent` image, `OPENCODE_VERSION` in `buildargs.conf` |
| [pi](https://github.com/earendil-works/pi) | `pi` | ✅ | ✅ | Its own `bun add -g` install (see [Notes](#notes)), `PI_VERSION` in `buildargs.conf` |
| [Rover](https://www.apollographql.com/docs/rover/) | `rover` | ❌ ¹ | ✅ | Binary copied from the `rover` image, `ROVER_VERSION` in `buildargs.conf` |
| [Python](https://www.python.org) (+ [uv](https://github.com/astral-sh/uv), [Ruff](https://github.com/astral-sh/ruff)) | `python`, `uv`, `uvx`, `ruff` | ✅ | ✅ | Copied from the `python` image, `PYTHON_VERSION` / `UV_VERSION` / `RUFF_VERSION` in `buildargs.conf` |

Go, Bun, Claude Code, opencode, pi, and Python are present in both variants (on Alpine, Claude Code runs via the `posix_getdents` shim — see [Notes](#notes)).

> ¹ Rover only publishes glibc binaries, so it is absent from the Alpine (musl) variant.

See the [base README](../base/README.md) for the inherited base toolset and environment, and each tool's own image README — [`golang`](../golang/README.md), [`typescript`](../typescript/README.md), [`agent`](../agent/README.md), [`python`](../python/README.md), and [`rover`](../rover/README.md) — for tool-specific details.

### Environment

| Variable | Value | Description |
|----------|-------|--------------|
| `GOPATH` | `/go` | Standard Go workspace |
| `PATH` | prepends `/bun/bin:/usr/local/go/bin:/go/bin` | Global Bun-installed binaries, `go`, and Go-installed binaries on PATH |
| `GOCACHE` | `/var/cache/go/` | Build cache |
| `GOMODCACHE` | `/go/pkg/mod/` | Module cache |
| `GOPROXY` | `https://go.pyck.cloud,direct` | Internal Go module proxy with fallback to direct |
| `CGO_ENABLED` | `0` | Statically-linked builds by default; set to `1` explicitly for cgo |
| `BUN_INSTALL` | `/bun` | Bun global install prefix |
| `LD_PRELOAD` | `/usr/local/lib/claude_fix.so` | Alpine only: `posix_getdents` shim for Claude |
| `UV_PYTHON_INSTALL_DIR` | `/usr/local/python` | Where uv's managed Python lives |
| `UV_PYTHON_PREFERENCE` | `only-managed` | Always use the uv-managed Python |
| `PYTHONDONTWRITEBYTECODE` | `1` | Suppress `.pyc` generation |
| `PYTHONUNBUFFERED` | `1` | Unbuffered stdout/stderr |

### Default user

**Build image, not a hardened runtime base** — if you `FROM` this for a deployment image, set `USER` in your final stage (same as the official `golang`/`python` images).

Runs as **root (uid 0) by default**. A `nonroot` account (uid/gid 1001) still exists, and `/go`, `/bun`, and `/usr/local/python` are all nonroot-owned, so `go build`, `go install`, `bun add -g`, and `uv` also work under `--user 1001`. `WORKDIR` is `/app`.

## Usage

As a local-development image, mount a project directory and run whichever toolchain you need:

```sh
docker run --rm -it \
  -v $(pwd):/app \
  ghcr.io/pyck-ai/baseimages/all-in-one:latest \
  bash
```

Run unprivileged instead of the root default:

```sh
docker run --rm --user 1001 ghcr.io/pyck-ai/baseimages/all-in-one:latest go version
```

```sh
docker run --rm \
  -v $(pwd):/app \
  ghcr.io/pyck-ai/baseimages/all-in-one:latest \
  go test ./...
```

```sh
docker run --rm \
  -e ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}" \
  -v $(pwd):/app \
  ghcr.io/pyck-ai/baseimages/all-in-one:latest \
  claude -p "describe this repo"
```

## Notes

- **Claude on Alpine**: Uses the musl build with a `posix_getdents` shim (`LD_PRELOAD=/usr/local/lib/claude_fix.so`). This is the same approach as the `agent` image.
- **Claude on Debian**: Uses the native glibc build — no `LD_PRELOAD` shim needed.
- **pi**: A JavaScript CLI installed with its own `bun add -g` under `/bun` (copying it from the `agent` image would clash with the Bun install taken from the `typescript` image). Its binary is a `#!/usr/bin/env node` script, so `node` is symlinked to `bun` (which runs it in Node-compatibility mode); no separate Node.js runtime is installed.

## Build

```sh
task build -- all-in-one          # both variants
task build -- all-in-one-alpine
task build -- all-in-one-debian
```
