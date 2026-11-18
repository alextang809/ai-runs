#!/usr/bin/env bash
# Builds AI Runs, replaces /Applications/AI Runs.app with it, and opens it.
# Keeps a single copy, so macOS has one app to attach permissions to.
#
#   ./Scripts/install_local.sh
set -euo pipefail
cd "$(dirname "$0")/.."

./Scripts/package_app.sh

osascript -e 'quit app "AI Runs"' >/dev/null 2>&1 || true
pkill -x AIRuns >/dev/null 2>&1 || true
sleep 1

rm -rf "/Applications/AI Runs.app"
ditto "build/AI Runs.app" "/Applications/AI Runs.app"
rm -rf "build/AI Runs.app"

open "/Applications/AI Runs.app"
echo "Installed /Applications/AI Runs.app"
