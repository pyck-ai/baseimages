# syntax=docker/dockerfile:1

#===============================================================================
# DOWNLOADS
#===============================================================================

FROM debian AS rover
ARG TARGETPLATFORM TARGETARCH ROVER_VERSION
USER 0
RUN --mount=type=cache,id=downloads,target=/var/cache/downloads,sharing=shared\
    download.sh\
    --var "version=${ROVER_VERSION}"\
    --platform-arch "linux/amd64=x86_64"\
    --platform-arch "linux/arm64=aarch64"\
    --url "https://github.com/apollographql/rover/releases/download/v{version}/rover-v{version}-{arch}-unknown-linux-gnu.tar.gz"\
    --checksum-url "https://github.com/apollographql/rover/releases/download/v{version}/sha256sums.txt"\
    --install-paths "dist/rover"\
    --install-to "/usr/local/bin/"\
    --verify "rover --version | grep -qF '{version}'"

#===============================================================================
# RESULT
#===============================================================================

FROM debian
COPY --from=rover /usr/local/bin/rover /usr/local/bin/
