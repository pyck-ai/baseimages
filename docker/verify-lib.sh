#!/bin/bash
# Shared helpers for the per-image verify.sh scripts.
#
# These verify an ASSEMBLED image, which is different from `download.sh --verify`:
# that one checks a tool inside the build stage that installed it, this one checks
# the final image a consumer actually pulls. Bugs that only appear after all the
# COPYs are stitched together — a missing binary, a root-owned cache directory, a
# typo'd USER — are invisible to the build and are exactly what this catches.
#
# Most checks run the image as its DEFAULT user, asserting the image's declared
# default. Build-substrate images now default to root, so the `_as <uid>`
# variants additionally assert that the image still works when dropped to
# nonroot via `--user 1001` — otherwise a writability/smoke check under a
# root default would be trivially true and lose all signal.
#
# Sourced by docker/<image>/verify.sh, which is invoked by the top-level verify.sh:
#   verify.sh <image-ref> <variant>
# with every buildargs.conf key exported into the environment.

set -uo pipefail

_VERIFY_FAILED=0
_VERIFY_CHECKS=0

_pass() { _VERIFY_CHECKS=$((_VERIFY_CHECKS + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
_fail() {
    _VERIFY_CHECKS=$((_VERIFY_CHECKS + 1))
    _VERIFY_FAILED=$((_VERIFY_FAILED + 1))
    printf '  \033[31m✗\033[0m %s\n' "$1"
    [ -n "${2:-}" ] && printf '      %s\n' "$2"
    return 0
}

# run <image> <args...> — run as the image's default user.
run() { docker run --rm --entrypoint sh "$1" -c "${*:2}" 2>&1; }

# run_root <image> <args...> — run as root, for inspecting things the default user cannot read.
run_root() { docker run --rm --user 0 --entrypoint sh "$1" -c "${*:2}" 2>&1; }

# run_as <uid> <image> <args...> — run as an explicit uid. Used to assert the
# nonroot-on-demand path on images that now default to root.
run_as() { local uid=$1; shift; docker run --rm --user "$uid" --entrypoint sh "$1" -c "${*:2}" 2>&1; }

# check_writable_as <uid> <image> <path>... — the given uid can write there.
check_writable_as() {
    local uid=$1 img=$2 denied out
    shift 2
    out=$(run_as "$uid" "$img" 'for d in '"$*"'; do (mkdir -p "$d" && touch "$d/.wprobe" && rm -f "$d/.wprobe") 2>/dev/null || echo "$d"; done')
    denied=$(echo "$out" | tr -d '\r' | grep -v '^$' || true)
    [ -z "$denied" ] \
        && _pass "writable by uid $uid: $*" \
        || _fail "writable by uid $uid: $*" "denied: $(echo "$denied" | tr '\n' ' ')"
}

# check_shell_cmd_as <uid> <image> <description> <shell-command>
check_shell_cmd_as() {
    local uid=$1 img=$2 desc=$3 out rc
    shift 3
    out=$(run_as "$uid" "$img" "$*"); rc=$?
    [ $rc -eq 0 ] \
        && _pass "$desc" \
        || _fail "$desc" "$(echo "$out" | tail -3 | tr '\n' ' ')"
}

# image_files <image> — list every path in the image. Works on scratch images
# (no shell) because it reads the exported filesystem rather than executing anything.
image_files() {
    local cid
    # The trailing `true` is a dummy command: `docker create` refuses an image with
    # no CMD/ENTRYPOINT, which is every scratch image. It is never executed.
    cid=$(docker create "$1" true 2>/dev/null) || return 1
    docker export "$cid" 2>/dev/null | tar -tf - 2>/dev/null
    docker rm -f "$cid" >/dev/null 2>&1
}

# check_user <image> <expected-name> <expected-uid>
# Verifies both the configured USER and the uid it actually resolves to at runtime.
# A USER naming a nonexistent account still builds and inspects fine — it only
# fails on `docker run` — so the configured value alone is not enough.
check_user() {
    local img=$1 want_name=$2 want_uid=$3 cfg actual
    cfg=$(docker inspect -f '{{.Config.User}}' "$img" 2>/dev/null)
    [ -n "$cfg" ] || { _fail "default user is set" "Config.User is empty (image would run as root)"; return; }

    actual=$(docker run --rm --entrypoint sh "$img" -c 'id -u' 2>&1)
    if ! [[ $actual =~ ^[0-9]+$ ]]; then
        _fail "image starts as its configured user ($cfg)" "$actual"
        return
    fi
    [ "$actual" = "$want_uid" ] \
        && _pass "runs as $want_name (uid $want_uid)" \
        || _fail "runs as $want_name (uid $want_uid)" "got uid $actual (Config.User=$cfg)"
}

# check_user_inspect <image> <expected> — configured USER only, for shell-less images.
check_user_inspect() {
    local got
    got=$(docker inspect -f '{{.Config.User}}' "$1" 2>/dev/null)
    [ "$got" = "$2" ] && _pass "Config.User is $2" || _fail "Config.User is $2" "got '${got:-<empty>}'"
}

# check_workdir <image> <expected>
check_workdir() {
    local got
    got=$(docker inspect -f '{{.Config.WorkingDir}}' "$1" 2>/dev/null)
    [ "$got" = "$2" ] && _pass "WORKDIR is $2" || _fail "WORKDIR is $2" "got '${got:-<empty>}'"
}

# check_env <image> <VAR> <expected-value>
check_env() {
    local got
    got=$(docker inspect -f "{{range .Config.Env}}{{println .}}{{end}}" "$1" 2>/dev/null | sed -n "s/^$2=//p")
    [ "$got" = "$3" ] && _pass "$2=$3" || _fail "$2=$3" "got '${got:-<unset>}'"
}

# check_env_contains <image> <VAR> <substring>
check_env_contains() {
    local got
    got=$(docker inspect -f "{{range .Config.Env}}{{println .}}{{end}}" "$1" 2>/dev/null | sed -n "s/^$2=//p")
    case "$got" in
        *"$3"*) _pass "$2 contains $3" ;;
        *)      _fail "$2 contains $3" "got '${got:-<unset>}'" ;;
    esac
}

# check_cmd <image> <binary>... — each resolves on PATH for the default user.
check_cmd() {
    local img=$1 missing out
    shift
    out=$(run "$img" 'for c in '"$*"'; do command -v "$c" >/dev/null 2>&1 || echo "$c"; done')
    missing=$(echo "$out" | tr -d '\r' | grep -v '^$' || true)
    [ -z "$missing" ] \
        && _pass "on PATH: $*" \
        || _fail "on PATH: $*" "missing: $(echo "$missing" | tr '\n' ' ')"
}

# check_version <image> <command> <expected-substring>
# Guards against an image silently shipping a different version than buildargs.conf pins.
check_version() {
    local img=$1 cmd=$2 want=$3 out
    out=$(run "$img" "$cmd")
    case "$out" in
        *"$want"*) _pass "$cmd reports $want" ;;
        *)         _fail "$cmd reports $want" "got: $(echo "$out" | head -1)" ;;
    esac
}

# check_writable <image> <path>... — the default user can actually write there.
# This is the check that would have caught /go/bin, /var/cache/go and /bun being
# root-owned while the image ran as nonroot.
check_writable() {
    local img=$1 denied out
    shift
    out=$(run "$img" 'for d in '"$*"'; do (mkdir -p "$d" && touch "$d/.wprobe" && rm -f "$d/.wprobe") 2>/dev/null || echo "$d"; done')
    denied=$(echo "$out" | tr -d '\r' | grep -v '^$' || true)
    [ -z "$denied" ] \
        && _pass "writable by default user: $*" \
        || _fail "writable by default user: $*" "denied: $(echo "$denied" | tr '\n' ' ')"
}

# check_file <image> <path>... — path exists in the image.
check_file() {
    local img=$1 missing out
    shift
    out=$(run "$img" 'for f in '"$*"'; do [ -e "$f" ] || echo "$f"; done')
    missing=$(echo "$out" | tr -d '\r' | grep -v '^$' || true)
    [ -z "$missing" ] \
        && _pass "present: $*" \
        || _fail "present: $*" "missing: $(echo "$missing" | tr '\n' ' ')"
}

# check_shell_cmd <image> <description> <shell-command>
# Escape hatch for image-specific behaviour; passes when the command exits 0.
check_shell_cmd() {
    local img=$1 desc=$2 out rc
    out=$(run "$img" "${*:3}"); rc=$?
    [ $rc -eq 0 ] \
        && _pass "$desc" \
        || _fail "$desc" "$(echo "$out" | tail -3 | tr '\n' ' ')"
}

# check_host <description> <shell-command>
# Runs on the HOST rather than inside the image. Needed when the check cannot be
# expressed as a single in-container command: publishing a port and requesting it,
# bind-mounting a fixture, or inspecting a scratch image that has no shell to exec.
# The command is responsible for cleaning up anything it starts.
check_host() {
    local desc=$1 out rc
    out=$(eval "${*:2}" 2>&1); rc=$?
    [ $rc -eq 0 ] \
        && _pass "$desc" \
        || _fail "$desc" "$(echo "$out" | tail -3 | tr '\n' ' ')"
}

# check_image_file <image> <path>... — path exists, read from the exported
# filesystem instead of by exec'ing. The only option for scratch images.
check_image_file() {
    local img=$1 files missing=""
    shift
    files=$(image_files "$img") || { _fail "present: $*" "could not export image"; return; }
    for f in "$@"; do
        echo "$files" | grep -qE "^\.?${f#/}/?$" || missing="$missing $f"
    done
    [ -z "$missing" ] \
        && _pass "present: $*" \
        || _fail "present: $*" "missing:$missing"
}

# verify_summary — call at the end of every verify.sh; sets the exit status.
verify_summary() {
    if [ "$_VERIFY_FAILED" -gt 0 ]; then
        printf '  \033[31m%d of %d checks failed\033[0m\n' "$_VERIFY_FAILED" "$_VERIFY_CHECKS"
        exit 1
    fi
    printf '  \033[32mall %d checks passed\033[0m\n' "$_VERIFY_CHECKS"
    exit 0
}
