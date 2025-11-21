#!/bin/bash
set -euo pipefail

if [ "$(uname -m)" = "aarch64" ]; then
    echo "Detected ARM64 architecture - replacing Dart SDK with ARM64 version"
    cd /tmp

    # Get Dart version from Flutter releases metadata
    DART_VERSION_RAW=$(grep -A 10 "flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" releases.json 2>/dev/null | grep '"dart_sdk_version"' | cut -d'"' -f4 | head -1)

    # Extract version and determine channel (stable/beta/dev)
    if echo "$DART_VERSION_RAW" | grep -q "beta"; then
        DART_VERSION=$(echo "$DART_VERSION_RAW" | sed 's/.*build //' | sed 's/).*//')
        DART_CHANNEL="beta"
    elif echo "$DART_VERSION_RAW" | grep -q "dev"; then
        DART_VERSION=$(echo "$DART_VERSION_RAW" | sed 's/.*build //' | sed 's/).*//')
        DART_CHANNEL="dev"
    else
        DART_VERSION=$(echo "$DART_VERSION_RAW" | awk '{print $1}')
        DART_CHANNEL="stable"
    fi

    echo "Downloading Dart SDK ${DART_VERSION} from ${DART_CHANNEL} channel for ARM64"
    curl -fsSL "https://storage.googleapis.com/dart-archive/channels/${DART_CHANNEL}/release/${DART_VERSION}/sdk/dartsdk-linux-arm64-release.zip" -o dart-sdk-arm64.zip

    # Backup and replace the Dart SDK
    rm -rf /opt/flutter/bin/cache/dart-sdk
    unzip -q dart-sdk-arm64.zip -d /opt/flutter/bin/cache/
    rm -f dart-sdk-arm64.zip

    # Remove pre-compiled snapshots - Flutter will regenerate them with the new Dart SDK
    rm -rf /opt/flutter/bin/cache/*.stamp
    rm -rf /opt/flutter/bin/cache/artifacts/engine

    echo "Dart SDK replaced with ARM64 version ${DART_VERSION}"
else
    echo "Using bundled x86-64 Dart SDK"
fi

# Cleanup releases metadata
rm -f /tmp/releases.json
