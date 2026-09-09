#!/usr/bin/env bash
# Runs prune-ghcr.sh with flags mapped from the tidy-ghcr workflow_dispatch
# inputs, and translates its exit code into readable log annotations.
#
# Backs: tidy-ghcr.yml, job `prune`, step "Run prune-ghcr.sh".
#
# Expects env:
#   IN_APPLY            - "true"/"false" — whether to actually delete
#   IN_PACKAGES         - space-separated package names, or empty for all
#   IN_BUDGET           - max deletions for this run
#   IN_KEEP_ALL_TAGGED  - "true"/"false" — keep every tagged root
set -eo pipefail

: "${IN_APPLY:?IN_APPLY is required}"
: "${IN_PACKAGES:?IN_PACKAGES is required (may be empty, but must be set)}"
: "${IN_BUDGET:?IN_BUDGET is required}"
: "${IN_KEEP_ALL_TAGGED:?IN_KEEP_ALL_TAGGED is required}"

set -a
source buildargs.conf
set +a

args=(--budget "$IN_BUDGET" --json prune-plan.json)

if [ -n "$IN_PACKAGES" ]; then
  for p in $IN_PACKAGES; do
    args+=(--package "$p")
  done
fi

if [ "$IN_KEEP_ALL_TAGGED" = "true" ]; then
  args+=(--keep-all-tagged)
fi

if [ "$IN_APPLY" = "true" ]; then
  args+=(--apply)
fi

echo "Running: .github/scripts/prune-ghcr.sh ${args[*]}"
set +e
.github/scripts/prune-ghcr.sh "${args[@]}"
rc=$?
set -e

case "$rc" in
  0) echo "prune-ghcr.sh: clean run, nothing further to report." ;;
  1) echo "::warning::prune-ghcr.sh exited 1: completed with some delete failures. See the log and prune-plan.json artifact." ;;
  2) echo "::error::prune-ghcr.sh exited 2: operational failure (missing token, network error, or missing tooling). Not a classification problem." ;;
  3) echo "::error::prune-ghcr.sh exited 3: a safety rail tripped, or post-apply verification found a kept tag now broken. Nothing unsafe was deleted." ;;
  *) echo "::error::prune-ghcr.sh exited unexpected code $rc." ;;
esac

echo "NOTE: exit 2 with nginx and/or rover reported under FAIL-CLOSED is currently EXPECTED — those two packages already have broken tags from the pre-existing registry corruption (see audit-ghcr.sh) and prune-ghcr.sh correctly refuses to plan for them until that is remediated separately. This is not a new problem introduced by this run."

exit "$rc"
