# Runner Image

GitHub Actions runner image for the `self-hosted-kata` ARC pool: the [all-in-one](../all-in-one/README.md) toolset plus the [actions/runner](https://github.com/actions/runner) agent plus rootless [BuildKit](https://github.com/moby/buildkit). One image that serves as both the **runner pod** and a job **`container:`**, so a job gets the same toolchain whether or not it declares one, and can build container images without a Docker daemon.

## Based on

Our [all-in-one](../all-in-one/README.md) image: `all-in-one:debian`. The runner agent is a glibc .NET application, so no Alpine variant is provided.

The agent is copied from `ghcr.io/actions/actions-runner:<runner_version>` and the BuildKit binaries from `moby/buildkit:v<buildkit_version>-rootless`. Current versions are defined in [`buildargs.conf`](../../buildargs.conf) (`ACTIONS_RUNNER_VERSION`, `BUILDKIT_VERSION`).

## Tags

Because the image ships more than one versioned component, BuildKit tags are namespaced (`buildkit-…`). The runner agent takes the bare version tags: it is the component GitHub can deprecate out from under us, so it is the one worth pinning.

| Tag | Description |
|-----|-------------|
| `runner:latest` | Most recent build |
| `runner:debian` | Most recent build |
| `runner:<version>` | Exact pinned `actions/runner` version (also `<major>` / `<major.minor>` aliases) |
| `runner:buildkit-<version>` | Exact pinned BuildKit version (also `buildkit-<major>` / `buildkit-<major.minor>` aliases) |

## What is included

Everything in [all-in-one](../all-in-one/README.md) (Debian), plus the two components below. Supports `linux/amd64` and `linux/arm64`.

### GitHub Actions runner agent

Copied verbatim from `ghcr.io/actions/actions-runner` into `/home/runner`. That path is an interface, not a choice: ARC's chart hardcodes `command: ["/home/runner/run.sh"]` and `ACTIONS_RUNNER_CONTAINER_HOOKS=/home/runner/k8s-novolume/index.js`.

Native dependencies (libicu, libssl, libkrb5, …) are installed by the agent's own `bin/installdependencies.sh` so they track each runner release rather than a hand-maintained `apt` line. Passwordless `sudo` is granted to uid 1001, mirroring upstream's image — some actions assume it.

### Rootless BuildKit

Builds container images inside the job with no Docker daemon, no `dind` sidecar and no `privileged: true`. Only the statically-linked binaries are copied from the vendor image; the rest comes from `apt`.

| Tool | Binary | Source |
|------|--------|--------|
| [BuildKit](https://github.com/moby/buildkit) daemon | `buildkitd` | `moby/buildkit:rootless`, `BUILDKIT_VERSION` |
| BuildKit client | `buildctl` | `moby/buildkit:rootless`, `BUILDKIT_VERSION` |
| runc (BuildKit build) | `buildkit-runc` | `moby/buildkit:rootless` — keeps its name, buildkitd looks for `buildkit-runc` before `runc` |
| [RootlessKit](https://github.com/rootless-containers/rootlesskit) | `rootlesskit` | `moby/buildkit:rootless` |
| Daemonless wrapper | `buildctl-daemonless.sh` | `moby/buildkit:rootless` — spawns an ephemeral `buildkitd` per build |
| uid/gid mapping helpers | `newuidmap`, `newgidmap` | Debian `uidmap` package (see [Notes](#notes)) |

Deliberately **not** copied from the vendor image: `buildkit-cni-*` (rootless forces `network=host`), `buildkit-qemu-*` (cross-arch needs host `binfmt_misc`), and `fuse-overlayfs`/`fusermount3` (see [Notes](#notes)).

### Environment

| Variable | Value | Description |
|----------|-------|--------------|
| `RUNNER_MANUALLY_TRAP_SIG` | `1` | Agent traps signals itself (as upstream) |
| `ACTIONS_RUNNER_PRINT_LOG_TO_STDOUT` | `1` | Agent logs to stdout, not only to `_diag/` |
| `XDG_RUNTIME_DIR` | `/run/user/1001` | Required by `buildctl-daemonless.sh`, which dereferences it unguarded under `set -eu` |
| `TMPDIR` | `/home/nonroot/.local/tmp` | BuildKit scratch space |
| `BUILDKIT_HOST` | `unix:///run/user/1001/buildkit/buildkitd.sock` | Where the ephemeral daemon listens |

Everything from [all-in-one](../all-in-one/README.md) (`GOPATH`, `GOCACHE`, `BUN_INSTALL`, `UV_PYTHON_INSTALL_DIR`, …) is inherited unchanged.

### Default user

Runs as `nonroot` (uid/gid 1001) by default — **unlike** the other build-substrate images in this repo, which default to root. ARC runs the pod as the image's declared `USER`, and the runner agent refuses to run as root. `WORKDIR` is `/home/runner`.

uid 1001 is load-bearing across three things that must agree: our `nonroot` account, upstream's `runner` account, and the uid ARC's `securityContext` applies (see [base](../base/README.md)). It is what lets the agent's files land with an owner that already exists here.

## Usage

### As the runner pod image

In `values/gha-runner-scale-set-kata.yaml.gotmpl` (pyck-ai/deployment):

```yaml
containers:
  - name: runner
    image: ghcr.io/pyck-ai/baseimages/runner:2.337.0
```

Jobs without a `container:` then execute directly in this image, with the full toolchain available and no per-job image pull.

### As a job container

```yaml
jobs:
  test:
    runs-on: self-hosted-kata
    container:
      image: ghcr.io/pyck-ai/baseimages/runner:latest
    steps:
      - run: go test ./...
```

### Building an image inside a job

```yaml
    steps:
      - run: |
          buildctl-daemonless.sh build \
            --frontend dockerfile.v0 \
            --local context=. --local dockerfile=. \
            --output type=image,name=ghcr.io/pyck-ai/foo:$GITHUB_SHA,push=true
        env:
          BUILDKITD_FLAGS: --oci-worker-no-process-sandbox
```

`--oci-worker-no-process-sandbox` is required under Kubernetes (see [Notes](#notes)). Cache is registry-only (`--export-cache type=registry,…`); there is no persistent local layer cache, because kata-fc has no virtio-fs and nothing on the node can be mounted into the guest.

## Notes

- **subuid/subgid**: RootlessKit always shells out to `newuidmap`/`newgidmap` and hard-fails without a subuid range — there is no single-uid fallback. `/etc/subuid` and `/etc/subgid` carry `nonroot:100000:65536`. The vendor image preseeds the same range for its own user, which is why a build that passes in `moby/buildkit:rootless` fails in any hand-rolled image that forgets it. The vendor's `newuidmap`/`newgidmap` are musl-linked and `COPY` drops their file capabilities, so they come from Debian's `uidmap` instead.
- **`--oci-worker-no-process-sandbox`**: Kubernetes masks `/proc` by default, and the kernel refuses a fresh procfs mount inside a nested user namespace unless the parent `/proc` is fully visible. The flag makes `RUN` steps share buildkitd's PID namespace instead of each getting their own. Cost: a `RUN` step can see and kill buildkitd's other processes — a non-issue inside a throwaway per-job microVM.
- **Snapshotter**: buildkitd picks it by probing, not by kernel version — it attempts a real nested overlay mount at its state root (`/home/nonroot/.local/share/buildkit`) and falls back to `fuse-overlayfs`, then `native`, if that fails. Under kata-fc with the devmapper snapshotter the container rootfs is ext4 inside the guest, so plain `overlayfs` is expected. `fuse-overlayfs` is not installed: `/dev/fuse` is not available in the pod anyway.
- **Verification**: `verify.sh` does not perform an actual rootless build. That needs unprivileged nested user namespaces, which the CI host (a privileged `dind` sidecar on Ubuntu 24.04, `kernel.apparmor_restrict_unprivileged_userns=1`) does not grant regardless of the image being correct. It checks presence, versions, subuid ranges and capabilities instead; the end-to-end build is proven on the pool itself by pyck-ai/deployment's kata smoke test.

## Build

```sh
task build -- runner
```
