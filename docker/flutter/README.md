# Flutter Image

A Flutter + Dart runtime image with a pre-installed RFW (Remote Flutter Widgets) validator and the AWS CLI. Supports both `linux/amd64` and `linux/arm64`.

## Variants

| Image | Based on | Tags |
|-------|----------|------|
| Alpine | our [alpine base](../base/README.md) | see below |
| Debian | our [debian base](../base/README.md) | see below |

Current version is defined in [`buildargs.conf`](../../buildargs.conf).

### Alpine tags

| Tag | Description |
|-----|-------------|
| `flutter:latest` | Most recent Flutter version (Alpine) |
| `flutter:alpine` | Most recent Flutter version (Alpine) |
| `flutter:<major>` | Major-version alias, e.g. `flutter:3` |
| `flutter:<major.minor>` | Minor-version alias, e.g. `flutter:3.38` |
| `flutter:<version>` | Exact pinned version, e.g. `flutter:3.38.1` |
| `flutter:<major>-alpine` | Major alias on Alpine, e.g. `flutter:3-alpine` |
| `flutter:<major.minor>-alpine` | Minor alias on Alpine, e.g. `flutter:3.38-alpine` |
| `flutter:<version>-alpine` | Exact version on Alpine, e.g. `flutter:3.38.1-alpine` |

### Debian tags

| Tag | Description |
|-----|-------------|
| `flutter:debian` | Most recent Flutter version (Debian) |
| `flutter:<major>-debian` | Major alias on Debian, e.g. `flutter:3-debian` |
| `flutter:<major.minor>-debian` | Minor alias on Debian, e.g. `flutter:3.38-debian` |
| `flutter:<version>-debian` | Exact version on Debian, e.g. `flutter:3.38.1-debian` |

## What is included

### Flutter toolchain

| Path | Alpine | Debian | Description |
|------|--------|--------|-------------|
| `/opt/flutter` | ✅ | ✅ | Full Flutter SDK (including bundled Dart SDK) |
| `/usr/local/bin/flutter` | ✅ | ✅ | Symlink to flutter binary |
| `/usr/local/bin/dart` | ✅ | ✅ | Symlink to dart binary |

Flutter analytics and Dart telemetry are disabled at build time.

### arm64 notes

Flutter only ships a Linux x86_64 release archive. For `linux/arm64` builds the image automatically:

1. Replaces the bundled x86_64 Dart SDK with an arm64 build downloaded from the Dart archive.
2. Clears pre-compiled snapshots and engine artifacts so Flutter regenerates them for arm64.
3. Runs `flutter precache` to download arm64 engine artifacts and recompile `flutter_tools.snapshot`.

The precache result is persisted in a BuildKit cache mount keyed by Flutter version + arch, so repeat arm64 builds restore in seconds rather than recompiling.

### RFW validator app

Pre-installed at `/opt/rfw-validator`. Validates Remote Flutter Widgets (RFW) files for syntax errors.

| File | Description |
|------|-------------|
| `/opt/rfw-validator/validate_rfw.dart` | Validates `.rfwtxt` (text) and `.rfw` (binary) files |
| `/opt/rfw-validator/generate_binary.dart` | Converts text RFW to binary format |
| `/usr/local/bin/validate-rfw` | Entrypoint script for simplified CLI use |

### Additional tools

| Binary | Path | Alpine | Debian | Description |
|--------|------|--------|--------|-------------|
| `aws` | `/usr/bin/aws` | ✅ | ✅ | AWS CLI for pushing build artefacts to S3/ECR from CI |

### Additional packages installed

| Package | Alpine | Debian | Purpose |
|---------|--------|--------|---------|
| AWS CLI | `aws-cli` | `awscli` | Cloud deployments from CI |
| gosu | `gosu` | `gosu` | Privilege drop in the entrypoint |
| OpenGL | `glu` | `libglu1-mesa` | Required by the Flutter engine |
| C++ runtime | _(via gcompat)_ | `libgcc-s1`, `libstdc++6` | Required by Flutter |

### Default user

Runs as `flutter` (UID 1000, home `/opt/flutter`). `WORKDIR` is `/app`.

## Build stages

The Dockerfile uses three stages to isolate the expensive Flutter SDK download from routine base image updates:

1. **`flutter-sdk`** (`FROM alpine`/`FROM debian`) — downloads the Flutter archive, fixes up the Dart SDK for arm64, and runs `flutter precache`. Only rebuilds when `FLUTTER_VERSION` changes.
2. **`rfw-validator`** (`FROM flutter-sdk`) — resolves pub dependencies for the RFW validator. Only rebuilds when `pubspec.yaml` or the Flutter version changes.
3. **RESULT** (`FROM alpine`/`FROM debian`) — installs system packages, creates the flutter user, and assembles the final image. Rebuilds on any base image update, but in seconds since no downloads are involved.

## Usage

### Validate an RFW file

```sh
docker run --rm \
  -v $(pwd):/app \
  ghcr.io/pyck-ai/baseimages/flutter:latest \
  validate-rfw /app/widgets.rfwtxt

docker run --rm \
  -v $(pwd):/app \
  ghcr.io/pyck-ai/baseimages/flutter:latest \
  validate-rfw /app/widgets.rfw
```

### Convert text RFW to binary format

```sh
docker run --rm \
  -v $(pwd):/app \
  -w /opt/rfw-validator \
  ghcr.io/pyck-ai/baseimages/flutter:latest \
  dart run generate_binary.dart /app/input.rfwtxt /app/output.rfw
```

### Use as a base for a Flutter app image

```dockerfile
FROM ghcr.io/pyck-ai/baseimages/flutter:latest
COPY --chown=flutter:flutter . /app
RUN /opt/flutter/bin/dart pub get
```

## Build

```sh
task build -- flutter           # both alpine and debian variants
task build -- flutter-alpine    # alpine only
task build -- flutter-debian    # debian only
```
