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
# Build the icon with Apple's own tool so Finder, the Dock and notifications accept it.
if command -v iconutil >/dev/null; then
    iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
else
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
cp -R BrowserExtension "$APP/Contents/Resources/BrowserExtension"

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
    <key>CFBundleIconName</key><string>AppIcon</string>
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

# Sign with the local identity from Scripts/make_signing_identity.sh when it
# exists: macOS then keeps the Accessibility permission across rebuilds.
# Otherwise sign ad hoc, which macOS treats as a new app after every build.
# Releases should be signed with a Developer ID and notarised instead.
IDENTITY="${SIGN_IDENTITY:-AI Runs Local Signing}"
identity_available=false
if command -v security >/dev/null; then
    if identities="$(security find-identity -p codesigning 2>/dev/null)"; then
        if grep -qF "\"$IDENTITY\"" <<< "$identities"; then identity_available=true; fi
    fi
fi
if [[ "$identity_available" == true ]]; then
    codesign --force --deep --sign "$IDENTITY" "$APP"
    echo "Signed with \"$IDENTITY\""
else
    if [[ "${REQUIRE_SIGN_IDENTITY:-0}" == "1" ]]; then
        echo "Signing identity \"$IDENTITY\" is unavailable. The installed app was left unchanged." >&2
        exit 1
    fi
    codesign --force --deep --sign - "$APP"
    echo "Signed ad hoc (run ./Scripts/make_signing_identity.sh once to keep permissions across rebuilds)"
fi

echo "Built $APP"
