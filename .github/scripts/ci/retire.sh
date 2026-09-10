#!/usr/bin/env bash
# Runs retire-packages.sh with flags mapped from the tidy-ghcr workflow_dispatch
# inputs, and translates its exit code into readable log annotations.
#
# Backs: tidy-ghcr.yml, job `retire`, step "Run retire-packages.sh".
#
# Expects env:
#   IN_APPLY             - "true"/"false" — whether to actually delete
#   IN_RETIRE_AFTER_DAYS - minimum days since a package's last update before
#                          it becomes a retirement candidate
set -eo pipefail

: "${IN_APPLY:?IN_APPLY is required}"
: "${IN_RETIRE_AFTER_DAYS:?IN_RETIRE_AFTER_DAYS is required}"

args=(--after-days "$IN_RETIRE_AFTER_DAYS" --json retire-plan.json)

if [ "$IN_APPLY" = "true" ]; then
  args+=(--apply)
fi

echo "Running: .github/scripts/retire-packages.sh ${args[*]}"
set +e
.github/scripts/retire-packages.sh "${args[@]}"
rc=$?
set -e

case "$rc" in
  0) echo "retire-packages.sh: clean run, nothing further to report." ;;
  1) echo "::warning::retire-packages.sh exited 1: completed with some delete failures. See the log and retire-plan.json artifact." ;;
  2) echo "::error::retire-packages.sh exited 2: operational failure (missing token, network error, or missing tooling). Not a classification problem." ;;
  3) echo "::warning::retire-packages.sh exited 3: a safety rail tripped (bakefile discovery failed, a non-orphan ended up in the candidate set, or more packages qualified than --max-retire allows). Nothing was deleted. See the log for the candidate list." ;;
  *) echo "::error::retire-packages.sh exited unexpected code $rc." ;;
esac

exit "$rc"

