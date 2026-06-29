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
variable "OPENCODE_VERSION" {}
variable "FLUTTER_VERSION" {}
variable "BUN_VERSION" {}
variable "PYTHON_VERSION" {}
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
    vtags(registry, "all-in-one", GOLANG_VERSION,   "${distro}-golang-",   ""),
    vtags(registry, "all-in-one", BUN_VERSION,      "${distro}-bun-",      ""),
    vtags(registry, "all-in-one", CLAUDE_VERSION,   "${distro}-claude-",   ""),
    vtags(registry, "all-in-one", OPENCODE_VERSION, "${distro}-opencode-", ""),
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
  ]
}

# CI build stages — used by build.yml to enforce ordering.
# ci-stage-1 (slim) → ci-stage-2 (direct slim dependents) → ci-stage-3 (all-in-one).
# Each stage fans out in parallel across targets.

group "ci-stage-1" {
  targets = [
    "slim",
    "nginx",
  ]
}

group "ci-stage-2" {
  targets = [
    "static",
    "golang",
    "agents",
    "typescript",
    "python",
    "rover",
    "flutter",
  ]
}

group "ci-stage-3" {
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

group "static" {
  targets = [
    "static-alpine",
  ]
}

target "static-alpine" {
  inherits = ["_common"]
  context = "./docker/static"
  dockerfile = "Dockerfile.alpine"
  contexts = {
    "alpine" = "target:slim-alpine"
  }
  tags = [
    "${REGISTRY}/static:latest",
  ]
  cache-from = ["type=registry,ref=${REGISTRY}/buildcache:static-alpine"]
  cache-to   = ["type=registry,ref=${REGISTRY}/buildcache:static-alpine,mode=max"]
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

group "nginx" {
  targets = [
    "nginx-alpine",
  ]
}

target "nginx-alpine" {
  inherits = ["_common"]
  context = "./docker/nginx"
  dockerfile = "Dockerfile.alpine"
  tags = concat(
    ["${REGISTRY}/nginx:latest"],
    vtags(REGISTRY, "nginx", NGINX_VERSION, "", ""),
  )
  cache-from = ["type=registry,ref=${REGISTRY}/buildcache:nginx-alpine"]
  cache-to   = ["type=registry,ref=${REGISTRY}/buildcache:nginx-alpine,mode=max"]
}

# ==============================================================================
# AGENTS
# ==============================================================================
#
# Bundles multiple coding-agent CLIs (Claude Code + opencode). Because it ships
# more than one tool, version tags are namespaced per tool — claude-<version> and
# opencode-<version> — mirroring the all-in-one per-tool tag convention.

group "agents" {
  targets = [
    "agents-alpine",
    "agents-debian",
  ]
}

target "agents-alpine" {
  inherits = ["_common"]
  context = "./docker/agents"
  dockerfile = "Dockerfile.alpine"
  contexts = {
    "alpine" = "target:slim-alpine"
  }
  tags = concat(
    ["${REGISTRY}/agents:latest", "${REGISTRY}/agents:alpine"],
    vtags(REGISTRY, "agents", CLAUDE_VERSION,   "claude-",   ""),
    vtags(REGISTRY, "agents", CLAUDE_VERSION,   "claude-",   "-alpine"),
    vtags(REGISTRY, "agents", OPENCODE_VERSION, "opencode-", ""),
    vtags(REGISTRY, "agents", OPENCODE_VERSION, "opencode-", "-alpine"),
  )
  cache-from = ["type=registry,ref=${REGISTRY}/buildcache:agents-alpine"]
  cache-to   = ["type=registry,ref=${REGISTRY}/buildcache:agents-alpine,mode=max"]
}

target "agents-debian" {
  inherits = ["_common"]
  context = "./docker/agents"
  dockerfile = "Dockerfile.debian"
  contexts = {
    "debian" = "target:slim-debian"
  }
  tags = concat(
    ["${REGISTRY}/agents:debian"],
    vtags(REGISTRY, "agents", CLAUDE_VERSION,   "claude-",   "-debian"),
    vtags(REGISTRY, "agents", OPENCODE_VERSION, "opencode-", "-debian"),
  )
  cache-from = ["type=registry,ref=${REGISTRY}/buildcache:agents-debian"]
  cache-to   = ["type=registry,ref=${REGISTRY}/buildcache:agents-debian,mode=max"]
}

# ==============================================================================
# FLUTTER
# ==============================================================================

group "flutter" {
  targets = [
    "flutter-alpine",
    "flutter-debian",
  ]
}

target "flutter-alpine" {
  inherits = ["_common"]
  context = "./docker/flutter"
  dockerfile = "Dockerfile.alpine"
  contexts = {
    "alpine" = "target:slim-alpine"
  }
  tags = concat(
    ["${REGISTRY}/flutter:latest", "${REGISTRY}/flutter:alpine"],
    vtags(REGISTRY, "flutter", FLUTTER_VERSION, "", ""),
    vtags(REGISTRY, "flutter", FLUTTER_VERSION, "", "-alpine"),
  )
  cache-from = ["type=registry,ref=${REGISTRY}/buildcache:flutter-alpine"]
  cache-to   = ["type=registry,ref=${REGISTRY}/buildcache:flutter-alpine,mode=max"]
}

target "flutter-debian" {
  inherits = ["_common"]
  context = "./docker/flutter"
  dockerfile = "Dockerfile.debian"
  contexts = {
    "debian" = "target:slim-debian"
  }
  tags = concat(
    ["${REGISTRY}/flutter:debian"],
    vtags(REGISTRY, "flutter", FLUTTER_VERSION, "", "-debian"),
  )
  cache-from = ["type=registry,ref=${REGISTRY}/buildcache:flutter-debian"]
  cache-to   = ["type=registry,ref=${REGISTRY}/buildcache:flutter-debian,mode=max"]
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
    [
      "${REGISTRY}/typescript:latest", 
      "${REGISTRY}/typescript:alpine",
    ],
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
# PYTHON
# ==============================================================================

group "python" {
  targets = [
    "python-debian",
  ]
}

target "python-debian" {
  inherits = ["_common"]
  context = "./docker/python"
  dockerfile = "Dockerfile.debian"
  contexts = {
    "debian" = "target:slim-debian"
  }
  tags = concat(
    [
      "${REGISTRY}/python:latest",
      "${REGISTRY}/python:debian",
    ],
    vtags(REGISTRY, "python", PYTHON_VERSION, "", ""),
    vtags(REGISTRY, "python", PYTHON_VERSION, "", "-debian"),
  )
  cache-from = ["type=registry,ref=${REGISTRY}/buildcache:python-debian"]
  cache-to   = ["type=registry,ref=${REGISTRY}/buildcache:python-debian,mode=max"]
}

# ==============================================================================
# ROVER
# ==============================================================================

group "rover" {
  targets = [
    "rover-debian",
  ]
}

target "rover-debian" {
  inherits = ["_common"]
  context = "./docker/rover"
  dockerfile = "Dockerfile.debian"
  contexts = {
    "debian" = "target:slim-debian"
  }
  tags = concat(
    ["${REGISTRY}/rover:latest", "${REGISTRY}/rover:debian"],
    vtags(REGISTRY, "rover", ROVER_VERSION, "", ""),
    vtags(REGISTRY, "rover", ROVER_VERSION, "", "-debian"),
  )
  cache-from = ["type=registry,ref=${REGISTRY}/buildcache:rover-debian"]
  cache-to   = ["type=registry,ref=${REGISTRY}/buildcache:rover-debian,mode=max"]
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
    "claude"        = "target:agents-alpine"
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
    "claude"        = "target:agents-debian"
    "rover"         = "target:rover-debian"
    "python"        = "target:python-debian"
  }
  tags = concat(
    [
      "${REGISTRY}/debian:latest",
      "${REGISTRY}/all-in-one:debian",
    ],
    all_in_one_tags(REGISTRY, "debian-${DEBIAN_RELEASE}"),
    vtags(REGISTRY, "all-in-one", ROVER_VERSION,  "debian-${DEBIAN_RELEASE}-rover-",  ""),
    vtags(REGISTRY, "all-in-one", PYTHON_VERSION, "debian-${DEBIAN_RELEASE}-python-", ""),
  )
  cache-from = ["type=registry,ref=${REGISTRY}/buildcache:all-in-one-debian"]
  cache-to   = ["type=registry,ref=${REGISTRY}/buildcache:all-in-one-debian,mode=max"]
}
