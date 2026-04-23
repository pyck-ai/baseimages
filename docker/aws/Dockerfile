# syntax=docker/dockerfile:1

FROM alpine

USER 0
RUN --mount=type=cache,id=apk-cache,target=/var/cache/apk/,sharing=locked\
    apk add --update --no-progress aws-cli
USER nonroot
WORKDIR /app
