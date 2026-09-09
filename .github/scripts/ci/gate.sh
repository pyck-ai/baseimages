#!/usr/bin/env bash
# Single aggregate gate for the branch-protection required status check.
# Matrix jobs can't be required directly: their targets are discovered
# dynamically, and a matrix job skipped via a failed `needs` reports a bare
# context that a required check treats as passing. This job has a stable
# name, runs even when upstream stages fail (if: always()), and fails
# unless every stage succeeded.
#
# Backs: build-images.yml, job `gate`, step "Verify all stages succeeded".
#
# Expects env:
#   RESULT_DISCOVER - needs.discover.result
#   RESULT_BUILD    - needs.build.result
#   RESULT_VERIFY   - needs.verify.result
#   RESULT_PUBLISH  - needs.publish.result
set -uo pipefail

: "${RESULT_DISCOVER:?RESULT_DISCOVER is required}"
: "${RESULT_BUILD:?RESULT_BUILD is required}"
: "${RESULT_VERIFY:?RESULT_VERIFY is required}"
: "${RESULT_PUBLISH:?RESULT_PUBLISH is required}"

# `publish` is intentionally skipped on PRs (if: github.event_name !=
# 'pull_request'), so it must be accepted as either "success" or
# "skipped" — a naive `[ "$r" = "success" ]` loop would fail every PR.
# Every other job must be "success" on every event.
required="$RESULT_DISCOVER $RESULT_BUILD $RESULT_VERIFY"
for r in $required; do
  [ "$r" = "success" ] || { echo "A stage did not succeed: $required"; exit 1; }
done

case "$RESULT_PUBLISH" in
  success|skipped) ;;
  *) echo "publish did not succeed: $RESULT_PUBLISH"; exit 1 ;;
esac

echo "All stages succeeded."
