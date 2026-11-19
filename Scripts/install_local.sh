#!/usr/bin/env bash
# Builds AI Runs, replaces /Applications/AI Runs.app with it, and opens it.
# Keeps a single copy, so macOS has one app to attach permissions to.
#
#   ./Scripts/install_local.sh
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${SIGN_IDENTITY:-AI Runs Local Signing}"
if ! identities="$(security find-identity -p codesigning 2>/dev/null)"; then
    echo "Could not inspect signing identities. The installed app was left unchanged." >&2
    exit 1
fi
if ! grep -qF "\"$IDENTITY\"" <<< "$identities"; then
    echo "Signing identity \"$IDENTITY\" is unavailable. Run ./Scripts/make_signing_identity.sh before installing." >&2
    exit 1
fi

SIGN_IDENTITY="$IDENTITY" REQUIRE_SIGN_IDENTITY=1 ./Scripts/package_app.sh
codesign --verify --deep --strict "build/AI Runs.app"

osascript -e 'quit app "AI Runs"' >/dev/null 2>&1 || true
pkill -x AIRuns >/dev/null 2>&1 || true
sleep 1

rm -rf "/Applications/AI Runs.app"
ditto "build/AI Runs.app" "/Applications/AI Runs.app"
rm -rf "build/AI Runs.app"

open "/Applications/AI Runs.app"
echo "Installed /Applications/AI Runs.app"
