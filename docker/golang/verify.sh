#!/bin/sh
# Verifies the assembled golang image, run INSIDE the image as its default
# user (root). Invoked as:
#   docker run --rm --env-file buildargs.conf -e TARGET=golang-alpine|golang-debian \
#     -v $PWD/docker/golang/verify.sh:/verify.sh:ro --entrypoint /bin/sh <ref> /verify.sh

fails=0
ck() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

# These were root-owned while the image ran as nonroot, silently breaking `go build`.
writable_go() {
    su -s /bin/sh -c '
        for d in /go /go/bin /go/pkg/mod /var/cache/go; do
            mkdir -p "$d" && touch "$d/.wprobe" && rm -f "$d/.wprobe" || exit 1
        done
    ' nonroot
}

# go build works end-to-end (exercises GOCACHE/GOMODCACHE).
go_build_e2e() {
    su -s /bin/sh -c '
        d=$(mktemp -d) && cd "$d" && go mod init smoke &&
        printf "package main\nfunc main() {}\n" > main.go &&
        go build .
    ' nonroot
}

# `go install` into /go/bin is the documented workflow.
go_install_e2e() {
    su -s /bin/sh -c '
        d=$(mktemp -d) && cd "$d" && go mod init smoke &&
        printf "package main\nfunc main() {}\n" > main.go &&
        go install . && [ -x /go/bin/smoke ]
    ' nonroot
}

ck "runs as root (uid 0)" '[ "$(id -u)" = 0 ]'
ck "WORKDIR is /app" '[ "$(pwd)" = /app ]'
ck "GOPATH=/go" '[ "$GOPATH" = /go ]'
ck "GOCACHE=/var/cache/go/" '[ "$GOCACHE" = /var/cache/go/ ]'
ck "GOMODCACHE=/go/pkg/mod/" '[ "$GOMODCACHE" = /go/pkg/mod/ ]'
ck "GOPROXY=https://go.pyck.cloud,direct" '[ "$GOPROXY" = "https://go.pyck.cloud,direct" ]'
ck "CGO_ENABLED=0" '[ "$CGO_ENABLED" = 0 ]'
ck "PATH contains /usr/local/go/bin" 'case "$PATH" in *"/usr/local/go/bin"*) true ;; *) false ;; esac'
ck "PATH contains /go/bin" 'case "$PATH" in *"/go/bin"*) true ;; *) false ;; esac'

ck "on PATH: go gofmt dlv golangci-lint gotestsum go-arch-lint" '
    for c in go gofmt dlv golangci-lint gotestsum go-arch-lint; do
        command -v "$c" >/dev/null 2>&1 || exit 1
    done
'

ck "go version reports go$GOLANG_VERSION" 'go version 2>&1 | grep -qF "go$GOLANG_VERSION"'
ck "dlv version reports Version: $DELVE_VERSION" 'dlv version 2>&1 | grep -qF "Version: $DELVE_VERSION"'
ck "golangci-lint --version reports version $GOLANGCILINT_VERSION" 'golangci-lint --version 2>&1 | grep -qF "version $GOLANGCILINT_VERSION"'
ck "gotestsum --version reports version v$GOTESTSUM_VERSION" 'gotestsum --version 2>&1 | grep -qF "version v$GOTESTSUM_VERSION"'
ck "go-arch-lint version --output-color=false reports version: $GOARCHLINT_VERSION" 'go-arch-lint version --output-color=false 2>&1 | grep -qF "version: $GOARCHLINT_VERSION"'

ck "writable by uid 1001: /go /go/bin /go/pkg/mod /var/cache/go" writable_go
ck "go build works end-to-end (exercises GOCACHE/GOMODCACHE)" go_build_e2e
ck "go install writes to /go/bin" go_install_e2e

exit $((fails > 0))
