# RFW Validator Tools

Remote Flutter Widgets (RFW) validator for syntax checking widget files.

Supports both **text format** (`.rfwtxt`) and **binary format** (`.rfw`). Binary format is 10x faster to parse and recommended for production use.

## Quick Test

Test the validator with the example widget:

```bash
task test:flutter
```

Or manually:

```bash
docker run --rm \
  -v $(pwd)/flutter:/workspace:z \
  ghcr.io/pyck-ai/baseimages/flutter:latest \
  validate-rfw example.dart
```

## Usage

### Validate RFW files (text or binary):

```bash
# Validate text format
docker run --rm \
  -v $(pwd):/workspace:z \
  ghcr.io/pyck-ai/baseimages/flutter:latest \
  validate-rfw dist/widgets.rfwtxt

# Validate binary format (auto-detected)
docker run --rm \
  -v $(pwd):/workspace:z \
  ghcr.io/pyck-ai/baseimages/flutter:latest \
  validate-rfw dist/widgets.rfw
```

### Convert text to binary format:

```bash
docker run --rm \
  -v $(pwd):/workspace:z \
  -w /opt/rfw-validator \
  ghcr.io/pyck-ai/baseimages/flutter:latest \
  bash -c "dart run generate_binary.dart /workspace/input.rfwtxt /workspace/output.rfw"
```

### Run bash instead:

```bash
docker run --rm -it \
  -v $(pwd):/workspace:z \
  ghcr.io/pyck-ai/baseimages/flutter:latest \
  bash
```

### Previous complex command (now simplified):

Before:
```bash
docker run --rm \
  -v $(pwd):/workspace:z \
  -w /workspace/tools \
  ghcr.io/pyck-ai/baseimages/flutter:latest \
  bash -c "dart pub get && dart run validate_rfw.dart ../dist/widgets.dart"
```

After:
```bash
docker run --rm \
  -v $(pwd):/workspace:z \
  ghcr.io/pyck-ai/baseimages/flutter:latest \
  validate-rfw dist/widgets.dart
```

## What's included

- `validate_rfw.dart` - RFW syntax validator (supports both text and binary formats)
- `generate_binary.dart` - Converts text RFW files to binary format
- `pubspec.yaml` - Dependencies (rfw package)
- `entrypoint.sh` - Entrypoint script for simplified commands
- `example.dart` - Example RFW widget file for testing (text format)
