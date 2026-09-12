#!/bin/sh
# Verifies the assembled golang image, run INSIDE the image as its default
# user (root). Invoked as:
#   docker run --rm --env-file buildargs.conf -e TARGET=golang-alpine|golang-debian \
#     -v $PWD/docker/golang/verify.sh:/verify.sh:ro --entrypoint /bin/sh <ref> /verify.sh

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

# These were root-owned while the image ran as nonroot, silently breaking
# `go build`; assert the path still works when dropped to nonroot.
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

if case "$PATH" in *"/usr/local/go/bin"*) true ;; *) false ;; esac; then
    ok "PATH contains /usr/local/go/bin"
else
    bad "PATH contains /usr/local/go/bin"
fi

if case "$PATH" in *"/go/bin"*) true ;; *) false ;; esac; then
    ok "PATH contains /go/bin"
else
    bad "PATH contains /go/bin"
fi

check_cmd go gofmt dlv golangci-lint gotestsum go-arch-lint

check_version "go version"                              "go$GOLANG_VERSION"
check_version "dlv version"                              "Version: $DELVE_VERSION"
check_version "golangci-lint --version"                  "version $GOLANGCILINT_VERSION"
check_version "gotestsum --version"                      "version v$GOTESTSUM_VERSION"
check_version "go-arch-lint version --output-color=false" "version: $GOARCHLINT_VERSION"

check_writable_as nonroot /go /go/bin /go/pkg/mod /var/cache/go

# go build works end-to-end (exercises GOCACHE/GOMODCACHE). The single quotes
# are deliberate: $d must expand inside the nonroot subshell, not out here.
# shellcheck disable=SC2016
if su -s /bin/sh -c '
    d=$(mktemp -d) && cd "$d" && go mod init smoke &&
    printf "package main\nfunc main() {}\n" > main.go &&
    go build .
' nonroot; then
    ok "go build works end-to-end (exercises GOCACHE/GOMODCACHE)"
else
    bad "go build works end-to-end (exercises GOCACHE/GOMODCACHE)"
fi

# `go install` into /go/bin is the documented workflow.
# shellcheck disable=SC2016
if su -s /bin/sh -c '
    d=$(mktemp -d) && cd "$d" && go mod init smoke &&
    printf "package main\nfunc main() {}\n" > main.go &&
    go install . && [ -x /go/bin/smoke ]
' nonroot; then
    ok "go install writes to /go/bin"
else
    bad "go install writes to /go/bin"
fi

exit $((fails > 0))
