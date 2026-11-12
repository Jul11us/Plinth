#!/bin/bash
# Builds Plinth.app (release) into ./build with icon, resources and Info.plist, ad-hoc signed.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)"
APP="build/Plinth.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/FitHair" "$APP/Contents/MacOS/Plinth"
cp -R "$BIN/FitHair_FitHair.bundle" "$APP/Contents/Resources/"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp assets/AppIcon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --deep --sign - "$APP"
echo "Built $APP"
