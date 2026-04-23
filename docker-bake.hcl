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

# Returns version tags for a given image, supporting 1-, 2-, or 3-part versions.
# prefix/suffix wrap each version segment (e.g., prefix="alpine-" or suffix="-alpine").
# Example: vtags(REGISTRY, "golang", "1.26.1", "", "-alpine")
#   → ["golang:1.26.1-alpine", "golang:1.26-alpine", "golang:1-alpine"]
function "vtags" {
  params = [registry, image, version, prefix, suffix]
  result = concat(
    ["${registry}/${image}:${prefix}${version}${suffix}"],
    length(split(".", version)) >= 2 ? ["${registry}/${image}:${prefix}${split(".", version)[0]}.${split(".", version)[1]}${suffix}"] : [],
    ["${registry}/${image}:${prefix}${split(".", version)[0]}${suffix}"]
  )
}

# Returns versioned per-tool tags for an all-in-one image.
# e.g. all_in_one_tags(REGISTRY, "alpine-3") produces:
#   all-in-one:alpine-3-golang-1.26.1, all-in-one:alpine-3-golang-1.26, all-in-one:alpine-3-golang-1, ...
function "all_in_one_tags" {
  params = [registry, distro]
  result = concat(
    vtags(registry, "all-in-one", GOLANG_VERSION,  "${distro}-golang-",  ""),
    vtags(registry, "all-in-one", FLUTTER_VERSION, "${distro}-flutter-", ""),
    vtags(registry, "all-in-one", ROVER_VERSION,   "${distro}-rover-",   ""),
    vtags(registry, "all-in-one", BUN_VERSION,     "${distro}-bun-",     ""),
    vtags(registry, "all-in-one", CLAUDE_VERSION,  "${distro}-claude-",  ""),
  )
}

target "_common" {
  platforms = [
    "linux/amd64",
    "linux/arm64",
  ]
}

group "default" {
  targets = [
    "ci-stage-1",
    "ci-stage-2",
    "ci-stage-3",
    "ci-stage-4",
  ]
}

# CI build stages — used by build.yml to enforce ordering.
# ci-stage-1 (slim) → ci-stage-2 (direct slim dependents) → ci-stage-3 (flutter)
# → ci-stage-4 (all-in-one). Each stage fans out in parallel across targets.

group "ci-stage-1" {
  targets = [
    "slim-alpine",
    "slim-debian",
    "nginx",
  ]
}

group "ci-stage-2" {
  targets = [
    "static",
    "golang-alpine",
    "golang-debian",
    "claude-alpine",
    "claude-debian",
    "typescript-alpine",
    "typescript-debian",
    "rover",
    "aws-alpine",
    "aws-debian",
  ]
}

group "ci-stage-3" {
  targets = [
    "flutter",
  ]
}

group "ci-stage-4" {
  targets = [
    "all-in-one",
  ]
}



# ==============================================================================
# SLIM
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
  tags = concat(
    ["${REGISTRY}/slim:latest", "${REGISTRY}/slim:alpine"],
    vtags(REGISTRY, "slim", ALPINE_VERSION, "alpine-", ""),
  )
  cache-from = ["type=registry,ref=${REGISTRY}/buildcache:alpine"]
  cache-to   = ["type=registry,ref=${REGISTRY}/buildcache:alpine,mode=max"]
}

target "slim-debian" {
  inherits = ["_common"]
  context = "./docker/slim"
  dockerfile = "Dockerfile.debian"
  tags = [
    "${REGISTRY}/slim:debian",
    "${REGISTRY}/slim:debian-${DEBIAN_RELEASE}",
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
  tags = concat(
    ["${REGISTRY}/golang:latest", "${REGISTRY}/golang:alpine", "${REGISTRY}/golang:alpine-${ALPINE_VERSION}"],
    vtags(REGISTRY, "golang", GOLANG_VERSION, "", ""),
    vtags(REGISTRY, "golang", GOLANG_VERSION, "", "-alpine"),
  )
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
  tags = concat(
    ["${REGISTRY}/golang:debian", "${REGISTRY}/golang:debian-${DEBIAN_RELEASE}"],
    vtags(REGISTRY, "golang", GOLANG_VERSION, "", "-debian"),
  )
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
  tags = concat(
    ["${REGISTRY}/nginx:latest"],
    vtags(REGISTRY, "nginx", NGINX_VERSION, "", ""),
  )
  cache-from = ["type=registry,ref=${REGISTRY}/buildcache:nginx"]
  cache-to   = ["type=registry,ref=${REGISTRY}/buildcache:nginx,mode=max"]
}

# ==============================================================================
# CLAUDE
# ==============================================================================

group "claude" {
  targets = [
    "claude-alpine",
    "claude-debian",
  ]
}

target "claude-alpine" {
  inherits = ["_common"]
  context = "./docker/claude"
  dockerfile = "Dockerfile.alpine"
  contexts = {
    "alpine" = "target:slim-alpine"
  }
  tags = concat(
    ["${REGISTRY}/claude:latest", "${REGISTRY}/claude:alpine"],
    vtags(REGISTRY, "claude", CLAUDE_VERSION, "", ""),
    vtags(REGISTRY, "claude", CLAUDE_VERSION, "", "-alpine"),
  )
  cache-from = ["type=registry,ref=${REGISTRY}/buildcache:claude-alpine"]
  cache-to   = ["type=registry,ref=${REGISTRY}/buildcache:claude-alpine,mode=max"]
}

target "claude-debian" {
  inherits = ["_common"]
  context = "./docker/claude"
  dockerfile = "Dockerfile.debian"
  contexts = {
    "debian" = "target:slim-debian"
  }
  tags = concat(
    ["${REGISTRY}/claude:debian"],
    vtags(REGISTRY, "claude", CLAUDE_VERSION, "", "-debian"),
  )
  cache-from = ["type=registry,ref=${REGISTRY}/buildcache:claude-debian"]
  cache-to   = ["type=registry,ref=${REGISTRY}/buildcache:claude-debian,mode=max"]
}

# ==============================================================================
# FLUTTER
# ==============================================================================

target "flutter" {
  inherits = ["_common"]
  context = "./docker/flutter"
  dockerfile = "Dockerfile"
  contexts = {
    "aws" = "target:aws-debian"
  }
  tags = concat(
    ["${REGISTRY}/flutter:latest"],
    vtags(REGISTRY, "flutter", FLUTTER_VERSION, "", ""),
  )
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
  tags = concat(
    ["${REGISTRY}/typescript:latest", "${REGISTRY}/typescript:alpine"],
    vtags(REGISTRY, "typescript", BUN_VERSION, "", ""),
    vtags(REGISTRY, "typescript", BUN_VERSION, "", "-alpine"),
  )
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
  tags = concat(
    ["${REGISTRY}/typescript:debian"],
    vtags(REGISTRY, "typescript", BUN_VERSION, "", "-debian"),
  )
  cache-from = ["type=registry,ref=${REGISTRY}/buildcache:typescript-debian"]
  cache-to   = ["type=registry,ref=${REGISTRY}/buildcache:typescript-debian,mode=max"]
}

# ==============================================================================
# AWS
# ==============================================================================

group "aws" {
  targets = [
    "aws-alpine",
    "aws-debian",
  ]
}

target "aws-alpine" {
  inherits = ["_common"]
  context = "./docker/aws"
  dockerfile = "Dockerfile.alpine"
  contexts = {
    "alpine" = "target:slim-alpine"
  }
  tags = [
    "${REGISTRY}/aws:latest",
    "${REGISTRY}/aws:alpine",
  ]
  cache-from = ["type=registry,ref=${REGISTRY}/buildcache:aws-alpine"]
  cache-to   = ["type=registry,ref=${REGISTRY}/buildcache:aws-alpine,mode=max"]
}

target "aws-debian" {
  inherits = ["_common"]
  context = "./docker/aws"
  dockerfile = "Dockerfile.debian"
  contexts = {
    "debian" = "target:slim-debian"
  }
  tags = [
    "${REGISTRY}/aws:debian",
  ]
  cache-from = ["type=registry,ref=${REGISTRY}/buildcache:aws-debian"]
  cache-to   = ["type=registry,ref=${REGISTRY}/buildcache:aws-debian,mode=max"]
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
  tags = concat(
    ["${REGISTRY}/rover:latest"],
    vtags(REGISTRY, "rover", ROVER_VERSION, "", ""),
  )
  cache-from = ["type=registry,ref=${REGISTRY}/buildcache:rover"]
  cache-to   = ["type=registry,ref=${REGISTRY}/buildcache:rover,mode=max"]
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
    "golang-alpine" = "target:golang-alpine"
    "typescript"    = "target:typescript-alpine"
    "claude"        = "target:claude-alpine"
    "flutter"       = "target:flutter"
    "rover"         = "target:rover"
  }
  tags = concat(
    [
      "${REGISTRY}/alpine:latest",
      "${REGISTRY}/all-in-one:latest",
      "${REGISTRY}/all-in-one:alpine",
    ],
    all_in_one_tags(REGISTRY, "alpine-${split(".", ALPINE_VERSION)[0]}"),
  )
  cache-from = ["type=registry,ref=${REGISTRY}/buildcache:all-in-one-alpine"]
  cache-to   = ["type=registry,ref=${REGISTRY}/buildcache:all-in-one-alpine,mode=max"]
}

target "all-in-one-debian" {
  inherits = ["_common"]
  context = "./docker/all-in-one"
  dockerfile = "Dockerfile.debian"
  contexts = {
    "golang-debian" = "target:golang-debian"
    "typescript"    = "target:typescript-debian"
    "claude"        = "target:claude-debian"
    "flutter"       = "target:flutter"
    "rover"         = "target:rover"
  }
  tags = concat(
    [
      "${REGISTRY}/debian:latest",
      "${REGISTRY}/all-in-one:debian",
    ],
    all_in_one_tags(REGISTRY, "debian-${DEBIAN_RELEASE}"),
  )
  cache-from = ["type=registry,ref=${REGISTRY}/buildcache:all-in-one-debian"]
  cache-to   = ["type=registry,ref=${REGISTRY}/buildcache:all-in-one-debian,mode=max"]
}
