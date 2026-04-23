#!/bin/bash
set -euo pipefail

# Entrypoint script for Flutter RFW validator container
# Simplifies running the validator against widget files

# If running as root, fix GitHub Actions workspace permissions and switch to flutter user
if [ "$(id -u)" = "0" ]; then
    # Fix GitHub Actions workspace permissions if directory exists
    if [ -d "/__w" ]; then
        chmod -R 777 /__w
    fi

    # Switch to flutter user and re-execute this script
    exec gosu flutter "$0" "$@"
fi

# Default command: validate-rfw
COMMAND="${1:-validate-rfw}"

case "$COMMAND" in
  validate-rfw)
    shift || true
    if [ $# -eq 0 ]; then
      echo "Usage: docker run ... validate-rfw <file.rfwtxt|file.rfw>"
      echo ""
      echo "Validates Remote Flutter Widget files for syntax errors."
      echo "Supports both text (.rfwtxt) and binary (.rfw) formats."
      exit 1
    fi
    cd /opt/rfw-validator
    dart run validate_rfw.dart "$@"
    ;;

  generate-binary)
    shift || true
    if [ $# -ne 2 ]; then
      echo "Usage: docker run ... generate-binary <input.rfwtxt> <output.rfw>"
      echo ""
      echo "Converts text RFW files to binary format."
      exit 1
    fi
    cd /opt/rfw-validator
    dart run generate_binary.dart "$@"
    ;;

  bash|sh)
    exec "$@"
    ;;

  *)
    exec "$@"
    ;;
esac
