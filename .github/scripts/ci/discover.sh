#!/usr/bin/env bash
# Derives the build matrix and per-target bake --set overrides from the bake
# file's dependency graph.
#
# Backs: build-images.yml, job `discover`, step "Read targets and build args
# from bake file".
#
# Expects env:
#   REGISTRY          - registry/repo prefix passed to `docker buildx bake`
#   GITHUB_EVENT_NAME  - the triggering event name (used to disable cache-to
#                        export on pull_request builds)
#   GITHUB_OUTPUT      - path to the GitHub Actions step output file
set -euo pipefail

: "${REGISTRY:?REGISTRY is required}"
: "${GITHUB_EVENT_NAME:?GITHUB_EVENT_NAME is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

set -a
source buildargs.conf
set +a

print=$(REGISTRY="$REGISTRY" docker buildx bake --print default)

# Derive the build matrix from the dependency graph instead of hard-coded
# CI stages: build an undirected adjacency list from the `target:` edges
# in `contexts`, label-propagate to a fixed point to find connected
# components, then group targets by component. `name` is the component's
# root (the target with no outgoing edges, i.e. nothing it depends on) —
# chosen purely so job names read well; it plays no role in the grouping.
matrix=$(jq -c '
  .target as $t
  | ($t | keys) as $nodes
  | ( [ $t | to_entries[] | .key as $from
        | (.value.contexts // {}) | to_entries[]
        | select(.value | startswith("target:"))
        | {a:$from, b:(.value | ltrimstr("target:"))} ] ) as $edges
  | ( reduce $edges[] as $e ({}; .[$e.a] += [$e.b] | .[$e.b] += [$e.a]) ) as $adj
  | ( reduce $edges[] as $e ({}; .[$e.a] += 1) ) as $deps
  | ( reduce range(0; ($nodes|length)) as $_
        ( ($nodes | map({key:., value:.}) | from_entries);
          . as $lab
          | reduce $nodes[] as $n ($lab;
              .[$n] = ([ $n, .[$n] ] + [ ($adj[$n] // [])[] | $lab[.] ] | min)) )
    ) as $label
  | $nodes | group_by($label[.])
  | map( sort as $m
         | { name: ([ $m[] | select(($deps[.] // 0) == 0) ] | sort | .[0] // $m[0]),
             # Newline-separated, NOT space-separated: docker/bake-action takes
             # `targets` as a multi-value input and splits it on newlines. A
             # space-separated list is read as one target name and fails with
             # "failed to find target a b c". A single-target component looks
             # identical either way, which is why only the multi-target ones broke.
             targets: ($m | join("\n")) } )
  | sort_by(.name)' <<<"$print")

{
  echo "matrix=$matrix"
  echo 'bakeargs-set<<EOF'
  grep -v '^#' buildargs.conf | grep -v '^\s*$' | sed 's/^/*.args./'
  if [ "$GITHUB_EVENT_NAME" = "pull_request" ]; then
    # On PRs, disable cache export so an unmerged (possibly broken) bump can't
    # poison the shared registry build cache that scheduled builds rely on.
    echo '*.cache-to='
  fi
  # Push every build by digest only: clear every target's floating/version
  # tags and push with push-by-digest, so the image is uploaded for
  # inspection (reference it as <repo>@sha256:...) without writing or moving
  # any tag such as golang:alpine-3.24. Tags are applied later by the
  # `publish` job, once the `verify` job has confirmed the pushed digest is
  # good. The repo to push to is derived from each target's first tag
  # (e.g. .../golang:latest). Guard against targets with no tags (e.g. a
  # future internal-only target) so `.value.tags[0]` doesn't explode.
  jq -rn --argjson p "$print" '
    $p.target | to_entries[]
    | select((.value.tags // []) | length > 0)
    | .key as $k
    | (.value.tags[0] | sub(":[^/]+$"; "")) as $repo
    | ($k + ".tags="),
      ($k + ".output=type=image,name=" + $repo + ",push-by-digest=true,name-canonical=true,push=true")'
  echo 'EOF'
} >> "$GITHUB_OUTPUT"
