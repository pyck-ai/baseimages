#!/usr/bin/env bash
#
# retire.sh — delete entire orphaned GHCR container packages.
#
# THE PROBLEM: when an image is renamed or removed from docker-bake.hcl, its
# GHCR package is orphaned FOREVER. prune.sh deliberately cannot fix
# this: it does per-version retention *inside* a package, so on an orphan it
# deletes some versions and leaves the package itself alive and pullable.
# Removing a dead package outright is a different operation
# (DELETE /orgs/{owner}/packages/container/{enc}, which removes ALL versions
# at once) and this script exists to do exactly that, nothing more.
#
# THIS SCRIPT DELETES ENTIRE CONTAINER PACKAGES. Default to refusing: dry
# run is the default output mode, and a low --max-retire cap requires a
# second explicit choice (--force or a larger cap) before anything acts on
# more than a couple of packages in one run.
#
# THE RULE (verified against live data 2026-09-09 — see the retire-ghcr
# project memory; do not re-derive without checking that first):
# a package is retirable when ALL of these hold:
#   - linked to this repo (repository.full_name == <owner>/<repo>) and its
#     name starts with <repo-prefix>/
#   - NOT a target in the current bakefile (see discover_live_images below)
#   - NOT an infra package (buildcache and anything passed via --infra)
#   - its updated_at is older than --after-days
#
# updated_at IS a reliable abandonment signal here: every live package is
# rebuilt daily by build-images.yml, so it always reads ~0 days old, while an
# orphan only ages monotonically once nothing publishes to it anymore.
# Verified live: all 9 current image packages and buildcache read 0 days;
# the 8 known orphans read 12-141 days. No separate state file is needed —
# the registry's own timestamp is the signal.
#
# SAFETY RAILS, all abort the run (exit 3):
#   #1 FAIL CLOSED on bakefile discovery. If `docker buildx bake --print
#      default` fails or yields zero targets, ABORT immediately. Without a
#      live set every package looks orphaned and this script would retire
#      the entire registry.
#   #2 No live package may appear in the retire set. True by construction;
#      a violation means the classification logic itself is broken, so the
#      whole run aborts rather than filtering the bad entry out.
#   #3 No infra package may appear in the retire set. Same reasoning as #2.
#   #4 --max-retire N cap (default 3): if more packages qualify than the
#      cap, retire NONE and report every candidate, unless --force.
#      Deleting several packages at once should be a deliberate, reviewed
#      act, not something that falls out of a routine scheduled run.
#
# CREDENTIAL: GITHUB_TOKEN/GH_TOKEN must be a classic PAT with read:packages,
# read:org (and delete:packages to --apply) — see list_packages below. A
# GitHub App installation token (e.g. the default Actions GITHUB_TOKEN) is
# scoped to a single repository and gets HTTP 400 from the org packages-list
# endpoint; there is no repo-scoped REST alternative. The workflow supplies
# GHCR_ADMIN_TOKEN for this reason; this script only ever reads GITHUB_TOKEN.
#
# --apply accumulates delete failures and continues (rc=1) rather than
# aborting on the first one, so a re-run converges instead of getting stuck
# retrying an already-processed package.
#
# DRY RUN IS THE DEFAULT. Deleting requires the explicit --apply flag (or the
# APPLY=true environment variable — see below); no other input changes this.
#
# Usage:
#   retire.sh [--owner ORG] [--repo REPO] [--repo-prefix PREFIX]
#             [--package NAME]... [--after-days N] [--infra NAME]...
#             [--max-retire N] [--apply] [--force] [--json FILE]
#
# --package NAME (repeatable) RESTRICTS the candidate set to the named bare
# image names; it does NOT bypass any eligibility check. A named package
# must still be repo-linked, absent from the bakefile, not infra, and older
# than --after-days to be retired — if it fails any of those, it is reported
# with the reason (live / infra / too-recent) rather than silently skipped.
# A named package that doesn't exist at all under <owner>/<repo> with prefix
# <repo-prefix>/ is an OPERATIONAL failure (exit 2), not a silent no-op.
# --max-retire still applies to the filtered set.
#
# Backs: tidy-ghcr.yml, job `retire`, step "Retire orphaned packages". This
# script doubles as the workflow entry point (the former thin wrapper script
# has been folded in here): the environment variables below are read as
# DEFAULTS, with any CLI flag of the same name taking precedence. Only the
# exact string "true" enables APPLY — anything else, including unset/empty
# (what a `schedule` event yields), is treated as false, which is what keeps
# scheduled runs dry.
#
#   APPLY            - "true" to enable --apply; anything else is dry-run
#   RETIRE_PACKAGES  - space-separated package names, each becomes a
#                      repeated --package. NOTE: deliberately not named
#                      PACKAGES — that name is already bound to prune.sh in
#                      tidy-ghcr.yml, and reusing it here would silently
#                      scope the wrong job.
#   AFTER_DAYS       - default for --after-days
#   MAX_RETIRE       - default for --max-retire
#   OWNER            - default for --owner
#   REPO             - default for --repo
#   REPO_PREFIX      - default for --repo-prefix
#
# When run under GitHub Actions (GITHUB_ACTIONS is set), this script also
# annotates its own exit code with a human-readable ::warning::/::error::
# message on the way out, mirroring what the old wrapper printed after
# delegating to this script. Hand-runs outside Actions stay quiet.
#
# Exit codes:
#   0  nothing to do / dry run clean
#   1  completed with some delete failures (--apply only)
#   2  operational failure (no token, network error, jq/docker missing, ...)
#   3  a safety-critical condition: rail #1/#2/#3 tripped (whole run
#      aborted, nothing deleted), or rail #4 tripped (nothing deleted,
#      candidates reported)

set -uo pipefail

if [ -n "${GITHUB_ACTIONS:-}" ]; then
  annotate_exit() {
    local rc=$?
    case "$rc" in
      0) echo "retire.sh: clean run, nothing further to report." ;;
      1) echo "::warning::retire.sh exited 1: completed with some delete failures. See the log and retire-plan.json artifact." ;;
      2) echo "::error::retire.sh exited 2: operational failure (missing token, network error, or missing tooling). Not a classification problem." ;;
      3) echo "::warning::retire.sh exited 3: a safety rail tripped (bakefile discovery failed, a non-orphan ended up in the candidate set, or more packages qualified than --max-retire allows). Nothing was deleted. See the log for the candidate list." ;;
      *) echo "::error::retire.sh exited unexpected code $rc." ;;
    esac
  }
fi

# ---------------------------------------------------------------------------
# Defaults / argument parsing
# ---------------------------------------------------------------------------

# Env vars supply defaults (see header comment); CLI flags below take
# precedence over all of them. Captured before APPLY is reassigned below,
# since the env var and the internal flag share a name.
APPLY_FROM_ENV="${APPLY:-}"
APPLY=0
[ "$APPLY_FROM_ENV" = "true" ] && APPLY=1

OWNER="${OWNER:-pyck-ai}"
REPO="${REPO:-baseimages}"
REPO_PREFIX="${REPO_PREFIX:-baseimages}"
REQUESTED_PACKAGES=()
if [ -n "${RETIRE_PACKAGES:-}" ]; then
  for _p in $RETIRE_PACKAGES; do
    REQUESTED_PACKAGES+=("$_p")
  done
  unset _p
fi
AFTER_DAYS="${AFTER_DAYS:-30}"
INFRA_NAMES=()
MAX_RETIRE="${MAX_RETIRE:-3}"
FORCE=0
JSON_OUT=""

usage() {
  cat <<'EOF'
Usage: retire.sh [--owner ORG] [--repo REPO] [--repo-prefix PREFIX]
                           [--package NAME]... [--after-days N]
                           [--infra NAME]... [--max-retire N]
                           [--apply] [--force] [--json FILE]

Deletes ENTIRE orphaned GHCR container packages (every version at once) for
packages that are linked to this repo, are no longer a target in the current
bakefile, are not infra, and have been untouched for --after-days. See the
header comment in this script for the full model. DRY RUN IS THE DEFAULT.

Options:
  --owner ORG            GitHub org/user owning the packages (default: pyck-ai)
  --repo REPO             Repository packages must be linked to (default: baseimages)
  --repo-prefix PREFIX    Package name prefix (default: baseimages); packages
                          are addressed as <repo-prefix>/<image>
  --package NAME          Restrict to this bare image name (e.g. aws,
                          renovate); repeatable. Restricts the candidate set
                          only — eligibility rules (live/infra/too-recent)
                          still apply, and a named package is reported with
                          its reason rather than silently skipped. A named
                          package that does not exist at all is an
                          operational failure (exit 2). Default: every
                          package linked to <owner>/<repo> whose name starts
                          with <repo-prefix>/
  --after-days N          Only retire packages whose updated_at is older than
                          N days (default: 30)
  --infra NAME            Package (bare) name to treat as infra, never
                          retirable; repeatable (default: buildcache)
  --max-retire N          Safety rail: if more than N packages qualify,
                          retire none and report all candidates, unless
                          --force (default: 3)
  --apply                Actually delete. Without this flag nothing is ever
                          deleted, regardless of any other option.
  --force                Override the --max-retire rail
  --json FILE             Write the full machine-readable plan to FILE
  -h, --help              Show this help and exit

Exit codes:
  0  nothing to do / dry run clean
  1  completed with some delete failures (--apply only)
  2  operational failure (no token, network error, jq/docker missing, ...)
  3  a safety-critical condition: rail #1/#2/#3 tripped (whole run aborted,
     nothing deleted), or rail #4 tripped (nothing deleted, candidates
     reported)
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
    --after-days)
      AFTER_DAYS="${2:?--after-days requires a value}"
      shift 2
      ;;
    --infra)
      INFRA_NAMES+=("${2:?--infra requires a value}")
      shift 2
      ;;
    --max-retire)
      MAX_RETIRE="${2:?--max-retire requires a value}"
      shift 2
      ;;
    --apply)
      APPLY=1
      shift
      ;;
    --force)
      FORCE=1
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
      echo "retire.sh: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "${#INFRA_NAMES[@]}" -eq 0 ]; then
  INFRA_NAMES=('buildcache')
fi

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------

for bin in curl jq docker; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "retire.sh: required command '$bin' not found in PATH" >&2
    exit 2
  fi
done

GH_TOKEN_VALUE="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
if [ -z "$GH_TOKEN_VALUE" ]; then
  echo "retire.sh: GITHUB_TOKEN or GH_TOKEN must be set (needs read:packages, and delete:packages to --apply)" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

if [ ! -f "$REPO_ROOT/buildargs.conf" ] || [ ! -f "$REPO_ROOT/docker-bake.hcl" ]; then
  echo "retire.sh: expected buildargs.conf and docker-bake.hcl under $REPO_ROOT" >&2
  exit 2
fi

GITHUB_ACCEPT="application/vnd.github+json"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/retire.XXXXXX")"
if [ -n "${GITHUB_ACTIONS:-}" ]; then
  trap 'rm -rf "$WORKDIR"; annotate_exit' EXIT
else
  trap 'rm -rf "$WORKDIR"' EXIT
fi

log_warn() { echo "WARN: $*" >&2; }
log_info() { echo "INFO: $*" >&2; }
log_err()  { echo "ERROR: $*" >&2; }

# report_enum_failure STATUS -> prints a diagnostic for a failed
# organization packages-list call. HTTP 400/403/401 from
# `GET /orgs/{owner}/packages` almost always means the token is a
# repository-scoped GitHub App installation token (the default Actions
# GITHUB_TOKEN) rather than a classic PAT — that endpoint can only list org
# packages for a classic PAT (or an App token installed at the org level).
# Any other status (network error, 5xx, rate limit) gets the generic
# message instead, so a transient failure isn't misreported as a
# credential problem.
report_enum_failure() {
  local status="$1"
  case "$status" in
    400|401|403)
      log_err "failed to enumerate packages via the Packages API (HTTP ${status})."
      log_err "This endpoint cannot be called with a repository-scoped GitHub App"
      log_err "installation token (the default Actions GITHUB_TOKEN): it can only list"
      log_err "organization packages for a classic PAT (or an App token installed at the"
      log_err "org level). Set GHCR_ADMIN_TOKEN as a repository secret to a classic PAT"
      log_err "with read:packages, delete:packages and read:org scopes."
      log_err "(A fine-grained PAT will not work; GitHub Packages does not support them.)"
      log_err "Note: an invalid/expired token also produces 401 here, so 401 alone doesn't"
      log_err "prove a scope problem — but the fix (a valid classic PAT with the scopes"
      log_err "above) is the same either way."
      ;;
    *)
      log_err "failed to enumerate packages via the Packages API (HTTP ${status:-unknown})."
      ;;
  esac
}

OPERATIONAL_FAILURE=0
DELETE_FAILURES=0
NOW_EPOCH=$(date -u +%s)

# ---------------------------------------------------------------------------
# HTTP helpers (mirrors prune.sh's retry/backoff conventions)
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

# github_api_paginate URL OUT_FILE -> appends each page's JSON array elements
# (one compact JSON object per line) to OUT_FILE, following `Link: rel="next"`.
# Returns 1 on any page failure (OUT_FILE contents up to that point are
# unreliable and must not be trusted by the caller). On failure, also sets
# LAST_API_STATUS to the failing HTTP status so callers can distinguish a
# credential/scope problem from a transient one (see report_enum_failure).
LAST_API_STATUS=""
github_api_paginate() {
  local url="$1" out_file="$2"
  local body headers status link next

  while [ -n "$url" ]; do
    body="$(mktemp "$WORKDIR/ghpage.XXXXXX")"
    headers="$(mktemp "$WORKDIR/ghhdrs.XXXXXX")"
    status=$(request_with_retry "$url" "$GITHUB_ACCEPT" "Authorization: Bearer ${GH_TOKEN_VALUE}" "$body" "$headers" GET)

    if [ "$status" != "200" ]; then
      log_warn "GitHub API request failed: ${url} (status ${status})"
      LAST_API_STATUS="$status"
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
# Bakefile / package discovery
# ---------------------------------------------------------------------------

# discover_live_images -> one bare image name per line, derived from the
# bakefile's current tags. Used ONLY to classify packages — see safety rail
# #1: if this fails or is empty, the caller must abort rather than treat
# everything as orphaned.
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
    docker buildx bake --print default 2>/dev/null
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
# REPO_PREFIX/ are kept. NOTE: the list endpoint does not include
# version_count/updated_at — those require a per-package GET (see
# fetch_package_detail).
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

# fetch_package_detail PKG_NAME -> writes "$WORKDIR/detail-<image>.json"
# with {name, version_count, updated_at, visibility}. Returns 1 on failure.
fetch_package_detail() {
  local pkg_name="$1" image="$2"
  local enc body headers status
  enc=$(jq -rn --arg s "$pkg_name" '$s|@uri')
  body="$WORKDIR/detail-${image}.json"
  headers="$(mktemp "$WORKDIR/dh.XXXXXX")"
  status=$(request_with_retry "https://api.github.com/orgs/${OWNER}/packages/container/${enc}" "$GITHUB_ACCEPT" "Authorization: Bearer ${GH_TOKEN_VALUE}" "$body" "$headers" GET)
  rm -f "$headers"
  if [ "$status" != "200" ]; then
    log_warn "failed to fetch package detail for ${pkg_name} (status ${status})"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

log_info "discovering live images from the bakefile ..."
LIVE_IMAGES_FILE="$WORKDIR/live-images.txt"
if ! discover_live_images > "$LIVE_IMAGES_FILE"; then
  log_err "SAFETY RAIL #1 TRIPPED: failed to run 'docker buildx bake --print default' against $REPO_ROOT — refusing to classify anything as orphaned"
  exit 3
fi
if [ ! -s "$LIVE_IMAGES_FILE" ]; then
  log_err "SAFETY RAIL #1 TRIPPED: bakefile discovery produced no images — refusing to classify anything as orphaned"
  exit 3
fi
log_info "live images: $(tr '\n' ' ' < "$LIVE_IMAGES_FILE")"

log_info "discovering packages linked to ${OWNER}/${REPO} with prefix ${REPO_PREFIX}/ ..."
if ! list_packages; then
  report_enum_failure "$LAST_API_STATUS"
  exit 2
fi

if [ ! -s "$WORKDIR/packages.jsonl" ]; then
  log_err "no packages found linked to ${OWNER}/${REPO} with prefix ${REPO_PREFIX}/"
  exit 2
fi

# --package restricts the candidate set. This only narrows WHICH packages
# are considered below; every eligibility check (live/infra/too-recent)
# still runs normally on whatever survives the filter. A requested package
# that isn't present at all under this owner/repo/prefix is an operational
# failure, not a silent no-op.
if [ "${#REQUESTED_PACKAGES[@]}" -gt 0 ]; then
  ALL_PACKAGES_FILE="$WORKDIR/packages-all.jsonl"
  cp "$WORKDIR/packages.jsonl" "$ALL_PACKAGES_FILE"
  : > "$WORKDIR/packages.jsonl"
  while IFS= read -r pkg_json; do
    name=$(printf '%s' "$pkg_json" | jq -r '.name')
    image="${name#"${REPO_PREFIX}"/}"
    for want in "${REQUESTED_PACKAGES[@]}"; do
      if [ "$want" = "$image" ]; then
        echo "$pkg_json" >> "$WORKDIR/packages.jsonl"
        break
      fi
    done
  done < "$ALL_PACKAGES_FILE"

  for want in "${REQUESTED_PACKAGES[@]}"; do
    found=0
    while IFS= read -r pkg_json; do
      [ -z "$pkg_json" ] && continue
      name=$(printf '%s' "$pkg_json" | jq -r '.name')
      image="${name#"${REPO_PREFIX}"/}"
      [ "$want" = "$image" ] && found=1 && break
    done < "$WORKDIR/packages.jsonl"
    if [ "$found" -ne 1 ]; then
      log_err "requested package '${want}' not found under ${OWNER}/${REPO} with prefix ${REPO_PREFIX}/"
      exit 2
    fi
  done
fi

is_infra() {
  local image="$1" n
  for n in "${INFRA_NAMES[@]}"; do
    [ "$n" = "$image" ] && return 0
  done
  return 1
}

# Classify each package and fetch its detail (version_count/updated_at).
ROWS_FILE="$WORKDIR/rows.jsonl"
: > "$ROWS_FILE"

while IFS= read -r pkg_json; do
  name=$(printf '%s' "$pkg_json" | jq -r '.name')
  image="${name#"${REPO_PREFIX}"/}"

  if grep -qxF "$image" "$LIVE_IMAGES_FILE"; then
    class="live"
  elif is_infra "$image"; then
    class="infra"
  else
    class="orphan"
  fi

  if ! fetch_package_detail "$name" "$image"; then
    OPERATIONAL_FAILURE=1
    jq -cn --arg image "$image" --arg pkg "$name" --arg class "$class" \
      '{image: $image, package: $pkg, class: $class, error: "failed to fetch package detail", skipped: true}' \
      >> "$ROWS_FILE"
    continue
  fi

  jq -c --arg image "$image" --arg class "$class" --argjson now "$NOW_EPOCH" '
    {
      image: $image,
      package: .name,
      class: $class,
      version_count: .version_count,
      updated_at: .updated_at,
      days_since: (($now - (.updated_at | fromdateiso8601)) / 86400 | floor)
    }' "$WORKDIR/detail-${image}.json" >> "$ROWS_FILE"
done < "$WORKDIR/packages.jsonl"

# ---------------------------------------------------------------------------
# Safety rails #2 / #3: no live or infra package may ever appear in the
# candidate/retire set. True by construction from the classification above;
# a violation here means the classification logic itself is broken.
# ---------------------------------------------------------------------------

CANDIDATES_FILE="$WORKDIR/candidates.jsonl"
jq -c --argjson afterdays "$AFTER_DAYS" \
  'select(.class == "orphan" and ((.error // "") | length == 0) and .days_since > $afterdays)' \
  "$ROWS_FILE" > "$CANDIDATES_FILE" 2>/dev/null || : > "$CANDIDATES_FILE"

bad_class=$(jq -r 'select(.class != "orphan") | .package' "$CANDIDATES_FILE" 2>/dev/null)
if [ -n "$bad_class" ]; then
  log_err "SAFETY RAIL #2/#3 TRIPPED: a non-orphan package ended up in the candidate set: ${bad_class} — aborting the whole run, nothing deleted"
  exit 3
fi

CANDIDATE_COUNT=$(wc -l < "$CANDIDATES_FILE" | tr -d ' ')

# ---------------------------------------------------------------------------
# Reporting: full table of every package.
# ---------------------------------------------------------------------------

PACKAGE_FILTER_DESC="all"
if [ "${#REQUESTED_PACKAGES[@]}" -gt 0 ]; then
  PACKAGE_FILTER_DESC="${REQUESTED_PACKAGES[*]}"
fi
echo "=== package inventory (owner=${OWNER} repo=${REPO} prefix=${REPO_PREFIX}/ packages=${PACKAGE_FILTER_DESC} after-days=${AFTER_DAYS} max-retire=${MAX_RETIRE}) ==="
printf '%-14s %-8s %10s  %-22s %10s  %s\n' "PACKAGE" "CLASS" "VERSIONS" "UPDATED_AT" "DAYS_AGO" "ACTION"

RETIRE_SET_FILE="$WORKDIR/retire-set.jsonl"
: > "$RETIRE_SET_FILE"

RAIL4_TRIPPED=0
if [ "$CANDIDATE_COUNT" -gt "$MAX_RETIRE" ] && [ "$FORCE" -ne 1 ]; then
  RAIL4_TRIPPED=1
fi

while IFS= read -r row; do
  [ -z "$row" ] && continue
  image=$(jq -r '.image' <<<"$row")
  class=$(jq -r '.class' <<<"$row")
  if jq -e '.error' <<<"$row" >/dev/null 2>&1; then
    printf '%-14s %-8s %10s  %-22s %10s  %s\n' "$image" "$class" "?" "?" "?" "SKIPPED (detail fetch failed)"
    continue
  fi
  vc=$(jq -r '.version_count' <<<"$row")
  ua=$(jq -r '.updated_at' <<<"$row")
  ds=$(jq -r '.days_since' <<<"$row")

  action="KEEP"
  if [ "$class" = "orphan" ]; then
    if [ "$ds" -le "$AFTER_DAYS" ]; then
      action="too-recent"
    elif [ "$RAIL4_TRIPPED" -eq 1 ]; then
      action="RETIRE (blocked by --max-retire)"
    else
      action="RETIRE"
      echo "$row" >> "$RETIRE_SET_FILE"
    fi
  fi

  printf '%-14s %-8s %10s  %-22s %10s  %s\n' "$image" "$class" "$vc" "$ua" "${ds}d" "$action"
done < "$ROWS_FILE"

RETIRE_COUNT=$(wc -l < "$RETIRE_SET_FILE" | tr -d ' ')
RETIRE_VERSIONS=$(jq -s '[.[].version_count] | add // 0' "$RETIRE_SET_FILE")

echo "---"
if [ "$RAIL4_TRIPPED" -eq 1 ]; then
  log_err "SAFETY RAIL #4 TRIPPED: ${CANDIDATE_COUNT} package(s) qualify for retirement, exceeding --max-retire (${MAX_RETIRE}); retiring NONE this run (pass --force, or a larger --max-retire, to proceed)"
  echo "candidates that would be retired if the cap allowed it:"
  jq -r '"  - " + .package + " (" + (.version_count|tostring) + " versions, " + (.days_since|tostring) + "d since update)"' "$CANDIDATES_FILE"
fi

if [ "$RETIRE_COUNT" -eq 0 ] && [ "$RAIL4_TRIPPED" -eq 0 ]; then
  echo "no packages qualify for retirement."
fi

if [ -n "$JSON_OUT" ]; then
  jq -n --argjson owner_repo "$(jq -n --arg o "$OWNER" --arg r "$REPO" --arg p "$REPO_PREFIX" '{owner:$o, repo:$r, repo_prefix:$p}')" \
    --argjson after_days "$AFTER_DAYS" --argjson max_retire "$MAX_RETIRE" \
    --argjson apply "$([ "$APPLY" -eq 1 ] && echo true || echo false)" \
    --argjson rail4_tripped "$([ "$RAIL4_TRIPPED" -eq 1 ] && echo true || echo false)" \
    --slurpfile rows <(jq -s '.' "$ROWS_FILE") \
    --slurpfile retire_set <(jq -s '.' "$RETIRE_SET_FILE") \
    '{config: $owner_repo, after_days: $after_days, max_retire: $max_retire, apply: $apply,
      rail4_tripped: $rail4_tripped, packages: $rows[0], retire_set: $retire_set[0]}' \
    > "$JSON_OUT"
  log_info "wrote plan to ${JSON_OUT}"
fi

if [ "$RAIL4_TRIPPED" -eq 1 ]; then
  exit 3
fi

if [ "$RETIRE_COUNT" -eq 0 ]; then
  if [ "$OPERATIONAL_FAILURE" -eq 1 ]; then
    exit 2
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Apply (only with --apply)
# ---------------------------------------------------------------------------

if [ "$APPLY" -ne 1 ]; then
  echo ""
  echo "DRY RUN: would retire ${RETIRE_COUNT} package(s) totalling ${RETIRE_VERSIONS} version(s):"
  jq -r '"  - " + .package + " (" + (.version_count|tostring) + " versions, " + (.days_since|tostring) + "d since update)"' "$RETIRE_SET_FILE"
  if [ "$OPERATIONAL_FAILURE" -eq 1 ]; then
    exit 2
  fi
  exit 0
fi

echo ""
echo "APPLYING: retiring ${RETIRE_COUNT} package(s) totalling ${RETIRE_VERSIONS} version(s):"
RETIRED_OK=()
RETIRED_FAILED=()
while IFS= read -r row; do
  [ -z "$row" ] && continue
  pkg_name=$(jq -r '.package' <<<"$row")
  enc=$(jq -rn --arg s "$pkg_name" '$s|@uri')
  status=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE \
    -H "Authorization: Bearer ${GH_TOKEN_VALUE}" \
    -H "Accept: ${GITHUB_ACCEPT}" \
    "https://api.github.com/orgs/${OWNER}/packages/container/${enc}")
  if [ "$status" = "204" ] || [ "$status" = "200" ]; then
    echo "  retired ${pkg_name}"
    RETIRED_OK+=("$pkg_name")
  else
    log_warn "failed to retire ${pkg_name} (status ${status})"
    RETIRED_FAILED+=("$pkg_name")
    DELETE_FAILURES=$((DELETE_FAILURES + 1))
  fi
done < "$RETIRE_SET_FILE"

echo "---"
echo "retired ${#RETIRED_OK[@]} of ${RETIRE_COUNT} package(s) (${DELETE_FAILURES} failure(s))"

if [ "$DELETE_FAILURES" -gt 0 ]; then
  exit 1
fi
if [ "$OPERATIONAL_FAILURE" -eq 1 ]; then
  exit 2
fi
exit 0

