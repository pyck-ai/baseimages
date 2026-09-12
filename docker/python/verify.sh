#!/bin/sh
# Verifies the assembled python image, run INSIDE the image as its default
# user (root). Invoked as:
#   docker run --rm --env-file buildargs.conf -e TARGET=python-alpine|python-debian \
#     -v $PWD/docker/python/verify.sh:/verify.sh:ro --entrypoint /bin/sh <ref> /verify.sh

fails=0
ck() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

writable_python() {
    su -s /bin/sh -c 'mkdir -p /usr/local/python && touch /usr/local/python/.wprobe && rm -f /usr/local/python/.wprobe' nonroot
}

# Proves uv works unprivileged under UV_PYTHON_PREFERENCE=only-managed.
uv_venv_smoke() {
    su -s /bin/sh -c 'd=$(mktemp -d) && cd "$d" && uv venv' nonroot
}

ck "runs as root (uid 0)" '[ "$(id -u)" = 0 ]'
ck "WORKDIR is /app" '[ "$(pwd)" = /app ]'
ck "UV_PYTHON_INSTALL_DIR=/usr/local/python" '[ "$UV_PYTHON_INSTALL_DIR" = /usr/local/python ]'
ck "UV_PYTHON_PREFERENCE=only-managed" '[ "$UV_PYTHON_PREFERENCE" = only-managed ]'
ck "PYTHONDONTWRITEBYTECODE=1" '[ "$PYTHONDONTWRITEBYTECODE" = 1 ]'
ck "PYTHONUNBUFFERED=1" '[ "$PYTHONUNBUFFERED" = 1 ]'

# pip, pydoc and python are symlinks recreated into the uv-managed install and
# have broken before, so check them explicitly rather than trusting uv alone.
ck "on PATH: uv uvx ruff python python3 pip pip3 pydoc pydoc3" '
    for c in uv uvx ruff python python3 pip pip3 pydoc pydoc3; do
        command -v "$c" >/dev/null 2>&1 || exit 1
    done
'

ck "uv --version reports $UV_VERSION" 'uv --version 2>&1 | grep -qF "$UV_VERSION"'
ck "ruff --version reports $RUFF_VERSION" 'ruff --version 2>&1 | grep -qF "$RUFF_VERSION"'
ck "python --version reports $PYTHON_VERSION" 'python --version 2>&1 | grep -qF "$PYTHON_VERSION"'

ck "writable by uid 1001: /usr/local/python" writable_python
ck "python runs" 'python -c "print(1)"'
ck "uv venv works unprivileged" uv_venv_smoke

exit $((fails > 0))
