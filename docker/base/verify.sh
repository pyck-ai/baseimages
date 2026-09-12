#!/bin/sh
# Verifies the assembled base image, run INSIDE the image as its default user.
#
#   docker run --rm --env-file buildargs.conf -e TARGET=base-alpine \
#     -v $PWD/docker/base/verify.sh:/verify.sh:ro --entrypoint /bin/sh <ref> /verify.sh
#
# Every buildargs.conf key is in the environment, so versions are plain "$VARS".

fails=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }

check_user() {
    if [ "$(id -u)" = "$1" ]; then ok "runs as uid $1"; else bad "runs as uid $(id -u), want $1"; fi
}

check_workdir() {
    if [ "$(pwd)" = "$1" ]; then ok "workdir is $1"; else bad "workdir is $(pwd), want $1"; fi
}

check_env() {
    if [ "$(printenv "$1")" = "$2" ]; then ok "$1=$2"; else bad "$1=$(printenv "$1"), want $2"; fi
}

check_cmd() {
    missing=
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
    done
    if [ -z "$missing" ]; then ok "on PATH: $*"; else bad "not on PATH:$missing"; fi
}

check_file() {
    missing=
    for f in "$@"; do
        [ -e "$f" ] || missing="$missing $f"
    done
    if [ -z "$missing" ]; then ok "present: $*"; else bad "absent:$missing"; fi
}

# Runs a command and looks for a substring, so a version bump in buildargs.conf
# fails the check instead of silently passing.
check_version() {
    out=$(sh -c "$1" 2>&1)
    case "$out" in
        *"$2"*) ok "$1 reports $2" ;;
        *)      bad "$1 does not report $2: $out" ;;
    esac
}

# Build-substrate images default to root, so a plain writability check on them
# is trivially true. This asserts the path still works when dropped to nonroot.
check_writable_as() {
    u=$1
    shift
    for d in "$@"; do
        if su "$u" -s /bin/sh -c "mkdir -p '$d/.verify' && rmdir '$d/.verify'" 2>/dev/null; then
            ok "writable by $u: $d"
        else
            bad "not writable by $u: $d"
        fi
    done
}

check_user 0
check_workdir /app

# /app is the documented working directory, so it must be writable under the
# nonroot uid, not just the root default.
check_writable_as nonroot /app

# Shell, VCS and the archive/search tooling every downstream image relies on.
check_cmd bash git curl wget jq rg rsync rclone tar unzip zip xz zstd gpg make gcc file gawk patch ssh

# fd is packaged as `fd` on Alpine but `fd-find` on Debian, which installs the
# binary as `fdfind`; the Debian Dockerfile symlinks it. Assert the name.
check_cmd fd

# Third-party tools, checked against the versions buildargs.conf pins.
check_cmd task flyctl gh helm kubectl kustomize watchexec
check_version "task --version"                "$TASKFILE_VERSION"
check_version "flyctl --version"              "version $FLYCTL_VERSION"
check_version "gh --version"                  "version $GHCLI_VERSION"
check_version "helm version"                  "Version:\"v$HELM_VERSION\""
check_version "kubectl version --client=true" "Client Version: v$KUBECTL_VERSION"
check_version "kustomize version"             "v$KUSTOMIZE_VERSION"
check_version "watchexec --version"           "watchexec $WATCHEXEC_VERSION"

# download.sh is inherited by every downstream image's build stages.
check_file /usr/local/sbin/download.sh

case "$TARGET" in
    *-debian) check_env DEBIAN_FRONTEND noninteractive ;;
esac

# Bind-mounted repositories are owned by the host user, not by nonroot, so git
# refuses to operate on them without this.
if git config --system --get-all safe.directory | grep -qF '*'; then
    ok "git safe.directory covers any path"
else
    bad "git safe.directory covers any path"
fi

if curl -sSf --max-time 20 https://github.com -o /dev/null; then
    ok "CA certificates are usable"
else
    bad "CA certificates are usable"
fi

if [ "$(date +%Z)" = UTC ]; then
    ok "timezone is UTC"
else
    bad "timezone is UTC, got $(date +%Z)"
fi

exit $((fails > 0))
