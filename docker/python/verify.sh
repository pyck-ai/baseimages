#!/bin/bash
# Verifies the assembled python image. See docker/verify-lib.sh for the helpers.
# Run via `task verify -- python`.

. "$(dirname "$0")/../verify-lib.sh"

IMG=$1
VARIANT=$2

check_user    "$IMG" root 0
check_workdir "$IMG" /app

check_env "$IMG" UV_PYTHON_INSTALL_DIR /usr/local/python
check_env "$IMG" UV_PYTHON_PREFERENCE only-managed
check_env "$IMG" PYTHONDONTWRITEBYTECODE 1
check_env "$IMG" PYTHONUNBUFFERED 1

# pip, pydoc and python are symlinks recreated into the uv-managed install and
# have broken before, so check them explicitly rather than trusting uv alone.
check_cmd "$IMG" uv uvx ruff python python3 pip pip3 pydoc pydoc3

check_version "$IMG" "uv --version"      "${UV_VERSION}"
check_version "$IMG" "ruff --version"    "${RUFF_VERSION}"
check_version "$IMG" "python --version"  "${PYTHON_VERSION}"

check_writable_as 65532 "$IMG" /usr/local/python

check_shell_cmd "$IMG" "python runs" 'python -c "print(1)"'

# Proves uv works unprivileged under UV_PYTHON_PREFERENCE=only-managed.
check_shell_cmd_as 65532 "$IMG" "uv venv works unprivileged" \
    'd=$(mktemp -d) && cd "$d" && uv venv'

verify_summary
