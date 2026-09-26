#!/bin/bash
# Build JevFolderSort.app.
#   scripts/build_app.sh            development build: runs the engine from this repo's engine/
#   scripts/build_app.sh --release  self-contained: embeds build/engine (run scripts/bundle_engine.sh first)
# Signing: ad-hoc by default. Set SIGN_IDENTITY="Developer ID Application: …" for a notarizable build
# (see scripts/notarize.sh).
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP="$REPO/build/JevFolderSort.app"
VERSION="$(cat "$REPO/VERSION")"
RELEASE=0
[[ "${1:-}" == "--release" ]] && RELEASE=1
IDENTITY="${SIGN_IDENTITY:--}"

cd "$REPO/app"
swift build -c release --product JevFolderSort
BIN="$(swift build -c release --show-bin-path)/JevFolderSort"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/JevFolderSort"
cp "$REPO/app/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
DEV_KEY=""
if [[ $RELEASE == 0 ]]; then
  DEV_KEY="<key>JEVEngineDirectory</key><string>$REPO/engine</string>"
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>jev-folder-sort</string>
    <key>CFBundleDisplayName</key><string>jev-folder-sort</string>
    <key>CFBundleIdentifier</key><string>dev.jevfoldersort.app</string>
    <key>CFBundleExecutable</key><string>JevFolderSort</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSArchitecturePriority</key><array><string>arm64</string></array>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>Apache-2.0 · github.com/itsArnavPrasad/jev-folder-sort</string>
    <key>NSDesktopFolderUsageDescription</key><string>jev-folder-sort sorts files on your Desktop into the folders you choose.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>jev-folder-sort sorts files in Downloads into the folders you choose.</string>
    <key>NSDocumentsFolderUsageDescription</key><string>jev-folder-sort moves files into the destination folders you choose in Documents.</string>
    $DEV_KEY
</dict>
</plist>
PLIST

SIGN_ARGS=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" != "-" ]]; then
  SIGN_ARGS+=(--options runtime --timestamp)
fi

if [[ $RELEASE == 1 ]]; then
  [[ -x "$REPO/build/engine/python/bin/python3" ]] || { echo "run scripts/bundle_engine.sh first"; exit 1; }
  echo "==> Embedding engine"
  rsync -a "$REPO/build/engine/" "$APP/Contents/Resources/engine/"
  echo "==> Signing embedded code (inside-out)"
  ENT="$REPO/scripts/engine.entitlements"
  find "$APP/Contents/Resources/engine" -type f \( -name "*.dylib" -o -name "*.so" \) -print0 \
    | xargs -0 -n 50 codesign "${SIGN_ARGS[@]}" 2>/dev/null
  for exe in "$APP/Contents/Resources/engine/python/bin/python3.12" "$APP/Contents/Resources/engine/site-packages/torch/bin/torch_shm_manager"; do
    [[ -f "$exe" ]] && codesign "${SIGN_ARGS[@]}" --entitlements "$ENT" "$exe"
  done
fi
codesign "${SIGN_ARGS[@]}" --entitlements "$REPO/scripts/app.entitlements" "$APP"
codesign --verify --strict "$APP" && echo "Signature OK ($IDENTITY)"
du -sh "$APP"
echo "Built $APP"
