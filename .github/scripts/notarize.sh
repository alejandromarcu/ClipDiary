#!/bin/bash
# Notarize a file with Apple, then staple the ticket onto the built product.
#
# Usage: notarize.sh <file-to-submit> <bundle-to-staple>
#   (for an app the submission is a zip of it; for a dmg both are the dmg)
#
# Why this isn't just two `xcrun` calls: `notarytool submit --wait` exits 0
# even when Apple's verdict is "Invalid". A plain submit-then-staple pipeline
# therefore walks straight into `stapler`, which fails with an opaque
# "Record not found ... Error 65" -- true (there is no ticket, the build was
# rejected) but silent about WHY. The reason only lives in the notary log, so
# this checks the verdict and prints that log on rejection, where the failing
# path and reason are named.
#
# Requires APPLE_ID / APPLE_TEAM_ID / APPLE_APP_SPECIFIC_PASSWORD in the env.

set -euo pipefail

submit_path="$1"
staple_path="$2"

: "${APPLE_ID:?APPLE_ID is not set}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID is not set}"
: "${APPLE_APP_SPECIFIC_PASSWORD:?APPLE_APP_SPECIFIC_PASSWORD is not set}"

credentials=(
  --apple-id "$APPLE_ID"
  --team-id "$APPLE_TEAM_ID"
  --password "$APPLE_APP_SPECIFIC_PASSWORD"
)

echo "Submitting $(basename "$submit_path") to the notary service…"
result="$(xcrun notarytool submit "$submit_path" "${credentials[@]}" \
  --wait --output-format json)"
echo "$result"

submission_id="$(printf '%s' "$result" | jq -r '.id // empty')"
status="$(printf '%s' "$result" | jq -r '.status // empty')"

if [ "$status" != "Accepted" ]; then
  echo "::error::Notarization of $(basename "$submit_path") came back '${status:-unknown}'. Apple's log follows."
  if [ -n "$submission_id" ]; then
    xcrun notarytool log "$submission_id" "${credentials[@]}" \
      || echo "(could not fetch the notary log for submission $submission_id)"
  fi
  exit 1
fi

xcrun stapler staple "$staple_path"
