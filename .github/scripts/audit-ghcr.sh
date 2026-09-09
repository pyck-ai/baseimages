#!/usr/bin/env bash
#
# ghcr-audit.sh — audit the integrity of published multi-arch images in GHCR.
#
# For every tag of every requested image, this script resolves the tag to its
# manifest via the OCI Distribution API and, if that manifest is an image
# index / manifest list, verifies that EVERY child manifest it references is
# actually fetchable. A tag whose index references a missing child is BROKEN:
# `docker pull` of that tag fails even though the tag itself still "exists".
#
# It exists because a previous cleanup job deleted child platform manifests
# of live (tagged) images out from under their parent indexes. It serves two
# roles: (1) a standalone read-only audit you can run any time, and (2) the
# intended post-run safety rail for a prune/cleanup job later.
#
# Two gotchas this script exists specifically to avoid:
#
#   1. PAGINATION. GET /v2/<img>/tags/list returns at most 100 tags by
#      default and paginates via a `Link: <...>; rel="next"` response
#      header. An earlier ad-hoc scan silently truncated at 100 tags and
#      undercounted several packages. This script always follows `Link`
#      until exhausted — never assume a single page.
#
#   2. AUTHORITY. The registry (ghcr.io/v2/.../manifests/<tag>) is the only
#      authoritative source for what a tag currently points at. The GitHub
#      Packages REST API's per-version `tags` array is a secondary index
#      that goes stale when a tag moves — it has been observed claiming a
#      tag that, per the registry itself, resolves to a different, healthy
#      digest. This script never reads the Packages API.
#
# This script is strictly READ-ONLY against the registry. It never deletes,
# untags, or modifies anything.
#
# Usage:
#   ghcr-audit.sh [--owner ORG] [--repo-prefix PREFIX] [--image NAME]...
#                 [--json FILE] [--quiet]
#
# Exit codes:
#   0  all tags intact
#   1  at least one broken tag found
#   2  operational failure (no token, network error, jq missing, etc.)

set -uo pipefail

# ---------------------------------------------------------------------------
# Defaults / argument parsing
# ---------------------------------------------------------------------------

OWNER="pyck-ai"
REPO_PREFIX="baseimages"
IMAGES=()
JSON_OUT=""
QUIET=0

DEFAULT_IMAGES=(base golang python typescript agent rover nginx static all-in-one)

usage() {
  cat <<'EOF'
Usage: ghcr-audit.sh [--owner ORG] [--repo-prefix PREFIX] [--image NAME]...
                      [--json FILE] [--quiet]

Audits GHCR multi-arch images: for every tag, verifies that every child
manifest referenced by its (index) manifest is actually fetchable.

Options:
  --owner ORG          GitHub org/user owning the packages (default: pyck-ai)
  --repo-prefix PREFIX Package name prefix (default: baseimages); packages
                        are addressed as <owner>/<repo-prefix>/<image>
  --image NAME          Image to audit; repeatable. Default: all nine
                        (base golang python typescript agent rover nginx
                        static all-in-one)
  --json FILE           Write machine-readable JSON results to FILE
  --quiet               Suppress informational/warning diagnostics on stderr
  -h, --help            Show this help and exit

Exit codes:
  0  all tags intact
  1  at least one broken tag found
  2  operational failure (no token, network error, jq missing, etc.)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --owner)
      OWNER="${2:?--owner requires a value}"
      shift 2
      ;;
    --repo-prefix)
      REPO_PREFIX="${2:?--repo-prefix requires a value}"
      shift 2
      ;;
    --image)
      IMAGES+=("${2:?--image requires a value}")
      shift 2
      ;;
    --json)
      JSON_OUT="${2:?--json requires a value}"
      shift 2
      ;;
    --quiet)
      QUIET=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ghcr-audit.sh: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "${#IMAGES[@]}" -eq 0 ]; then
  IMAGES=("${DEFAULT_IMAGES[@]}")
fi

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------

for bin in curl jq; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "ghcr-audit.sh: required command '$bin' not found in PATH" >&2
    exit 2
  fi
done

ACCEPT_HEADER="application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/ghcr-audit.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

log_warn() {
  [ "$QUIET" -eq 1 ] && return 0
  echo "WARN: $*" >&2
}

log_info() {
  [ "$QUIET" -eq 1 ] && return 0
  echo "INFO: $*" >&2
}

OPERATIONAL_FAILURE=0
BROKEN_FOUND=0

# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------

# request_with_retry URL TOKEN ACCEPT OUT_BODY OUT_HEADERS [METHOD]
# Prints the HTTP status code (or "000" on total curl failure) on stdout.
# Retries up to 3 times with backoff on 429 / 5xx / total failure.
request_with_retry() {
  local url="$1" token="$2" accept="$3" out_body="$4" out_headers="$5" method="${6:-GET}"
  local attempt status curl_rc

  local method_flag=(-X "$method")
  if [ "$method" = "HEAD" ]; then
    # `-X HEAD -o file` makes curl expect a body matching Content-Length and
    # fail with exit 18 ("bytes missing") since HEAD responses have none.
    # `--head` is the correct way to issue a HEAD request and discard body.
    method_flag=(--head)
  fi

  for attempt in 1 2 3; do
    : > "$out_body"
    : > "$out_headers"
    status=$(curl -sS "${method_flag[@]}" \
      -D "$out_headers" -o "$out_body" -w '%{http_code}' \
      -H "Authorization: Bearer ${token}" \
      -H "Accept: ${accept}" \
      "$url" 2>/dev/null)
    curl_rc=$?
    if [ "$curl_rc" -ne 0 ] || [ -z "$status" ]; then
      status="000"
    fi
    case "$status" in
      429|5[0-9][0-9]|000)
        if [ "$attempt" -lt 3 ]; then
          sleep "$((attempt * 2))"
          continue
        fi
        ;;
    esac
    break
  done

  printf '%s' "$status"
}

# get_token PKG -> prints bearer token on stdout, or empty on failure.
get_token() {
  local pkg="$1"
  local scope="repository:${pkg}:pull"
  local url="https://ghcr.io/token?scope=${scope}&service=ghcr.io"
  local body
  body="$(mktemp "$WORKDIR/token.XXXXXX")"
  local status curl_rc

  if [ -n "${GITHUB_TOKEN:-}${GH_TOKEN:-}" ]; then
    local gt="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
    status=$(curl -sS -u "token:${gt}" -o "$body" -w '%{http_code}' "$url" 2>/dev/null)
  else
    status=$(curl -sS -o "$body" -w '%{http_code}' "$url" 2>/dev/null)
  fi
  curl_rc=$?

  if [ "$curl_rc" -ne 0 ] || [ "$status" != "200" ]; then
    rm -f "$body"
    return 1
  fi

  local token
  token=$(jq -r '.token // empty' "$body" 2>/dev/null)
  rm -f "$body"
  if [ -z "$token" ] || [ "$token" = "null" ]; then
    return 1
  fi
  printf '%s' "$token"
}

# list_tags PKG TOKEN -> prints one tag per line, following Link pagination.
list_tags() {
  local pkg="$1" token="$2"
  local url="https://ghcr.io/v2/${pkg}/tags/list?n=100"
  local body headers status link next

  while [ -n "$url" ]; do
    body="$(mktemp "$WORKDIR/tags.XXXXXX")"
    headers="$(mktemp "$WORKDIR/hdrs.XXXXXX")"
    status=$(request_with_retry "$url" "$token" "application/json" "$body" "$headers" GET)

    if [ "$status" != "200" ]; then
      log_warn "failed to list tags for ${pkg} at ${url} (status ${status})"
      OPERATIONAL_FAILURE=1
      rm -f "$body" "$headers"
      return 1
    fi

    jq -r '.tags[]? // empty' "$body"

    link=$(grep -i '^Link:' "$headers" | tail -1)
    rm -f "$body" "$headers"

    next=""
    if [ -n "$link" ]; then
      next=$(printf '%s' "$link" | sed -n 's/.*<\([^>]*\)>[[:space:]]*;[[:space:]]*rel="next".*/\1/p')
    fi

    if [ -n "$next" ]; then
      case "$next" in
        http*) url="$next" ;;
        *) url="https://ghcr.io${next}" ;;
      esac
    else
      url=""
    fi
  done
  return 0
}

# platform_string MANIFEST_ENTRY_JSON -> "os/arch[/variant]" or "unknown"
platform_string() {
  local entry="$1"
  printf '%s' "$entry" | jq -r '
    if .platform then
      (.platform.os // "unknown") + "/" + (.platform.architecture // "unknown") +
      (if .platform.variant then "/" + .platform.variant else "" end)
    else
      (.artifactType // .mediaType // "unknown")
    end'
}

# ---------------------------------------------------------------------------
# Per-image audit
# ---------------------------------------------------------------------------

# audit_image IMAGE -> writes "$WORKDIR/result-<image>.json" and prints the
# human-readable summary. Returns 0 if clean, 1 if broken tags found, 2 on
# operational failure for this image.
audit_image() {
  local image="$1"
  local pkg="${OWNER}/${REPO_PREFIX}/${image}"
  local token
  local image_rc=0

  if ! token=$(get_token "$pkg"); then
    log_warn "failed to obtain registry token for ${pkg}"
    echo "${image}  tags=? broken=? (operational failure: no token)"
    jq -n --arg image "$image" --arg pkg "$pkg" \
      '{image: $image, package: $pkg, error: "no token", tags_total: 0, broken_total: 0, broken_tags: [], indices: []}' \
      > "$WORKDIR/result-${image}.json"
    return 2
  fi

  local tags_file="$WORKDIR/taglist-${image}.txt"
  if ! list_tags "$pkg" "$token" > "$tags_file"; then
    echo "${image}  tags=? broken=? (operational failure: could not list tags)"
    jq -n --arg image "$image" --arg pkg "$pkg" \
      '{image: $image, package: $pkg, error: "could not list tags", tags_total: 0, broken_total: 0, broken_tags: [], indices: []}' \
      > "$WORKDIR/result-${image}.json"
    return 2
  fi

  mapfile -t tags < "$tags_file"

  if [ "${#tags[@]}" -eq 0 ]; then
    echo "${image}  tags=0 broken=0"
    jq -n --arg image "$image" --arg pkg "$pkg" \
      '{image: $image, package: $pkg, tags_total: 0, broken_total: 0, broken_tags: [], indices: []}' \
      > "$WORKDIR/result-${image}.json"
    return 0
  fi

  # tag -> digest map, and digest -> tags (space-separated) map
  local -A digest_for_tag=()
  local -A tags_for_digest=()
  local -A digest_seen=()
  local broken_tags=()
  local tag digest body headers status

  for tag in "${tags[@]}"; do
    [ -z "$tag" ] && continue
    body="$(mktemp "$WORKDIR/mfbody.XXXXXX")"
    headers="$(mktemp "$WORKDIR/mfhdrs.XXXXXX")"
    status=$(request_with_retry "https://ghcr.io/v2/${pkg}/manifests/${tag}" "$token" "$ACCEPT_HEADER" "$body" "$headers" GET)

    if [ "$status" != "200" ]; then
      if [ "$status" != "404" ] && [ "$status" != "000" ]; then
        log_warn "unexpected status ${status} resolving ${image}:${tag}"
        OPERATIONAL_FAILURE=1
      fi
      broken_tags+=("$tag")
      rm -f "$body" "$headers"
      continue
    fi

    digest=$(grep -i '^Docker-Content-Digest:' "$headers" | tail -1 | tr -d '\r' | awk '{print $2}')
    if [ -z "$digest" ]; then
      digest="sha256:$(sha256sum "$body" | awk '{print $1}')"
    fi

    digest_for_tag["$tag"]="$digest"
    if [ -n "${tags_for_digest[$digest]:-}" ]; then
      tags_for_digest["$digest"]="${tags_for_digest[$digest]}"$'\n'"$tag"
    else
      tags_for_digest["$digest"]="$tag"
    fi

    if [ -z "${digest_seen[$digest]:-}" ]; then
      digest_seen["$digest"]=1
      cp "$body" "$WORKDIR/manifest-${image}-${digest//:/_}.json"
    fi
    rm -f "$body" "$headers"
  done

  # For each distinct digest, check children (if it's an index) once.
  local -A digest_status=()
  local index_results_file="$WORKDIR/indices-${image}.jsonl"
  : > "$index_results_file"

  local d manifest_file has_children
  for d in "${!digest_seen[@]}"; do
    manifest_file="$WORKDIR/manifest-${image}-${d//:/_}.json"
    has_children=$(jq -e '(.manifests // []) | length > 0' "$manifest_file" >/dev/null 2>&1 && echo yes || echo no)

    local tags_json
    tags_json=$(printf '%s\n' "${tags_for_digest[$d]}" | jq -R . | jq -s .)

    if [ "$has_children" = "no" ]; then
      digest_status["$d"]="ok"
      jq -n --arg digest "$d" --argjson tags "$tags_json" \
        '{digest: $digest, status: "ok", tags: $tags, children: []}' >> "$index_results_file"
      continue
    fi

    local children_file="$WORKDIR/children-${image}-${d//:/_}.jsonl"
    : > "$children_file"
    local all_ok=1
    local child_count child_index
    child_count=$(jq '(.manifests // []) | length' "$manifest_file")

    for ((child_index=0; child_index<child_count; child_index++)); do
      local child_entry child_digest platform cbody chdrs cstatus
      child_entry=$(jq -c ".manifests[$child_index]" "$manifest_file")
      child_digest=$(printf '%s' "$child_entry" | jq -r '.digest')
      platform=$(platform_string "$child_entry")

      cbody="$(mktemp "$WORKDIR/child.XXXXXX")"
      chdrs="$(mktemp "$WORKDIR/childh.XXXXXX")"
      cstatus=$(request_with_retry "https://ghcr.io/v2/${pkg}/manifests/${child_digest}" "$token" "$ACCEPT_HEADER" "$cbody" "$chdrs" HEAD)
      rm -f "$cbody" "$chdrs"

      jq -n --arg digest "$child_digest" --arg platform "$platform" --arg status "$cstatus" \
        '{digest: $digest, platform: $platform, status: ($status | tonumber? // $status)}' >> "$children_file"

      if [ "$cstatus" != "200" ]; then
        all_ok=0
        if [ "$cstatus" != "404" ] && [ "$cstatus" != "000" ]; then
          log_warn "unexpected status ${cstatus} checking child ${child_digest} (${platform}) of ${image}@${d}"
          OPERATIONAL_FAILURE=1
        fi
      fi
    done

    if [ "$all_ok" -eq 1 ]; then
      digest_status["$d"]="ok"
    else
      digest_status["$d"]="broken"
    fi

    jq -n --arg digest "$d" --arg status "${digest_status[$d]}" --argjson tags "$tags_json" \
      --slurpfile children "$children_file" \
      '{digest: $digest, status: $status, tags: $tags, children: $children}' >> "$index_results_file"
  done

  # Map broken digests back onto their tags.
  for tag in "${!digest_for_tag[@]}"; do
    d="${digest_for_tag[$tag]}"
    if [ "${digest_status[$d]:-}" = "broken" ]; then
      broken_tags+=("$tag")
    fi
  done

  local tags_total="${#tags[@]}"
  local broken_total="${#broken_tags[@]}"

  if [ "$broken_total" -gt 0 ]; then
    echo "${image}  tags=${tags_total}  broken=${broken_total}"
    local bt
    for bt in "${broken_tags[@]}"; do
      echo "    ${bt}"
    done
    image_rc=1
  else
    echo "${image}  tags=${tags_total}  broken=${broken_total}"
  fi

  local broken_tags_json indices_json
  if [ "${#broken_tags[@]}" -gt 0 ]; then
    broken_tags_json=$(printf '%s\n' "${broken_tags[@]}" | jq -R . | jq -s .)
  else
    broken_tags_json="[]"
  fi
  if [ -s "$index_results_file" ]; then
    indices_json=$(jq -s . "$index_results_file")
  else
    indices_json="[]"
  fi

  jq -n --arg image "$image" --arg pkg "$pkg" \
    --argjson tags_total "$tags_total" --argjson broken_total "$broken_total" \
    --argjson broken_tags "$broken_tags_json" --argjson indices "$indices_json" \
    '{image: $image, package: $pkg, tags_total: $tags_total, broken_total: $broken_total, broken_tags: $broken_tags, indices: $indices}' \
    > "$WORKDIR/result-${image}.json"

  return "$image_rc"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

for image in "${IMAGES[@]}"; do
  audit_image "$image"
  rc=$?
  case "$rc" in
    1) BROKEN_FOUND=1 ;;
    2) OPERATIONAL_FAILURE=1 ;;
  esac
done

if [ -n "$JSON_OUT" ]; then
  result_files=("$WORKDIR"/result-*.json)
  if [ -e "${result_files[0]}" ]; then
    jq -s . "${result_files[@]}" > "$JSON_OUT"
    log_info "wrote JSON results to ${JSON_OUT}"
  else
    echo "[]" > "$JSON_OUT"
  fi
fi

if [ "$OPERATIONAL_FAILURE" -eq 1 ]; then
  exit 2
elif [ "$BROKEN_FOUND" -eq 1 ]; then
  exit 1
else
  exit 0
fi
