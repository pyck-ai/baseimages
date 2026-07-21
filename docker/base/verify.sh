#!/bin/bash
# Verifies the assembled base image. See docker/verify-lib.sh for the helpers.
# Run via `task verify -- base`.

. "$(dirname "$0")/../verify-lib.sh"

IMG=$1
VARIANT=$2

check_user     "$IMG" root 0
check_workdir  "$IMG" /app

# /app is the documented working directory, so it must be writable under the
# nonroot uid, not just the root default.
check_writable_as 65532 "$IMG" /app

# Shell, VCS and the archive/search tooling every downstream image relies on.
check_cmd "$IMG" bash git curl wget jq rg rsync rclone tar unzip zip xz zstd gpg make gcc file gawk patch ssh

# fd is packaged as `fd` on Alpine but as `fd-find` on Debian, which installs the
# binary as `fdfind`; the Debian Dockerfile symlinks it so the command name is the
# same on both. Assert the name, not the package.
check_cmd "$IMG" fd

# Third-party tools, checked against the versions buildargs.conf pins.
check_cmd     "$IMG" task flyctl gh helm kubectl kustomize watchexec
check_version "$IMG" "task --version"                "$TASKFILE_VERSION"
check_version "$IMG" "flyctl --version"              "version $FLYCTL_VERSION"
check_version "$IMG" "gh --version"                  "version $GHCLI_VERSION"
check_version "$IMG" "helm version"                  "Version:\"v$HELM_VERSION\""
check_version "$IMG" "kubectl version --client=true" "Client Version: v$KUBECTL_VERSION"
check_version "$IMG" "kustomize version"             "v$KUSTOMIZE_VERSION"
check_version "$IMG" "watchexec --version"           "watchexec $WATCHEXEC_VERSION"

# download.sh is inherited by every downstream image's build stages.
check_file "$IMG" /usr/local/sbin/download.sh

# Bind-mounted repositories are owned by the host user, not by nonroot, so git
# refuses to operate on them without this.
check_shell_cmd "$IMG" "git safe.directory covers any path" \
    'git config --system --get-all safe.directory | grep -qF "*"'

check_shell_cmd "$IMG" "CA certificates are usable" \
    'curl -sSf --max-time 20 https://github.com -o /dev/null'

check_shell_cmd "$IMG" "timezone is UTC" '[ "$(date +%Z)" = "UTC" ]'

[ "$VARIANT" = "debian" ] && check_env "$IMG" DEBIAN_FRONTEND noninteractive

verify_summary
