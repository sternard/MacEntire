#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCT_NAME="MacEntire"
EXECUTABLE_NAME="MacEntire"
BUNDLE_IDENTIFIER="local.macentire"
CONFIGURATION="${CONFIGURATION:-release}"
BUILD_DIR="$ROOT_DIR/.build/$CONFIGURATION"
STAGING_DIR="$ROOT_DIR/.build/install"
STAGED_APP_BUNDLE="$STAGING_DIR/$PRODUCT_NAME.app"
INSTALL_DIR="${MACENTIRE_INSTALL_DIR:-$HOME/Applications}"
APP_BUNDLE="$INSTALL_DIR/$PRODUCT_NAME.app"
CONTENTS_DIR="$STAGED_APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

cd "$ROOT_DIR"
swift build -c "$CONFIGURATION"

rm -rf "$STAGED_APP_BUNDLE"
mkdir -p "$MACOS_DIR"
cp "$BUILD_DIR/MacEntireApp" "$MACOS_DIR/$EXECUTABLE_NAME"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$EXECUTABLE_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_IDENTIFIER</string>
    <key>CFBundleName</key>
    <string>$PRODUCT_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$PRODUCT_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>MacEntireRoot</key>
    <string></string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

plutil -replace MacEntireRoot -string "$ROOT_DIR" "$CONTENTS_DIR/Info.plist"

if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "$STAGED_APP_BUNDLE" >/dev/null
fi

mkdir -p "$INSTALL_DIR"
rm -rf "$APP_BUNDLE"
cp -R "$STAGED_APP_BUNDLE" "$APP_BUNDLE"

plutil -lint "$APP_BUNDLE/Contents/Info.plist" >/dev/null

REINSTALL_MARKER="$HOME/Library/Application Support/MacEntire/reinstall-required"
rm -f "$REINSTALL_MARKER"

echo "Installed $APP_BUNDLE"
echo "Use Start on Login in the MacEntire menu to control login startup."
open "$APP_BUNDLE"
