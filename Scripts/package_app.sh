#!/usr/bin/env bash
# Builds "AI Runs.app" into ./build from the Swift package.
#
#   ./Scripts/package_app.sh            release build
#   CONFIG=debug ./Scripts/package_app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
VERSION="$(cat VERSION 2>/dev/null || echo 0.1.0)"
BUNDLE_ID="${BUNDLE_ID:-io.github.alextang809.airuns}"

swift build -c "$CONFIG" --product AIRuns
swift build -c "$CONFIG" --product airuns-hook
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/AI Runs.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/AIRuns" "$APP/Contents/MacOS/AIRuns"
cp "$BIN/airuns-hook" "$APP/Contents/MacOS/airuns-hook"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>AIRuns</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>AI Runs</string>
    <key>CFBundleDisplayName</key><string>AI Runs</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>AI Runs uses Apple Events to bring the right Terminal or iTerm2 tab to the front, and to read the title and address of a browser tab you pin.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature so macOS will launch it locally. Releases should be signed
# with a Developer ID and notarised instead.
codesign --force --deep --sign - "$APP"

echo "Built $APP"
