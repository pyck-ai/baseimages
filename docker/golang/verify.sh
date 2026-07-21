#!/bin/bash
# Verifies the assembled golang image. See docker/verify-lib.sh for the helpers.
# Run via `task verify -- golang`.

. "$(dirname "$0")/../verify-lib.sh"

IMG=$1
VARIANT=$2

check_user    "$IMG" root 0
check_workdir "$IMG" /app

check_env          "$IMG" GOPATH /go
check_env          "$IMG" GOCACHE /var/cache/go/
check_env          "$IMG" GOMODCACHE /go/pkg/mod/
check_env          "$IMG" GOPROXY https://go.pyck.cloud,direct
check_env          "$IMG" CGO_ENABLED 0
check_env_contains "$IMG" PATH /usr/local/go/bin
check_env_contains "$IMG" PATH /go/bin

check_cmd "$IMG" go gofmt dlv golangci-lint gotestsum go-arch-lint

check_version "$IMG" "go version"                             "go${GOLANG_VERSION}"
check_version "$IMG" "dlv version"                             "Version: ${DELVE_VERSION}"
check_version "$IMG" "golangci-lint --version"                 "version ${GOLANGCILINT_VERSION}"
check_version "$IMG" "gotestsum --version"                     "version v${GOTESTSUM_VERSION}"
check_version "$IMG" "go-arch-lint version --output-color=false" "version: ${GOARCHLINT_VERSION}"

# These were root-owned while the image ran as nonroot, silently breaking `go build`.
check_writable_as 65532 "$IMG" /go /go/bin /go/pkg/mod /var/cache/go

check_shell_cmd_as 65532 "$IMG" "go build works end-to-end (exercises GOCACHE/GOMODCACHE)" \
    'd=$(mktemp -d) && cd "$d" && go mod init smoke && echo "package main
func main() {}" > main.go && go build .'

# `go install` into /go/bin is the documented workflow.
check_shell_cmd_as 65532 "$IMG" "go install writes to /go/bin" \
    'd=$(mktemp -d) && cd "$d" && go mod init smoke && echo "package main
func main() {}" > main.go && go install . && [ -x /go/bin/smoke ]'

verify_summary
