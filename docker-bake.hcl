# Docker Bake configuration for base images
#
# All build args are read from buildargs.conf via environment variables.
# Task automatically sources buildargs.conf before calling bake.
#
# Usage:
#   task build              # Build all images
#   task build:flutter      # Build flutter image
#   task push               # Build and push multi-platform
#
# Or directly with docker:
#   set -a && source buildargs.conf && set +a && docker buildx bake
#   set -a && source buildargs.conf && set +a && docker buildx bake flutter

#######################################################################
#   VARIABLES                                                         #
#######################################################################

variable "REGISTRY" {
  default = "ghcr.io/pyck-ai/baseimages"
}

# Only declare variables used in tags - all others come from environment
variable "ALPINE_VERSION" {}
variable "DEBIAN_RELEASE" {}
variable "FLUTTER_VERSION" {}
variable "NGINX_VERSION" {}
variable "CLAUDE_VERSION" {}
variable "RENOVATE_VERSION" {}

#######################################################################
#   GROUPS                                                            #
#######################################################################

# Default group: build all images
group "default" {
  targets = ["alpine", "debian", "flutter", "nginx", "static", "claude", "renovate"]
}

#######################################################################
#   TARGETS                                                           #
#######################################################################

target "_common" {
  pull = true
}

target "alpine" {
  inherits = ["_common"]
  dockerfile = "Dockerfile.alpine"
  tags = [
    "${REGISTRY}/alpine:latest",
    "${REGISTRY}/alpine:${ALPINE_VERSION}"
  ]
  platforms = ["linux/amd64", "linux/arm64"]
}

target "debian" {
  inherits = ["_common"]
  dockerfile = "Dockerfile.debian"
  tags = [
    "${REGISTRY}/debian:latest",
    "${REGISTRY}/debian:${DEBIAN_RELEASE}"
  ]
  platforms = ["linux/amd64", "linux/arm64"]
}

target "flutter" {
  inherits = ["_common"]
  pull = false
  dockerfile = "Dockerfile.flutter"
  # Use debian target as base - automatic dependency resolution
  contexts = {
    "ghcr.io/pyck-ai/baseimages/debian:latest" = "target:debian"
  }
  tags = [
    "${REGISTRY}/flutter:latest",
    "${REGISTRY}/flutter:${FLUTTER_VERSION}"
  ]
  platforms = ["linux/amd64", "linux/arm64"]
}

target "claude" {
  inherits = ["_common"]
  pull = false
  dockerfile = "Dockerfile.claude"
  # Use debian target as base - automatic dependency resolution
  contexts = {
    "ghcr.io/pyck-ai/baseimages/alpine:latest" = "target:alpine"
  }
  tags = [
    "${REGISTRY}/claude:latest",
    "${REGISTRY}/claude:${CLAUDE_VERSION}"
  ]
  platforms = ["linux/amd64", "linux/arm64"]
}

target "renovate" {
  inherits = ["_common"]
  pull = false
  dockerfile = "Dockerfile.renovate"
  # Use debian target as base - automatic dependency resolution
  contexts = {
    "ghcr.io/pyck-ai/baseimages/alpine:latest" = "target:alpine"
  }
  tags = [
    "${REGISTRY}/renovate:latest",
    "${REGISTRY}/renovate:${RENOVATE_VERSION}"
  ]
  platforms = ["linux/amd64", "linux/arm64"]
}

target "static" {
  inherits = ["_common"]
  dockerfile = "Dockerfile.static"
  tags = [
    "${REGISTRY}/static:latest"
  ]
  platforms = ["linux/amd64", "linux/arm64"]
}

target "nginx" {
  inherits = ["_common"]
  dockerfile = "Dockerfile.nginx"
  tags = [
    "${REGISTRY}/nginx:latest",
    "${REGISTRY}/nginx:${NGINX_VERSION}"
  ]
  platforms = ["linux/amd64", "linux/arm64"]
}
