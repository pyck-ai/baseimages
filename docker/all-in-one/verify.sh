#!/bin/bash
# Verifies the assembled all-in-one image. See docker/verify-lib.sh for the helpers.
# Run via `task verify -- all-in-one`.

. "$(dirname "$0")/../verify-lib.sh"

IMG=$1
VARIANT=$2

check_user    "$IMG" root 0
check_workdir "$IMG" /app

check_env "$IMG" GOPATH /go
check_env "$IMG" GOCACHE /var/cache/go/
check_env "$IMG" GOMODCACHE /go/pkg/mod/
check_env "$IMG" GOPROXY https://go.pyck.cloud,direct
check_env "$IMG" CGO_ENABLED 0

check_env "$IMG" BUN_INSTALL /bun

check_env "$IMG" UV_PYTHON_INSTALL_DIR /usr/local/python
check_env "$IMG" UV_PYTHON_PREFERENCE only-managed
check_env "$IMG" PYTHONDONTWRITEBYTECODE 1
check_env "$IMG" PYTHONUNBUFFERED 1

check_env_contains "$IMG" PATH /go/bin
check_env_contains "$IMG" PATH /bun/bin

check_cmd "$IMG" go gofmt dlv golangci-lint gotestsum go-arch-lint\
    bun node pi claude opencode\
    python python3 pip uv uvx ruff

check_version "$IMG" "go version"         "go${GOLANG_VERSION}"
check_version "$IMG" "bun --version"      "${BUN_VERSION}"
check_version "$IMG" "claude --version"   "${CLAUDE_VERSION}"
check_version "$IMG" "opencode --version" "${OPENCODE_VERSION}"
check_version "$IMG" "pi --version"       "${PI_VERSION}"
check_version "$IMG" "python --version"   "${PYTHON_VERSION}"
check_version "$IMG" "uv --version"       "${UV_VERSION}"
check_version "$IMG" "ruff --version"     "${RUFF_VERSION}"

# rover ships glibc binaries only, so it is Debian-only; assert both sides of the
# split so this cannot silently drift.
if [ "$VARIANT" = "debian" ]; then
    check_cmd     "$IMG" rover
    check_version "$IMG" "rover --version" "${ROVER_VERSION}"
else
    check_shell_cmd "$IMG" "rover absent on alpine" '! command -v rover >/dev/null 2>&1'
fi

if [ "$VARIANT" = "alpine" ]; then
    check_env  "$IMG" LD_PRELOAD /usr/local/lib/claude_fix.so
    check_file "$IMG" /usr/local/lib/claude_fix.so
else
    check_shell_cmd "$IMG" "no LD_PRELOAD shim on debian" '[ -z "${LD_PRELOAD:-}" ]'
    check_shell_cmd "$IMG" "claude_fix.so absent on debian" '[ ! -e /usr/local/lib/claude_fix.so ]'
fi

# These directories are chowned to nonroot explicitly in the Dockerfile because
# each toolchain's own build stage installs as root.
check_writable_as 65532 "$IMG" /go /go/bin /go/pkg/mod /var/cache/go\
    /bun /bun/bin /bun/install/global\
    /usr/local/python

check_shell_cmd_as 65532 "$IMG" "go build works end-to-end" \
    'd=$(mktemp -d) && cd "$d" && go mod init smoke && echo "package main
func main() {}" > main.go && go build .'

check_shell_cmd_as 65532 "$IMG" "bun add -g installs a binary that resolves on PATH" \
    'bun add -g --ignore-scripts cowsay && command -v cowsay >/dev/null 2>&1'

check_shell_cmd_as 65532 "$IMG" "python runs" 'python -c "print(1)"'

verify_summary
