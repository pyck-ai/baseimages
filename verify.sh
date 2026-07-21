#!/bin/bash
# Post-build image verification driver.
#
# Resolves the requested bake targets, works out which image each one produces,
# and runs that image's docker/<image>/verify.sh against it. Verification logic
# lives next to the image it describes; this file only does the wiring.
#
# Run via `task verify` (which builds with --load first), or directly:
#   ./verify.sh                 # every target in the default group
#   ./verify.sh golang          # a group
#   ./verify.sh golang-alpine   # a single target
#
# Images must already be loaded into the local docker daemon.

set -uo pipefail

cd "$(dirname "$0")"

REGISTRY="${REGISTRY:-ghcr.io/pyck-ai/baseimages}"

command -v jq >/dev/null 2>&1 || { echo "[ERR] jq is required" >&2; exit 1; }

targets_json=$(REGISTRY="$REGISTRY" docker buildx bake --print "$@" 2>/dev/null) || {
    echo "[ERR] could not resolve bake targets: $*" >&2
    exit 1
}

# name<TAB>context<TAB>first-tag, skipping targets that publish no tags (_common)
mapfile -t entries < <(
    echo "$targets_json" |
        jq -r '.target | to_entries[]
               | select(.value.tags != null and (.value.tags | length) > 0)
               | "\(.key)\t\(.value.context // "")\t\(.value.tags | join(","))"'
)

[ "${#entries[@]}" -gt 0 ] || { echo "[ERR] no taggable targets matched: $*" >&2; exit 1; }

failed=0 ran=0

for entry in "${entries[@]}"; do
    IFS=$'\t' read -r target context tags <<<"$entry"

    image_dir=${context#./}                       # ./docker/golang -> docker/golang
    image=${image_dir#docker/}                    # docker/golang   -> golang
    variant=${target#"$image"}                    # golang-alpine   -> -alpine
    variant=${variant#-}                          # -alpine         -> alpine

    script="$image_dir/verify.sh"
    if [ ! -x "$script" ]; then
        if [ -f "$script" ]; then
            echo "[ERR] $script is not executable" >&2
        else
            echo "[ERR] $target — no verify.sh" >&2
        fi
        failed=$((failed + 1))
        continue
    fi

    # Prefer the tag matching this variant so alpine/debian are verified distinctly;
    # fall back to :latest for single-variant images whose tag carries no variant
    # (rover-debian publishes rover:latest, not rover:debian).
    ref=""
    IFS=',' read -ra tag_list <<<"$tags"
    for t in "${tag_list[@]}"; do
        [ -n "$variant" ] && [ "${t##*:}" = "$variant" ] && { ref=$t; break; }
        [ -z "$variant" ] && [ "${t##*:}" = "latest" ] && { ref=$t; break; }
    done
    [ -z "$ref" ] && for t in "${tag_list[@]}"; do
        [ "${t##*:}" = "latest" ] && { ref=$t; break; }
    done
    [ -z "$ref" ] && ref=${tag_list[0]}

    if ! docker image inspect "$ref" >/dev/null 2>&1; then
        echo "[ERR] $target — image not loaded: $ref" >&2
        echo "      build it first, e.g. task verify -- $target" >&2
        failed=$((failed + 1))
        continue
    fi

    echo "▸ $target ($ref)"
    if "./$script" "$ref" "$variant"; then
        ran=$((ran + 1))
    else
        failed=$((failed + 1))
    fi
done

echo
if [ "$failed" -gt 0 ]; then
    echo "FAILED: $failed image(s) failed verification ($ran passed)"
    exit 1
fi
echo "OK: $ran image(s) verified"
