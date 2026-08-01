#!/bin/bash
# Re-sign the helpers nested inside Sparkle.framework with our own Developer ID.
#
# Xcode signs the app and the frameworks it embeds, but it does not re-sign code
# nested *inside* a framework -- it only seals it by reference. Sparkle's
# XCFramework ships its helpers (Updater.app, Autoupdate, and the Downloader /
# Installer XPC services) ad-hoc signed, so the archive ends up with our
# Developer ID on the outside and Sparkle's ad-hoc signatures within.
# Notarization rejects precisely that, once per helper per architecture:
#
#     "The binary is not signed with a valid Developer ID certificate."
#     "The signature does not include a secure timestamp."
#
# Signing a bundle seals everything inside it, so re-signing an inner bundle
# invalidates every container above it: work inside-out and finish with the app.
# --preserve-metadata=entitlements keeps each target's entitlements as they
# were: the app stays sandboxed with its mach-lookup exceptions, and Sparkle's
# helpers keep carrying none at all -- which is deliberate on Sparkle's part,
# since an XPC service inheriting our sandbox could not reach the network to
# fetch an update. The checks below fail loudly if the app's are ever lost,
# rather than shipping a quietly de-sandboxed build.
#
# Usage: resign-sparkle.sh <app-bundle> [identity]
#   identity defaults to "Developer ID Application". Pass "-" to rehearse the
#   whole sequence ad-hoc on a machine that has no certificate.

set -euo pipefail

app="${1:?usage: resign-sparkle.sh <app-bundle> [identity]}"
identity="${2:-Developer ID Application}"
versions="$app/Contents/Frameworks/Sparkle.framework/Versions/B"

[ -d "$versions" ] || { echo "error: no Sparkle.framework inside $app" >&2; exit 1; }

flags=(--force --sign "$identity" --options runtime --preserve-metadata=entitlements)
# Ad-hoc signatures cannot carry a secure timestamp; real ones must have one.
[ "$identity" = "-" ] || flags+=(--timestamp)

targets=(
  "$versions/XPCServices/Downloader.xpc"
  "$versions/XPCServices/Installer.xpc"
  "$versions/Updater.app"
  "$versions/Autoupdate"
  "$versions"
  "$app"
)

for target in "${targets[@]}"; do
  echo "signing ${target#"$app/"}"
  codesign "${flags[@]}" "$target"
done

echo
echo "verifying the result…"
codesign --verify --deep --strict --verbose=2 "$app"

# The app must still be sandboxed, still able to open the user's files, and
# still allowed the mach-lookup exceptions its XPC services are reached through.
entitlements="$(codesign -d --entitlements - "$app" 2>/dev/null || true)"
for required in \
  "com.apple.security.app-sandbox" \
  "com.apple.security.files.user-selected.read-write" \
  "-spks" \
  "-spki"; do
  case "$entitlements" in
    *"$required"*) ;;
    *) echo "error: the app lost '$required' while being re-signed" >&2; exit 1 ;;
  esac
done

# Catch an incomplete re-sign here rather than after a five-minute round trip
# to the notary service.
if [ "$identity" != "-" ]; then
  for target in "${targets[@]}"; do
    info="$(codesign -dvvv "$target" 2>&1)"
    case "$info" in
      *"Authority=Developer ID Application"*) ;;
      *) echo "error: ${target#"$app/"} is not signed with a Developer ID certificate" >&2; exit 1 ;;
    esac
    case "$info" in
      *"Timestamp="*) ;;
      *) echo "error: ${target#"$app/"} has no secure timestamp" >&2; exit 1 ;;
    esac
  done
fi

echo "Sparkle's helpers and the app are signed with: $identity"
