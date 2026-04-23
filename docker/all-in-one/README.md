# All-in-One Image

Image bundling the complete toolset into a single image. Available in Alpine and Debian flavours. Useful for CI jobs or dev containers that need everything without pulling and layering multiple images at runtime.

Prefer the individual images (`golang`, `typescript`, `flutter`, `aws`, etc.) when only a subset of tools is needed — they are smaller and have cleaner dependency boundaries. Use this image when the overhead of that separation outweighs its benefits.

## Based on

Our [golang alpine image](../golang/README.md) (`latest`/`alpine`) or [golang debian image](../golang/README.md) (`debian`), which themselves build on our [base images](../slim/README.md).

## Tags

| Tag | Description |
|-----|-------------|
| `all-in-one:latest` | Full toolset on Alpine (musl) |
| `all-in-one:alpine` | Full toolset on Alpine (musl) |
| `all-in-one:debian` | Full toolset on Debian (glibc) |

## What is included

Everything from the respective [golang image](../golang/README.md), plus:

| Tool | Binary | Alpine | Debian | Source |
|------|--------|--------|--------|--------|
| [Flutter](https://flutter.dev) | `flutter` | glibc via gcompat | glibc | SDK copied from the `flutter` image, `FLUTTER_VERSION` in `buildargs.conf` |
| [Dart](https://dart.dev) | `dart` | glibc via gcompat | glibc | Bundled with the Flutter SDK |
| [Bun](https://bun.sh) | `bun` | musl | glibc | `BUN_VERSION` in `buildargs.conf` |
| [Rover](https://www.apollographql.com/docs/rover/) | `rover` | glibc via gcompat | glibc | Copied from the `rover` image, `ROVER_VERSION` in `buildargs.conf` |
| [Claude Code](https://claude.ai/code) | `claude` | musl + shim | glibc | `CLAUDE_VERSION` in `buildargs.conf` |
| [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/) | `aws` | apk package | apt package | Version tracks `ALPINE_VERSION` / `DEBIAN_RELEASE` |

Refer to the [golang README](../golang/README.md) and [base README](../slim/README.md) for the full inherited toolset and environment variables.

### Additional environment variables

| Variable | Value | Description |
|----------|-------|-------------|
| `BUN_INSTALL` | `/bun` | Bun global install prefix |
| `PATH` | prepends `/bun/bin` | Global Bun-installed binaries on PATH |
| `LD_PRELOAD` | `/usr/local/lib/claude_fix.so` | Alpine only: `posix_getdents` shim for Claude |

### Flutter SDK location

| Path | Description |
|------|-------------|
| `/opt/flutter` | Flutter SDK root (owned by nonroot, UID/GID 65532) |
| `/usr/local/bin/flutter` | Symlink to flutter binary |
| `/usr/local/bin/dart` | Symlink to dart binary |

The RFW validator app and `validate-rfw` entrypoint from the `flutter` image are not included — only the SDK binaries are present.

### Default user

Runs as `nonroot` (UID/GID 65532). `WORKDIR` is `/app`.

## Notes

- **Flutter cache**: `/opt/flutter` is owned by `nonroot` so flutter can write to its cache at runtime. The arm64 precache is pre-warmed (copied from the `flutter` image build).
- **Claude on Alpine**: Uses the musl build with a `posix_getdents` shim (`LD_PRELOAD=/usr/local/lib/claude_fix.so`). This is the same approach as the `claude` image.
- **Claude on Debian**: Uses the native glibc build — no `LD_PRELOAD` shim needed.
- **Rover**: Only ships glibc builds. On Alpine the binary runs via the `gcompat` shim present in the base image; on Debian it runs natively.

## Build

```sh
task build -- all-in-one          # both variants
task build -- all-in-one-alpine
task build -- all-in-one-debian
```
