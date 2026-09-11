#!/bin/bash
# Verifies the assembled runner image. See docker/verify-lib.sh for the helpers.
# Run via `task verify -- runner`.

. "$(dirname "$0")/../verify-lib.sh"

IMG=$1
VARIANT=$2

# ARC runs the pod as the image's default user and expects it to be uid 1001.
check_user    "$IMG" nonroot 1001
check_workdir "$IMG" /home/runner

# The agent and its hooks live at paths ARC's chart hardcodes.
check_file "$IMG" /home/runner/run.sh
check_file "$IMG" /home/runner/bin/Runner.Listener
check_file "$IMG" /home/runner/k8s-novolume/index.js
check_file "$IMG" /home/runner/k8s/index.js

check_env "$IMG" RUNNER_MANUALLY_TRAP_SIG 1
check_env "$IMG" ACTIONS_RUNNER_PRINT_LOG_TO_STDOUT 1
check_env "$IMG" USER nonroot
check_env "$IMG" HOME /home/nonroot

# Everything all-in-one ships must still be here — this image is a superset.
check_cmd "$IMG" go gofmt dlv golangci-lint gotestsum go-arch-lint\
    bun node pi claude opencode rover\
    python python3 pip uv uvx ruff\
    task flyctl gh helm kubectl kustomize watchexec\
    sudo git

check_version "$IMG" "go version"          "go${GOLANG_VERSION}"
check_version "$IMG" "bun --version"       "${BUN_VERSION}"
check_version "$IMG" "python --version"    "${PYTHON_VERSION}"
check_version "$IMG" "task --version"      "${TASKFILE_VERSION}"

# The agent's .NET runtime needs libicu et al.; a missing dependency only shows
# up when the binary is actually executed.
check_shell_cmd "$IMG" "runner agent starts and reports its version" \
    "/home/runner/bin/Runner.Listener --version | grep -qF '${ACTIONS_RUNNER_VERSION}'"

check_shell_cmd "$IMG" "passwordless sudo works" 'sudo -n true'

# Rootless BuildKit: the five static binaries, plus the pieces that must come
# from apt because the vendor's are musl-linked.
check_cmd "$IMG" buildkitd buildctl buildkit-runc rootlesskit buildctl-daemonless.sh\
    newuidmap newgidmap

check_version "$IMG" "buildctl --version"  "v${BUILDKIT_VERSION}"
check_version "$IMG" "buildkitd --version" "v${BUILDKIT_VERSION}"

check_env "$IMG" XDG_RUNTIME_DIR /run/user/1001
check_env "$IMG" BUILDKIT_HOST   unix:///run/user/1001/buildkit/buildkitd.sock

# RootlessKit hard-fails without a subuid range for the invoking user. Checked
# here because a build that passed in moby/buildkit:rootless (which preseeds
# one) would otherwise fail in this image with no hint why.
check_shell_cmd "$IMG" "subuid range for nonroot" 'grep -qE "^(nonroot|1001):100000:65536$" /etc/subuid'
check_shell_cmd "$IMG" "subgid range for nonroot" 'grep -qE "^(nonroot|1001):100000:65536$" /etc/subgid'
# File capabilities, not setuid — see the Dockerfile comment above the
# `setcap` RUN. Asserting both directions: cap_setuid/cap_setgid present AND
# the setuid/setgid bits actually gone, not just "one of the two mechanisms
# is present", since the whole point is that this image does NOT rely on
# CAP_SYS_ADMIN the way a plain setuid-root newuidmap would.
check_shell_cmd "$IMG" "newuidmap has cap_setuid (file capability, not setuid)" \
    'getcap /usr/bin/newuidmap 2>/dev/null | grep -q cap_setuid'
check_shell_cmd "$IMG" "newgidmap has cap_setgid (file capability, not setuid)" \
    'getcap /usr/bin/newgidmap 2>/dev/null | grep -q cap_setgid'
check_shell_cmd "$IMG" "newuidmap/newgidmap are NOT setuid" \
    '[ ! -u /usr/bin/newuidmap ] && [ ! -u /usr/bin/newgidmap ]'

# /go/pkg itself, not just /go/pkg/mod — see the Dockerfile comment above the
# `chown nonroot:nonroot /go/pkg` RUN. This is the one that actually catches
# the bug: /go/pkg/mod was always nonroot-owned, so a check that only covered
# it would have passed even with the parent broken.
check_writable_as 1001 "$IMG" /run/user/1001 /home/nonroot/.local/tmp /home/nonroot/.local/share/buildkit\
    /home/runner /go /go/bin /go/pkg /go/pkg/mod /var/cache/go /bun /bun/bin /usr/local/python

# NOT an actual build: that needs unprivileged nested user namespaces, which
# the CI host does not grant (it builds inside a privileged dind sidecar on
# Ubuntu 24.04, which sets kernel.apparmor_restrict_unprivileged_userns=1).
# This pool's real target, a kata-fc guest, has no such restriction — proven
# separately in pyck-ai/deployment's kata-pool smoke test. Here we only check
# that rootlesskit itself runs and that buildctl-daemonless.sh is valid, both
# of which need no userns at all.
check_shell_cmd "$IMG" "rootlesskit runs" 'rootlesskit --version'
check_shell_cmd "$IMG" "buildctl-daemonless.sh is valid shell" 'sh -n /usr/bin/buildctl-daemonless.sh'

verify_summary
