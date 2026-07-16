#!/bin/bash
# Build, sign, notarize, and package a ClipDiary release for Sparkle auto-updates.
#
# Produces:
#   releases/<version>/ClipDiary-<version>.zip  — upload to a GitHub Release (tag v<version>)
#   docs/appcast.xml                            — the Sparkle feed; commit + push
#                                                 (served by GitHub Pages from /docs)
#
# Usage:
#   Tools/release.sh                  # full flow: Developer ID + notarization
#   Tools/release.sh --skip-notarize  # ad-hoc signed, no notarization (local testing only)
#
# One-time setup before the first real release:
#   1. Apple Developer Program membership; a "Developer ID Application"
#      certificate installed in the login Keychain.
#   2. Notarization credentials stored once:
#        xcrun notarytool store-credentials clipdiary-notary \
#          --apple-id <apple-id> --team-id <team-id>
#      (or set NOTARY_PROFILE to an existing profile name).
#   3. Sparkle's command-line tools: download the release .tar.xz from
#      https://github.com/sparkle-project/Sparkle/releases and unpack its bin/
#      into Tools/sparkle/bin (gitignored), or set SPARKLE_BIN to wherever the
#      tools live. Then run generate_keys ONCE, put the printed public key in
#      ClipDiary/Info.plist (SUPublicEDKey), and BACK UP the private key
#      (Keychain item "Private key for signing Sparkle updates"):
#        Tools/sparkle/bin/generate_keys
#   4. Enable GitHub Pages: repo Settings → Pages → deploy from branch,
#      main + /docs.

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
NOTARY_PROFILE=${NOTARY_PROFILE:-clipdiary-notary}
SKIP_NOTARIZE=0
[[ "${1:-}" == "--skip-notarize" ]] && SKIP_NOTARIZE=1

VERSION=$(sed -n 's/^[[:space:]]*MARKETING_VERSION = \(.*\);/\1/p' \
    "$REPO_ROOT/ClipDiary.xcodeproj/project.pbxproj" | head -n 1)
[[ -n "$VERSION" ]] || { echo "error: could not read MARKETING_VERSION" >&2; exit 1; }

RELEASE_DIR="$REPO_ROOT/releases/$VERSION"
ARCHIVE="$REPO_ROOT/build/ClipDiary-$VERSION.xcarchive"
APP="$ARCHIVE/Products/Applications/ClipDiary.app"
ZIP="$RELEASE_DIR/ClipDiary-$VERSION.zip"

# Sparkle's generate_appcast: $SPARKLE_BIN, then Tools/sparkle/bin.
GENERATE_APPCAST=""
for candidate in "${SPARKLE_BIN:-}/generate_appcast" "$REPO_ROOT/Tools/sparkle/bin/generate_appcast"; do
    [[ -x "$candidate" ]] && GENERATE_APPCAST="$candidate" && break
done
[[ -n "$GENERATE_APPCAST" ]] || {
    echo "error: generate_appcast not found — see 'One-time setup' step 3 in this script" >&2
    exit 1
}

echo "== Archiving ClipDiary $VERSION (Release) =="
rm -rf "$ARCHIVE"
if [[ $SKIP_NOTARIZE == 1 ]]; then
    SIGN_ARGS=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual)
else
    SIGN_ARGS=(CODE_SIGN_IDENTITY="Developer ID Application" CODE_SIGN_STYLE=Manual
               ENABLE_HARDENED_RUNTIME=YES)
fi
xcodebuild archive -project "$REPO_ROOT/ClipDiary.xcodeproj" -scheme ClipDiary \
    -configuration Release -archivePath "$ARCHIVE" "${SIGN_ARGS[@]}" -quiet

if [[ $SKIP_NOTARIZE == 0 ]]; then
    echo "== Notarizing =="
    NOTARIZE_ZIP=$(mktemp -d)/ClipDiary.zip
    ditto -c -k --keepParent "$APP" "$NOTARIZE_ZIP"
    xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
fi

echo "== Packaging =="
mkdir -p "$RELEASE_DIR"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# One-item appcast for just this version: everyone updates straight to the
# latest, and the enclosure URL prefix (per-tag) stays correct.
echo "== Generating appcast =="
"$GENERATE_APPCAST" \
    --download-url-prefix "https://github.com/alejandromarcu/ClipDiary/releases/download/v$VERSION/" \
    --link "https://github.com/alejandromarcu/ClipDiary/releases" \
    -o "$REPO_ROOT/docs/appcast.xml" "$RELEASE_DIR"

echo
echo "Done. To publish:"
echo "  1. gh release create v$VERSION \"$ZIP\" --title \"ClipDiary $VERSION\" --notes \"See CHANGELOG.md\""
echo "  2. git add docs/appcast.xml && git commit -m \"Release $VERSION\" && git push"
