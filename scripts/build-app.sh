#!/bin/bash
# Builds VolMix.app into ./build. Usage: scripts/build-app.sh [debug|release]
# Set SIGN_IDENTITY to a real certificate (e.g. "Apple Development: you@example.com")
# so macOS remembers the audio permission across rebuilds; defaults to ad-hoc signing.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/VolMix.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/VolMix" "$APP/Contents/MacOS/VolMix"
cp Support/Info.plist "$APP/Contents/Info.plist"
[ -f Support/AppIcon.icns ] || swift scripts/make-icon.swift
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"

# Install so it opens by double-click / Launchpad / Spotlight like any app.
# Uses /Applications when writable without sudo, otherwise ~/Applications.
if [ -w /Applications ]; then INSTALL_DIR=/Applications; else INSTALL_DIR="$HOME/Applications"; fi
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/VolMix.app"
ditto "$APP" "$INSTALL_DIR/VolMix.app"
echo "Installed $INSTALL_DIR/VolMix.app"
