#!/usr/bin/env bash
#
# prune.sh — reachability-safe GHCR prune for this repo's container
# packages.
#
# THE PROBLEM WITH THE OLD PRUNE: it treated "untagged == garbage" and
# deleted 168 published tags. GHCR lists the child platform manifests AND
# the buildx provenance attestation manifests of a live multi-arch index as
# separate UNTAGGED package versions. Deleting one corrupts the tagged index
# that references it (verified live; see vlaurin/action-ghcr-prune#76).
#
# THE MODEL THIS SCRIPT IMPLEMENTS INSTEAD (two phases):
#
#   ROOTS       = versions with >=1 tag
#   KEEP_ROOTS  = { d in ROOTS : retain(d) }               # phase 1, policy
#   CHILDREN(d) = manifest(d).manifests[].digest, or {} if d is a flat manifest
#   REACHABLE   = least fixed point R with KEEP_ROOTS subset R and, for all
#                 d in R, CHILDREN(d) subset R               # phase 2, graph
#   INFLIGHT    = versions younger than --grace-days (protects digests
#                 pushed-by-digest but not yet tagged by a later `publish`
#                 job — see build-images.yml's discover/verify/publish split)
#   DELETE      = ALL \ (REACHABLE union INFLIGHT)
#
# This correctly degenerates for flat-manifest packages: `buildcache`'s
# tagged versions are plain `application/vnd.oci.image.manifest.v1+json`
# manifests with zero children, so CHILDREN is empty, REACHABLE is exactly
# the tagged set, and DELETE is everything else. No special case needed.
#
# retain(d) (phase 1, --keep-all-tagged off — the default, right for
# published images): true if d carries a tag matching --keep-tag-regex, OR
# d is among the newest --keep-last roots, OR d is younger than --keep-days.
#
# retain(d) (--keep-all-tagged on — the right mode for CACHE-LIKE packages
# such as `buildcache`): true for EVERY tagged root, unconditionally. A
# cache package's tags are live entries for currently-building targets —
# age and count say nothing about liveness — so only its untagged versions
# (superseded cache layers) are ever dead. Use this flag for `buildcache`
# and any similar cache/scratch package; using the image-shaped default
# policy on such a package works only by accident (it happens to age out
# tags belonging to images no longer in the bakefile) and will misclassify
# a genuinely active but infrequently-rebuilt cache tag as garbage.
#
# PACKAGE ENUMERATION is inverted from the old `discover` job, which derived
# image names from `docker buildx bake --print` — meaning any image renamed
# or removed from the bakefile was orphaned from cleanup FOREVER (this is
# how buildcache/flutter/slim/agents/alpine/debian/claude/aws/renovate,
# 9,640 versions / 40% of the registry, went invisible). Instead this script
# enumerates the REAL packages from the Packages API and classifies each
# one against the bakefile, rather than the other way around:
#
#   live    - package name appears as an image in `docker buildx bake --print`
#   infra   - package name is the buildcache package (build-cache churn,
#             not a published artifact, but still safe to reachability-prune)
#   orphan  - neither; reported but never touched unless --include-orphans
#
# This script never assumes a fallback when something can't be verified: an
# unresolved manifest fails the whole package closed (see the FAIL-CLOSED
# report in the output) rather than being treated as childless.
#
# SAFETY RAILS:
#   #1 DELETE ∩ REACHABLE must be empty (set-arithmetic bug detector).
#      Tripping this ABORTS THE WHOLE RUN (exit 3, nothing deleted) — it
#      means the script's own logic is broken, not that one package's data
#      is unusual, so continuing to plan other packages isn't trustworthy.
#   #2 No version carrying a protected tag (--keep-tag-regex) may appear in
#      DELETE. Same whole-run abort as #1, same reasoning.
#   #3 If ANY keep-root or its descendant fails to resolve, that PACKAGE is
#      skipped (fail-closed) and reported in the FAIL-CLOSED section: this
#      is real, already-existing registry corruption, not a bug in this
#      script, so other packages are still processed normally.
#   #4 DELETE must not exceed --max-delete-ratio (default 0.98) of a
#      package's total versions, unless --force. This is a PER-PACKAGE
#      skip-and-continue, not a whole-run abort: a high delete ratio is the
#      EXPECTED steady state here (every build pushes ~5 versions — index +
#      2 platform manifests + 2 attestations — and only the newest are
#      retained, so 80-90%+ garbage is routine after months of daily
#      builds). The rail exists to catch "classification went wrong and
#      this is about to delete nearly everything", not to gate normal
#      cleanup, hence the high default threshold.
#
# VERIFICATION (--verify-only, and automatically after --apply): re-resolves
# every currently-tagged version's manifest tree via `audit.sh`
# (co-located in this directory; invoked rather than reimplemented — see
# that script's header for why the registry, not the Packages API, is the
# only authoritative source for "is this tag actually pullable"). If any
# kept tag's index now has a missing child, that's a catastrophic
# regression: reported loudly by tag, exit 3.
#
# DRY RUN IS THE DEFAULT. Deleting requires the explicit --apply flag (or the
# APPLY=true environment variable — see below); no other input changes this.
#
# Usage:
#   prune.sh [--owner ORG] [--repo REPO] [--repo-prefix PREFIX]
#            [--package NAME]... [--keep-last N] [--keep-days N]
#            [--keep-all-tagged] [--grace-days N] [--keep-tag-regex RE]...
#            [--max-delete-ratio R] [--budget N] [--include-orphans]
#            [--apply] [--force] [--verify-only] [--json FILE]
#
# Backs: tidy-ghcr.yml, job `prune`, step "Prune GHCR packages". This script
# doubles as the workflow entry point (the former thin wrapper script has
# been folded in here): the environment variables below are read as
# DEFAULTS, with any CLI flag of the same name taking precedence. Only the
# exact string "true" enables APPLY / KEEP_ALL_TAGGED — anything else,
# including unset/empty (what a `schedule` event yields), is treated as
# false, which is what keeps scheduled runs dry.
#
#   APPLY            - "true" to enable --apply; anything else is dry-run
#   PACKAGES         - space-separated package names, each becomes a
#                      repeated --package
#   BUDGET           - default for --budget
#   KEEP_ALL_TAGGED  - "true" to enable --keep-all-tagged
#   OWNER            - default for --owner
#   REPO             - default for --repo
#   REPO_PREFIX      - default for --repo-prefix
#
# When run under GitHub Actions (GITHUB_ACTIONS is set), this script also
# annotates its own exit code with a human-readable ::warning::/::error::
# message on the way out — including the note that exit 2 with nginx/rover
# fail-closed is currently EXPECTED — mirroring what the old wrapper printed
# after delegating to this script. Hand-runs outside Actions stay quiet.
#
# Exit codes:
#   0  nothing to do / dry run clean
#   1  completed with some delete failures (--apply only)
#   2  operational failure (no token, network error, jq/docker missing, ...)
#   3  a safety-critical condition: rail #1/#2 tripped (whole run aborted,
#      nothing deleted), OR rail #4 tripped for at least one package (that
#      package skipped, others still processed), OR verification found a
#      kept tag that is now broken

set -uo pipefail

if [ -n "${GITHUB_ACTIONS:-}" ]; then
  annotate_exit() {
    local rc=$?
    case "$rc" in
      0) echo "prune.sh: clean run, nothing further to report." ;;
      1) echo "::warning::prune.sh exited 1: completed with some delete failures. See the log and prune-plan.json artifact." ;;
      2) echo "::error::prune.sh exited 2: operational failure (missing token, network error, or missing tooling). Not a classification problem." ;;
      3) echo "::error::prune.sh exited 3: a safety rail tripped, or post-apply verification found a kept tag now broken. Nothing unsafe was deleted." ;;
      *) echo "::error::prune.sh exited unexpected code $rc." ;;
    esac
    echo "NOTE: exit 2 with nginx and/or rover reported under FAIL-CLOSED is currently EXPECTED — those two packages already have broken tags from the pre-existing registry corruption (see audit.sh) and prune.sh correctly refuses to plan for them until that is remediated separately. This is not a new problem introduced by this run."
  }
fi

# ---------------------------------------------------------------------------
# Defaults / argument parsing
# ---------------------------------------------------------------------------

# Env vars supply defaults (see header comment); CLI flags below take
# precedence over all of them. Captured before APPLY/KEEP_ALL_TAGGED are
# reassigned below, since the env vars and the internal flags share names.
APPLY_FROM_ENV="${APPLY:-}"
KEEP_ALL_TAGGED_FROM_ENV="${KEEP_ALL_TAGGED:-}"

OWNER="${OWNER:-pyck-ai}"
REPO="${REPO:-baseimages}"
REPO_PREFIX="${REPO_PREFIX:-baseimages}"
REQUESTED_PACKAGES=()
if [ -n "${PACKAGES:-}" ]; then
  for _p in $PACKAGES; do
    REQUESTED_PACKAGES+=("$_p")
  done
  unset _p
fi
KEEP_LAST=10
KEEP_DAYS=90
KEEP_ALL_TAGGED=0
[ "$KEEP_ALL_TAGGED_FROM_ENV" = "true" ] && KEEP_ALL_TAGGED=1
GRACE_DAYS=7
KEEP_TAG_REGEXES=()
MAX_DELETE_RATIO="0.98"
BUDGET="${BUDGET:-400}"
INCLUDE_ORPHANS=0
APPLY=0
[ "$APPLY_FROM_ENV" = "true" ] && APPLY=1
FORCE=0
VERIFY_ONLY=0
JSON_OUT=""

usage() {
  cat <<'EOF'
Usage: prune.sh [--owner ORG] [--repo REPO] [--repo-prefix PREFIX]
                      [--package NAME]... [--keep-last N] [--keep-days N]
                      [--keep-all-tagged] [--grace-days N]
                      [--keep-tag-regex RE]... [--max-delete-ratio R]
                      [--budget N] [--include-orphans] [--apply] [--force]
                      [--verify-only] [--json FILE]

Reachability-safe prune of this repo's GHCR container packages. See the
header comment in this script for the full model. DRY RUN IS THE DEFAULT.

Options:
  --owner ORG           GitHub org/user owning the packages (default: pyck-ai)
  --repo REPO           Repository packages must be linked to (default: baseimages)
  --repo-prefix PREFIX  Package name prefix (default: baseimages); packages
                        are addressed as <repo-prefix>/<image>
  --package NAME        Restrict to this bare image name (e.g. golang,
                        buildcache); repeatable. Default: every package
                        linked to <owner>/<repo> whose name starts with
                        <repo-prefix>/
  --keep-last N         Keep the N most recently created tagged roots per
                        package, regardless of age (default: 10)
  --keep-days N         Keep tagged roots created within the last N days
                        (default: 90)
  --keep-all-tagged     Keep EVERY tagged root regardless of age or count,
                        ignoring --keep-last/--keep-days/--keep-tag-regex.
                        Use for cache-like packages (e.g. buildcache) whose
                        tags are live cache entries, not release history.
  --grace-days N        Keep ANY version (tagged or not) younger than N days,
                        in-flight protection for digest-push-then-tag races
                        (default: 7)
  --keep-tag-regex RE   Keep any root carrying a tag matching this extended
                        regex; repeatable. Default: ^latest$ ^alpine$ ^debian$
  --max-delete-ratio R  Per-package safety rail: skip (don't touch) a
                        package whose planned DELETE exceeds this fraction
                        of its total versions, unless --force (default: 0.98)
  --budget N            Stop after N deletions this run and report the
                        remainder (default: 400)
  --include-orphans     Also operate on packages not classified live/infra
                        (default: report them only, never touch them)
  --apply               Actually delete. Without this flag nothing is ever
                        deleted, regardless of any other option. Runs
                        verification (see --verify-only) afterwards on every
                        package that had deletions applied.
  --force               Override the --max-delete-ratio rail
  --verify-only         Skip planning/deletion entirely; just re-resolve
                        every currently-tagged version's manifest tree via
                        audit.sh and report any broken tags. Exit 3 if
                        any are found.
  --json FILE           Write the full machine-readable plan to FILE
  -h, --help            Show this help and exit

Exit codes:
  0  nothing to do / dry run clean
  1  completed with some delete failures (--apply only)
  2  operational failure (no token, network error, jq/docker missing, ...)
  3  a safety-critical condition: rail #1/#2 tripped (whole run aborted,
     nothing deleted), OR rail #4 tripped for at least one package (that
     package skipped, others still processed), OR verification found a
     kept tag that is now broken
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --owner)
      OWNER="${2:?--owner requires a value}"
      shift 2
      ;;
    --repo)
      REPO="${2:?--repo requires a value}"
      shift 2
      ;;
    --repo-prefix)
      REPO_PREFIX="${2:?--repo-prefix requires a value}"
      shift 2
      ;;
    --package)
      REQUESTED_PACKAGES+=("${2:?--package requires a value}")
      shift 2
      ;;
    --keep-last)
      KEEP_LAST="${2:?--keep-last requires a value}"
      shift 2
      ;;
    --keep-days)
      KEEP_DAYS="${2:?--keep-days requires a value}"
      shift 2
      ;;
    --keep-all-tagged)
      KEEP_ALL_TAGGED=1
      shift
      ;;
    --grace-days)
      GRACE_DAYS="${2:?--grace-days requires a value}"
      shift 2
      ;;
    --keep-tag-regex)
      KEEP_TAG_REGEXES+=("${2:?--keep-tag-regex requires a value}")
      shift 2
      ;;
    --max-delete-ratio)
      MAX_DELETE_RATIO="${2:?--max-delete-ratio requires a value}"
      shift 2
      ;;
    --budget)
      BUDGET="${2:?--budget requires a value}"
      shift 2
      ;;
    --include-orphans)
      INCLUDE_ORPHANS=1
      shift
      ;;
    --apply)
      APPLY=1
      shift
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --verify-only)
      VERIFY_ONLY=1
      shift
      ;;
    --json)
      JSON_OUT="${2:?--json requires a value}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "prune.sh: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "${#KEEP_TAG_REGEXES[@]}" -eq 0 ]; then
  KEEP_TAG_REGEXES=('^latest$' '^alpine$' '^debian$')
fi

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------

for bin in curl jq docker; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "prune.sh: required command '$bin' not found in PATH" >&2
    exit 2
  fi
done

GH_TOKEN_VALUE="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
if [ -z "$GH_TOKEN_VALUE" ]; then
  echo "prune.sh: GITHUB_TOKEN or GH_TOKEN must be set (needs read:packages, and delete:packages to --apply)" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
AUDIT_SCRIPT="$SCRIPT_DIR/audit.sh"

if [ ! -f "$REPO_ROOT/buildargs.conf" ] || [ ! -f "$REPO_ROOT/docker-bake.hcl" ]; then
  echo "prune.sh: expected buildargs.conf and docker-bake.hcl under $REPO_ROOT" >&2
  exit 2
fi

REGISTRY_ACCEPT="application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json"
GITHUB_ACCEPT="application/vnd.github+json"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/prune.XXXXXX")"
if [ -n "${GITHUB_ACTIONS:-}" ]; then
  trap 'rm -rf "$WORKDIR"; annotate_exit' EXIT
else
  trap 'rm -rf "$WORKDIR"' EXIT
fi

log_warn() { echo "WARN: $*" >&2; }
log_info() { echo "INFO: $*" >&2; }
log_err()  { echo "ERROR: $*" >&2; }

OPERATIONAL_FAILURE=0
SAFETY_ABORT=0
RATIO_TRIPPED=0
VERIFY_REGRESSION=0
DELETE_FAILURES=0
NOW_EPOCH=$(date -u +%s)

# ---------------------------------------------------------------------------
# HTTP helpers (mirrors audit.sh's retry/backoff conventions)
# ---------------------------------------------------------------------------

# request_with_retry URL ACCEPT AUTH_HEADER OUT_BODY OUT_HEADERS [METHOD]
# Prints the HTTP status code (or "000" on total curl failure) on stdout.
request_with_retry() {
  local url="$1" accept="$2" auth_header="$3" out_body="$4" out_headers="$5" method="${6:-GET}"
  local attempt status curl_rc

  for attempt in 1 2 3; do
    : > "$out_body"
    : > "$out_headers"
    status=$(curl -sS -X "$method" \
      -D "$out_headers" -o "$out_body" -w '%{http_code}' \
      -H "$auth_header" \
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

# get_registry_token PKG -> prints bearer token on stdout, or empty on failure.
get_registry_token() {
  local pkg="$1"
  local scope="repository:${pkg}:pull"
  local url="https://ghcr.io/token?scope=${scope}&service=ghcr.io"
  local body status curl_rc
  body="$(mktemp "$WORKDIR/token.XXXXXX")"

  status=$(curl -sS -u "token:${GH_TOKEN_VALUE}" -o "$body" -w '%{http_code}' "$url" 2>/dev/null)
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

# github_api_paginate URL OUT_FILE -> appends each page's JSON array elements
# (one compact JSON object per line) to OUT_FILE, following `Link: rel="next"`.
# Returns 1 on any page failure (OUT_FILE contents up to that point are
# unreliable and must not be trusted by the caller).
github_api_paginate() {
  local url="$1" out_file="$2"
  local body headers status link next

  while [ -n "$url" ]; do
    body="$(mktemp "$WORKDIR/ghpage.XXXXXX")"
    headers="$(mktemp "$WORKDIR/ghhdrs.XXXXXX")"
    status=$(request_with_retry "$url" "$GITHUB_ACCEPT" "Authorization: Bearer ${GH_TOKEN_VALUE}" "$body" "$headers" GET)

    if [ "$status" != "200" ]; then
      log_warn "GitHub API request failed: ${url} (status ${status})"
      rm -f "$body" "$headers"
      return 1
    fi

    jq -c '.[]' "$body" >> "$out_file"

    link=$(grep -i '^Link:' "$headers" | tail -1)
    rm -f "$body" "$headers"

    next=""
    if [ -n "$link" ]; then
      next=$(printf '%s' "$link" | sed -n 's/.*<\([^>]*\)>[[:space:]]*;[[:space:]]*rel="next".*/\1/p')
    fi
    url="$next"
  done
  return 0
}

# ---------------------------------------------------------------------------
# Package discovery / classification
# ---------------------------------------------------------------------------

# discover_live_images -> one bare image name per line, derived from the
# bakefile's current tags (mirrors the old discover job's derivation, but
# used here only to CLASSIFY packages, never to enumerate them).
discover_live_images() {
  local bake_out
  bake_out="$WORKDIR/bake-print.json"
  if ! (
    cd "$REPO_ROOT" || exit 2
    set -a
    # shellcheck disable=SC1091
    source ./buildargs.conf
    set +a
    export REGISTRY="ghcr.io/${OWNER}/${REPO_PREFIX}"
    docker buildx bake --print 2>/dev/null
  ) > "$bake_out"; then
    return 1
  fi

  jq -r '[.target[].tags[]?] | unique | .[]' "$bake_out" \
    | sed -E 's#:[^/:]+$##' \
    | sed -E 's#.*/##' \
    | sort -u
}

# list_packages -> writes one compact JSON object per line to
# "$WORKDIR/packages.jsonl": {name, repository, visibility}. Only packages
# whose repository.full_name matches OWNER/REPO and whose name starts with
# REPO_PREFIX/ are kept.
list_packages() {
  local raw="$WORKDIR/packages-raw.jsonl"
  : > "$raw"
  if ! github_api_paginate "https://api.github.com/orgs/${OWNER}/packages?package_type=container&per_page=100" "$raw"; then
    return 1
  fi
  jq -c --arg fullrepo "${OWNER}/${REPO}" --arg prefix "${REPO_PREFIX}/" \
    'select(.repository.full_name == $fullrepo and (.name | startswith($prefix))) | {name, repository: .repository.full_name, visibility}' \
    "$raw" > "$WORKDIR/packages.jsonl"
}

# ---------------------------------------------------------------------------
# Verification (audit.sh wrapper — see header comment for rationale)
# ---------------------------------------------------------------------------

# verify_package IMAGE -> writes "$WORKDIR/verify-<image>.json" (audit.sh's
# raw JSON array, one element). Returns 0 clean, 1 broken tags found,
# 2 operational failure (including audit.sh missing).
verify_package() {
  local image="$1"
  local out_json="$WORKDIR/verify-${image}.json"
  local stderr_file="$WORKDIR/verify-${image}.stderr"

  if [ ! -x "$AUDIT_SCRIPT" ]; then
    log_err "cannot verify ${image}: ${AUDIT_SCRIPT} not found or not executable"
    return 2
  fi

  "$AUDIT_SCRIPT" --owner "$OWNER" --repo-prefix "$REPO_PREFIX" --image "$image" \
    --json "$out_json" --quiet >/dev/null 2>"$stderr_file"
  local rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *)
      log_err "verification of ${image} failed operationally: $(tr '\n' ' ' < "$stderr_file")"
      return 2
      ;;
  esac
}

# print_broken_tags IMAGE -> prints "    - <tag>" for every broken tag found
# by the last verify_package call for IMAGE.
print_broken_tags() {
  local image="$1"
  jq -r '.[0].broken_tags[]? // empty' "$WORKDIR/verify-${image}.json" 2>/dev/null | while IFS= read -r t; do
    echo "    - ${image}:${t}"
  done
}

# ---------------------------------------------------------------------------
# Per-package plan
# ---------------------------------------------------------------------------

# list_versions PKG_NAME OUT_FILE -> writes one compact JSON object per line:
# {id, digest, created_at, tags}. Returns 1 on any pagination failure.
list_versions() {
  local pkg_name="$1" out_file="$2"
  local enc raw
  enc=$(jq -rn --arg s "$pkg_name" '$s|@uri')
  raw="$WORKDIR/versions-raw-$$-${RANDOM}.jsonl"
  : > "$raw"
  if ! github_api_paginate "https://api.github.com/orgs/${OWNER}/packages/container/${enc}/versions?per_page=100" "$raw"; then
    rm -f "$raw"
    return 1
  fi
  jq -c '{id, digest: .name, created_at, tags: (.metadata.container.tags // [])}' "$raw" > "$out_file"
  rm -f "$raw"
}

# resolve_manifest PKG_REGISTRY_PATH TOKEN DIGEST -> prints child digests
# (one per line) on stdout if the manifest is an index/list; prints nothing
# for a flat manifest. Returns 1 if the manifest could not be resolved.
#
# Callers typically invoke this as `children=$(resolve_manifest ...)`, which
# runs the function in a SUBSHELL — any `VAR=...` assignment inside it is
# invisible to the caller once the subshell exits. So the observed HTTP
# status (needed by callers to report *why* a resolution failed) is written
# to a fixed file instead of a global variable.
resolve_manifest() {
  local pkg_path="$1" token="$2" digest="$3"
  local body headers status
  body="$(mktemp "$WORKDIR/mf.XXXXXX")"
  headers="$(mktemp "$WORKDIR/mfh.XXXXXX")"
  status=$(request_with_retry "https://ghcr.io/v2/${pkg_path}/manifests/${digest}" "$REGISTRY_ACCEPT" "Authorization: Bearer ${token}" "$body" "$headers" GET)
  rm -f "$headers"
  printf '%s' "$status" > "$WORKDIR/resolve-last-status.txt"

  if [ "$status" != "200" ]; then
    rm -f "$body"
    return 1
  fi

  jq -r '(.manifests // [])[].digest' "$body" 2>/dev/null
  rm -f "$body"
  return 0
}

# plan_package IMAGE CLASS -> writes "$WORKDIR/plan-<image>.json" with the
# full per-package plan, and prints the summary line. Returns:
#   0 ok
#   2 operational failure (package skipped: version listing / token / fail-closed)
#   3 safety rail #1 or #2 tripped (bug detector; caller must abort the WHOLE run)
#   4 safety rail #4 tripped (delete-ratio); this package skipped, run continues
plan_package() {
  local image="$1" class="$2"
  local pkg_name="${REPO_PREFIX}/${image}"
  local pkg_path="${OWNER}/${REPO_PREFIX}/${image}"
  local versions_file="$WORKDIR/versions-${image}.jsonl"

  if ! list_versions "$pkg_name" "$versions_file"; then
    log_warn "skipping ${pkg_name}: failed to list versions (fail-closed)"
    echo "${image}  ${class}  total=?  (SKIPPED: version listing failed)"
    jq -n --arg image "$image" --arg pkg "$pkg_name" --arg class "$class" \
      '{image: $image, package: $pkg, class: $class, error: "version listing failed", skipped: true}' \
      > "$WORKDIR/plan-${image}.json"
    return 2
  fi

  local total
  total=$(wc -l < "$versions_file" | tr -d ' ')
  if [ "$total" -eq 0 ]; then
    echo "${image}  ${class}  total=0  roots=0  reachable=0  inflight=0  DELETE=0"
    jq -n --arg image "$image" --arg pkg "$pkg_name" --arg class "$class" \
      '{image: $image, package: $pkg, class: $class, total: 0, roots: 0, reachable: 0, inflight: 0, delete: [], delete_count: 0}' \
      > "$WORKDIR/plan-${image}.json"
    return 0
  fi

  # Roots: versions with >=1 tag.
  local roots_file="$WORKDIR/roots-${image}.jsonl"
  jq -c 'select((.tags | length) > 0)' "$versions_file" > "$roots_file"
  local roots_total
  roots_total=$(wc -l < "$roots_file" | tr -d ' ')

  # Build the keep-tag-regex jq alternation once.
  local tag_regex_json
  tag_regex_json=$(printf '%s\n' "${KEEP_TAG_REGEXES[@]}" | jq -R . | jq -s .)

  # KEEP_ROOTS: see the --keep-all-tagged header comment for the two policies.
  local keep_roots_file="$WORKDIR/keeproots-${image}.txt"
  if [ "$KEEP_ALL_TAGGED" -eq 1 ]; then
    jq -r '.digest' "$roots_file" | sort -u > "$keep_roots_file"
  else
    jq -rs --argjson regexes "$tag_regex_json" --argjson keeplast "$KEEP_LAST" \
      --argjson keepdays "$KEEP_DAYS" --argjson now "$NOW_EPOCH" '
      def age_days($rec): ($now - ($rec.created_at | fromdateiso8601)) / 86400;
      def protected_tag($rec): ($rec.tags // []) | any(. as $t | $regexes | any(. as $re | $t | test($re)));
      (
        . as $all |
        ($all | map(select(protected_tag(.))) | map(.digest)) as $by_tag |
        ($all | sort_by(.created_at) | reverse | .[0:$keeplast] | map(.digest)) as $by_last |
        ($all | map(select(age_days(.) < $keepdays)) | map(.digest)) as $by_age |
        ($by_tag + $by_last + $by_age) | unique | .[]
      )' "$roots_file" > "$keep_roots_file"
  fi

  local keep_roots_count
  keep_roots_count=$(wc -l < "$keep_roots_file" | tr -d ' ')

  local token
  if ! token=$(get_registry_token "$pkg_path"); then
    log_warn "skipping ${pkg_name}: failed to obtain registry token (fail-closed)"
    echo "${image}  ${class}  total=${total}  (SKIPPED: no registry token)"
    jq -n --arg image "$image" --arg pkg "$pkg_name" --arg class "$class" --argjson total "$total" \
      '{image: $image, package: $pkg, class: $class, total: $total, error: "no registry token", skipped: true}' \
      > "$WORKDIR/plan-${image}.json"
    return 2
  fi

  # Reachability: process each keep-root's subtree (root + descendants)
  # INDEPENDENTLY, sharing one global $reachable_file for cross-root dedup.
  # Doing this per-root (rather than one merged BFS) means one broken root
  # doesn't hide diagnostics about the others: every failure is recorded
  # with the root's own tags before the package is skipped.
  local reachable_file="$WORKDIR/reachable-${image}.txt"
  local failclosed_file="$WORKDIR/failclosed-${image}.jsonl"
  local subtree_queue="$WORKDIR/sq-${image}.txt"
  local subtree_next="$WORKDIR/sq2-${image}.txt"
  : > "$reachable_file"
  : > "$failclosed_file"

  local keep_digest root_tags_json d children subtree_failed
  while IFS= read -r keep_digest; do
    [ -z "$keep_digest" ] && continue
    root_tags_json=$(jq -c --arg d "$keep_digest" 'select(.digest == $d) | .tags' "$roots_file" | head -1)
    [ -z "$root_tags_json" ] && root_tags_json="[]"

    printf '%s\n' "$keep_digest" > "$subtree_queue"
    subtree_failed=0

    while [ -s "$subtree_queue" ] && [ "$subtree_failed" -eq 0 ]; do
      : > "$subtree_next"
      while IFS= read -r d; do
        [ -z "$d" ] && continue
        if grep -qxF "$d" "$reachable_file" 2>/dev/null; then
          continue
        fi
        if children=$(resolve_manifest "$pkg_path" "$token" "$d"); then
          echo "$d" >> "$reachable_file"
          printf '%s\n' "$children" >> "$subtree_next"
        else
          local last_status
          last_status=$(cat "$WORKDIR/resolve-last-status.txt" 2>/dev/null || echo "???")
          jq -cn --arg root "$keep_digest" --argjson tags "$root_tags_json" \
            --arg failed "$d" --arg status "$last_status" \
            '{root: $root, tags: $tags, failed_digest: $failed, status: $status}' >> "$failclosed_file"
          subtree_failed=1
        fi
      done < "$subtree_queue"
      if [ "$subtree_failed" -eq 1 ]; then
        break
      fi
      if [ -s "$subtree_next" ]; then
        grep -vxFf "$reachable_file" "$subtree_next" 2>/dev/null | sort -u > "$subtree_queue" || : > "$subtree_queue"
      else
        : > "$subtree_queue"
      fi
    done
  done < "$keep_roots_file"

  if [ -s "$failclosed_file" ]; then
    local failcount
    failcount=$(wc -l < "$failclosed_file" | tr -d ' ')
    log_warn "skipping ${pkg_name}: ${failcount} keep-root(s) have an unresolved descendant (fail-closed)"
    echo "${image}  ${class}  total=${total}  (SKIPPED: manifest resolution failed — see FAIL-CLOSED report)"
    jq -n --arg image "$image" --arg pkg "$pkg_name" --arg class "$class" --argjson total "$total" \
      --slurpfile details "$failclosed_file" \
      '{image: $image, package: $pkg, class: $class, total: $total, error: "manifest resolution failed",
        skipped: true, fail_closed_details: $details}' \
      > "$WORKDIR/plan-${image}.json"
    return 2
  fi

  local reachable_count
  sort -u "$reachable_file" -o "$reachable_file"
  reachable_count=$(wc -l < "$reachable_file" | tr -d ' ')

  # INFLIGHT: any version younger than --grace-days, regardless of tags.
  local inflight_file="$WORKDIR/inflight-${image}.txt"
  jq -r --argjson gracedays "$GRACE_DAYS" --argjson now "$NOW_EPOCH" '
    def age_days: ($now - (.created_at | fromdateiso8601)) / 86400;
    select(age_days < $gracedays) | .digest' "$versions_file" | sort -u > "$inflight_file"
  local inflight_count
  inflight_count=$(wc -l < "$inflight_file" | tr -d ' ')

  # DELETE = versions.digest not in (REACHABLE ∪ INFLIGHT).
  local excluded_file="$WORKDIR/excluded-${image}.txt"
  sort -u "$reachable_file" "$inflight_file" > "$excluded_file"

  local delete_file="$WORKDIR/delete-${image}.jsonl"
  jq -c --slurpfile excluded <(jq -Rn '[inputs]' "$excluded_file") '
    (.digest as $d | ($excluded[0] | index($d)) == null) as $notexcluded |
    select($notexcluded)' "$versions_file" > "$delete_file"
  local delete_count
  delete_count=$(wc -l < "$delete_file" | tr -d ' ')

  # --- Safety rail #1: DELETE ∩ REACHABLE must be empty. Whole-run abort. ---
  local overlap
  overlap=$(jq -r '.digest' "$delete_file" | sort -u | comm -12 - "$reachable_file" | wc -l | tr -d ' ')
  if [ "$overlap" -gt 0 ]; then
    log_err "SAFETY RAIL #1 TRIPPED for ${pkg_name}: ${overlap} digest(s) are in both DELETE and REACHABLE (set-arithmetic bug) — aborting the whole run"
    return 3
  fi

  # --- Safety rail #2: no protected-tag version may appear in DELETE. Whole-run abort. ---
  local protected_in_delete
  protected_in_delete=$(jq -c --argjson regexes "$tag_regex_json" '
    select((.tags // []) | any(. as $t | $regexes | any(. as $re | $t | test($re))))' "$delete_file" | wc -l | tr -d ' ')
  if [ "$protected_in_delete" -gt 0 ]; then
    log_err "SAFETY RAIL #2 TRIPPED for ${pkg_name}: ${protected_in_delete} version(s) carrying a protected tag are in DELETE — aborting the whole run"
    return 3
  fi

  # --- Safety rail #4: DELETE must not exceed --max-delete-ratio, unless --force. Per-package skip. ---
  local threshold_hit ratio_pct
  threshold_hit=$(awk -v d="$delete_count" -v t="$total" -v r="$MAX_DELETE_RATIO" 'BEGIN { print (t > 0 && d > r * t) ? 1 : 0 }')
  ratio_pct=$(awk -v d="$delete_count" -v t="$total" 'BEGIN { if (t > 0) printf "%.1f", (d / t) * 100; else print "0.0" }')
  if [ "$threshold_hit" -eq 1 ] && [ "$FORCE" -ne 1 ]; then
    log_err "SAFETY RAIL #4 TRIPPED for ${pkg_name}: DELETE (${delete_count}/${total} = ${ratio_pct}%) exceeds --max-delete-ratio (${MAX_DELETE_RATIO}); skipping this package (pass --force to include it anyway)"
    echo "${image}  ${class}  total=${total}  roots=${roots_total}  reachable=${reachable_count}  inflight=${inflight_count}  DELETE=${delete_count}  (SKIPPED: exceeds --max-delete-ratio ${MAX_DELETE_RATIO}, ${ratio_pct}%)"
    jq -n --arg image "$image" --arg pkg "$pkg_name" --arg class "$class" \
      --argjson total "$total" --argjson roots "$roots_total" --argjson keep_roots "$keep_roots_count" \
      --argjson reachable "$reachable_count" --argjson inflight "$inflight_count" --argjson delete_count "$delete_count" \
      --arg ratio_pct "$ratio_pct" \
      '{image: $image, package: $pkg, class: $class, total: $total, roots: $roots, keep_roots: $keep_roots,
        reachable: $reachable, inflight: $inflight, delete_count: $delete_count, delete_ratio_pct: $ratio_pct,
        skipped: true, error: "exceeds --max-delete-ratio"}' \
      > "$WORKDIR/plan-${image}.json"
    return 4
  fi

  echo "${image}  ${class}  total=${total}  roots=${roots_total}  reachable=${reachable_count}  inflight=${inflight_count}  DELETE=${delete_count}"

  jq -n --arg image "$image" --arg pkg "$pkg_name" --arg class "$class" \
    --argjson total "$total" --argjson roots "$roots_total" --argjson keep_roots "$keep_roots_count" \
    --argjson reachable "$reachable_count" --argjson inflight "$inflight_count" \
    --slurpfile delete_items "$delete_file" \
    '{image: $image, package: $pkg, class: $class, total: $total, roots: $roots,
      keep_roots: $keep_roots, reachable: $reachable, inflight: $inflight,
      delete: $delete_items, delete_count: ($delete_items | length)}' \
    > "$WORKDIR/plan-${image}.json"

  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

log_info "discovering packages linked to ${OWNER}/${REPO} with prefix ${REPO_PREFIX}/ ..."
if ! list_packages; then
  log_err "failed to enumerate packages via the Packages API"
  exit 2
fi

if [ ! -s "$WORKDIR/packages.jsonl" ]; then
  log_err "no packages found linked to ${OWNER}/${REPO} with prefix ${REPO_PREFIX}/"
  exit 2
fi

log_info "discovering live images from the bakefile ..."
LIVE_IMAGES_FILE="$WORKDIR/live-images.txt"
if ! discover_live_images > "$LIVE_IMAGES_FILE"; then
  log_err "failed to run 'docker buildx bake --print' against $REPO_ROOT"
  exit 2
fi
if [ ! -s "$LIVE_IMAGES_FILE" ]; then
  log_err "bakefile discovery produced no images; refusing to classify anything as orphaned"
  exit 2
fi

# Build the work list: (image, class) pairs, filtered by --package if given.
WORKLIST_FILE="$WORKDIR/worklist.tsv"
: > "$WORKLIST_FILE"
while IFS= read -r pkg_json; do
  name=$(printf '%s' "$pkg_json" | jq -r '.name')
  image="${name#"${REPO_PREFIX}"/}"

  if grep -qxF "$image" "$LIVE_IMAGES_FILE"; then
    class="live"
  elif [ "$image" = "buildcache" ]; then
    class="infra"
  else
    class="orphan"
  fi

  if [ "${#REQUESTED_PACKAGES[@]}" -gt 0 ]; then
    match=0
    for want in "${REQUESTED_PACKAGES[@]}"; do
      [ "$want" = "$image" ] && match=1 && break
    done
    [ "$match" -eq 0 ] && continue
  fi

  printf '%s\t%s\n' "$image" "$class" >> "$WORKLIST_FILE"
done < "$WORKDIR/packages.jsonl"

if [ "${#REQUESTED_PACKAGES[@]}" -gt 0 ]; then
  for want in "${REQUESTED_PACKAGES[@]}"; do
    if ! cut -f1 "$WORKLIST_FILE" | grep -qxF "$want"; then
      log_warn "requested package '${want}' not found under ${OWNER}/${REPO} with prefix ${REPO_PREFIX}/ (or filtered out)"
    fi
  done
fi

# ---------------------------------------------------------------------------
# --verify-only: skip planning entirely, just audit current registry state.
# ---------------------------------------------------------------------------

if [ "$VERIFY_ONLY" -eq 1 ]; then
  echo "=== VERIFY-ONLY: re-resolving every currently-tagged version's manifest tree via audit.sh ==="
  verify_any_broken=0
  verify_any_opfail=0
  while IFS=$'\t' read -r image class; do
    [ -z "$image" ] && continue
    if [ "$class" = "orphan" ] && [ "$INCLUDE_ORPHANS" -ne 1 ]; then
      continue
    fi
    verify_package "$image"
    vrc=$?
    case "$vrc" in
      0) echo "${image}  ${class}  VERIFY OK (all tags intact)" ;;
      1)
        verify_any_broken=1
        echo "${image}  ${class}  VERIFY FAILED — broken tags:"
        print_broken_tags "$image"
        ;;
      2)
        verify_any_opfail=1
        echo "${image}  ${class}  VERIFY UNKNOWN (operational failure, see stderr above)"
        ;;
    esac
  done < "$WORKLIST_FILE"

  if [ -n "$JSON_OUT" ]; then
    verify_files=("$WORKDIR"/verify-*.json)
    if [ -e "${verify_files[0]}" ]; then
      jq -s '. | flatten' "${verify_files[@]}" > "$JSON_OUT"
    else
      echo "[]" > "$JSON_OUT"
    fi
    log_info "wrote verification results to ${JSON_OUT}"
  fi

  if [ "$verify_any_broken" -eq 1 ]; then
    exit 3
  fi
  if [ "$verify_any_opfail" -eq 1 ]; then
    exit 2
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Planning loop
# ---------------------------------------------------------------------------

TOTAL_DELETE=0
TOTAL_PLANNED=0
SKIPPED_PACKAGES=()
RATIO_TRIPPED_PACKAGES=()
FAILCLOSED_PACKAGES=()
PROCESSED_PACKAGES=()

while IFS=$'\t' read -r image class; do
  [ -z "$image" ] && continue

  if [ "$class" = "orphan" ] && [ "$INCLUDE_ORPHANS" -ne 1 ]; then
    echo "${image}  orphan  (reported only; pass --include-orphans to include in the plan)"
    continue
  fi

  plan_package "$image" "$class"
  rc=$?
  case "$rc" in
    0)
      PROCESSED_PACKAGES+=("$image")
      dc=$(jq -r '.delete_count' "$WORKDIR/plan-${image}.json")
      TOTAL_DELETE=$((TOTAL_DELETE + dc))
      TOTAL_PLANNED=$((TOTAL_PLANNED + 1))
      ;;
    2)
      SKIPPED_PACKAGES+=("$image")
      OPERATIONAL_FAILURE=1
      if jq -e '.fail_closed_details and (.fail_closed_details | length > 0)' "$WORKDIR/plan-${image}.json" >/dev/null 2>&1; then
        FAILCLOSED_PACKAGES+=("$image")
      fi
      ;;
    3)
      SAFETY_ABORT=1
      ;;
    4)
      RATIO_TRIPPED_PACKAGES+=("$image")
      RATIO_TRIPPED=1
      ;;
  esac

  if [ "$SAFETY_ABORT" -eq 1 ]; then
    break
  fi
done < "$WORKLIST_FILE"

if [ "$SAFETY_ABORT" -eq 1 ]; then
  log_err "aborting run: a safety rail bug-detector (#1/#2) tripped, nothing was deleted"
  exit 3
fi

# ---------------------------------------------------------------------------
# Apply (only with --apply) + post-apply verification
# ---------------------------------------------------------------------------

EFFECTIVE_DELETE=$TOTAL_DELETE
if [ "$EFFECTIVE_DELETE" -gt "$BUDGET" ]; then
  EFFECTIVE_DELETE=$BUDGET
fi
REMAINING=$((TOTAL_DELETE - EFFECTIVE_DELETE))

APPLIED_PACKAGES=()

if [ "$APPLY" -eq 1 ]; then
  BUDGET_LEFT=$BUDGET
  for image in "${PROCESSED_PACKAGES[@]}"; do
    [ "$BUDGET_LEFT" -le 0 ] && break
    pkg_name="${REPO_PREFIX}/${image}"
    enc=$(jq -rn --arg s "$pkg_name" '$s|@uri')
    delete_count=$(jq -r '.delete_count' "$WORKDIR/plan-${image}.json")
    [ "$delete_count" -eq 0 ] && continue

    package_deleted=0
    while IFS= read -r id; do
      [ -z "$id" ] && continue
      [ "$BUDGET_LEFT" -le 0 ] && break
      status=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE \
        -H "Authorization: Bearer ${GH_TOKEN_VALUE}" \
        -H "Accept: ${GITHUB_ACCEPT}" \
        "https://api.github.com/orgs/${OWNER}/packages/container/${enc}/versions/${id}")
      if [ "$status" != "204" ] && [ "$status" != "200" ]; then
        log_warn "failed to delete ${pkg_name} version ${id} (status ${status})"
        DELETE_FAILURES=$((DELETE_FAILURES + 1))
      else
        package_deleted=1
      fi
      BUDGET_LEFT=$((BUDGET_LEFT - 1))
      sleep 1
    done < <(jq -r '.delete[].id' "$WORKDIR/plan-${image}.json" | head -n "$delete_count")

    if [ "$package_deleted" -eq 1 ]; then
      APPLIED_PACKAGES+=("$image")
    fi
  done
  REMAINING=$((TOTAL_DELETE - (BUDGET - BUDGET_LEFT)))

  if [ "${#APPLIED_PACKAGES[@]}" -gt 0 ]; then
    echo "=== POST-APPLY VERIFICATION: re-resolving kept tags via audit.sh ==="
    for image in "${APPLIED_PACKAGES[@]}"; do
      verify_package "$image"
      vrc=$?
      case "$vrc" in
        0) log_info "post-apply verify OK: ${image}" ;;
        1)
          VERIFY_REGRESSION=1
          log_err "POST-APPLY REGRESSION in ${image}: a kept tag is now broken"
          print_broken_tags "$image" >&2
          ;;
        2) OPERATIONAL_FAILURE=1 ;;
      esac
    done
  fi
fi

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

echo "---"
if [ "$APPLY" -eq 1 ]; then
  echo "deleted up to $((BUDGET - REMAINING > 0 ? BUDGET - REMAINING : 0)) versions across ${TOTAL_PLANNED} package(s) (budget ${BUDGET}, ${REMAINING} remaining, ${DELETE_FAILURES} failures)"
else
  echo "DRY RUN: would delete ${EFFECTIVE_DELETE} of ${TOTAL_DELETE} planned versions across ${TOTAL_PLANNED} package(s) (budget ${BUDGET}, ${REMAINING} remaining)"
fi

if [ "${#RATIO_TRIPPED_PACKAGES[@]}" -gt 0 ]; then
  echo ""
  echo "=== --max-delete-ratio (${MAX_DELETE_RATIO}) TRIPPED — skipped, not touched ==="
  for image in "${RATIO_TRIPPED_PACKAGES[@]}"; do
    ratio_pct=$(jq -r '.delete_ratio_pct' "$WORKDIR/plan-${image}.json")
    dc=$(jq -r '.delete_count' "$WORKDIR/plan-${image}.json")
    tot=$(jq -r '.total' "$WORKDIR/plan-${image}.json")
    echo "  ${image}: DELETE ${dc}/${tot} = ${ratio_pct}% (pass --force to include it anyway)"
  done
fi

OTHER_SKIPPED=()
for image in "${SKIPPED_PACKAGES[@]:-}"; do
  [ -z "$image" ] && continue
  is_failclosed=0
  for fc in "${FAILCLOSED_PACKAGES[@]:-}"; do
    [ "$fc" = "$image" ] && is_failclosed=1 && break
  done
  [ "$is_failclosed" -eq 0 ] && OTHER_SKIPPED+=("$image")
done

if [ "${#FAILCLOSED_PACKAGES[@]}" -gt 0 ]; then
  echo ""
  echo "=== FAIL-CLOSED — CANNOT BE PRUNED UNTIL REMEDIATED ==="
  echo "These packages have at least one currently-tagged version whose manifest tree"
  echo "already has a missing child in the registry (docker pull already fails for the"
  echo "tags listed below, independent of this script). Fix/republish those tags first;"
  echo "this script will refuse to plan deletions for the package until it can prove"
  echo "every kept root is fully resolvable."
  for image in "${FAILCLOSED_PACKAGES[@]}"; do
    echo "  ${image}:"
    jq -r '.fail_closed_details[] | "    tags " + (.tags | join(", ")) + " -> missing child " + .failed_digest + " (status " + .status + ")"' \
      "$WORKDIR/plan-${image}.json"
  done
fi

if [ "${#OTHER_SKIPPED[@]}" -gt 0 ]; then
  echo ""
  echo "SKIPPED (operational failure — version listing or registry token): ${OTHER_SKIPPED[*]}"
fi

if [ "$VERIFY_REGRESSION" -eq 1 ]; then
  echo ""
  echo "=== POST-APPLY REGRESSION DETECTED — see ERROR lines above for broken tags ==="
fi

if [ -n "$JSON_OUT" ]; then
  plan_files=("$WORKDIR"/plan-*.json)
  if [ -e "${plan_files[0]}" ]; then
    jq -n --argjson budget "$BUDGET" --argjson apply "$([ "$APPLY" -eq 1 ] && echo true || echo false)" \
      --argjson max_delete_ratio "$MAX_DELETE_RATIO" \
      --slurpfile packages <(jq -s . "${plan_files[@]}") \
      '{budget: $budget, apply: $apply, max_delete_ratio: $max_delete_ratio, packages: $packages[0]}' > "$JSON_OUT"
  else
    jq -n --argjson budget "$BUDGET" --argjson apply "$([ "$APPLY" -eq 1 ] && echo true || echo false)" \
      --argjson max_delete_ratio "$MAX_DELETE_RATIO" \
      '{budget: $budget, apply: $apply, max_delete_ratio: $max_delete_ratio, packages: []}' > "$JSON_OUT"
  fi
  log_info "wrote plan to ${JSON_OUT}"
fi

# ---------------------------------------------------------------------------
# Exit code priority: verification regression > ratio rail > apply failures
# > operational failure > clean.
# ---------------------------------------------------------------------------

if [ "$VERIFY_REGRESSION" -eq 1 ]; then
  exit 3
fi
if [ "$RATIO_TRIPPED" -eq 1 ]; then
  exit 3
fi
if [ "$APPLY" -eq 1 ] && [ "$DELETE_FAILURES" -gt 0 ]; then
  exit 1
fi
if [ "$OPERATIONAL_FAILURE" -eq 1 ]; then
  exit 2
fi
exit 0
