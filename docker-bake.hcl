# Docker Bake configuration for slim images
#
# All build args are read from buildargs.conf via environment variables.
# Task automatically sources buildargs.conf before calling bake.
#
# Usage:
#   task build             # Build all images
#   task build -- flutter  # Build flutter image
#
# Or directly with docker:
#   set -a && source buildargs.conf && set +a && docker buildx bake
#   set -a && source buildargs.conf && set +a && docker buildx bake flutter

variable "REGISTRY" {}
variable "GOLANG_VERSION" {}
variable "ALPINE_VERSION" {}
variable "DEBIAN_RELEASE" {}
variable "NGINX_VERSION" {}
variable "CLAUDE_VERSION" {}
variable "FLUTTER_VERSION" {}
variable "BUN_VERSION" {}
variable "ROVER_VERSION" {}

target "_common" {
  platforms = [
    "linux/amd64",
    "linux/arm64",
  ]
}

group "default" {
  targets = [
    "slim",
    "static",
    "golang",
    "nginx",
    "claude",
    "flutter",
    "typescript",
    "rover",
    "aws",
    "all-in-one",
  ]
}


# ==============================================================================
# slim
# ==============================================================================

group "slim" {
  targets = [
    "slim-alpine",
    "slim-debian",
  ]
}

target "slim-alpine" {
  inherits = ["_common"]
  context = "./docker/slim"
  dockerfile = "Dockerfile.alpine"
  tags = [
    "${REGISTRY}/slim:latest",
    "${REGISTRY}/slim:alpine",
    "${REGISTRY}/slim:alpine-${ALPINE_VERSION}"
  ]
  cache-from = ["type=registry,ref=${REGISTRY}/buildcache:alpine"]
  cache-to   = ["type=registry,ref=${REGISTRY}/buildcache:alpine,mode=max"]
}

target "slim-debian" {
  inherits = ["_common"]
  context = "./docker/slim"
  dockerfile = "Dockerfile.debian"
  tags = [
    "${REGISTRY}/slim:debian",
    "${REGISTRY}/slim:debian-${DEBIAN_RELEASE}"
  ]
  cache-from = ["type=registry,ref=${REGISTRY}/buildcache:debian"]
  cache-to   = ["type=registry,ref=${REGISTRY}/buildcache:debian,mode=max"]
}

# ==============================================================================
# STATIC
# ==============================================================================

target "static" {
  inherits = ["_common"]
  context = "./docker/static"
  dockerfile = "Dockerfile"
  contexts = {
    "alpine" = "target:slim-alpine"
  }
  tags = [
    "${REGISTRY}/static:latest",
  ]
  cache-from = ["type=registry,ref=${REGISTRY}/buildcache:static"]
  cache-to   = ["type=registry,ref=${REGISTRY}/buildcache:static,mode=max"]
}

# ==============================================================================
# GOLANG
# ==============================================================================

group "golang" {
  targets = [
    "golang-alpine",
    "golang-debian",
  ]
}

target "golang-alpine" {
  inherits = ["_common"]
  context = "./docker/golang"
  dockerfile = "Dockerfile.alpine"
  contexts = {
    "alpine" = "target:slim-alpine"
  }
  tags = [
    "${REGISTRY}/golang:latest",
    "${REGISTRY}/golang:${GOLANG_VERSION}",
    "${REGISTRY}/golang:${GOLANG_VERSION}-alpine",
    "${REGISTRY}/golang:${GOLANG_VERSION}-alpine-${ALPINE_VERSION}",
    "${REGISTRY}/golang:alpine",
    "${REGISTRY}/golang:alpine-${ALPINE_VERSION}"
  ]
  cache-from = ["type=registry,ref=${REGISTRY}/buildcache:golang-alpine"]
  cache-to   = ["type=registry,ref=${REGISTRY}/buildcache:golang-alpine,mode=max"]
}

target "golang-debian" {
  inherits = ["_common"]
  context = "./docker/golang"
  dockerfile = "Dockerfile.debian"
  contexts = {
    "debian" = "target:slim-debian"
  }
  tags = [
    "${REGISTRY}/golang:${GOLANG_VERSION}-debian",
    "${REGISTRY}/golang:${GOLANG_VERSION}-debian-${DEBIAN_RELEASE}",
    "${REGISTRY}/golang:debian",
    "${REGISTRY}/golang:debian-${DEBIAN_RELEASE}"
  ]
  cache-from = ["type=registry,ref=${REGISTRY}/buildcache:golang-debian"]
  cache-to   = ["type=registry,ref=${REGISTRY}/buildcache:golang-debian,mode=max"]
}

# ==============================================================================
# NGINX
# ==============================================================================

target "nginx" {
  inherits = ["_common"]
  context = "./docker/nginx"
  dockerfile = "Dockerfile"
  tags = [
    "${REGISTRY}/nginx:latest",
    "${REGISTRY}/nginx:${NGINX_VERSION}"
  ]
  cache-from = ["type=registry,ref=${REGISTRY}/buildcache:nginx"]
  cache-to   = ["type=registry,ref=${REGISTRY}/buildcache:nginx,mode=max"]
}

# ==============================================================================
# CLAUDE
# ==============================================================================

target "claude" {
  inherits = ["_common"]
  context = "./docker/claude"
  dockerfile = "Dockerfile"
  contexts = {
    "alpine" = "target:slim-alpine"
  }
  tags = [
    "${REGISTRY}/claude:latest",
    "${REGISTRY}/claude:${CLAUDE_VERSION}"
  ]
  cache-from = ["type=registry,ref=${REGISTRY}/buildcache:claude"]
  cache-to   = ["type=registry,ref=${REGISTRY}/buildcache:claude,mode=max"]
}

# ==============================================================================
# FLUTTER
# ==============================================================================

target "flutter" {
  inherits = ["_common"]
  context = "./docker/flutter"
  dockerfile = "Dockerfile"
  contexts = {
    "debian" = "target:slim-debian"
  }
  tags = [
    "${REGISTRY}/flutter:latest",
    "${REGISTRY}/flutter:${FLUTTER_VERSION}"
  ]
  cache-from = ["type=registry,ref=${REGISTRY}/buildcache:flutter"]
  cache-to   = ["type=registry,ref=${REGISTRY}/buildcache:flutter,mode=max"]
}

# ==============================================================================
# TYPESCRIPT
# ==============================================================================

group "typescript" {
  targets = [
    "typescript-alpine",
    "typescript-debian",
  ]
}

target "typescript-alpine" {
  inherits = ["_common"]
  context = "./docker/typescript"
  dockerfile = "Dockerfile.alpine"
  contexts = {
    "alpine" = "target:slim-alpine"
  }
  tags = [
    "${REGISTRY}/typescript:latest",
    "${REGISTRY}/typescript:${BUN_VERSION}",
    "${REGISTRY}/typescript:alpine",
    "${REGISTRY}/typescript:${BUN_VERSION}-alpine"
  ]
  cache-from = ["type=registry,ref=${REGISTRY}/buildcache:typescript-alpine"]
  cache-to   = ["type=registry,ref=${REGISTRY}/buildcache:typescript-alpine,mode=max"]
}

target "typescript-debian" {
  inherits = ["_common"]
  context = "./docker/typescript"
  dockerfile = "Dockerfile.debian"
  contexts = {
    "debian" = "target:slim-debian"
  }
  tags = [
    "${REGISTRY}/typescript:debian",
    "${REGISTRY}/typescript:${BUN_VERSION}-debian"
  ]
  cache-from = ["type=registry,ref=${REGISTRY}/buildcache:typescript-debian"]
  cache-to   = ["type=registry,ref=${REGISTRY}/buildcache:typescript-debian,mode=max"]
}

# ==============================================================================
# ALL-IN-ONE
# ==============================================================================

group "all-in-one" {
  targets = [
    "all-in-one-alpine",
    "all-in-one-debian",
  ]
}

target "all-in-one-alpine" {
  inherits = ["_common"]
  context = "./docker/all-in-one"
  dockerfile = "Dockerfile.alpine"
  contexts = {
    "alpine"        = "target:slim-alpine"
    "golang-alpine" = "target:golang-alpine"
    "flutter"       = "target:flutter"
    "rover"         = "target:rover"
  }
  tags = [
    "${REGISTRY}/alpine:latest",
    "${REGISTRY}/all-in-one:latest",
    "${REGISTRY}/all-in-one:alpine",
  ]
  cache-from = ["type=registry,ref=${REGISTRY}/buildcache:all-in-one-alpine"]
  cache-to   = ["type=registry,ref=${REGISTRY}/buildcache:all-in-one-alpine,mode=max"]
}

target "all-in-one-debian" {
  inherits = ["_common"]
  context = "./docker/all-in-one"
  dockerfile = "Dockerfile.debian"
  contexts = {
    "debian"        = "target:slim-debian"
    "golang-debian" = "target:golang-debian"
    "flutter"       = "target:flutter"
    "rover"         = "target:rover"
  }
  tags = [
    "${REGISTRY}/debian:latest",
    "${REGISTRY}/all-in-one:debian",
  ]
  cache-from = ["type=registry,ref=${REGISTRY}/buildcache:all-in-one-debian"]
  cache-to   = ["type=registry,ref=${REGISTRY}/buildcache:all-in-one-debian,mode=max"]
}

# ==============================================================================
# AWS
# ==============================================================================

target "aws" {
  inherits = ["_common"]
  context = "./docker/aws"
  dockerfile = "Dockerfile"
  contexts = {
    "alpine" = "target:slim-alpine"
  }
  tags = [
    "${REGISTRY}/aws:latest",
  ]
  cache-from = ["type=registry,ref=${REGISTRY}/buildcache:aws"]
  cache-to   = ["type=registry,ref=${REGISTRY}/buildcache:aws,mode=max"]
}

# ==============================================================================
# ROVER
# ==============================================================================

target "rover" {
  inherits = ["_common"]
  context = "./docker/rover"
  dockerfile = "Dockerfile"
  contexts = {
    "debian" = "target:slim-debian"
  }
  tags = [
    "${REGISTRY}/rover:latest",
    "${REGISTRY}/rover:${ROVER_VERSION}"
  ]
  cache-from = ["type=registry,ref=${REGISTRY}/buildcache:rover"]
  cache-to   = ["type=registry,ref=${REGISTRY}/buildcache:rover,mode=max"]
}

