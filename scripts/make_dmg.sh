#!/bin/bash
# Package build/JevFolderSort.app into build/jev-folder-sort-<version>-arm64.dmg (+ .sha256).
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$REPO/VERSION")"
APP="$REPO/build/JevFolderSort.app"
DMG="$REPO/build/jev-folder-sort-$VERSION-arm64.dmg"
[[ -d "$APP/Contents/Resources/engine" ]] || { echo "build a release app first: scripts/build_app.sh --release"; exit 1; }
STAGE="$REPO/build/dmg-stage"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/jev-folder-sort.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/READ ME FIRST.txt" <<TXT
jev-folder-sort $VERSION

1. Drag jev-folder-sort into Applications.
2. First launch: right-click the app > Open > Open
   (this build isn't notarized by Apple yet; you only need to do this once).
   Or: System Settings > Privacy & Security > "Open Anyway".
3. Look for the tray icon in the menu bar and follow the welcome window.

Everything runs locally. Source: https://github.com/itsArnavPrasad/jev-folder-sort
TXT
hdiutil create -volname "jev-folder-sort $VERSION" -srcfolder "$STAGE" -ov -format UDZO -imagekey zlib-level=9 "$DMG" >/dev/null
rm -rf "$STAGE"
(cd "$(dirname "$DMG")" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
du -h "$DMG"
cat "$DMG.sha256"
