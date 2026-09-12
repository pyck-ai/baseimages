#!/bin/sh
# Verifies the assembled all-in-one image, run INSIDE the image as its
# default user (root). Invoked as:
#   docker run --rm --env-file buildargs.conf -e TARGET=all-in-one-alpine|all-in-one-debian \
#     -v $PWD/docker/all-in-one/verify.sh:/verify.sh:ro --entrypoint /bin/sh <ref> /verify.sh

fails=0
ck() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

# These directories are chowned to nonroot explicitly in the Dockerfile
# because each toolchain's own build stage installs as root.
writable_toolchains() {
    su -s /bin/sh -c '
        for d in /go /go/bin /go/pkg/mod /var/cache/go /bun /bun/bin /bun/install/global /usr/local/python; do
            mkdir -p "$d" && touch "$d/.wprobe" && rm -f "$d/.wprobe" || exit 1
        done
    ' nonroot
}

go_build_e2e() {
    su -s /bin/sh -c '
        d=$(mktemp -d) && cd "$d" && go mod init smoke &&
        printf "package main\nfunc main() {}\n" > main.go &&
        go build .
    ' nonroot
}

bun_cowsay() {
    su -s /bin/sh -c 'bun add -g --ignore-scripts cowsay && command -v cowsay >/dev/null 2>&1' nonroot
}

python_smoke() {
    su -s /bin/sh -c 'python -c "print(1)"' nonroot
}

ck "runs as root (uid 0)" '[ "$(id -u)" = 0 ]'
ck "WORKDIR is /app" '[ "$(pwd)" = /app ]'

ck "GOPATH=/go" '[ "$GOPATH" = /go ]'
ck "GOCACHE=/var/cache/go/" '[ "$GOCACHE" = /var/cache/go/ ]'
ck "GOMODCACHE=/go/pkg/mod/" '[ "$GOMODCACHE" = /go/pkg/mod/ ]'
ck "GOPROXY=https://go.pyck.cloud,direct" '[ "$GOPROXY" = "https://go.pyck.cloud,direct" ]'
ck "CGO_ENABLED=0" '[ "$CGO_ENABLED" = 0 ]'
ck "BUN_INSTALL=/bun" '[ "$BUN_INSTALL" = /bun ]'
ck "UV_PYTHON_INSTALL_DIR=/usr/local/python" '[ "$UV_PYTHON_INSTALL_DIR" = /usr/local/python ]'
ck "UV_PYTHON_PREFERENCE=only-managed" '[ "$UV_PYTHON_PREFERENCE" = only-managed ]'
ck "PYTHONDONTWRITEBYTECODE=1" '[ "$PYTHONDONTWRITEBYTECODE" = 1 ]'
ck "PYTHONUNBUFFERED=1" '[ "$PYTHONUNBUFFERED" = 1 ]'
ck "PATH contains /go/bin" 'case "$PATH" in *"/go/bin"*) true ;; *) false ;; esac'
ck "PATH contains /bun/bin" 'case "$PATH" in *"/bun/bin"*) true ;; *) false ;; esac'

ck "on PATH: go gofmt dlv golangci-lint gotestsum go-arch-lint bun node pi claude opencode python python3 pip uv uvx ruff" '
    for c in go gofmt dlv golangci-lint gotestsum go-arch-lint bun node pi claude opencode python python3 pip uv uvx ruff; do
        command -v "$c" >/dev/null 2>&1 || exit 1
    done
'

ck "go version reports go$GOLANG_VERSION" 'go version 2>&1 | grep -qF "go$GOLANG_VERSION"'
ck "bun --version reports $BUN_VERSION" 'bun --version 2>&1 | grep -qF "$BUN_VERSION"'
ck "claude --version reports $CLAUDE_VERSION" 'claude --version 2>&1 | grep -qF "$CLAUDE_VERSION"'
ck "opencode --version reports $OPENCODE_VERSION" 'opencode --version 2>&1 | grep -qF "$OPENCODE_VERSION"'
ck "pi --version reports $PI_VERSION" 'pi --version 2>&1 | grep -qF "$PI_VERSION"'
ck "python --version reports $PYTHON_VERSION" 'python --version 2>&1 | grep -qF "$PYTHON_VERSION"'
ck "uv --version reports $UV_VERSION" 'uv --version 2>&1 | grep -qF "$UV_VERSION"'
ck "ruff --version reports $RUFF_VERSION" 'ruff --version 2>&1 | grep -qF "$RUFF_VERSION"'

# rover ships glibc binaries only, so it is Debian-only; assert both sides of
# the split so this cannot silently drift.
case "$TARGET" in
    *-debian)
        ck "on PATH: rover" 'command -v rover >/dev/null 2>&1'
        ck "rover --version reports $ROVER_VERSION" 'rover --version 2>&1 | grep -qF "$ROVER_VERSION"'
        ;;
    *-alpine)
        ck "rover absent on alpine" '! command -v rover >/dev/null 2>&1'
        ;;
esac

case "$TARGET" in
    *-alpine)
        # The official Claude binaries are musl-incompatible without this shim.
        ck "LD_PRELOAD=/usr/local/lib/claude_fix.so" '[ "$LD_PRELOAD" = /usr/local/lib/claude_fix.so ]'
        ck "present: /usr/local/lib/claude_fix.so" '[ -e /usr/local/lib/claude_fix.so ]'
        ;;
    *-debian)
        ck "no LD_PRELOAD shim on debian" '[ -z "${LD_PRELOAD:-}" ]'
        ck "claude_fix.so absent on debian" '[ ! -e /usr/local/lib/claude_fix.so ]'
        ;;
esac

ck "writable by uid 1001: /go /go/bin /go/pkg/mod /var/cache/go /bun /bun/bin /bun/install/global /usr/local/python" writable_toolchains
ck "go build works end-to-end" go_build_e2e
ck "bun add -g installs a binary that resolves on PATH" bun_cowsay
ck "python runs" python_smoke

exit $((fails > 0))
