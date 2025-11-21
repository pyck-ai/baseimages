#!/bin/bash
set -euo pipefail
cd /tmp

# Download Flutter releases metadata to get SHA256 and Dart version
curl -fsSL "https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json" -o releases.json

# Extract SHA256 for the specific version
FLUTTER_SHA256=$(grep -A 5 "flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" releases.json | grep '"sha256"' | cut -d'"' -f4 | head -1)

# Validate SHA256 was found
if [ -z "$FLUTTER_SHA256" ]; then
    echo "Error: SHA256 not found for Flutter ${FLUTTER_VERSION}"
    exit 1
fi

echo "Found SHA256: $FLUTTER_SHA256"

# Download Flutter SDK
curl -fsSL "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" -o flutter.tar.xz

# Verify checksum
echo "$FLUTTER_SHA256  flutter.tar.xz" | sha256sum -c -

# Extract to /opt/
tar -xf flutter.tar.xz -C /opt/

# Cleanup flutter archive (keep releases.json for Dart SDK version lookup)
rm -f flutter.tar.xz
