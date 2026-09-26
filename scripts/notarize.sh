#!/bin/bash
# Sign with a Developer ID, notarize with Apple and staple — removes the
# Gatekeeper warning. Requires a paid Apple Developer account.
#
# One-time setup:
#   1. Install your "Developer ID Application" certificate (Xcode > Settings > Accounts,
#      or developer.apple.com > Certificates) and check: security find-identity -v -p codesigning
#   2. Store notary credentials (app-specific password from appleid.apple.com):
#      xcrun notarytool store-credentials jevsort --apple-id you@example.com --team-id TEAMID
#
# Then:  SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/notarize.sh
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
: "${SIGN_IDENTITY:?set SIGN_IDENTITY to your Developer ID Application identity}"
PROFILE="${NOTARY_PROFILE:-jevsort}"
VERSION="$(cat "$REPO/VERSION")"

SIGN_IDENTITY="$SIGN_IDENTITY" "$REPO/scripts/build_app.sh" --release
"$REPO/scripts/make_dmg.sh"
DMG="$REPO/build/jev-folder-sort-$VERSION-arm64.dmg"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"
(cd "$REPO/build" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "Notarized: $DMG"
