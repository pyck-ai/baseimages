# syntax=docker/dockerfile:1

FROM alpine

ARG TARGETPLATFORM
ARG TARGETARCH
ARG CLAUDE_VERSION

USER 0

# The official binaries are not compatible with alpine due to a missing symbol,
# so we provide a shim for it.
COPY <<EOF /tmp/claude_fix.c
#define _GNU_SOURCE
#include <dirent.h>
#include <sys/syscall.h>
#include <unistd.h>

ssize_t posix_getdents(int fd, void *buf, size_t count) {
    return syscall(SYS_getdents64, fd, buf, count);
}
EOF
RUN gcc -shared -fPIC -o /usr/local/lib/claude_fix.so /tmp/claude_fix.c &&\
    rm /tmp/claude_fix.c

ENV LD_PRELOAD=/usr/local/lib/claude_fix.so

RUN --mount=type=cache,id=downloads,target=/var/cache/downloads,sharing=shared\
    download.sh\
    --var "version=${CLAUDE_VERSION}"\
    --var "bucket=claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819"\
    --platform-arch "linux/amd64=x64"\
    --platform-arch "linux/arm64=arm64"\
    --url "https://storage.googleapis.com/{bucket}/claude-code-releases/{version}/linux-{arch}-musl/claude"\
    --checksum-url "https://storage.googleapis.com/{bucket}/claude-code-releases/{version}/manifest.json"\
    --checksum-jq '.platforms["linux-{arch}-musl"] | (.checksum + " " + .binary)'\
    --install-to "/usr/local/bin/"\
    --verify 'claude --version | grep -qF "{version}"'

USER nonroot
WORKDIR /app
