# Runner Image

[all-in-one](../all-in-one/README.md) plus the GitHub Actions runner agent plus rootless BuildKit. One image that serves as both the **runner pod** on the `self-hosted-kata` ARC pool and as a **job `container:`** — so a job gets the same toolchain whether or not it declares one, and can build container images without a Docker daemon.

Debian only. The trunk is `all-in-one:debian`; there is no Alpine variant because the runner agent is a glibc .NET app.

## Tags

| Tag | Description |
|-----|-------------|
| `runner:latest` | Most recent build |
| `runner:debian` | Same, spelled out |
| `runner:<runner_version>` | Exact `actions/runner` version, e.g. `runner:2.337.0` |
| `runner:<major>.<minor>` | Minor alias of the runner version |
| `runner:buildkit-<version>` | Exact BuildKit version, e.g. `runner:buildkit-0.33.0` |

The `actions/runner` version is the one that matters operationally: GitHub deprecates old runner versions server-side and a deprecated agent crash-loops every pod in the pool (`AccessDeniedException: Runner version ... is deprecated and cannot receive messages`). `ACTIONS_RUNNER_VERSION` is pinned in [`buildargs.conf`](../../buildargs.conf) with a Renovate annotation so that bump is automatic.

## What is included

Everything in [all-in-one](../all-in-one/README.md), plus:

### GitHub Actions runner agent

Copied verbatim from `ghcr.io/actions/actions-runner:<ACTIONS_RUNNER_VERSION>` into `/home/runner`. That path is an interface, not a choice: ARC's chart hardcodes `command: ["/home/runner/run.sh"]` and `ACTIONS_RUNNER_CONTAINER_HOOKS=/home/runner/k8s-novolume/index.js`.

Native dependencies (libicu, libssl, libkrb5 …) are installed by the agent's own `bin/installdependencies.sh`, so they track each runner release rather than a hand-maintained apt line.

Passwordless `sudo` is granted to uid 1001, mirroring upstream's image.

### Rootless BuildKit

| Binary | Source | Notes |
|--------|--------|-------|
| `buildkitd`, `buildctl` | `moby/buildkit:v<BUILDKIT_VERSION>-rootless` | static |
| `buildkit-runc` | same | static; keeps its name — buildkitd looks for `buildkit-runc` before `runc` |
| `rootlesskit` | same | static |
| `buildctl-daemonless.sh` | same | spawns an ephemeral `buildkitd` per build |
| `newuidmap`, `newgidmap` | apt `uidmap` | **not** copied from the vendor image — those are musl-linked and `COPY` drops their file capabilities |

Deliberately **not** included from the vendor image: `buildkit-cni-*` (rootless forces `network=host`), `buildkit-qemu-*` (cross-arch needs host `binfmt_misc`), `fuse-overlayfs`/`fusermount3` (not needed on kernel ≥ 5.11 — see below).

RootlessKit always shells out to `newuidmap`/`newgidmap` and hard-fails without a subuid range; there is no single-uid fallback. `/etc/subuid` and `/etc/subgid` therefore carry `nonroot:100000:65536`. This is the detail that makes a build which passes in `moby/buildkit:rootless` (which preseeds the same range) fail in any hand-rolled image that forgets it.

### Environment

| Variable | Value | Description |
|----------|-------|-------------|
| `RUNNER_MANUALLY_TRAP_SIG` | `1` | Agent traps signals itself (as upstream) |
| `ACTIONS_RUNNER_PRINT_LOG_TO_STDOUT` | `1` | Agent logs to stdout, not only `_diag/` |
| `XDG_RUNTIME_DIR` | `/run/user/1001` | Required by `buildctl-daemonless.sh` (`set -eu`, unguarded) |
| `TMPDIR` | `/home/nonroot/.local/tmp` | BuildKit scratch |
| `BUILDKIT_HOST` | `unix:///run/user/1001/buildkit/buildkitd.sock` | Where the ephemeral daemon listens |

Plus everything inherited from all-in-one (`GOPATH`, `GOCACHE`, `BUN_INSTALL`, `UV_PYTHON_INSTALL_DIR`, …).

### Default user

Runs as **uid 1001** (`nonroot`), `WORKDIR /home/runner`. Unlike the other images in this repo this one does **not** default to root: ARC runs the pod as the image's default user and the agent refuses to run as root.

uid 1001 is load-bearing across three places that must agree: our `nonroot` account, upstream's `runner` account, and the `securityContext` ARC applies. See the comment in [base](../base/Dockerfile.debian).

## Usage

### As the runner pod image (no `container:`)

In `values/gha-runner-scale-set-kata.yaml.gotmpl` (pyck-ai/deployment):

```yaml
containers:
  - name: runner
    image: ghcr.io/pyck-ai/baseimages/runner:2.337.0
```

Jobs without a `container:` then execute directly in this image, with the full toolchain available and no per-job image pull.

### As a job `container:`

```yaml
jobs:
  build:
    runs-on: self-hosted-kata
    container:
      image: ghcr.io/pyck-ai/baseimages/runner:latest
    steps:
      - run: go test ./...
```

### Building an image inside a job, no Docker daemon

```yaml
      - run: |
          buildctl-daemonless.sh build \
            --frontend dockerfile.v0 \
            --local context=. --local dockerfile=. \
            --output type=image,name=ghcr.io/pyck-ai/foo:$GITHUB_SHA,push=true
        env:
          BUILDKITD_FLAGS: --oci-worker-no-process-sandbox
```

`--oci-worker-no-process-sandbox` is required under Kubernetes: the default masked `/proc` refuses a fresh procfs mount inside the nested user namespace, so `RUN` steps share buildkitd's PID namespace instead. Cost: a `RUN` step can see and kill buildkitd's other processes — a non-issue inside a throwaway per-job microVM.

Cache is registry-only (`--export-cache type=registry,...`). There is no persistent local layer cache: kata-fc has no virtio-fs, so nothing on the node can be mounted into the guest.

## Snapshotter

buildkitd picks its snapshotter by **probing**, not by kernel version: it attempts a real nested overlay mount at its state root (`/home/nonroot/.local/share/buildkit`) and only falls back to `fuse-overlayfs` or `native` if that fails. Under kata-fc with the devmapper snapshotter the container rootfs is ext4 inside the guest, so the nested mount is expected to succeed and plain `overlayfs` is used. On a plain containerd/overlayfs node the probe fails and it silently drops to `native` (full copies) — `fuse-overlayfs` is not installed here, because `/dev/fuse` is not available in the pod anyway.

## Build

```sh
task build -- runner
task verify -- runner
```

The verify script includes an end-to-end rootless build. On an Ubuntu 24.04 **host** that needs `kernel.apparmor_restrict_unprivileged_userns=0`, the same as any rootless container runtime.
