#!/usr/bin/env bash
# Applies the floating/version tags to the digests recorded in digests.json,
# now that the `verify` job has confirmed they are good.
#
# Backs: build-images.yml, job `publish`, step "Apply tags". Lives at
# .github/scripts/build-images/apply-tags.sh.
#
# Expects env:
#   REGISTRY - registry/repo prefix passed to `docker buildx bake`
#
# Expects: digests.json in the working directory (see merge-digests.sh).
set -euo pipefail

: "${REGISTRY:?REGISTRY is required}"

set -a
source buildargs.conf
set +a

print=$(REGISTRY="$REGISTRY" docker buildx bake --print default | jq -c '.target')
rc=0
while IFS=$'\t' read -r target tags; do
  d=$(jq -r --arg t "$target" '.[$t] // empty' digests.json)
  if [ -z "$d" ]; then echo "::error::no digest recorded for $target"; rc=1; continue; fi
  IFS=',' read -ra tl <<<"$tags"
  # Derive the repo the same way discover's jq does
  # (sub(":[^/]+$"; "")) so the two agree on registries with a port.
  # Do not substitute bash ${x%:*} for this reason.
  repo=$(sed 's/:[^/]*$//' <<<"${tl[0]}")
  # Assert the source is a multi-arch index rather than passing
  # --prefer-index=false: every target inherits _common's two
  # platforms, so all sources ARE indexes and `imagetools create`
  # does a cheap carbon copy. If a target ever became single-platform,
  # --prefer-index=false would silently publish a bare manifest;
  # failing loudly here is correct instead.
  if ! docker buildx imagetools inspect --raw "${repo}@${d}" \
       | jq -e '.mediaType|test("index|manifest.list")' >/dev/null; then
    echo "::error::$target digest is not a multi-arch index: ${repo}@${d}"; rc=1; continue
  fi
  args=(); for t in "${tl[@]}"; do args+=(-t "$t"); done
  # Accumulate failures rather than aborting on the first error, so a
  # re-run converges in one pass. imagetools create from a recorded
  # digest is idempotent.
  docker buildx imagetools create "${args[@]}" "${repo}@${d}" || rc=1
done < <(jq -r 'to_entries[] | select((.value.tags//[])|length>0) | "\(.key)\t\(.value.tags|join(","))"' <<<"$print")
exit $rc
