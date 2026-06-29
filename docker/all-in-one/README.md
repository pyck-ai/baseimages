# All-in-One Image

Image bundling the complete toolset into a single image. Available in Alpine and Debian flavours. Useful for CI jobs or dev containers that need everything without pulling and layering multiple images at runtime.

Prefer the individual images (`golang`, `typescript`, `rover`, `agents`, etc.) when only a subset of tools is needed — they are smaller and have cleaner dependency boundaries. Use this image when the overhead of that separation outweighs its benefits.

## Based on

Our [golang alpine image](../golang/README.md) (`latest`/`alpine`) or [golang debian image](../golang/README.md) (`debian`), which themselves build on our [base images](../slim/README.md).

## Tags

### Distro tags

| Tag | Description |
|-----|-------------|
| `all-in-one:latest` | Full toolset on Alpine (musl) |
| `all-in-one:alpine` | Full toolset on Alpine (musl) |
| `all-in-one:debian` | Full toolset on Debian (glibc) |

### Per-tool version tags

Each included tool gets a set of version tags in the form `<distro>-<tool>-<version>`, with major.minor and major aliases. Examples for Alpine 3 with Go 1.26.1 and Bun 1.2.3:

| Tag pattern | Example |
|-------------|---------|
| `all-in-one:alpine-<major>-golang-<version>` | `all-in-one:alpine-3-golang-1.26.1` |
| `all-in-one:alpine-<major>-bun-<version>` | `all-in-one:alpine-3-bun-1.2.3` |
| `all-in-one:alpine-<major>-claude-<version>` | `all-in-one:alpine-3-claude-1.2.3` |

The Debian variant also tags by Rover version:

| Tag pattern | Example |
|-------------|---------|
| `all-in-one:debian-<release>-golang-<version>` | `all-in-one:debian-trixie-golang-1.26.1` |
| `all-in-one:debian-<release>-rover-<version>` | `all-in-one:debian-trixie-rover-0.38.0` |
| `all-in-one:debian-<release>-bun-<version>` | `all-in-one:debian-trixie-bun-1.2.3` |
| `all-in-one:debian-<release>-claude-<version>` | `all-in-one:debian-trixie-claude-1.2.3` |

## What is included

Everything from the respective [golang image](../golang/README.md), plus:

| Tool | Binary | Alpine | Debian | Source |
|------|--------|--------|--------|--------|
| [Bun](https://bun.sh) | `bun` | musl | glibc | Binary copied from the `typescript` image, `BUN_VERSION` in `buildargs.conf` |
| [Rover](https://www.apollographql.com/docs/rover/) | `rover` | — | glibc | Binary copied from the `rover` image, `ROVER_VERSION` in `buildargs.conf` |
| [Claude Code](https://claude.ai/code) | `claude` | musl + shim | glibc | Binary copied from the `agents` image, `CLAUDE_VERSION` in `buildargs.conf` |

Rover is not included in the Alpine variant — it only ships glibc binaries, which are incompatible with Alpine's musl libc.

Refer to the [golang README](../golang/README.md) and [base README](../slim/README.md) for the full inherited toolset and environment variables.

### Additional environment variables

| Variable | Value | Description |
|----------|-------|-------------|
| `BUN_INSTALL` | `/bun` | Bun global install prefix |
| `PATH` | prepends `/bun/bin` | Global Bun-installed binaries on PATH |
| `LD_PRELOAD` | `/usr/local/lib/claude_fix.so` | Alpine only: `posix_getdents` shim for Claude |

### Default user

Runs as `root` (UID 0). `WORKDIR` is `/app`.

## Notes

- **Claude on Alpine**: Uses the musl build with a `posix_getdents` shim (`LD_PRELOAD=/usr/local/lib/claude_fix.so`). This is the same approach as the `agents` image.
- **Claude on Debian**: Uses the native glibc build — no `LD_PRELOAD` shim needed.

## Build

```sh
task build -- all-in-one          # both variants
task build -- all-in-one-alpine
task build -- all-in-one-debian
```
