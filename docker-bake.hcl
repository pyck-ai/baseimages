# Docker Bake configuration for base images
#
# All build args are read from buildargs.conf via environment variables.
# Task automatically sources buildargs.conf before calling bake.
#
# Usage:
#   task build            # Build all images
#   task build -- golang  # Build golang image
#
# Or directly with docker:
#   set -a && source buildargs.conf && set +a && docker buildx bake
#   set -a && source buildargs.conf && set +a && docker buildx bake golang

variable "REGISTRY" {}
variable "GOLANG_VERSION" {}
variable "ALPINE_VERSION" {}
variable "DEBIAN_RELEASE" {}
variable "NGINX_VERSION" {}
variable "CLAUDE_VERSION" {}
variable "OPENCODE_VERSION" {}
variable "PI_VERSION" {}
variable "BUN_VERSION" {}
variable "PYTHON_VERSION" {}
variable "ROVER_VERSION" {}
variable "ACTIONS_RUNNER_VERSION" {}
variable "BUILDKIT_VERSION" {}

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
    vtags(registry, "all-in-one", PI_VERSION,       "${distro}-pi-",       ""),
    vtags(registry, "all-in-one", PYTHON_VERSION,   "${distro}-python-",   ""),
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
    "base", "golang", "python", "typescript", "agent",
    "rover", "all-in-one", "runner", "nginx", "static",
  ]
}

# There are deliberately no CI-specific groups (this file used to have three
# hand-maintained stage groups sequencing base → dependents → all-in-one). That
# ordering was redundant: it's already fully encoded in the `contexts = { x =
# "target:y" }"
# edges below, which is how bake knows a target needs another target built
# first. Running both mechanisms meant every stage boundary cut across a
# dependency edge, so build-images.yml re-resolved (and rebuilt) the subgraph
# beneath each stage on every invocation — base-alpine alone was built seven
# times per run. CI now derives its build matrix directly from these `contexts`
# edges (see build-images.yml's `discover` job), grouping targets into the
# connected components of the dependency graph and building each component in
# one `bake` invocation, which bake dedupes internally. Adding an image means
# declaring its target and edges here — nothing under .github/ needs to change.


# ==============================================================================
# AGENT
# ==============================================================================
#
# Bundles multiple coding-agent CLIs (Claude Code + opencode). Because it ships
# more than one tool, version tags are namespaced per tool — claude-<version> and
# opencode-<version> — mirroring the all-in-one per-tool tag convention.

group "agent" {
  targets = [
    "agent-alpine",
    "agent-debian",
  ]
}

target "agent-alpine" {
  inherits = ["_common"]
  context = "./docker/agent"
  dockerfile = "Dockerfile.alpine"
  contexts = {
    "base" = "target:base-alpine"
  }
  tags = concat(
    ["${REGISTRY}/agent:latest", "${REGISTRY}/agent:alpine"],
    vtags(REGISTRY, "agent", CLAUDE_VERSION,   "claude-",   ""),
    vtags(REGISTRY, "agent", CLAUDE_VERSION,   "claude-",   "-alpine"),
    vtags(REGISTRY, "agent", OPENCODE_VERSION, "opencode-", ""),
    vtags(REGISTRY, "agent", OPENCODE_VERSION, "opencode-", "-alpine"),
    vtags(REGISTRY, "agent", PI_VERSION,       "pi-",       ""),
    vtags(REGISTRY, "agent", PI_VERSION,       "pi-",       "-alpine"),
  )
  cache-from = ["type=registry,ref=${REGISTRY}/buildcache:agent-alpine"]
  cache-to   = ["type=registry,ref=${REGISTRY}/buildcache:agent-alpine,mode=max"]
}

target "agent-debian" {
  inherits = ["_common"]
  context = "./docker/agent"
  dockerfile = "Dockerfile.debian"
  contexts = {
    "base" = "target:base-debian"
  }
  tags = concat(
    ["${REGISTRY}/agent:debian"],
    vtags(REGISTRY, "agent", CLAUDE_VERSION,   "claude-",   "-debian"),
    vtags(REGISTRY, "agent", OPENCODE_VERSION, "opencode-", "-debian"),
    vtags(REGISTRY, "agent", PI_VERSION,       "pi-",       "-debian"),
  )
  cache-from = ["type=registry,ref=${REGISTRY}/buildcache:agent-debian"]
  cache-to   = ["type=registry,ref=${REGISTRY}/buildcache:agent-debian,mode=max"]
}


# ==============================================================================
# BASE
# ==============================================================================

group "base" {
  targets = [
    "base-alpine",
    "base-debian",
  ]
}

target "base-alpine" {
  inherits = ["_common"]
  context = "./docker/base"
  dockerfile = "Dockerfile.alpine"
  tags = concat(
    ["${REGISTRY}/base:latest", "${REGISTRY}/base:alpine"],
    vtags(REGISTRY, "base", ALPINE_VERSION, "alpine-", ""),
  )
  cache-from = ["type=registry,ref=${REGISTRY}/buildcache:alpine"]
  cache-to   = ["type=registry,ref=${REGISTRY}/buildcache:alpine,mode=max"]
}

target "base-debian" {
  inherits = ["_common"]
  context = "./docker/base"
  dockerfile = "Dockerfile.debian"
  tags = [
    "${REGISTRY}/base:debian",
    "${REGISTRY}/base:debian-${DEBIAN_RELEASE}",
  ]
  cache-from = ["type=registry,ref=${REGISTRY}/buildcache:debian"]
  cache-to   = ["type=registry,ref=${REGISTRY}/buildcache:debian,mode=max"]
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
    "base" = "target:base-alpine"
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
    "base" = "target:base-debian"
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
# PYTHON
# ==============================================================================

group "python" {
  targets = [
    "python-alpine",
    "python-debian",
  ]
}

target "python-alpine" {
  inherits = ["_common"]
  context = "./docker/python"
  dockerfile = "Dockerfile.alpine"
  contexts = {
    "base" = "target:base-alpine"
  }
  tags = concat(
    ["${REGISTRY}/python:latest", "${REGISTRY}/python:alpine"],
    vtags(REGISTRY, "python", PYTHON_VERSION, "", ""),
    vtags(REGISTRY, "python", PYTHON_VERSION, "", "-alpine"),
  )
  cache-from = ["type=registry,ref=${REGISTRY}/buildcache:python-alpine"]
  cache-to   = ["type=registry,ref=${REGISTRY}/buildcache:python-alpine,mode=max"]
}

target "python-debian" {
  inherits = ["_common"]
  context = "./docker/python"
  dockerfile = "Dockerfile.debian"
  contexts = {
    "base" = "target:base-debian"
  }
  tags = concat(
    ["${REGISTRY}/python:debian"],
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
    "base" = "target:base-debian"
  }
  tags = concat(
    ["${REGISTRY}/rover:latest"],
    vtags(REGISTRY, "rover", ROVER_VERSION, "", ""),
  )
  cache-from = ["type=registry,ref=${REGISTRY}/buildcache:rover-debian"]
  cache-to   = ["type=registry,ref=${REGISTRY}/buildcache:rover-debian,mode=max"]
}

# ==============================================================================
# STATIC
# ==============================================================================

target "static" {
  inherits = ["_common"]
  context = "./docker/static"
  dockerfile = "Dockerfile"
  contexts = {
    "base" = "target:base-alpine"
  }
  tags = [
    "${REGISTRY}/static:latest",
  ]
  cache-from = ["type=registry,ref=${REGISTRY}/buildcache:static"]
  cache-to   = ["type=registry,ref=${REGISTRY}/buildcache:static,mode=max"]
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
    "base" = "target:base-alpine"
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
    "base" = "target:base-debian"
  }
  tags = concat(
    ["${REGISTRY}/typescript:debian"],
    vtags(REGISTRY, "typescript", BUN_VERSION, "", "-debian"),
  )
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
    "base"       = "target:base-alpine"
    "golang"     = "target:golang-alpine"
    "typescript" = "target:typescript-alpine"
    "agent"      = "target:agent-alpine"
    "python"     = "target:python-alpine"
  }
  tags = concat(
    [
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
    "base"       = "target:base-debian"
    "golang"     = "target:golang-debian"
    "typescript" = "target:typescript-debian"
    "agent"      = "target:agent-debian"
    "rover"      = "target:rover-debian"
    "python"     = "target:python-debian"
  }
  tags = concat(
    [
      "${REGISTRY}/all-in-one:debian",
    ],
    all_in_one_tags(REGISTRY, "debian-${DEBIAN_RELEASE}"),
    vtags(REGISTRY, "all-in-one", ROVER_VERSION,  "debian-${DEBIAN_RELEASE}-rover-",  ""),
  )
  cache-from = ["type=registry,ref=${REGISTRY}/buildcache:all-in-one-debian"]
  cache-to   = ["type=registry,ref=${REGISTRY}/buildcache:all-in-one-debian,mode=max"]
}


# ==============================================================================
# RUNNER
# ==============================================================================
#
# all-in-one + the GitHub Actions runner agent + rootless BuildKit, for the
# self-hosted-kata ARC pool (pyck-ai/deployment). Serves as both the runner pod
# image and as a job `container:`. Debian only — the agent is a glibc .NET app.
#
# Version tags are namespaced per tool like agent/all-in-one: the runner version
# is the one GitHub can deprecate out from under us, so it gets the bare tags.

target "runner" {
  inherits = ["_common"]
  context = "./docker/runner"
  dockerfile = "Dockerfile.debian"
  contexts = {
    "all-in-one"    = "target:all-in-one-debian"
    "actionsrunner" = "docker-image://ghcr.io/actions/actions-runner:${ACTIONS_RUNNER_VERSION}"
    "buildkit"      = "docker-image://moby/buildkit:v${BUILDKIT_VERSION}-rootless"
  }
  tags = concat(
    ["${REGISTRY}/runner:latest", "${REGISTRY}/runner:debian"],
    vtags(REGISTRY, "runner", ACTIONS_RUNNER_VERSION, "", ""),
    vtags(REGISTRY, "runner", BUILDKIT_VERSION, "buildkit-", ""),
  )
  cache-from = ["type=registry,ref=${REGISTRY}/buildcache:runner"]
  cache-to   = ["type=registry,ref=${REGISTRY}/buildcache:runner,mode=max"]
}
