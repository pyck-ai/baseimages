#!/bin/sh
# Verifies the assembled python image, run INSIDE the image as its default
# user (root). Invoked as:
#   docker run --rm --env-file buildargs.conf -e TARGET=python-alpine|python-debian \
#     -v $PWD/docker/python/verify.sh:/verify.sh:ro --entrypoint /bin/sh <ref> /verify.sh

fails=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }

check_user() {
    if [ "$(id -u)" = "$1" ]; then ok "runs as uid $1"; else bad "runs as uid $(id -u), want $1"; fi
}

check_workdir() {
    if [ "$(pwd)" = "$1" ]; then ok "workdir is $1"; else bad "workdir is $(pwd), want $1"; fi
}

check_env() {
    if [ "$(printenv "$1")" = "$2" ]; then ok "$1=$2"; else bad "$1=$(printenv "$1"), want $2"; fi
}

check_cmd() {
    missing=
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
    done
    if [ -z "$missing" ]; then ok "on PATH: $*"; else bad "not on PATH:$missing"; fi
}

# Runs a command and looks for a substring, so a version bump in buildargs.conf
# fails the check instead of silently passing.
check_version() {
    out=$(sh -c "$1" 2>&1)
    case "$out" in
        *"$2"*) ok "$1 reports $2" ;;
        *)      bad "$1 does not report $2: $out" ;;
    esac
}

check_writable_as() {
    u=$1
    shift
    missing=
    for d in "$@"; do
        su "$u" -s /bin/sh -c "mkdir -p '$d/.verify' && rmdir '$d/.verify'" 2>/dev/null || missing="$missing $d"
    done
    if [ -z "$missing" ]; then ok "writable by $u: $*"; else bad "not writable by $u:$missing"; fi
}

check_user 0
check_workdir /app
check_env UV_PYTHON_INSTALL_DIR /usr/local/python
check_env UV_PYTHON_PREFERENCE only-managed
check_env PYTHONDONTWRITEBYTECODE 1
check_env PYTHONUNBUFFERED 1

# pip, pydoc and python are symlinks recreated into the uv-managed install and
# have broken before, so check them explicitly rather than trusting uv alone.
check_cmd uv uvx ruff python python3 pip pip3 pydoc pydoc3

check_version "uv --version"     "$UV_VERSION"
check_version "ruff --version"   "$RUFF_VERSION"
check_version "python --version" "$PYTHON_VERSION"

check_writable_as nonroot /usr/local/python

if python -c "print(1)"; then
    ok "python runs"
else
    bad "python runs"
fi

# Proves uv works unprivileged under UV_PYTHON_PREFERENCE=only-managed. The
# single quotes are deliberate: $d must expand inside the nonroot subshell.
# shellcheck disable=SC2016
if su -s /bin/sh -c 'd=$(mktemp -d) && cd "$d" && uv venv' nonroot; then
    ok "uv venv works unprivileged"
else
    bad "uv venv works unprivileged"
fi

exit $((fails > 0))
