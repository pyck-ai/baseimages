#!/bin/sh
# Verifies the assembled base image, run INSIDE the image as its default user
# (root). See AGENTS.md for what belongs in a verify.sh.
#
# Invoked as:
#   docker run --rm --env-file buildargs.conf -e TARGET=base-alpine|base-debian \
#     -v $PWD/docker/base/verify.sh:/verify.sh:ro --entrypoint /bin/sh <ref> /verify.sh

fails=0
ck() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

# /app is the documented working directory, so it must be writable under the
# nonroot uid, not just the root default.
writable_app() {
    su -s /bin/sh -c 'mkdir -p /app && touch /app/.wprobe && rm -f /app/.wprobe' nonroot
}

ck "runs as root (uid 0)" '[ "$(id -u)" = 0 ]'
ck "WORKDIR is /app" '[ "$(pwd)" = /app ]'
ck "writable by uid 1001: /app" writable_app

ck "on PATH: bash git curl wget jq rg rsync rclone tar unzip zip xz zstd gpg make gcc file gawk patch ssh" '
    for c in bash git curl wget jq rg rsync rclone tar unzip zip xz zstd gpg make gcc file gawk patch ssh; do
        command -v "$c" >/dev/null 2>&1 || exit 1
    done
'
# fd is packaged as `fd` on Alpine but as `fd-find` on Debian, which installs
# the binary as `fdfind`; the Debian Dockerfile symlinks it so the command
# name is the same on both. Assert the name, not the package.
ck "on PATH: fd" 'command -v fd >/dev/null 2>&1'

ck "on PATH: task flyctl gh helm kubectl kustomize watchexec" '
    for c in task flyctl gh helm kubectl kustomize watchexec; do
        command -v "$c" >/dev/null 2>&1 || exit 1
    done
'

ck "task --version reports $TASKFILE_VERSION" 'task --version 2>&1 | grep -qF "$TASKFILE_VERSION"'
ck "flyctl --version reports version $FLYCTL_VERSION" 'flyctl --version 2>&1 | grep -qF "version $FLYCTL_VERSION"'
ck "gh --version reports version $GHCLI_VERSION" 'gh --version 2>&1 | grep -qF "version $GHCLI_VERSION"'
ck 'helm version reports Version:"v'"$HELM_VERSION"'"' 'helm version 2>&1 | grep -qF "Version:\"v$HELM_VERSION\""'
ck "kubectl version --client=true reports Client Version: v$KUBECTL_VERSION" 'kubectl version --client=true 2>&1 | grep -qF "Client Version: v$KUBECTL_VERSION"'
ck "kustomize version reports v$KUSTOMIZE_VERSION" 'kustomize version 2>&1 | grep -qF "v$KUSTOMIZE_VERSION"'
ck "watchexec --version reports watchexec $WATCHEXEC_VERSION" 'watchexec --version 2>&1 | grep -qF "watchexec $WATCHEXEC_VERSION"'

# download.sh is inherited by every downstream image's build stages.
ck "present: /usr/local/sbin/download.sh" '[ -e /usr/local/sbin/download.sh ]'

# Bind-mounted repositories are owned by the host user, not by nonroot, so git
# refuses to operate on them without this.
ck "git safe.directory covers any path" 'git config --system --get-all safe.directory | grep -qF "*"'

ck "CA certificates are usable" 'curl -sSf --max-time 20 https://github.com -o /dev/null'

ck "timezone is UTC" '[ "$(date +%Z)" = "UTC" ]'

case "$TARGET" in
    *-debian)
        ck "DEBIAN_FRONTEND=noninteractive" '[ "$DEBIAN_FRONTEND" = noninteractive ]'
        ;;
esac

exit $((fails > 0))
