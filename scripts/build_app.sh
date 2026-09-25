#!/bin/bash
# Build JevFolderSort.app (development build: the app runs the engine from this
# repo's engine/ folder; bundling Python + weights is milestone M8).
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP="$REPO/build/JevFolderSort.app"
VERSION="0.1.0"

cd "$REPO/app"
swift build -c release --product JevFolderSort
BIN="$(swift build -c release --show-bin-path)/JevFolderSort"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/JevFolderSort"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>jev-folder-sort</string>
    <key>CFBundleDisplayName</key><string>jev-folder-sort</string>
    <key>CFBundleIdentifier</key><string>dev.jevfoldersort.app</string>
    <key>CFBundleExecutable</key><string>JevFolderSort</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>Apache-2.0</string>
    <key>NSDesktopFolderUsageDescription</key><string>jev-folder-sort sorts files on your Desktop into the folders you choose.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>jev-folder-sort sorts files in Downloads into the folders you choose.</string>
    <key>NSDocumentsFolderUsageDescription</key><string>jev-folder-sort moves files into the destination folders you choose in Documents.</string>
    <key>JEVEngineDirectory</key><string>$REPO/engine</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
