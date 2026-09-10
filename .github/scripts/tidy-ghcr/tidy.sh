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
# THE MODEL THIS SCRIPT IMPLEMENTS INSTEAD (two phases, ONE POLICY for every
# package regardless of class — see RETIREMENT below for the one thing that
# IS class-dependent):
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
# RETIREMENT is a separate, PACKAGE-LEVEL decision made BEFORE any of the
# above ever runs, not a side effect of pruning: if a package's class is
# `orphan` (target removed from the bakefile — see PACKAGE ENUMERATION
# below) AND it has no version younger than $ORPHAN_STALE_DAYS days
# (deliberately its own constant, not tied to --keep-days — see its
# definition below), the ENTIRE package is removed with one
# `DELETE /orgs/{owner}/packages/container/{name}` call (delete_package_call
# — the same helper --delete-package uses) and NO version-level plan is
# computed for it at all. THIS REPLACES THE OLD DESIGN of pruning an
# orphan's versions down to zero and then re-querying for emptiness: CI
# proved (2026-09, see PR #262) that DELETE on the package itself returns
# 204 even while versions still exist — the earlier HTTP 400 seen deleting a
# VERSION was specific to that endpoint refusing to remove a package's LAST
# remaining version, not a download-count restriction — so whole-package
# removal is one reliable API call and the empty-then-sweep machinery that
# used to require is gone. This is PERMANENT AND IRREVERSIBLE, logged
# distinctly from ordinary per-version deletions. In dry-run nothing is
# called; the per-package planning line says RETIRE and the WOULD RETIRE
# section previews it.
#
# This correctly degenerates for flat-manifest packages: `buildcache`'s
# tagged versions are plain `application/vnd.oci.image.manifest.v1+json`
# manifests with zero children, so CHILDREN is empty, REACHABLE is exactly
# the tagged set, and DELETE is everything else. No special case needed.
#
# retain(d) (phase 1, --keep-all-tagged off — the default, right for
# published images): true if d carries a tag matching --keep-tag-regex, OR
# d is among the newest --keep-last roots, OR d is younger than --keep-days.
# IDENTICAL for live, infra, and orphan packages — an orphan that reaches
# this point already failed the RETIREMENT staleness check above (it has a
# version younger than $ORPHAN_STALE_DAYS), so from here on it is pruned
# exactly like a live package, never by a separate weaker rule.
#
# The protected-tag term ($by_tag below) is DIGEST-scoped, not tag-scoped,
# which is what makes "never delete latest, or whatever shares its sha"
# free: a tag is an alias for a digest, so protecting the digest `latest`
# currently points at protects every OTHER alias sharing that same digest
# too (e.g. rover's single tagged version currently carries `0`, `0.41`,
# `0.41.0` AND `latest` — one digest, four tags, all protected by
# protecting the digest once). No enumeration of "every tag that happens to
# alias latest" is ever needed.
#
# retain(d) (--keep-all-tagged on — the right mode for CACHE-LIKE packages
# such as `buildcache`): true for EVERY tagged root, unconditionally. A
# cache package's tags are live entries for currently-building targets —
# age and count say nothing about liveness — so only its untagged versions
# (superseded cache layers) are ever dead. class == infra (today: exactly
# `buildcache`) gets this AUTOMATICALLY, regardless of the --keep-all-tagged
# flag/env — a single global flag cannot be set per-package from the
# workflow, so a scheduled run used to leave buildcache on the image-shaped
# default policy, benign today only because cache tags happen to be
# rewritten daily and stay under --keep-days by luck, not by design. The
# flag itself remains as a manual override for hand runs against any OTHER
# cache/scratch-shaped package; using the image-shaped default policy on
# such a package works only by accident (it happens to age out tags
# belonging to images no longer in the bakefile) and will misclassify a
# genuinely active but infrequently-rebuilt cache tag as garbage.
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
#   orphan  - neither; RETIRED WHOLESALE once stale (see RETIREMENT above),
#             or pruned by the identical uniform policy as live/infra while
#             it still has a version younger than $ORPHAN_STALE_DAYS
#
# THE BAKEFILE CROSS-CHECK (in Main, right after package enumeration) IS
# MORE LOAD-BEARING NOW than when this comment was first written: orphan
# classification now directly triggers an irreversible whole-package
# DELETE, not merely weaker retention, so a wrong classification is a
# data-loss bug, not just an over-retention one. It aborts the whole run
# (exit 2) rather than trust either source if they disagree.
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
#      DELETE. Applies UNIFORMLY to every package (live, infra, orphan) —
#      now that retirement (see above) is the only way an orphan's protected
#      tag is ever removed, this rail is close to a pure invariant of the
#      policy rather than something an orphan is deliberately allowed to
#      trip. This is a PER-PACKAGE skip-and-continue (exit 3 overall, like
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
# --delete-package NAME: an OPERATOR ESCAPE HATCH, not part of automatic
# policy. It calls DELETE on the container package itself (not a version)
# directly — bypassing classification, every safety rail, the budget, and
# the planning pass entirely. When given, this is the ONLY thing the script
# does: it does not touch the nightly path in any way, does not run
# alongside --package/--verify-only/etc., and exits as soon as it's done.
# Two guards run first and are reported before anything is called:
#   (a) the named package must be linked to <owner>/<repo> (same check
#       list_packages already applies to the normal enumeration), and
#   (b) the named package must NOT be a live bakefile target — refusing to
#       let a typo point this at a currently-published image.
# Either guard failing refuses to act (exit 2) and says which one failed.
# Honours --apply/APPLY=true exactly like everything else: without it, this
# prints the call it WOULD make and exits without calling anything. 204 and
# 404 (already gone) are both reported as success; anything else is a loud
# failure with the HTTP status and response body printed verbatim — that
# status code is the point of running this, so it is never swallowed.
#
# Usage:
#   tidy.sh [--owner ORG] [--repo REPO] [--repo-prefix PREFIX]
#            [--package NAME]... [--keep-last N] [--keep-days N]
#            [--keep-all-tagged] [--grace-days N] [--keep-tag-regex RE]...
#            [--max-delete-ratio R] [--budget N]
#            [--delete-broken-roots] [--apply] [--force] [--verify-only]
#            [--delete-package NAME] [--json FILE]
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
#   DELETE_PACKAGE      - default for --delete-package; empty means "not
#                         requested" (the nightly schedule must never set
#                         this — it is an operator-only escape hatch)
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
#      (or only PRE-EXISTING broken tags — see VERIFICATION above). A
#      package being RETIRED (see RETIREMENT above) is reported but alone
#      does NOT prevent exit 0.
#   1  completed with some delete failures (--apply only); this also covers
#      a failed retirement package-delete call (see RETIREMENT above)
#   2  operational failure (no token, network error, jq/docker missing, ...)
#   3  a safety-critical condition: rail #1 tripped (whole run aborted,
#      nothing deleted — the only rail that still aborts the whole run), OR
#      rail #2/#4 tripped GENUINELY for at least one package (that package
#      skipped, others still processed), OR post-apply verification found a
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
# Threshold for RETIREMENT (see the header comment): an orphan package with
# no version younger than this many days is removed WHOLESALE via a single
# package-delete call, no version-level plan computed at all. Deliberately
# a fixed constant, NOT tied to --keep-days: an operator retuning
# --keep-days for the pruning policy must not accidentally change when a
# stale orphan is irreversibly retired.
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
DELETE_PACKAGE="${DELETE_PACKAGE:-}"

usage() {
  cat <<'EOF'
Usage: tidy.sh [--owner ORG] [--repo REPO] [--repo-prefix PREFIX]
                      [--package NAME]... [--keep-last N] [--keep-days N]
                      [--keep-all-tagged] [--grace-days N]
                      [--keep-tag-regex RE]... [--max-delete-ratio R]
                      [--budget N]
                      [--delete-broken-roots] [--apply] [--force]
                      [--verify-only] [--delete-package NAME] [--json FILE]

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
                        (default: 30). Applies IDENTICALLY to every
                        package — live, infra, and orphan alike. An orphan
                        package is never pruned by a weaker rule than this:
                        it is instead RETIRED WHOLESALE (a single
                        package-delete, see the header comment) once it has
                        no version younger than the separate, fixed
                        orphan-staleness threshold; short of that, it is
                        pruned by this exact same rule as a live package.
  --keep-all-tagged     Keep EVERY tagged root regardless of age or count,
                        ignoring --keep-last/--keep-days/--keep-tag-regex.
                        Use for cache-like packages (e.g. buildcache) whose
                        tags are live cache entries, not release history.
                        Applied AUTOMATICALLY to any package classified
                        `infra` (today: buildcache) regardless of this
                        flag; it remains available here as a manual
                        override for hand runs against other packages.
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
  --delete-package NAME Operator escape hatch: DELETE the named container
                        package itself (not a version), bypassing
                        classification, every safety rail, the budget, and
                        the planning pass entirely. Refuses unless the
                        package is linked to <owner>/<repo> and is NOT a
                        live bakefile target. Honours --apply exactly like
                        everything else (dry-run prints the call it would
                        make). When given, this is the only thing the
                        script does; see the header comment for the full
                        contract. NOT part of automatic/nightly policy.
  --json FILE           Write the full machine-readable plan to FILE
  -h, --help            Show this help and exit

Exit codes:
  0  nothing to do / dry run clean / --verify-only found no broken tags
     (or only PRE-EXISTING ones). A package being RETIRED is reported but
     doesn't prevent this.
  1  completed with some delete failures (--apply only), including a
     failed retirement package-delete call
  2  operational failure (no token, network error, jq/docker missing, ...)
  3  a safety-critical condition: rail #1 tripped (whole run aborted,
     nothing deleted — the only rail that still aborts the whole run), OR
     rail #2/#4 tripped GENUINELY for at least one package (that package
     skipped, others still processed), OR post-apply verification found a
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
    --delete-package)
      DELETE_PACKAGE="${2:?--delete-package requires a value}"
      shift 2
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

# delete_package_call PKG_NAME -> calls
# `DELETE /orgs/{OWNER}/packages/container/{PKG_NAME}` via request_with_retry
# (inheriting its retry/backoff — this is the ONE mutating call in this
# script that already routed through it correctly; see the version-delete
# loop in Main for the other one, fixed to match this). Treats 204
# (deleted) and 404 (already gone) as success and prints a
# DELETE_PACKAGE_RESULT line for each; any other status is a loud failure
# with the HTTP status and response body printed verbatim (never swallowed
# — that status code is the whole point of calling this). Returns 0 on
# success, 1 on failure. Does NOT check --apply itself: both call sites
# (the --delete-package escape hatch, and the RETIREMENT path in Main) gate
# that themselves before calling this.
delete_package_call() {
  local pkg_name="$1"
  local enc url body headers status
  enc=$(jq -rn --arg s "$pkg_name" '$s|@uri')
  url="https://api.github.com/orgs/${OWNER}/packages/container/${enc}"
  body="$(mktemp "$WORKDIR/delpkg-body.XXXXXX")"
  headers="$(mktemp "$WORKDIR/delpkg-headers.XXXXXX")"
  status=$(request_with_retry "$url" "$GITHUB_ACCEPT" "Authorization: Bearer ${GH_TOKEN_VALUE}" "$body" "$headers" DELETE)

  case "$status" in
    204)
      log_info "DELETE ${pkg_name}: HTTP 204 (package removed)."
      echo "DELETE_PACKAGE_RESULT: ${pkg_name} -> HTTP 204 (deleted)"
      rm -f "$body" "$headers"
      return 0
      ;;
    404)
      log_info "DELETE ${pkg_name}: HTTP 404 (already gone; treated as success)."
      echo "DELETE_PACKAGE_RESULT: ${pkg_name} -> HTTP 404 (already gone)"
      rm -f "$body" "$headers"
      return 0
      ;;
    *)
      log_err "DELETE ${pkg_name}: unexpected HTTP ${status}. Response body:"
      cat "$body" >&2
      echo "DELETE_PACKAGE_RESULT: ${pkg_name} -> HTTP ${status} (FAILED — see response body above)"
      rm -f "$body" "$headers"
      return 1
      ;;
  esac
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
#
# S3: a package can match the name prefix but fail the repository-link half
# of this filter — most commonly because its `.repository` link is entirely
# absent (jq evaluates `null.full_name` as `null` without raising, so this
# silently drops the package: no count, no name, no warning), but the same
# code path also covers a package linked to some OTHER repo. Either way it
# is otherwise invisible with only "at least one package survived" as a
# backstop — precisely the class of bug this whole rewrite exists to fix
# (see the PACKAGE ENUMERATION header comment: ~40% of the registry went
# invisible to the previous cleanup for an analogous silent-exclusion
# reason). So every excluded-by-repository-link match is logged by name and
# count below. This is a WARNING, not a failure: it does not abort the run
# (the exclusion may be entirely correct — a package genuinely transferred
# or unlinked), but it must never again be silent.
list_packages() {
  local raw="$WORKDIR/packages-raw.jsonl"
  : > "$raw"
  if ! github_api_paginate "https://api.github.com/orgs/${OWNER}/packages?package_type=container&per_page=100" "$raw"; then
    return 1
  fi
  jq -c --arg fullrepo "${OWNER}/${REPO}" --arg prefix "${REPO_PREFIX}/" \
    'select(.repository.full_name == $fullrepo and (.name | startswith($prefix))) | {name, repository: .repository.full_name, visibility}' \
    "$raw" > "$WORKDIR/packages.jsonl"

  local excluded_names excluded_count
  excluded_names=$(jq -r --arg fullrepo "${OWNER}/${REPO}" --arg prefix "${REPO_PREFIX}/" \
    'select((.repository.full_name != $fullrepo) and (.name | startswith($prefix))) | .name' \
    "$raw")
  if [ -n "$excluded_names" ]; then
    excluded_count=$(printf '%s\n' "$excluded_names" | wc -l | tr -d ' ')
    log_warn "${excluded_count} package(s) match prefix '${REPO_PREFIX}/' but were EXCLUDED because their repository link is not ${OWNER}/${REPO} (absent, or linked elsewhere): $(printf '%s' "$excluded_names" | tr '\n' ' ')"
  fi
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
#   7 RETIREMENT: this package is a stale orphan (see the header comment) —
#     no version-level plan was computed at all; the caller queues it for a
#     single package-delete instead. Does NOT contribute to a non-zero exit
#     on its own (a failed retirement delete does, via DELETE_FAILURES).
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

  # --- RETIREMENT: a package-level decision, entirely separate from and
  # PRIOR TO pruning — see the header comment for the full rationale. An
  # orphan with no version younger than $ORPHAN_STALE_DAYS is retired
  # WHOLESALE here (no roots/reachability/DELETE ever computed for it) and
  # the caller (Main) performs the single package-delete call, gated on
  # --apply exactly like everything else. total == 0 is treated as
  # trivially stale (nothing to check an age against, nothing to protect
  # by waiting) rather than falling through to the total==0 branch below.
  if [ "$class" = "orphan" ]; then
    local retire_age_days retire_is_stale
    if [ "$total" -eq 0 ]; then
      retire_is_stale=1
      retire_age_days="n/a"
    else
      retire_age_days=$(jq -rs --argjson now "$NOW_EPOCH" '
        def age_days: ($now - (.created_at | fromdateiso8601)) / 86400;
        map(age_days) | min' "$versions_file")
      retire_is_stale=$(awk -v a="$retire_age_days" -v d="$ORPHAN_STALE_DAYS" 'BEGIN { print (a >= d) ? 1 : 0 }')
      retire_age_days=$(awk -v a="$retire_age_days" 'BEGIN { printf "%.1f", a }')
    fi
    if [ "$retire_is_stale" -eq 1 ]; then
      log_warn "RETIRE: ${pkg_name} — orphan, ${total} version(s), no version younger than ${ORPHAN_STALE_DAYS}d (newest is ${retire_age_days} day(s) old) — will be removed as a single whole-package delete, not pruned version-by-version. PERMANENT AND IRREVERSIBLE."
      echo "${image}  ${class}  total=${total}  RETIRE (whole-package delete — stale orphan, newest ${retire_age_days}d)"
      jq -n --arg image "$image" --arg pkg "$pkg_name" --arg class "$class" --argjson total "$total" \
        '{image: $image, package: $pkg, class: $class, total: $total, retire: true}' \
        > "$WORKDIR/plan-${image}.json"
      return 7
    fi
  fi

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

  # KEEP_ROOTS: see the --keep-all-tagged header comment. IDENTICAL policy
  # for every class (live, infra, orphan) EXCEPT that class == infra always
  # gets keep-all-tagged behaviour (below): protected tag ($by_tag, digest-
  # scoped — see the header comment for why that alone covers every alias
  # of `latest`) OR newest --keep-last OR younger than --keep-days. No
  # OTHER class-conditional branch here: an orphan that reaches this point
  # already failed the RETIREMENT staleness check above (it has a version
  # younger than $ORPHAN_STALE_DAYS), so it is pruned exactly like a live
  # package — there is no separate, weaker "let an orphan's tags decay"
  # rule anymore. Safety rail #2 below independently re-checks that this
  # policy never actually drops a protected tag into DELETE.
  #
  # S4: class == infra IMPLIES keep-all-tagged, unconditionally — this is
  # about the PACKAGE BEING CACHE-LIKE, not about being "infra" as a label:
  # today infra means exactly `buildcache`, and the header comment on
  # --keep-all-tagged explains why the image-shaped default policy "works
  # only by accident" for a cache package (its tags are live entries for
  # currently-building targets, not release history — age/count say
  # nothing about liveness). Before this, the scheduled run left
  # KEEP_ALL_TAGGED empty (a single global flag can't be set per-package
  # from the workflow), so buildcache silently got the wrong-shaped policy
  # and was benign only by luck (cache tags happen to get rewritten daily,
  # keeping everything under --keep-days). --keep-all-tagged / the
  # KEEP_ALL_TAGGED env var remain available as a manual override for hand
  # runs — e.g. testing another cache-like package before it is formally
  # classified `infra` — hence the `||`, not a replacement of the flag.
  local effective_keep_all_tagged=$KEEP_ALL_TAGGED
  [ "$class" = "infra" ] && effective_keep_all_tagged=1

  local keep_roots_file="$WORKDIR/keeproots-${image}.txt"
  if [ "$effective_keep_all_tagged" -eq 1 ]; then
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
  # S6: parent<TAB>child edges, recorded as a free side effect of every
  # successful resolve_manifest call below (no extra API calls — $children
  # is already fetched). Used only by the --delete-broken-roots
  # reclassification pass further down to answer "does any digest OTHER
  # than this broken root have it as a child?" without re-resolving
  # anything. See that pass's own comment for why this question matters.
  local edges_file="$WORKDIR/edges-${image}.tsv"
  : > "$reachable_file"
  : > "$failclosed_file"
  : > "$edges_file"

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
          if [ -n "$children" ]; then
            printf '%s\n' "$children" | sed "s/^/${d}\t/" >> "$edges_file"
          fi
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
    local fc_root class_result class_type broken_digests_file shared_parent
    broken_digests_file="$WORKDIR/broken-digests-${image}.txt"
    : > "$broken_digests_file"
    while IFS= read -r fc_root; do
      [ -z "$fc_root" ] && continue
      class_result=$(classify_root "$pkg_path" "$token" "$fc_root")
      class_type="${class_result%%$'\t'*}"
      if [ "$class_type" = "broken" ]; then
        # S6: fc_root's own manifest resolves fine (classify_root confirmed
        # only its CHILDREN are dead) — but if fc_root's digest is ALSO a
        # child of some OTHER digest in this package's reachability graph
        # (a tagged index nested as another index's child; low probability
        # but the failure mode is severe), removing it from reachable_file
        # below would move a digest a healthy index still references into
        # DELETE. Rail #1 cannot catch this: once removed, fc_root simply
        # isn't in reachable_file to overlap with. edges_file was built as
        # a free side effect of the reachability BFS above (no extra API
        # calls), so this check is a single cheap scan, not a fresh
        # traversal.
        shared_parent=$(awk -F'\t' -v t="$fc_root" '$2 == t { print $1; exit }' "$edges_file")
        if [ -n "$shared_parent" ]; then
          log_warn "${pkg_name}: keep-root ${fc_root} classified broken by --delete-broken-roots, but it is ALSO a child of ${shared_parent} elsewhere in this package's reachability graph — NOT reclassifying it (would risk orphaning a digest a healthy index still references); it stays fail-closed as before."
          continue
        fi
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
  # Applies UNIFORMLY to every package now (live, infra, orphan): with the
  # orphan-specific $by_tag drop removed from the KEEP_ROOTS policy (see its
  # comment above), a protected tag landing in DELETE is never the intended
  # outcome for ANY class — this is close to a pure invariant of the policy
  # rather than a bug detector that must stay silent for one class. PER-
  # PACKAGE skip (exit 3 overall, like rail #4 below), not a whole-run
  # abort: a set-arithmetic bug in one package's policy computation is not
  # evidence the other packages are miscomputed, and a whole-run abort here
  # let one bad package silently zero out an entire scheduled run,
  # indefinitely. Still loud — still a bug detector — just scoped to the
  # package it actually concerns.
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

  # --- Safety rail #4: DELETE must not exceed --max-delete-ratio, unless
  # --force. Per-package skip. Applies UNIFORMLY to every package now —
  # there is no orphan exemption: an orphan that would trip this by
  # decaying to ~100% DELETE is retired WHOLESALE before it ever reaches
  # this rail (see RETIREMENT in the header comment and the retirement
  # check near the top of this function), so any package that still
  # reaches rail #4 is either not an orphan, or an orphan with a version
  # younger than $ORPHAN_STALE_DAYS — i.e. genuinely still changing, not a
  # package whose decay this design intends to permit.
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
# arrays (APPLIED_PACKAGES, RETIRED_PACKAGES, ...) into write_plan_json's
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
# remaining, delete_failures, and which packages were applied/retired/
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
    # S7: guarded by length rather than a bare "${ARRAY[@]}" expansion —
    # bash_array_to_json_array's "$# -eq 0" empty-detection needs to see
    # ZERO arguments when the source array is empty, which "${ARR[@]:-}"
    # cannot provide (it substitutes one empty-string argument instead, so
    # this couldn't use the [@]:-} convention used elsewhere in this file
    # without silently corrupting the "no packages" case into `[""]`
    # instead of `[]`). Checking length first, and only ever writing
    # "${ARRAY[@]}" once that length is confirmed non-zero, avoids the
    # "unbound variable" bash-<4.4 behaviour on an empty array the same as
    # [@]:-} does elsewhere, without that trade-off.
    local applied_json='[]' retired_json='[]' regression_json='[]' preexisting_json='[]'
    [ "${#APPLIED_PACKAGES[@]}" -gt 0 ] && applied_json=$(bash_array_to_json_array "${APPLIED_PACKAGES[@]}")
    [ "${#RETIRED_PACKAGES[@]}" -gt 0 ] && retired_json=$(bash_array_to_json_array "${RETIRED_PACKAGES[@]}")
    [ "${#REGRESSION_PACKAGES[@]}" -gt 0 ] && regression_json=$(bash_array_to_json_array "${REGRESSION_PACKAGES[@]}")
    [ "${#PREEXISTING_CORRUPTION_PACKAGES[@]}" -gt 0 ] && preexisting_json=$(bash_array_to_json_array "${PREEXISTING_CORRUPTION_PACKAGES[@]}")
    jq -n --argjson budget "$BUDGET" --argjson apply "$([ "$APPLY" -eq 1 ] && echo true || echo false)" \
      --argjson max_delete_ratio "$MAX_DELETE_RATIO" --slurpfile packages "$packages_file" \
      --argjson actual_deleted "$ACTUAL_DELETED" --argjson remaining "$REMAINING" \
      --argjson delete_failures "$DELETE_FAILURES" \
      --argjson applied_packages "$applied_json" \
      --argjson retired_packages "$retired_json" \
      --argjson regression_packages "$regression_json" \
      --argjson preexisting_corruption_packages "$preexisting_json" \
      '{phase: "final", budget: $budget, apply: $apply, max_delete_ratio: $max_delete_ratio,
        packages: $packages[0],
        outcome: {actual_deleted: $actual_deleted, remaining: $remaining,
          delete_failures: $delete_failures, applied_packages: $applied_packages,
          retired_packages: $retired_packages, regression_packages: $regression_packages,
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

# --delete-package: operator escape hatch (see header comment). This does
# ONLY this, then exits — it must never fall through into the nightly
# discover/classify/plan/apply path below, regardless of --apply, --package,
# --verify-only, or any other flag also given alongside it.
if [ -n "$DELETE_PACKAGE" ]; then
  DP_PKG_NAME="${REPO_PREFIX}/${DELETE_PACKAGE}"
  DP_ENC=$(jq -rn --arg s "$DP_PKG_NAME" '$s|@uri')

  log_info "--delete-package ${DELETE_PACKAGE}: checking guards before acting on ${DP_PKG_NAME} ..."

  # Guard (a): the package must be linked to this repo. Reuses the same
  # enumeration list_packages already builds for the normal path, so this
  # guard can never see a package the nightly run itself wouldn't see.
  log_info "discovering packages linked to ${OWNER}/${REPO} with prefix ${REPO_PREFIX}/ ..."
  if ! list_packages; then
    report_enum_failure "$LAST_API_STATUS"
    exit 2
  fi
  if ! jq -e --arg name "$DP_PKG_NAME" 'select(.name == $name)' "$WORKDIR/packages.jsonl" >/dev/null 2>&1; then
    log_err "--delete-package ${DELETE_PACKAGE}: GUARD (a) FAILED — '${DP_PKG_NAME}' is not linked to ${OWNER}/${REPO} (or does not exist). Refusing to act."
    exit 2
  fi
  log_info "--delete-package ${DELETE_PACKAGE}: GUARD (a) PASSED — package is linked to ${OWNER}/${REPO}."

  # Guard (b): the package must NOT be a live bakefile target. An operator
  # should not be able to point this at a currently-published image by typo.
  log_info "discovering live images from the bakefile ..."
  DP_LIVE_IMAGES_FILE="$WORKDIR/live-images.txt"
  if ! discover_live_images > "$DP_LIVE_IMAGES_FILE"; then
    log_err "--delete-package ${DELETE_PACKAGE}: failed to run 'docker buildx bake --print' against $REPO_ROOT"
    exit 2
  fi
  if grep -qxF "$DELETE_PACKAGE" "$DP_LIVE_IMAGES_FILE"; then
    log_err "--delete-package ${DELETE_PACKAGE}: GUARD (b) FAILED — '${DELETE_PACKAGE}' IS a live bakefile target. Refusing to act; this flag must not be pointed at a live image."
    exit 2
  fi
  log_info "--delete-package ${DELETE_PACKAGE}: GUARD (b) PASSED — not present in the bakefile."

  if [ "$APPLY" -ne 1 ]; then
    echo "DRY RUN: would DELETE https://api.github.com/orgs/${OWNER}/packages/container/${DP_ENC} (pass --apply, or APPLY=true, to actually call this)"
    exit 0
  fi

  log_warn "--delete-package ${DELETE_PACKAGE}: both guards passed and --apply is set — calling DELETE ${DP_PKG_NAME} ..."
  if delete_package_call "$DP_PKG_NAME"; then
    exit 0
  fi
  exit 1
fi

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

  # S7: verify_any_broken is a COUNT (incremented per broken package), not
  # a boolean flag — `-eq 1` silently hid this summary line whenever two or
  # more packages were broken. `-gt 0` is correct for a count.
  if [ "$verify_any_broken" -gt 0 ]; then
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
FAILCLOSED_PACKAGES=()
PROCESSED_PACKAGES=()
BROKEN_ROOTS_PACKAGES=()
RETIRING_PACKAGES=()

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
    7)
      # RETIREMENT (see plan_package and the header comment): a stale
      # orphan, queued here for a single whole-package delete in the Apply
      # section below (or previewed only, in a dry run). Deliberately does
      # NOT set any *_TRIPPED flag and does NOT touch TOTAL_DELETE/
      # TOTAL_PLANNED — there is no version-level plan for this package at
      # all, so it must not count against either.
      RETIRING_PACKAGES+=("$image")
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
RETIRED_PACKAGES=()

if [ "$APPLY" -eq 1 ]; then
  # RETIREMENT: one whole-package DELETE per stale orphan queued by the
  # planning loop above (see plan_package / return 7). Deliberately NOT
  # subject to --budget (a single API call per package, unrelated to the
  # per-version delete budget below) or to safety rail #4 (there is no
  # version-level plan to compute a ratio against — see the header
  # comment). A failure here counts toward DELETE_FAILURES exactly like a
  # failed version delete, so the existing exit-1 path covers it without a
  # new exit code.
  if [ "${#RETIRING_PACKAGES[@]}" -gt 0 ]; then
    echo "=== RETIRING ${#RETIRING_PACKAGES[@]} stale orphan package(s) — whole-package delete, PERMANENT AND IRREVERSIBLE ==="
    for image in "${RETIRING_PACKAGES[@]}"; do
      pkg_name="${REPO_PREFIX}/${image}"
      log_warn "RETIRING ${pkg_name}: orphan, no version younger than ${ORPHAN_STALE_DAYS} day(s) — calling whole-package delete now."
      if delete_package_call "$pkg_name"; then
        RETIRED_PACKAGES+=("$image")
      else
        DELETE_FAILURES=$((DELETE_FAILURES + 1))
      fi
    done
  fi

  BUDGET_LEFT=$BUDGET
  # S7: guarded with [@]:-} + an immediate empty-check, matching the
  # convention already used for SKIPPED_PACKAGES/FAILCLOSED_PACKAGES below
  # — PROCESSED_PACKAGES can legitimately be empty (every package retiring,
  # skipped, or rail-tripped) and "${ARRAY[@]}" on a declared-but-empty
  # array throws "unbound variable" under `set -u` on bash < 4.4 (fixed in
  # 4.4). Harmless on the bash 5.x this normally runs under, but this file
  # otherwise guards every such expansion, so this one should too.
  VERDEL_BODY="$WORKDIR/verdel-body"
  VERDEL_HEADERS="$WORKDIR/verdel-headers"
  for image in "${PROCESSED_PACKAGES[@]:-}"; do
    [ -z "$image" ] && continue
    [ "$BUDGET_LEFT" -le 0 ] && break
    pkg_name="${REPO_PREFIX}/${image}"
    enc=$(jq -rn --arg s "$pkg_name" '$s|@uri')
    delete_count=$(jq -r '.delete_count' "$WORKDIR/plan-${image}.json")
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
    #
    # S1: routed through request_with_retry (not a raw curl call) so a
    # 429/5xx/timeout gets the same backoff-and-retry every read path in
    # this script already gets. GitHub applies SECONDARY rate limits to
    # mutating requests, and a nightly run issues up to --budget deletions
    # in a matter of minutes — squarely in that territory. Without this, a
    # single transient 429 was BOTH counted as a permanent DELETE_FAILURES
    # entry AND still consumed a budget slot for a version that was never
    # actually attempted-and-failed, just rate-limited. request_with_retry
    # only returns after up to 3 attempts, so the status checked below is
    # already the FINAL outcome: a 429 that eventually succeeds surfaces
    # here as 204/200 (success, not a failure), and only a delete that
    # genuinely failed after retries reaches the failure branch. Budget is
    # still spent exactly once per version either way — it tracks "one
    # version processed this run", not "one bare HTTP attempt".
    while IFS=$'\t' read -r id digest; do
      [ -z "$id" ] && continue
      [ "$BUDGET_LEFT" -le 0 ] && break
      status=$(request_with_retry "https://api.github.com/orgs/${OWNER}/packages/container/${enc}/versions/${id}" "$GITHUB_ACCEPT" "Authorization: Bearer ${GH_TOKEN_VALUE}" "$VERDEL_BODY" "$VERDEL_HEADERS" DELETE)
      if [ "$status" != "204" ] && [ "$status" != "200" ]; then
        log_warn "failed to delete ${pkg_name} version ${id} (status ${status})"
        DELETE_FAILURES=$((DELETE_FAILURES + 1))
      else
        package_deleted=1
        ACTUAL_DELETED=$((ACTUAL_DELETED + 1))
        log_info "DELETED ${pkg_name} ${digest}"
      fi
      BUDGET_LEFT=$((BUDGET_LEFT - 1))
      sleep 1
    done < <(jq -r '.delete | sort_by((.tags | length) == 0) | .[] | [.id, .digest] | @tsv' "$WORKDIR/plan-${image}.json")

    if [ "$package_deleted" -eq 1 ]; then
      APPLIED_PACKAGES+=("$image")
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
  # which packages were retired. Only reached if the apply phase ran to
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
  echo "deleted ${ACTUAL_DELETED} of ${TOTAL_DELETE} planned versions across ${TOTAL_PLANNED} package(s) (budget ${BUDGET}, ${REMAINING} remaining, ${DELETE_FAILURES} failures); retired ${#RETIRED_PACKAGES[@]} of ${#RETIRING_PACKAGES[@]} stale orphan package(s)"
else
  echo "DRY RUN: would delete ${EFFECTIVE_DELETE} of ${TOTAL_DELETE} planned versions across ${TOTAL_PLANNED} package(s) (budget ${BUDGET}, ${REMAINING} remaining); would retire ${#RETIRING_PACKAGES[@]} stale orphan package(s)"
fi

# WOULD RETIRE, dry-run preview: RETIRING_PACKAGES is populated by the
# planning loop above regardless of --apply (see plan_package / return 7),
# so this is purely a report of what --apply would do — nothing is called
# here.
if [ "$APPLY" -ne 1 ] && [ "${#RETIRING_PACKAGES[@]}" -gt 0 ]; then
  echo ""
  echo "=== WOULD RETIRE (dry run — nothing called) ==="
  echo "Each package below is class=orphan with no version younger than ${ORPHAN_STALE_DAYS} days;"
  echo "with --apply it is removed ENTIRELY via a single whole-package delete (not pruned"
  echo "version-by-version). This is permanent and irreversible."
  for image in "${RETIRING_PACKAGES[@]}"; do
    tot=$(jq -r '.total' "$WORKDIR/plan-${image}.json")
    echo "  would retire ${REPO_PREFIX}/${image} (${tot} version(s))"
  done
fi

if [ "${#RETIRED_PACKAGES[@]}" -gt 0 ]; then
  echo ""
  echo "=== PACKAGES RETIRED (whole-package delete — permanent, irreversible — see the DELETE_PACKAGE_RESULT lines above) ==="
  for image in "${RETIRED_PACKAGES[@]}"; do
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
