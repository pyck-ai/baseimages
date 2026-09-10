#!/usr/bin/env bash
#
# tidy.sh — reachability-safe GHCR prune for this repo's container
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
# EMPTY-PACKAGE SWEEP: with --apply, after a package's version deletions for
# this run complete, the package is RE-QUERIED (never inferred from local
# bookkeeping — the registry is the only authority). If that re-query shows
# zero versions remaining, the container package itself is deleted (or, if
# GHCR already auto-removed it, treated as already gone via a 404). This
# never fires on the planned DELETE count, only on confirmed post-deletion
# emptiness, so a budget cutoff or an individual version-delete failure mid-
# package correctly leaves the package (and the sweep) for the next run. In
# dry-run this is reported as `would delete package ...` with nothing called.
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
#   orphan  - neither; processed on every run exactly like live/infra
#             packages (no flag to remember — safety is rails #1-#4 and
#             reachability; see the ORPHAN DECAY EXEMPTION comment on rail
#             #4 in plan_package for how a genuinely stale orphan is
#             allowed to decay all the way to zero versions, at which
#             point the empty-package sweep removes the package itself)
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
#      DELETE. This is a PER-PACKAGE skip-and-continue (exit 3 overall, like
#      #4 below), not a whole-run abort: a set-arithmetic bug in one
#      package's policy computation isn't evidence the other packages are
#      miscomputed, and a whole-run abort here let one bad package silently
#      zero out an entire scheduled run's worth of deletions, indefinitely.
#      EXCLUDES digests confirmed `broken` by --delete-broken-roots (see
#      below): a root classify_root has independently confirmed dead (every
#      direct child a confirmed 404) already has an unpullable tag in the
#      registry, so deleting it cannot break a working pull — forbidding
#      that here would put this rail in direct conflict with the
#      remediation --delete-broken-roots exists to perform.
#   #3 If ANY keep-root or its descendant fails to resolve, that PACKAGE is
#      skipped (fail-closed) and reported in the FAIL-CLOSED section: this
#      is real, already-existing registry corruption, not a bug in this
#      script, so other packages are still processed normally.
#      --delete-broken-roots narrows this rail (see below) rather than
#      removing it: a root only escapes fail-closed if EVERY one of its
#      direct children is a confirmed 404, never merely "unresolved".
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
# --delete-broken-roots: remediation mode for pre-existing corruption (a
# keep-root whose descendants were already deleted by a *previous* buggy
# prune, e.g. nginx/rover — see rail #3; its interaction with rail #2 is
# covered in rail #2's own comment above). Off by default: with it off,
# behaviour is EXACTLY as without this flag at all — any unresolved
# descendant fails the whole package closed. With it on, a keep-root is
# reclassified as `broken` (dead index) rather than merely `unresolved`
# ONLY if EVERY one of its direct children definitively returns 404 —
# genuinely gone, not merely "couldn't be resolved just now". If even one
# child returns anything else (a live 200, a 429/5xx/timeout, i.e. status
# unknown), the root is NOT broken and the whole package still fails
# closed, exactly as today; the retry-with-backoff in request_with_retry
# still runs first, so a rate limit is never mistaken for a 404. A
# confirmed-broken root is added to that package's DELETE set (subject to
# every existing safety rail — #1, #2, #4, the budget) instead of forcing
# the whole package to be skipped, and is reported in its own BROKEN ROOTS
# section (digest + tags) separate from the ordinary delete plan, so a
# reviewer sees exactly which tags are about to disappear because their
# index was already dead. This does not touch classification of orphan
# vs. live/infra packages, and requires --apply (same as everything else
# in this script) to actually delete anything.
#
# CREDENTIAL: GITHUB_TOKEN/GH_TOKEN must be a classic PAT with read:packages,
# read:org (and delete:packages to --apply) — see list_packages below. A
# GitHub App installation token (e.g. the default Actions GITHUB_TOKEN) is
# scoped to a single repository and gets HTTP 400 from the org packages-list
# endpoint; there is no repo-scoped REST alternative. The workflow supplies
# GHCR_ADMIN_TOKEN for this reason; this script only ever reads GITHUB_TOKEN.
#
# VERIFICATION (--verify-only, and automatically after --apply): re-resolves
# every currently-tagged version's manifest tree via `audit.sh`
# (co-located in this directory; invoked rather than reimplemented — see
# that script's header for why the registry, not the Packages API, is the
# only authoritative source for "is this tag actually pullable").
#
# With --apply, this script snapshots each touched package's broken-tag set
# immediately BEFORE that package's deletions run ("pre"), then re-verifies
# it after ("post"). A tag is only a REGRESSION if it was healthy pre and is
# broken post — that's this run's own doing, reported loudly by tag, exit 3.
# A tag broken in BOTH pre and post is pre-existing corruption this run
# didn't cause (its version is simply beyond --budget, not yet reached);
# it's reported in its own non-fatal "KNOWN PRE-EXISTING CORRUPTION"
# section and does NOT trip exit 3. This distinction matters on a budgeted
# multi-run drain of an already-broken package (e.g. rover): without it,
# every single run would falsely report the same known, already-tracked
# corruption as a fresh regression. If the "pre" snapshot itself fails
# operationally, every broken "post" tag for that package is conservatively
# treated as a regression (fail loud, never silently swallow a real one).
#
# --verify-only never applies anything, so it has no "pre" snapshot from
# this run to diff against. Every broken tag it finds is therefore reported
# as PRE-EXISTING corruption, not a regression, and does NOT trip exit 3 —
# only its own operational failures (exit 2) do.
#
# DRY RUN IS THE DEFAULT. Deleting requires the explicit --apply flag (or the
# APPLY=true environment variable — see below); no other input changes this.
#
# Usage:
#   tidy.sh [--owner ORG] [--repo REPO] [--repo-prefix PREFIX]
#            [--package NAME]... [--keep-last N] [--keep-days N]
#            [--keep-all-tagged] [--grace-days N] [--keep-tag-regex RE]...
#            [--max-delete-ratio R] [--budget N]
#            [--delete-broken-roots] [--apply] [--force] [--verify-only]
#            [--json FILE]
#
# Backs: tidy-ghcr.yml, job `prune`, step "Prune GHCR packages". This script
# doubles as the workflow entry point (the former thin wrapper script has
# been folded in here): the environment variables below are read as
# DEFAULTS, with any CLI flag of the same name taking precedence. Only the
# exact string "true" enables APPLY / KEEP_ALL_TAGGED — anything else,
# including unset/empty (what a `schedule` event yields), is treated as
# false, which is what keeps scheduled runs dry.
#
#   APPLY               - "true" to enable --apply; anything else is dry-run
#   PACKAGES            - space-separated package names, each becomes a
#                         repeated --package
#   BUDGET              - default for --budget
#   KEEP_ALL_TAGGED     - "true" to enable --keep-all-tagged
#   DELETE_BROKEN_ROOTS - "true" to enable --delete-broken-roots
#   OWNER               - default for --owner
#   REPO                - default for --repo
#   REPO_PREFIX         - default for --repo-prefix
#
# When run under GitHub Actions (GITHUB_ACTIONS is set), this script also
# annotates its own exit code with a human-readable ::warning::/::error::
# message on the way out — including the note that exit 2 with nginx/rover
# fail-closed is currently EXPECTED — mirroring what the old wrapper printed
# after delegating to this script. Hand-runs outside Actions stay quiet.
#
# Exit codes:
#   0  nothing to do / dry run clean / --verify-only found no broken tags
#      (or only PRE-EXISTING broken tags — see VERIFICATION above). A rail
#      #4 trip on a never-tagged stale orphan (EXPECTED STEADY STATE — see
#      M4 in plan_package) is reported but alone does NOT prevent exit 0.
#   1  completed with some delete failures (--apply only)
#   2  operational failure (no token, network error, jq/docker missing, ...)
#   3  a safety-critical condition: rail #1 tripped (whole run aborted,
#      nothing deleted — the only rail that still aborts the whole run), OR
#      rail #2/#4 tripped GENUINELY for at least one package (that package
#      skipped, others still processed — this excludes the EXPECTED STEADY
#      STATE rail #4 case above), OR post-apply verification found a
#      REGRESSION — a tag that was healthy immediately before this run's
#      deletions and is broken now (pre-existing corruption alone
#      never trips this; see VERIFICATION above)

set -uo pipefail

if [ -n "${GITHUB_ACTIONS:-}" ]; then
  # Takes the real exit code as $1 rather than reading $? internally: the
  # EXIT trap below runs `rm -rf "$WORKDIR"` immediately before this
  # function, and that rm's own exit status (0 on success) would silently
  # clobber $? by the time a bare `local rc=$?` here ever ran — meaning
  # every case below except 0 would be dead code in practice. Found while
  # validating the exit-2 gate on the NOTE just below (ora-2 S2): the gate
  # was correct but unreachable without this fix, since rc was always 0.
  annotate_exit() {
    local rc="$1"
    case "$rc" in
      0) echo "tidy.sh: clean run, nothing further to report." ;;
      1) echo "::warning::tidy.sh exited 1: completed with some delete failures. See the log and tidy-plan.json artifact." ;;
      2) echo "::error::tidy.sh exited 2: operational failure (missing token, network error, or missing tooling). Not a classification problem." ;;
      3) echo "::error::tidy.sh exited 3: a safety rail tripped, or post-apply verification found a REGRESSION (a tag healthy before this run's deletions is now broken). Nothing unsafe was deleted. Pre-existing corruption alone does not trip this — see the log for a separate non-fatal KNOWN PRE-EXISTING CORRUPTION section if present." ;;
      *) echo "::error::tidy.sh exited unexpected code $rc." ;;
    esac
    # ora-2 S2: this NOTE used to print on EVERY exit path, including exit
    # 0 — making a genuinely disarming exit 2 (cross-check abort, expired
    # PAT, enumeration failure) visually indistinguishable from the benign,
    # already-known nginx/rover corruption we've trained ourselves to skip
    # past. Gated to the exit-2 branch only, where it's actually relevant.
    # DELETE THIS NOTE OUTRIGHT once nginx/rover's pre-existing corruption
    # is remediated (see --delete-broken-roots) — it must not outlive its
    # usefulness as a "yes, this is the known one" signal.
    if [ "$rc" -eq 2 ]; then
      echo "NOTE: exit 2 with nginx and/or rover reported under FAIL-CLOSED is currently EXPECTED — those two packages already have broken tags from the pre-existing registry corruption (see audit.sh) and tidy.sh correctly refuses to plan for them until that is remediated separately. Pass --delete-broken-roots to remediate: it clears keep-roots whose descendants are all confirmed 404 (dead indexes) so those packages can be pruned normally. This is not a new problem introduced by this run."
    fi
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
DELETE_BROKEN_ROOTS_FROM_ENV="${DELETE_BROKEN_ROOTS:-}"

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
KEEP_DAYS=30
# Threshold for the orphan --max-delete-ratio exemption (rail #4, see
# plan_package). Deliberately a fixed constant, NOT tied to --keep-days:
# an operator retuning --keep-days for the retention policy must not
# accidentally re-arm or disarm this separate safety gate.
ORPHAN_STALE_DAYS=30
KEEP_ALL_TAGGED=0
[ "$KEEP_ALL_TAGGED_FROM_ENV" = "true" ] && KEEP_ALL_TAGGED=1
# Deliberately equal to KEEP_DAYS: together they implement the agreed
# "nothing under 30 days is deleted, tagged or not" floor. KEEP_DAYS
# protects TAGGED ROOTS (via the KEEP_ROOTS policy in plan_package);
# GRACE_DAYS protects EVERYTHING ELSE (untagged children, in-flight
# digest-push-then-tag races — see INFLIGHT below) via the same age
# threshold. They stay separate knobs because they answer different
# questions, but lowering either one below 30 silently deletes inside the
# agreed floor — keep them equal unless the floor itself is renegotiated.
GRACE_DAYS=30
KEEP_TAG_REGEXES=()
MAX_DELETE_RATIO="0.98"
BUDGET="${BUDGET:-400}"
DELETE_BROKEN_ROOTS=0
[ "$DELETE_BROKEN_ROOTS_FROM_ENV" = "true" ] && DELETE_BROKEN_ROOTS=1
APPLY=0
[ "$APPLY_FROM_ENV" = "true" ] && APPLY=1
FORCE=0
VERIFY_ONLY=0
JSON_OUT=""

usage() {
  cat <<'EOF'
Usage: tidy.sh [--owner ORG] [--repo REPO] [--repo-prefix PREFIX]
                      [--package NAME]... [--keep-last N] [--keep-days N]
                      [--keep-all-tagged] [--grace-days N]
                      [--keep-tag-regex RE]... [--max-delete-ratio R]
                      [--budget N]
                      [--delete-broken-roots] [--apply] [--force]
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
                        (default: 30). Applies to packages whose target is
                        still in the bakefile; for orphan packages (target
                        removed from the bakefile) this is the ONLY
                        retention rule — --keep-last and --keep-tag-regex
                        do not apply, so an orphan's tags decay too.
  --keep-all-tagged     Keep EVERY tagged root regardless of age or count,
                        ignoring --keep-last/--keep-days/--keep-tag-regex.
                        Use for cache-like packages (e.g. buildcache) whose
                        tags are live cache entries, not release history.
  --grace-days N        Keep ANY version (tagged or not) younger than N days:
                        in-flight protection for digest-push-then-tag races,
                        and (deliberately equal to --keep-days by default)
                        the untagged half of the 30-day "nothing under 30
                        days is deleted" floor (default: 30)
  --keep-tag-regex RE   Keep any root carrying a tag matching this extended
                        regex; repeatable. Default: ^latest$ ^alpine$ ^debian$
  --max-delete-ratio R  Per-package safety rail: skip (don't touch) a
                        package whose planned DELETE exceeds this fraction
                        of its total versions, unless --force (default: 0.98)
  --budget N            Stop after N deletions this run and report the
                        remainder (default: 400)
  --delete-broken-roots Remediation mode: a keep-root whose EVERY direct
                        child resolves as a confirmed 404 (dead index —
                        pre-existing corruption, not touched by this run)
                        is added to that package's delete set instead of
                        forcing the whole package to fail closed. Any root
                        with even one non-404-unresolvable child still
                        fails the package closed, exactly as without this
                        flag. Reported in its own BROKEN ROOTS section.
                        Default: off (unchanged fail-closed behaviour).
  --apply               Actually delete. Without this flag nothing is ever
                        deleted, regardless of any other option. Runs
                        verification (see --verify-only) afterwards on every
                        package that had deletions applied.
  --force               Override the --max-delete-ratio rail
  --verify-only         Skip planning/deletion entirely; just re-resolve
                        every currently-tagged version's manifest tree via
                        audit.sh and report any broken tags. Since nothing
                        is applied, there is no "before" to diff against:
                        every broken tag found is reported as PRE-EXISTING
                        corruption, never as a regression, and does not
                        affect the exit code (still 0 unless an operational
                        failure occurs, then 2).
  --json FILE           Write the full machine-readable plan to FILE
  -h, --help            Show this help and exit

Exit codes:
  0  nothing to do / dry run clean / --verify-only found no broken tags
     (or only PRE-EXISTING ones). A rail #4 trip on a never-tagged stale
     orphan (EXPECTED STEADY STATE) is reported but doesn't prevent this.
  1  completed with some delete failures (--apply only)
  2  operational failure (no token, network error, jq/docker missing, ...)
  3  a safety-critical condition: rail #1 tripped (whole run aborted,
     nothing deleted — the only rail that still aborts the whole run), OR
     rail #2/#4 tripped GENUINELY for at least one package (that package
     skipped, others still processed — excludes the EXPECTED STEADY STATE
     rail #4 case above), OR post-apply verification found a
     REGRESSION (a tag healthy immediately before this run's
     deletions and broken now — pre-existing corruption alone never trips
     this)
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
    --delete-broken-roots)
      DELETE_BROKEN_ROOTS=1
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
      echo "tidy.sh: unknown argument: $1" >&2
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
    echo "tidy.sh: required command '$bin' not found in PATH" >&2
    exit 2
  fi
done

GH_TOKEN_VALUE="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
if [ -z "$GH_TOKEN_VALUE" ]; then
  echo "tidy.sh: GITHUB_TOKEN or GH_TOKEN must be set (needs read:packages, and delete:packages to --apply)" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
AUDIT_SCRIPT="$SCRIPT_DIR/audit.sh"

if [ ! -f "$REPO_ROOT/buildargs.conf" ] || [ ! -f "$REPO_ROOT/docker-bake.hcl" ]; then
  echo "tidy.sh: expected buildargs.conf and docker-bake.hcl under $REPO_ROOT" >&2
  exit 2
fi

REGISTRY_ACCEPT="application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json"
GITHUB_ACCEPT="application/vnd.github+json"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/tidy.XXXXXX")"
if [ -n "${GITHUB_ACTIONS:-}" ]; then
  # Capture $? into a variable FIRST, before rm -rf (or anything else)
  # runs and overwrites it — see annotate_exit's own comment for why this
  # matters: without it, rc is always whatever `rm -rf` returned, not the
  # script's actual exit status.
  trap 'rc=$?; rm -rf "$WORKDIR"; annotate_exit "$rc"' EXIT
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
SAFETY_ABORT=0
RATIO_TRIPPED=0
PROTECTED_TAG_TRIPPED=0
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

# verify_package IMAGE [LABEL] -> writes "$WORKDIR/verify-<image>-<label>.json"
# (audit.sh's raw JSON array, one element). LABEL defaults to "current" and
# distinguishes independent calls for the same image within one run (e.g.
# a PRE-apply snapshot and a POST-apply snapshot must not clobber each
# other — see the regression-vs-pre-existing comparison below). Returns
# 0 clean, 1 broken tags found, 2 operational failure (including audit.sh
# missing).
verify_package() {
  local image="$1" label="${2:-current}"
  local out_json="$WORKDIR/verify-${image}-${label}.json"
  local stderr_file="$WORKDIR/verify-${image}-${label}.stderr"

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

# print_broken_tags IMAGE [LABEL] -> prints "    - <tag>" for every broken
# tag found by the verify_package call for IMAGE/LABEL (see verify_package).
print_broken_tags() {
  local image="$1" label="${2:-current}"
  jq -r '.[0].broken_tags[]? // empty' "$WORKDIR/verify-${image}-${label}.json" 2>/dev/null | while IFS= read -r t; do
    echo "    - ${image}:${t}"
  done
}

# broken_tags_list IMAGE [LABEL] -> one broken tag per line (no "image:"
# prefix, sorted, deduped) from the verify_package call for IMAGE/LABEL. Used
# to diff two snapshots of the same image (pre vs post) with comm(1).
broken_tags_list() {
  local image="$1" label="${2:-current}"
  jq -r '.[0].broken_tags[]? // empty' "$WORKDIR/verify-${image}-${label}.json" 2>/dev/null | sort -u
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

# classify_root PKG_PATH TOKEN ROOT_DIGEST -> only used when
# --delete-broken-roots is active, and only for a root that already failed
# to resolve fully in the main reachability pass. Independently re-resolves
# the root and each of its DIRECT children (resolve_manifest already
# retries-with-backoff before concluding a status, so a rate limit is never
# mistaken for 404) and prints one tab-separated line on stdout:
#
#   broken\t<dead-count>\t          every direct child confirmed 404 (dead
#                                   index — eligible for deletion)
#   partial\t<live>/<dead>\t        some children resolved, some 404 — NOT
#                                   broken (ambiguous; package stays
#                                   fail-closed for this root)
#   unknown\tSTATUS\tDIGEST         the root itself, or some child,
#                                   returned neither 200 nor 404 (rate
#                                   limit, 5xx, timeout, ...) — status
#                                   unknown; package stays fail-closed
#   flat\t\t                       root has no children at all (shouldn't
#                                   normally reach here, since a flat
#                                   manifest can't fail to resolve its
#                                   nonexistent children — treated as not
#                                   broken, out of caution)
classify_root() {
  local pkg_path="$1" token="$2" root_digest="$3"
  local children status

  if ! children=$(resolve_manifest "$pkg_path" "$token" "$root_digest"); then
    status=$(cat "$WORKDIR/resolve-last-status.txt" 2>/dev/null || echo "???")
    printf 'unknown\t%s\t%s\n' "$status" "$root_digest"
    return
  fi

  if [ -z "$children" ]; then
    printf 'flat\t\t\n'
    return
  fi

  local dead=0 live=0 c child_status
  while IFS= read -r c; do
    [ -z "$c" ] && continue
    if resolve_manifest "$pkg_path" "$token" "$c" >/dev/null 2>&1; then
      live=$((live + 1))
    else
      child_status=$(cat "$WORKDIR/resolve-last-status.txt" 2>/dev/null || echo "???")
      if [ "$child_status" = "404" ]; then
        dead=$((dead + 1))
      else
        printf 'unknown\t%s\t%s\n' "$child_status" "$c"
        return
      fi
    fi
  done <<< "$children"

  if [ "$live" -gt 0 ]; then
    printf 'partial\t%s/%s\t\n' "$live" "$dead"
  else
    printf 'broken\t%s\t\n' "$dead"
  fi
}

# plan_package IMAGE CLASS -> writes "$WORKDIR/plan-<image>.json" with the
# full per-package plan, and prints the summary line. Returns:
#   0 ok
#   2 operational failure (package skipped: version listing / token / fail-closed)
#   3 safety rail #1 tripped (bug detector; caller must abort the WHOLE run)
#   4 safety rail #4 tripped (delete-ratio), a GENUINE trip; this package
#     skipped, run continues, contributes to a non-zero exit
#   5 safety rail #2 tripped (protected tag in DELETE); this package skipped, run continues
#   6 safety rail #4 tripped but is EXPECTED STEADY STATE (never-tagged
#     orphan correctly protected from whole-package deletion, see M4);
#     this package skipped, run continues, does NOT contribute to a
#     non-zero exit
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

  # KEEP_ROOTS: see the --keep-all-tagged header comment for the two policies
  # below "in_bakefile". IN-BAKEFILE (class != orphan, i.e. the image's
  # target still exists in the current bakefile — a live image, or infra
  # like buildcache) uses the full policy: protected tag OR newest
  # --keep-last OR younger than --keep-days. ORPHAN (target removed from
  # the bakefile) uses --keep-days ALONE: no --keep-last floor (an orphan
  # gets no "keep the newest N regardless of age" grace), and — the
  # subtle part — no protected-tag floor either. $by_tag would otherwise
  # pin an orphan's `latest`/`alpine`/`debian` tag forever, so the package
  # would never fully decay even though nothing builds it anymore. An
  # orphan's tags are allowed to age out like everything else in it. This
  # is a POLICY-level use of the protected-tag regex; it is unrelated to
  # safety rail #2 below, which independently forbids a protected tag from
  # landing in DELETE for an in-bakefile package (see that rail's comment).
  local in_bakefile=1
  [ "$class" = "orphan" ] && in_bakefile=0

  local keep_roots_file="$WORKDIR/keeproots-${image}.txt"
  if [ "$KEEP_ALL_TAGGED" -eq 1 ]; then
    jq -r '.digest' "$roots_file" | sort -u > "$keep_roots_file"
  elif [ "$in_bakefile" -eq 0 ]; then
    jq -rs --argjson keepdays "$KEEP_DAYS" --argjson now "$NOW_EPOCH" '
      def age_days($rec): ($now - ($rec.created_at | fromdateiso8601)) / 86400;
      (. as $all | ($all | map(select(age_days(.) < $keepdays)) | map(.digest)) as $by_age | $by_age | unique | .[])
      ' "$roots_file" > "$keep_roots_file"
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

  # --- --delete-broken-roots: reclassify. Purely a post-processing pass
  # over failclosed_file (populated above exactly as without this flag) —
  # detection logic above is completely unmodified, so with the flag off
  # nothing below this point ever runs and behaviour is byte-for-byte
  # unchanged from before this feature existed.
  local broken_roots_file="$WORKDIR/brokenroots-${image}.jsonl"
  : > "$broken_roots_file"
  if [ "$DELETE_BROKEN_ROOTS" -eq 1 ] && [ -s "$failclosed_file" ]; then
    local fc_root class_result class_type broken_digests_file
    broken_digests_file="$WORKDIR/broken-digests-${image}.txt"
    : > "$broken_digests_file"
    while IFS= read -r fc_root; do
      [ -z "$fc_root" ] && continue
      class_result=$(classify_root "$pkg_path" "$token" "$fc_root")
      class_type="${class_result%%$'\t'*}"
      if [ "$class_type" = "broken" ]; then
        echo "$fc_root" >> "$broken_digests_file"
        local broken_tags_json
        broken_tags_json=$(jq -c --arg r "$fc_root" 'select(.root == $r) | .tags' "$failclosed_file" | head -1)
        [ -z "$broken_tags_json" ] && broken_tags_json="[]"
        jq -cn --arg root "$fc_root" --argjson tags "$broken_tags_json" \
          '{root: $root, tags: $tags}' >> "$broken_roots_file"
        # The root's OWN manifest resolves fine (it's the index doc itself
        # that's still present — only its children are gone), so the BFS
        # above already added it to reachable_file; undo that so it's
        # eligible to land in DELETE below instead (rail #1 requires
        # DELETE ∩ REACHABLE to stay empty).
        if [ -s "$reachable_file" ]; then
          grep -vxF "$fc_root" "$reachable_file" > "$reachable_file.tmp" 2>/dev/null || : > "$reachable_file.tmp"
          mv "$reachable_file.tmp" "$reachable_file"
        fi
      fi
    done < <(jq -r '.root' "$failclosed_file" | sort -u)

    if [ -s "$broken_digests_file" ]; then
      # Drop the now-explained entries from failclosed_file; any root NOT
      # confirmed broken (unknown status, or partial: some children still
      # live) stays in failclosed_file and keeps failing the package
      # closed, exactly as without this flag.
      jq -c --slurpfile broken <(jq -Rn '[inputs]' "$broken_digests_file") \
        'select((.root as $r | ($broken[0] | index($r))) == null)' "$failclosed_file" > "${failclosed_file}.tmp"
      mv "${failclosed_file}.tmp" "$failclosed_file"
      local broken_count
      broken_count=$(wc -l < "$broken_roots_file" | tr -d ' ')
      log_info "${pkg_name}: reclassified ${broken_count} keep-root(s) as broken (all direct children confirmed 404) via --delete-broken-roots"
    fi
  fi

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

  # --- Safety rail #2: no protected-tag version may appear in DELETE.
  # PER-PACKAGE skip (exit 3 overall, like rail #4 below), not a whole-run
  # abort: a set-arithmetic bug in one package's policy computation is not
  # evidence the other packages are miscomputed, and a whole-run abort here
  # let one bad package silently zero out an entire scheduled run,
  # indefinitely. Still loud — still a bug detector — just scoped to the
  # package it actually concerns.
  #
  # IN-BAKEFILE ONLY: this rail enforces that the policy above never
  # actually drops a protected tag for a live/infra package (a bug detector
  # for rail #2's own policy counterpart, $by_tag). For an orphan, dropping
  # $by_tag from the policy is deliberate (see the KEEP_ROOTS comment above)
  # so a protected tag landing in DELETE there is the intended outcome, not
  # a bug — the rail must not fire for orphans, or the decay design it
  # exists to protect would never trip and instead permanently deadlock.
  #
  # EXCLUDES confirmed-broken roots (--delete-broken-roots, see its header
  # comment): classify_root marks a root `broken` only after independently
  # confirming EVERY direct child returns 404, so any tag that root carries
  # is already dead in the registry (audit.sh already reports it unpullable,
  # independent of this script) — deleting it cannot break a working pull.
  # Without this exclusion, --delete-broken-roots (armed by default on the
  # schedule) and this rail deadlock every single night: nginx's 7 broken
  # roots / rover's 1 legitimately carry latest/alpine/debian, and this rail
  # would otherwise forbid removing exactly what the remediation exists to
  # remove.
  if [ "$in_bakefile" -eq 1 ]; then
    local broken_digests_json
    broken_digests_json=$(jq -Rn '[inputs]' <(jq -r '.root' "$broken_roots_file" 2>/dev/null))
    local protected_in_delete
    protected_in_delete=$(jq -c --argjson regexes "$tag_regex_json" --argjson broken "$broken_digests_json" '
      select((.tags // []) | any(. as $t | $regexes | any(. as $re | $t | test($re)))) |
      .digest as $d | select(($broken | index($d)) == null)' "$delete_file" | wc -l | tr -d ' ')
    if [ "$protected_in_delete" -gt 0 ]; then
      log_err "SAFETY RAIL #2 TRIPPED for ${pkg_name}: ${protected_in_delete} version(s) carrying a protected tag are in DELETE (not explained by a confirmed-broken root) — skipping this package (other packages still processed)"
      echo "${image}  ${class}  total=${total}  roots=${roots_total}  reachable=${reachable_count}  inflight=${inflight_count}  DELETE=${delete_count}  (SKIPPED: protected tag in DELETE — safety rail #2)"
      jq -n --arg image "$image" --arg pkg "$pkg_name" --arg class "$class" \
        --argjson total "$total" --argjson roots "$roots_total" --argjson keep_roots "$keep_roots_count" \
        --argjson reachable "$reachable_count" --argjson inflight "$inflight_count" --argjson delete_count "$delete_count" \
        '{image: $image, package: $pkg, class: $class, total: $total, roots: $roots, keep_roots: $keep_roots,
          reachable: $reachable, inflight: $inflight, delete_count: $delete_count,
          skipped: true, error: "protected tag in DELETE (safety rail #2)"}' \
        > "$WORKDIR/plan-${image}.json"
      return 5
    fi
  fi

  # --- Safety rail #4: DELETE must not exceed --max-delete-ratio, unless --force. Per-package skip. ---
  #
  # ORPHAN DECAY EXEMPTION: an orphan (target absent from the bakefile —
  # see the KEEP_ROOTS comment above) decaying to ~100% DELETE is this
  # design's intended terminal state, not a classification bug, so rail #4
  # must not permanently block it the way it blocks a live package that
  # suddenly wants everything deleted. The exemption requires ALL THREE:
  # class == orphan, zero versions younger than ORPHAN_STALE_DAYS
  # (staleness is the real discriminator, not the orphan label alone — a
  # LIVE image that got misclassified as orphan is still rebuilt daily and
  # therefore always has a version younger than ORPHAN_STALE_DAYS, so rail
  # #4 still stops it even under this exemption), AND roots_total > 0.
  #
  # THE roots_total > 0 REQUIREMENT (M4): a package that has NEVER carried
  # a tag is unreleased work-in-progress, not an abandoned published
  # image, and must never be whole-deleted by this exemption. Confirmed
  # live exposure: `runner` has 20 versions pushed by digest from a WIP
  # branch and ZERO tagged roots; its target isn't in the bakefile so it
  # classifies orphan, and with roots_total == 0 it would otherwise
  # qualify for whole-package deletion the moment that branch goes quiet
  # for ORPHAN_STALE_DAYS — unattended, with no human ever having approved
  # its removal. Every OTHER path to `orphan` requires a reviewed commit
  # that deleted `docker/<name>/`; the never-tagged case is the one path a
  # human never approved, which is exactly why it must not decay to zero
  # like a normal orphan. See the rail #4 trip below for what happens to
  # this case instead (reported, but does not redden the run).
  #
  # Never combined with --force's blanket override semantics — this is a
  # narrow, provable condition, not a bypass switch.
  local threshold_hit ratio_pct
  threshold_hit=$(awk -v d="$delete_count" -v t="$total" -v r="$MAX_DELETE_RATIO" 'BEGIN { print (t > 0 && d > r * t) ? 1 : 0 }')
  ratio_pct=$(awk -v d="$delete_count" -v t="$total" 'BEGIN { if (t > 0) printf "%.1f", (d / t) * 100; else print "0.0" }')

  local orphan_exempt=0
  local never_tagged_stale_orphan=0
  if [ "$threshold_hit" -eq 1 ] && [ "$class" = "orphan" ]; then
    local youngest_age_days
    youngest_age_days=$(jq -rs --argjson now "$NOW_EPOCH" '
      def age_days: ($now - (.created_at | fromdateiso8601)) / 86400;
      map(age_days) | min' "$versions_file")
    local is_stale
    is_stale=$(awk -v a="$youngest_age_days" -v d="$ORPHAN_STALE_DAYS" 'BEGIN { print (a >= d) ? 1 : 0 }')
    if [ "$is_stale" -eq 1 ]; then
      local youngest_age_fmt
      youngest_age_fmt=$(awk -v a="$youngest_age_days" 'BEGIN { printf "%.1f", a }')
      if [ "$roots_total" -gt 0 ]; then
        orphan_exempt=1
        log_warn "ORPHAN DECAY EXEMPTION: ${pkg_name} — ${total} version(s), newest is ${youngest_age_fmt} day(s) old (>= ${ORPHAN_STALE_DAYS}d staleness threshold, independent of --keep-days); exempting from --max-delete-ratio (${MAX_DELETE_RATIO}, this package is at ${ratio_pct}%) — this is a PERMANENT WHOLE-PACKAGE DELETION of ${delete_count}/${total} version(s)"
      else
        never_tagged_stale_orphan=1
        log_warn "NEVER-TAGGED ORPHAN PROTECTED: ${pkg_name} — ${total} version(s), ZERO tagged roots, newest is ${youngest_age_fmt} day(s) old (>= ${ORPHAN_STALE_DAYS}d) — NOT granted the orphan decay exemption and NOT whole-deleted, because a package that has never carried a tag is unreleased work-in-progress, not an abandoned published image (see M4/roots_total in the rail #4 comment above). This rail #4 trip is EXPECTED STEADY STATE, reported below, and does not redden the run."
      fi
    fi
  fi

  if [ "$threshold_hit" -eq 1 ] && [ "$FORCE" -ne 1 ] && [ "$orphan_exempt" -ne 1 ]; then
    if [ "$never_tagged_stale_orphan" -eq 1 ]; then
      # EXPECTED STEADY STATE, not a genuine trip: distinct return code (6)
      # so the caller can report this without contributing to a non-zero
      # exit — see Change 2. Any OTHER rail #4 trip (notably a LIVE
      # package exceeding the ratio) still uses return 4 below and still
      # reddens the run; this branch is deliberately narrow to that one
      # discriminator (class == orphan AND stale AND roots_total == 0),
      # not a blanket silence of rail #4.
      echo "${image}  ${class}  total=${total}  roots=${roots_total}  reachable=${reachable_count}  inflight=${inflight_count}  DELETE=${delete_count}  (PROTECTED: never-tagged orphan, exceeds --max-delete-ratio ${MAX_DELETE_RATIO} at ${ratio_pct}% — expected steady state, not an alarm)"
      jq -n --arg image "$image" --arg pkg "$pkg_name" --arg class "$class" \
        --argjson total "$total" --argjson roots "$roots_total" --argjson keep_roots "$keep_roots_count" \
        --argjson reachable "$reachable_count" --argjson inflight "$inflight_count" --argjson delete_count "$delete_count" \
        --arg ratio_pct "$ratio_pct" \
        '{image: $image, package: $pkg, class: $class, total: $total, roots: $roots, keep_roots: $keep_roots,
          reachable: $reachable, inflight: $inflight, delete_count: $delete_count, delete_ratio_pct: $ratio_pct,
          skipped: true, error: "never-tagged orphan protected from whole-package deletion (rail #4 expected steady state)"}' \
        > "$WORKDIR/plan-${image}.json"
      return 6
    fi
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

  local broken_roots_count
  broken_roots_count=$(wc -l < "$broken_roots_file" | tr -d ' ')

  if [ "$broken_roots_count" -gt 0 ]; then
    echo "${image}  ${class}  total=${total}  roots=${roots_total}  reachable=${reachable_count}  inflight=${inflight_count}  broken_roots=${broken_roots_count}  DELETE=${delete_count}"
  else
    echo "${image}  ${class}  total=${total}  roots=${roots_total}  reachable=${reachable_count}  inflight=${inflight_count}  DELETE=${delete_count}"
  fi

  jq -n --arg image "$image" --arg pkg "$pkg_name" --arg class "$class" \
    --argjson total "$total" --argjson roots "$roots_total" --argjson keep_roots "$keep_roots_count" \
    --argjson reachable "$reachable_count" --argjson inflight "$inflight_count" \
    --slurpfile delete_items "$delete_file" --slurpfile broken_root_items "$broken_roots_file" \
    '{image: $image, package: $pkg, class: $class, total: $total, roots: $roots,
      keep_roots: $keep_roots, reachable: $reachable, inflight: $inflight,
      delete: $delete_items, delete_count: ($delete_items | length),
      broken_roots: $broken_root_items, broken_roots_count: ($broken_root_items | length)}' \
    > "$WORKDIR/plan-${image}.json"

  return 0
}

# bash_array_to_json_array ELEM... -> prints a JSON array of the given
# arguments (each on its own line via printf, so no delimiter-splitting
# surprises), or "[]" for zero arguments. Used to embed bash-side tracking
# arrays (APPLIED_PACKAGES, EMPTIED_PACKAGES, ...) into write_plan_json's
# output.
bash_array_to_json_array() {
  if [ "$#" -eq 0 ]; then
    printf '[]'
    return
  fi
  printf '%s\n' "$@" | jq -Rn '[inputs]'
}

# write_plan_json [--final] -> writes (or rewrites) $JSON_OUT from the
# per-package plan-<image>.json files currently in $WORKDIR. No-op if
# --json/JSON_OUT was not requested.
#
# M5: called TWICE, not once. The first call happens right after planning
# completes and BEFORE the apply phase begins (see Main below) — so if the
# job is killed mid-apply (timeout-minutes, a runner drop, an unhandled
# bash error), a forensic record of what was PLANNED already exists on
# disk; up to --budget PERMANENT deletions must never happen with zero
# trace of what was destroyed. Without this, `actions/upload-artifact`'s
# default `if-no-files-found: warn` uploads nothing and does not fail the
# job either — a silent, total loss of the record. With --apply, a SECOND
# call after the apply phase completes rewrites the same file with a
# `phase: "final"` marker and an `outcome` object (actual_deleted,
# remaining, delete_failures, and which packages were applied/emptied/
# regressed/pre-existing-corrupt) — a partial or interrupted apply still
# leaves the pre-apply version as the most recent successfully-written
# state, upgraded to the full outcome only once apply genuinely finishes.
# Without --apply (a dry run), only the first call ever happens, producing
# exactly the same single write dry runs have always produced — no
# regression there.
#
# ATOMIC REWRITE: always written to a temp file in $JSON_OUT's own
# directory first, then `mv`'d into place. `mv` within one filesystem is
# atomic, so a crash mid-write leaves either the complete new file or the
# untouched PREVIOUS version — never a truncated/corrupt one clobbering a
# good record.
write_plan_json() {
  local phase="${1:-}"
  [ -z "$JSON_OUT" ] && return 0

  # Packages go through a FILE (--slurpfile), never a command-line argument
  # (--argjson from a bash variable): a full run's packages array is
  # routinely several hundred KB (17 packages, tens of thousands of
  # versions) and Linux caps a single argv string at ~128KB
  # (MAX_ARG_STRLEN). Passing it via --argjson silently hits "Argument
  # list too long" (exit 126) — found live while validating this change: a
  # full-scale dry run produced a 0-byte tidy-plan.json with a false "wrote
  # plan" success log, because the shell's `> "$tmp_out"` redirection still
  # creates/truncates the file even though jq itself never executed. Do
  # NOT go back to --argjson for packages.
  local plan_files=("$WORKDIR"/plan-*.json)
  local packages_file="$WORKDIR/packages-for-json-out.json"
  if [ -e "${plan_files[0]}" ]; then
    jq -s . "${plan_files[@]}" > "$packages_file"
  else
    echo '[]' > "$packages_file"
  fi

  local tmp_out
  tmp_out=$(mktemp "$(dirname -- "$JSON_OUT")/.tidy-plan.XXXXXX" 2>/dev/null) || tmp_out="$WORKDIR/json-out-tmp.$$"

  local jq_rc
  if [ "$phase" = "--final" ]; then
    jq -n --argjson budget "$BUDGET" --argjson apply "$([ "$APPLY" -eq 1 ] && echo true || echo false)" \
      --argjson max_delete_ratio "$MAX_DELETE_RATIO" --slurpfile packages "$packages_file" \
      --argjson actual_deleted "$ACTUAL_DELETED" --argjson remaining "$REMAINING" \
      --argjson delete_failures "$DELETE_FAILURES" \
      --argjson applied_packages "$(bash_array_to_json_array "${APPLIED_PACKAGES[@]}")" \
      --argjson emptied_packages "$(bash_array_to_json_array "${EMPTIED_PACKAGES[@]}")" \
      --argjson regression_packages "$(bash_array_to_json_array "${REGRESSION_PACKAGES[@]}")" \
      --argjson preexisting_corruption_packages "$(bash_array_to_json_array "${PREEXISTING_CORRUPTION_PACKAGES[@]}")" \
      '{phase: "final", budget: $budget, apply: $apply, max_delete_ratio: $max_delete_ratio,
        packages: $packages[0],
        outcome: {actual_deleted: $actual_deleted, remaining: $remaining,
          delete_failures: $delete_failures, applied_packages: $applied_packages,
          emptied_packages: $emptied_packages, regression_packages: $regression_packages,
          preexisting_corruption_packages: $preexisting_corruption_packages}}' \
      > "$tmp_out"
    jq_rc=$?
  else
    jq -n --argjson budget "$BUDGET" --argjson apply "$([ "$APPLY" -eq 1 ] && echo true || echo false)" \
      --argjson max_delete_ratio "$MAX_DELETE_RATIO" --slurpfile packages "$packages_file" \
      '{phase: "pre-apply", budget: $budget, apply: $apply, max_delete_ratio: $max_delete_ratio,
        packages: $packages[0]}' \
      > "$tmp_out"
    jq_rc=$?
  fi

  # Only move the temp file into place if it was actually built successfully
  # and is non-empty: this is what makes the atomic rewrite meaningful on a
  # jq failure too, not just an OS-level crash mid-write — an unconditional
  # mv here is exactly what turned today's argv-length jq failure into a
  # SILENT empty-file clobber of a real previous plan (see the comment
  # above). A previous good $JSON_OUT (e.g. the pre-apply write) is left
  # untouched on failure rather than being overwritten with garbage.
  if [ "$jq_rc" -ne 0 ] || [ ! -s "$tmp_out" ]; then
    log_err "failed to build plan JSON (jq exit ${jq_rc}); leaving any existing ${JSON_OUT} untouched rather than overwriting it with a broken/empty file"
    rm -f "$tmp_out"
    return 1
  fi

  mv -f -- "$tmp_out" "$JSON_OUT"
  local phase_label="pre-apply"
  [ "$phase" = "--final" ] && phase_label="final"
  log_info "wrote plan (${phase_label}) to ${JSON_OUT}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

log_info "discovering packages linked to ${OWNER}/${REPO} with prefix ${REPO_PREFIX}/ ..."
if ! list_packages; then
  report_enum_failure "$LAST_API_STATUS"
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

# Cross-check: the bakefile-discovered live-image set MUST equal the set of
# image directories under docker/*/ (verified equal on the current tree:
# agent all-in-one base golang nginx python rover static typescript).
# Bakefile membership now decides whether a package keeps ANYTHING at all
# (see the KEEP_ROOTS comment in plan_package), so a discovery call that
# runs but returns a truncated/partial/stale target list is far more
# dangerous than before — every image missing from that list would be
# misclassified as orphan and have its --keep-last/protected-tag floors
# silently dropped. This is strictly stronger than a fixed sentinel list
# and self-maintaining: a new image directory is automatically covered
# without anyone remembering to update a list. Any divergence means one of
# the two independent sources is broken/stale, and this aborts the whole
# run (exit 2) rather than guess which one to trust.
#
# NON-IMAGE EXCLUSIONS: none today. If docker/ ever grows a subdirectory
# that is legitimately not an image (e.g. shared scripting, not itself a
# bake target), add its name here explicitly with a comment saying why —
# do NOT loosen this to a subset/fuzzy comparison; set equality is the
# point.
DOCKER_DIR_EXCLUDES=()  # e.g. DOCKER_DIR_EXCLUDES=(shared-scripts)

IMAGE_DIRS_FILE="$WORKDIR/image-dirs.txt"
: > "$IMAGE_DIRS_FILE"
for d in "$REPO_ROOT"/docker/*/; do
  [ -d "$d" ] || continue
  dirname_only="$(basename "$d")"
  excluded=0
  for ex in "${DOCKER_DIR_EXCLUDES[@]:-}"; do
    [ "$dirname_only" = "$ex" ] && excluded=1 && break
  done
  [ "$excluded" -eq 1 ] && continue
  echo "$dirname_only"
done | sort -u > "$IMAGE_DIRS_FILE"

LIVE_SORTED_FILE="$WORKDIR/live-images-sorted.txt"
sort -u "$LIVE_IMAGES_FILE" > "$LIVE_SORTED_FILE"

ONLY_IN_BAKE_FILE="$WORKDIR/only-in-bake.txt"
ONLY_IN_DIRS_FILE="$WORKDIR/only-in-dirs.txt"
comm -23 "$LIVE_SORTED_FILE" "$IMAGE_DIRS_FILE" > "$ONLY_IN_BAKE_FILE"
comm -13 "$LIVE_SORTED_FILE" "$IMAGE_DIRS_FILE" > "$ONLY_IN_DIRS_FILE"

if [ -s "$ONLY_IN_BAKE_FILE" ] || [ -s "$ONLY_IN_DIRS_FILE" ]; then
  log_err "bakefile-discovered live-image set does not equal the docker/*/ image directories; refusing to trust either (would misclassify live/orphan packages)"
  if [ -s "$ONLY_IN_BAKE_FILE" ]; then
    log_err "  only in bakefile output, not in docker/*/: $(tr '\n' ' ' < "$ONLY_IN_BAKE_FILE")"
  fi
  if [ -s "$ONLY_IN_DIRS_FILE" ]; then
    log_err "  only in docker/*/, not in bakefile output: $(tr '\n' ' ' < "$ONLY_IN_DIRS_FILE")"
  fi
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
  echo "NOTE: --verify-only takes no pre-run snapshot (it deletes nothing), so it has no"
  echo "'before' to diff against. Any broken tag found is therefore reported as PRE-EXISTING"
  echo "corruption, never as a regression — this run cannot have caused it. To distinguish a"
  echo "genuine regression from pre-existing corruption, use --apply, whose post-apply"
  echo "verification compares against a snapshot taken immediately before that run's deletions."
  verify_any_broken=0
  verify_any_opfail=0
  while IFS=$'\t' read -r image class; do
    [ -z "$image" ] && continue
    verify_package "$image" "known"
    vrc=$?
    case "$vrc" in
      0) echo "${image}  ${class}  VERIFY OK (all tags intact)" ;;
      1)
        verify_any_broken=$((verify_any_broken + 1))
        echo "${image}  ${class}  VERIFY FOUND PRE-EXISTING broken tags (not a regression — nothing ran):"
        print_broken_tags "$image" "known"
        ;;
      2)
        verify_any_opfail=1
        echo "${image}  ${class}  VERIFY UNKNOWN (operational failure, see stderr above)"
        ;;
    esac
  done < "$WORKLIST_FILE"

  if [ -n "$JSON_OUT" ]; then
    verify_files=("$WORKDIR"/verify-*-known.json)
    if [ -e "${verify_files[0]}" ]; then
      jq -s '. | flatten' "${verify_files[@]}" > "$JSON_OUT"
    else
      echo "[]" > "$JSON_OUT"
    fi
    log_info "wrote verification results to ${JSON_OUT}"
  fi

  if [ "$verify_any_broken" -eq 1 ]; then
    echo ""
    echo "=== ${verify_any_broken} package(s) above have known pre-existing broken tags — see runbook / --delete-broken-roots to remediate ==="
  fi

  # Pre-existing corruption found by --verify-only is reported above but is
  # NOT a regression (this run performed no deletions to have caused one),
  # so it does not trip exit 3 — see the exit-code table in the header.
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
ACTUAL_DELETED=0
SKIPPED_PACKAGES=()
RATIO_TRIPPED_PACKAGES=()
PROTECTED_TAG_PACKAGES=()
NEVER_TAGGED_PROTECTED_PACKAGES=()
FAILCLOSED_PACKAGES=()
PROCESSED_PACKAGES=()
BROKEN_ROOTS_PACKAGES=()

while IFS=$'\t' read -r image class; do
  [ -z "$image" ] && continue

  plan_package "$image" "$class"
  rc=$?
  case "$rc" in
    0)
      PROCESSED_PACKAGES+=("$image")
      dc=$(jq -r '.delete_count' "$WORKDIR/plan-${image}.json")
      TOTAL_DELETE=$((TOTAL_DELETE + dc))
      TOTAL_PLANNED=$((TOTAL_PLANNED + 1))
      if [ "$DELETE_BROKEN_ROOTS" -eq 1 ] && jq -e '(.broken_roots_count // 0) > 0' "$WORKDIR/plan-${image}.json" >/dev/null 2>&1; then
        BROKEN_ROOTS_PACKAGES+=("$image")
      fi
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
    5)
      PROTECTED_TAG_PACKAGES+=("$image")
      PROTECTED_TAG_TRIPPED=1
      ;;
    6)
      # EXPECTED STEADY STATE (never-tagged orphan protected from whole-
      # package deletion — see M4/Change 1&2). Deliberately does NOT set
      # any *_TRIPPED flag: this is rail #4 doing exactly its job, not a
      # signal, so it must not contribute to a non-zero exit.
      NEVER_TAGGED_PROTECTED_PACKAGES+=("$image")
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

# M5: write the plan NOW, before the apply phase begins — see
# write_plan_json's own header comment for the full rationale. This call
# happens unconditionally (dry run or --apply), so a dry run's JSON output
# is unchanged: it is written here and, since the Apply section below is a
# no-op without --apply, this is also the LAST write in that case.
write_plan_json

# ---------------------------------------------------------------------------
# Apply (only with --apply) + post-apply verification
# ---------------------------------------------------------------------------

EFFECTIVE_DELETE=$TOTAL_DELETE
if [ "$EFFECTIVE_DELETE" -gt "$BUDGET" ]; then
  EFFECTIVE_DELETE=$BUDGET
fi
REMAINING=$((TOTAL_DELETE - EFFECTIVE_DELETE))

APPLIED_PACKAGES=()
REGRESSION_PACKAGES=()
PREEXISTING_CORRUPTION_PACKAGES=()
EMPTIED_PACKAGES=()

if [ "$APPLY" -eq 1 ]; then
  BUDGET_LEFT=$BUDGET
  for image in "${PROCESSED_PACKAGES[@]}"; do
    [ "$BUDGET_LEFT" -le 0 ] && break
    pkg_name="${REPO_PREFIX}/${image}"
    enc=$(jq -rn --arg s "$pkg_name" '$s|@uri')
    delete_count=$(jq -r '.delete_count' "$WORKDIR/plan-${image}.json")
    pkg_total=$(jq -r '.total' "$WORKDIR/plan-${image}.json")
    [ "$delete_count" -eq 0 ] && continue

    # Snapshot this package's broken-tag state BEFORE its deletions run, so
    # post-apply verification can tell a genuine regression (healthy here,
    # broken after) apart from pre-existing corruption this run didn't
    # cause and simply hasn't reached yet (see the header comment).
    verify_package "$image" "pre"
    pre_rc=$?
    if [ "$pre_rc" -eq 2 ]; then
      : > "$WORKDIR/pre-unknown-${image}"
      log_warn "could not capture pre-apply state for ${image}; post-apply regression detection for it will fail loud (treat all broken tags as regressions) rather than silently miss one"
    fi

    # Real assertion (the "| head -n $delete_count" this replaced was a
    # no-op: delete_count IS .delete's length by definition — see
    # plan_package — so it silently bounded nothing). If the plan file
    # ever disagreed with its own delete_count, refuse to apply against it
    # for this package rather than trusting a corrupted plan.
    plan_delete_len=$(jq -r '.delete | length' "$WORKDIR/plan-${image}.json")
    if [ "$plan_delete_len" -ne "$delete_count" ]; then
      log_err "BUG: ${pkg_name} plan .delete array length (${plan_delete_len}) does not match .delete_count (${delete_count}); refusing to apply against a corrupted plan for this package"
      DELETE_FAILURES=$((DELETE_FAILURES + 1))
      continue
    fi

    package_deleted=0
    package_success_count=0
    # Delete TAGGED roots before their UNTAGGED children within this
    # package's DELETE set. Packages-API order between them is otherwise
    # arbitrary (they're typically created seconds apart by the same
    # build), and deleting a child before the index that references it
    # makes the still-tagged root unpullable for real users until the
    # budget reaches it — possibly days later, since REMAINING carries
    # across runs — and makes audit.sh see a tag broken now that its "pre"
    # snapshot saw healthy, i.e. a REGRESSION false-positive for an
    # entirely correct on-plan deletion. Removing the tagged root first
    # removes the tag itself, so no broken tag is ever exposed either way,
    # and an interrupted run leaves only untagged garbage behind for the
    # next run to reclaim instead of a broken published tag.
    # `sort_by((.tags | length) == 0)` sorts false (tagged) before true
    # (untagged) — verified: `sort_by(false)` prints before `sort_by(true)`
    # in jq's ascending sort, so tagged entries come first.
    # M5: log every SUCCESSFUL deletion too, not only failures — terse, one
    # line, unconditional (no verbosity flag to forget to pass), so the run
    # log itself is a usable forensic record of what was destroyed when the
    # JSON is missing or truncated (e.g. the job was killed by
    # timeout-minutes mid-apply). digest travels alongside id (tab-
    # separated) purely for this log line; it does not change the delete
    # ordering established above.
    while IFS=$'\t' read -r id digest; do
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
        package_success_count=$((package_success_count + 1))
        ACTUAL_DELETED=$((ACTUAL_DELETED + 1))
        log_info "DELETED ${pkg_name} ${digest}"
      fi
      BUDGET_LEFT=$((BUDGET_LEFT - 1))
      sleep 1
    done < <(jq -r '.delete | sort_by((.tags | length) == 0) | .[] | [.id, .digest] | @tsv' "$WORKDIR/plan-${image}.json")

    if [ "$package_deleted" -eq 1 ]; then
      APPLIED_PACKAGES+=("$image")

      # Empty-package sweep — a permanent, unrecoverable deletion, so it
      # requires ALL THREE of the following, not just the re-query. The
      # re-query alone is not enough on its own terms: audit.sh's header in
      # this repo documents `api.github.com/orgs/.../versions` as a
      # SECONDARY INDEX THAT GOES STALE, i.e. a written finding that this
      # exact endpoint can lie — so it is the LAST condition, never the
      # only one.
      #   1. delete_count == total: the PLAN intended to empty this
      #      package (not merely delete some fraction of it).
      #   2. package_success_count == delete_count: every planned deletion
      #      for THIS RUN actually succeeded — no budget cutoff mid-
      #      package, no individual delete failure. This is a real
      #      per-package counter, not the old package_deleted 0/1 flag
      #      (which only proved "at least one delete succeeded", far too
      #      weak a basis for whole-package deletion).
      #   3. the re-query returns zero versions — the registry, the only
      #      authority, confirms emptiness. Never inferred from local
      #      bookkeeping alone (the same class of mistake as a deletion
      #      counter that reads zero while reporting success).
      # Any one of these failing correctly leaves the package for a future
      # run: a budget cutoff or an individual failure fails condition 2
      # before the re-query ever runs; a stale-index false negative from
      # the re-query fails condition 3.
      #
      # STRUCTURAL PROPERTY, deliberate, not an accident: `d > 0.98*t` is
      # true for every `d == t` with `t > 0`, so a 100%-of-total plan
      # ALWAYS trips rail #4 in plan_package. That means this sweep is only
      # ever REACHABLE for a package that was explicitly let through rail
      # #4 — via the orphan decay exemption, or --force — never as a side
      # effect of an ordinary prune. The two rails compose on purpose.
      if [ "$delete_count" -eq "$pkg_total" ] && [ "$package_success_count" -eq "$delete_count" ]; then
        remaining_versions_file="$WORKDIR/remaining-${image}.jsonl"
        if list_versions "$pkg_name" "$remaining_versions_file"; then
          remaining_count=$(wc -l < "$remaining_versions_file" | tr -d ' ')
          if [ "$remaining_count" -eq 0 ]; then
            log_warn "PACKAGE EMPTY: ${pkg_name} has zero versions remaining (re-queried from the registry after this run's deletions, not inferred from the plan) — deleting the package itself"
            pkg_del_status=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE \
              -H "Authorization: Bearer ${GH_TOKEN_VALUE}" \
              -H "Accept: ${GITHUB_ACCEPT}" \
              "https://api.github.com/orgs/${OWNER}/packages/container/${enc}")
            case "$pkg_del_status" in
              204|200)
                # We do not yet know, from observation, whether GHCR
                # auto-removes a container package when its last version is
                # deleted or leaves an empty shell behind. This branch IS
                # that observation: the shell was still there, and this
                # explicit call is what removed it. Logged distinctly on
                # purpose — this is what tells us the real behaviour.
                log_warn "PACKAGE DELETED: ${pkg_name} — package-delete endpoint returned ${pkg_del_status}. OBSERVED: GHCR left an empty package shell after the last version was removed; this run's explicit package-delete call is what removed it."
                EMPTIED_PACKAGES+=("$image")
                ;;
              404)
                # The other branch: GHCR already auto-removed the container
                # package as soon as its last version went away, so this
                # call found nothing to delete. Treated as success, not an
                # error.
                log_warn "PACKAGE ALREADY GONE: ${pkg_name} — package-delete endpoint returned 404. OBSERVED: GHCR auto-removed the container package when its last version was deleted; no explicit delete was needed (treated as success)."
                EMPTIED_PACKAGES+=("$image")
                ;;
              *)
                log_warn "failed to delete empty package ${pkg_name} (status ${pkg_del_status}); it is genuinely empty and will be retried on a future run"
                ;;
            esac
          fi
        else
          log_warn "could not re-query ${pkg_name} after deletion to check for emptiness; skipping the empty-package sweep for it this run (will be re-checked next run)"
        fi
      else
        log_info "${pkg_name}: skipping empty-package sweep — plan not 100%-of-total (${delete_count}/${pkg_total}) or this run's deletions didn't all succeed (${package_success_count}/${delete_count}); leaving for a future run"
      fi
    fi
  done
  # REMAINING = versions still needing deletion = TOTAL_DELETE minus the
  # deletions that actually SUCCEEDED (ACTUAL_DELETED). A failed DELETE call
  # leaves that version in the registry, so it must still count toward
  # REMAINING even though budget was spent attempting it.
  REMAINING=$((TOTAL_DELETE - ACTUAL_DELETED))

  if [ "${#APPLIED_PACKAGES[@]}" -gt 0 ]; then
    echo "=== POST-APPLY VERIFICATION: re-resolving kept tags via audit.sh (compared against the pre-apply state captured above, per-package) ==="
    for image in "${APPLIED_PACKAGES[@]}"; do
      verify_package "$image" "post"
      vrc=$?
      case "$vrc" in
        0) log_info "post-apply verify OK: ${image}" ;;
        1)
          post_tags_file="$WORKDIR/broken-post-${image}.txt"
          pre_tags_file="$WORKDIR/broken-pre-${image}.txt"
          broken_tags_list "$image" "post" > "$post_tags_file"
          if [ -f "$WORKDIR/pre-unknown-${image}" ]; then
            log_warn "pre-apply state for ${image} could not be captured; treating every broken tag found now as a potential regression"
            : > "$pre_tags_file"
          else
            broken_tags_list "$image" "pre" > "$pre_tags_file"
          fi
          regression_tags_file="$WORKDIR/regression-${image}.txt"
          preexisting_tags_file="$WORKDIR/preexisting-${image}.txt"
          comm -23 "$post_tags_file" "$pre_tags_file" > "$regression_tags_file"
          comm -12 "$post_tags_file" "$pre_tags_file" > "$preexisting_tags_file"

          if [ -s "$regression_tags_file" ]; then
            VERIFY_REGRESSION=1
            REGRESSION_PACKAGES+=("$image")
            log_err "POST-APPLY REGRESSION in ${image}: a tag that was healthy before this run is now broken"
            while IFS= read -r t; do
              [ -z "$t" ] && continue
              echo "    - ${image}:${t}" >&2
            done < "$regression_tags_file"
          fi
          if [ -s "$preexisting_tags_file" ]; then
            PREEXISTING_CORRUPTION_PACKAGES+=("$image")
            preexisting_count=$(wc -l < "$preexisting_tags_file" | tr -d ' ')
            log_warn "${image}: ${preexisting_count} known pre-existing broken tag(s) remain (not caused by this run; will clear once the budget reaches their broken root)"
          fi
          ;;
        2) OPERATIONAL_FAILURE=1 ;;
      esac
    done
  fi

  # M5: rewrite the plan now that the apply phase (including post-apply
  # verification) has actually finished, with the real OUTCOME — what was
  # attempted, what succeeded, what failed, what remains under budget,
  # which packages were emptied. Only reached if the apply phase ran to
  # completion; a mid-apply kill leaves the pre-apply write from before
  # the Apply section (above) as the most recent record, which is exactly
  # the point — see write_plan_json's header comment.
  write_plan_json --final
fi

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

echo "---"
if [ "$APPLY" -eq 1 ]; then
  echo "deleted ${ACTUAL_DELETED} of ${TOTAL_DELETE} planned versions across ${TOTAL_PLANNED} package(s) (budget ${BUDGET}, ${REMAINING} remaining, ${DELETE_FAILURES} failures)"
else
  echo "DRY RUN: would delete ${EFFECTIVE_DELETE} of ${TOTAL_DELETE} planned versions across ${TOTAL_PLANNED} package(s) (budget ${BUDGET}, ${REMAINING} remaining)"
fi

# Empty-package sweep, dry-run preview: a package whose entire version count
# is planned for deletion would be left empty by --apply's real re-query
# sweep above. Nothing is called here — this is purely a report, computed
# from the plan already in hand.
if [ "$APPLY" -ne 1 ]; then
  EMPTY_CANDIDATES=()
  for image in "${PROCESSED_PACKAGES[@]}"; do
    tot=$(jq -r '.total' "$WORKDIR/plan-${image}.json")
    dc=$(jq -r '.delete_count' "$WORKDIR/plan-${image}.json")
    if [ "$tot" -gt 0 ] && [ "$dc" -eq "$tot" ]; then
      EMPTY_CANDIDATES+=("$image")
    fi
  done
  if [ "${#EMPTY_CANDIDATES[@]}" -gt 0 ]; then
    echo ""
    echo "=== EMPTY-PACKAGE SWEEP (dry run — nothing called) ==="
    for image in "${EMPTY_CANDIDATES[@]}"; do
      tot=$(jq -r '.total' "$WORKDIR/plan-${image}.json")
      echo "would delete package ${REPO_PREFIX}/${image} (${tot} versions, all planned for deletion)"
    done
  fi
fi

if [ "${#EMPTIED_PACKAGES[@]}" -gt 0 ]; then
  echo ""
  echo "=== PACKAGES DELETED (emptied by this run's deletions — see the PACKAGE DELETED / PACKAGE ALREADY GONE WARN lines above for which branch GHCR actually took) ==="
  for image in "${EMPTIED_PACKAGES[@]}"; do
    echo "  ${REPO_PREFIX}/${image}"
  done
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

if [ "${#PROTECTED_TAG_PACKAGES[@]}" -gt 0 ]; then
  echo ""
  echo "=== SAFETY RAIL #2 TRIPPED — skipped, not touched (bug in this package's set arithmetic, or an unexplained protected tag in DELETE; other packages were still processed) ==="
  for image in "${PROTECTED_TAG_PACKAGES[@]}"; do
    dc=$(jq -r '.delete_count' "$WORKDIR/plan-${image}.json")
    tot=$(jq -r '.total' "$WORKDIR/plan-${image}.json")
    echo "  ${image}: DELETE ${dc}/${tot} — see the SAFETY RAIL #2 TRIPPED ERROR line above for the count"
  done
fi

if [ "${#NEVER_TAGGED_PROTECTED_PACKAGES[@]}" -gt 0 ]; then
  echo ""
  echo "=== EXPECTED STEADY STATE — never-tagged orphan(s) correctly protected from whole-package deletion (NOT an alarm, does not affect the exit code) ==="
  echo "Each package below is class=orphan, stale (no version younger than ${ORPHAN_STALE_DAYS} days), and has"
  echo "ZERO tagged roots. It trips --max-delete-ratio like any other ~100% orphan, but is"
  echo "deliberately denied the orphan decay exemption (see M4): a package that has never"
  echo "carried a tag is unreleased work-in-progress pushed by digest from a branch, not an"
  echo "abandoned published image, and this run correctly refuses to whole-delete it."
  for image in "${NEVER_TAGGED_PROTECTED_PACKAGES[@]}"; do
    dc=$(jq -r '.delete_count' "$WORKDIR/plan-${image}.json")
    tot=$(jq -r '.total' "$WORKDIR/plan-${image}.json")
    ratio_pct=$(jq -r '.delete_ratio_pct' "$WORKDIR/plan-${image}.json")
    echo "  ${image}: DELETE ${dc}/${tot} = ${ratio_pct}% — protected, not touched"
  done
fi

if [ "${#BROKEN_ROOTS_PACKAGES[@]}" -gt 0 ]; then
  echo ""
  echo "=== BROKEN ROOTS (--delete-broken-roots) — dead indexes added to the delete plan ==="
  echo "Every direct child of each root below was independently confirmed 404 (genuinely"
  echo "gone, not merely unresolved — see classify_root). These are index versions left"
  echo "over from pre-existing registry corruption; deleting them is what allows the rest"
  echo "of the package to be pruned instead of failing closed. Subject to every existing"
  echo "safety rail (#1/#2/#4, the budget) just like the rest of the delete plan."
  for image in "${BROKEN_ROOTS_PACKAGES[@]}"; do
    echo "  ${image}:"
    jq -r '.broken_roots[] | "    " + .root + "  tags: " + ((.tags // []) | join(", "))' \
      "$WORKDIR/plan-${image}.json"
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

if [ "${#PREEXISTING_CORRUPTION_PACKAGES[@]}" -gt 0 ]; then
  echo ""
  echo "=== KNOWN PRE-EXISTING CORRUPTION REMAINING (not caused by this run) ==="
  echo "These tags were already broken before this run's deletions and are still broken;"
  echo "their versions simply haven't been reached by this run's --budget yet. Not a"
  echo "regression, not fatal — will clear once a future run's budget deletes their dead"
  echo "root (see --delete-broken-roots)."
  for image in "${PREEXISTING_CORRUPTION_PACKAGES[@]}"; do
    echo "  ${image}:"
    while IFS= read -r t; do
      [ -z "$t" ] && continue
      echo "    - ${image}:${t}"
    done < "$WORKDIR/preexisting-${image}.txt"
  done
fi

if [ "$VERIFY_REGRESSION" -eq 1 ]; then
  echo ""
  echo "=== POST-APPLY REGRESSION DETECTED in: ${REGRESSION_PACKAGES[*]} — see ERROR lines above for broken tags ==="
fi

# M5: the plan JSON was already written by write_plan_json above — once
# pre-apply (unconditionally, before the Apply section) and, with --apply,
# rewritten --final after it completes. No third write here; see
# write_plan_json's header comment for why the write happens where it does.

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
if [ "$PROTECTED_TAG_TRIPPED" -eq 1 ]; then
  exit 3
fi
if [ "$APPLY" -eq 1 ] && [ "$DELETE_FAILURES" -gt 0 ]; then
  exit 1
fi
if [ "$OPERATIONAL_FAILURE" -eq 1 ]; then
  exit 2
fi
exit 0
