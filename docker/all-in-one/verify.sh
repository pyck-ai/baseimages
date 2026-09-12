#!/bin/sh
# Verifies the assembled all-in-one image, run INSIDE the image as its
# default user (root). Invoked as:
#   docker run --rm --env-file buildargs.conf -e TARGET=all-in-one-alpine|all-in-one-debian \
#     -v $PWD/docker/all-in-one/verify.sh:/verify.sh:ro --entrypoint /bin/sh <ref> /verify.sh

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

check_file() {
    missing=
    for f in "$@"; do
        [ -e "$f" ] || missing="$missing $f"
    done
    if [ -z "$missing" ]; then ok "present: $*"; else bad "absent:$missing"; fi
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

# These directories are chowned to nonroot explicitly in the Dockerfile
# because each toolchain's own build stage installs as root.
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

check_env GOPATH /go
check_env GOCACHE /var/cache/go/
check_env GOMODCACHE /go/pkg/mod/
check_env GOPROXY "https://go.pyck.cloud,direct"
check_env CGO_ENABLED 0
check_env BUN_INSTALL /bun
check_env UV_PYTHON_INSTALL_DIR /usr/local/python
check_env UV_PYTHON_PREFERENCE only-managed
check_env PYTHONDONTWRITEBYTECODE 1
check_env PYTHONUNBUFFERED 1

if case "$PATH" in *"/go/bin"*) true ;; *) false ;; esac; then
    ok "PATH contains /go/bin"
else
    bad "PATH contains /go/bin"
fi

if case "$PATH" in *"/bun/bin"*) true ;; *) false ;; esac; then
    ok "PATH contains /bun/bin"
else
    bad "PATH contains /bun/bin"
fi

check_cmd go gofmt dlv golangci-lint gotestsum go-arch-lint bun node pi claude opencode python python3 pip uv uvx ruff

check_version "go version"         "go$GOLANG_VERSION"
check_version "bun --version"      "$BUN_VERSION"
check_version "claude --version"   "$CLAUDE_VERSION"
check_version "opencode --version" "$OPENCODE_VERSION"
check_version "pi --version"       "$PI_VERSION"
check_version "python --version"   "$PYTHON_VERSION"
check_version "uv --version"       "$UV_VERSION"
check_version "ruff --version"     "$RUFF_VERSION"

# rover ships glibc binaries only, so it is Debian-only; assert both sides of
# the split so this cannot silently drift.
case "$TARGET" in
    *-debian)
        check_cmd rover
        check_version "rover --version" "$ROVER_VERSION"
        ;;
    *-alpine)
        if ! command -v rover >/dev/null 2>&1; then
            ok "rover absent on alpine"
        else
            bad "rover absent on alpine"
        fi
        ;;
esac

case "$TARGET" in
    *-alpine)
        # The official Claude binaries are musl-incompatible without this shim.
        check_env LD_PRELOAD /usr/local/lib/claude_fix.so
        check_file /usr/local/lib/claude_fix.so
        ;;
    *-debian)
        if [ -z "${LD_PRELOAD:-}" ]; then
            ok "no LD_PRELOAD shim on debian"
        else
            bad "no LD_PRELOAD shim on debian"
        fi
        if [ ! -e /usr/local/lib/claude_fix.so ]; then
            ok "claude_fix.so absent on debian"
        else
            bad "claude_fix.so absent on debian"
        fi
        ;;
esac

check_writable_as nonroot /go /go/bin /go/pkg/mod /var/cache/go /bun /bun/bin /bun/install/global /usr/local/python

# go build works end-to-end (exercises GOCACHE/GOMODCACHE). The single quotes
# are deliberate: $d must expand inside the nonroot subshell, not out here.
# shellcheck disable=SC2016
if su -s /bin/sh -c '
    d=$(mktemp -d) && cd "$d" && go mod init smoke &&
    printf "package main\nfunc main() {}\n" > main.go &&
    go build .
' nonroot; then
    ok "go build works end-to-end"
else
    bad "go build works end-to-end"
fi

# The install can succeed while the binary stays invisible because /bun/bin is
# not on PATH — assert both halves.
if su -s /bin/sh -c 'bun add -g --ignore-scripts cowsay && command -v cowsay >/dev/null 2>&1' nonroot; then
    ok "bun add -g installs a binary that resolves on PATH"
else
    bad "bun add -g installs a binary that resolves on PATH"
fi

if su -s /bin/sh -c 'python -c "print(1)"' nonroot; then
    ok "python runs"
else
    bad "python runs"
fi

exit $((fails > 0))
