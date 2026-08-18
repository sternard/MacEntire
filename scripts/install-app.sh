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
TEMP_INSTALL_DIR="$(mktemp -d "$INSTALL_DIR/.${PRODUCT_NAME}.install.XXXXXX")"
TEMP_APP_BUNDLE="$TEMP_INSTALL_DIR/$PRODUCT_NAME.app"
BACKUP_APP_BUNDLE="$TEMP_INSTALL_DIR/previous-$PRODUCT_NAME.app"
CONFLICTING_APP_BUNDLE="$TEMP_INSTALL_DIR/conflicting-$PRODUCT_NAME.app"
KEEP_INSTALL_RECOVERY=0

cleanup_install() {
    if [[ -e "$BACKUP_APP_BUNDLE" || "$KEEP_INSTALL_RECOVERY" == 1 ]]; then
        echo "Installation recovery retained at $TEMP_INSTALL_DIR" >&2
    else
        rm -rf "$TEMP_INSTALL_DIR"
    fi
}
trap cleanup_install EXIT

cp -R "$STAGED_APP_BUNDLE" "$TEMP_APP_BUNDLE"

plutil -lint "$TEMP_APP_BUNDLE/Contents/Info.plist" >/dev/null

INSTALL_MARKER=".macentire-install-marker.$$.$RANDOM"
touch "$TEMP_APP_BUNDLE/$INSTALL_MARKER"
HAD_INSTALLED_BUNDLE=0
if [[ -e "$APP_BUNDLE" || -L "$APP_BUNDLE" ]]; then
    mv "$APP_BUNDLE" "$BACKUP_APP_BUNDLE"
    HAD_INSTALLED_BUNDLE=1
fi

REPLACEMENT_SUCCEEDED=0
if mv "$TEMP_APP_BUNDLE" "$APP_BUNDLE"; then
    if [[ -f "$APP_BUNDLE/$INSTALL_MARKER" ]]; then
        REPLACEMENT_SUCCEEDED=1
    fi
fi

if [[ "$REPLACEMENT_SUCCEEDED" != 1 ]]; then
    if [[ -e "$APP_BUNDLE" || -L "$APP_BUNDLE" ]]; then
        if mv "$APP_BUNDLE" "$CONFLICTING_APP_BUNDLE"; then
            KEEP_INSTALL_RECOVERY=1
        else
            echo "Could not replace $APP_BUNDLE; the previous installation remains at $BACKUP_APP_BUNDLE" >&2
            exit 1
        fi
    fi
    if [[ "$HAD_INSTALLED_BUNDLE" == 1 ]]; then
        if ! mv "$BACKUP_APP_BUNDLE" "$APP_BUNDLE"; then
            KEEP_INSTALL_RECOVERY=1
            echo "Could not restore $APP_BUNDLE; the previous installation remains at $BACKUP_APP_BUNDLE" >&2
            exit 1
        fi
    fi
    echo "Could not replace $APP_BUNDLE; the previous installation was restored" >&2
    exit 1
fi

rm -f "$APP_BUNDLE/$INSTALL_MARKER"
if [[ "$HAD_INSTALLED_BUNDLE" == 1 ]]; then
    rm -rf "$BACKUP_APP_BUNDLE"
fi
rmdir "$TEMP_INSTALL_DIR"
trap - EXIT

REINSTALL_MARKER="$HOME/Library/Application Support/MacEntire/reinstall-required"
rm -f "$REINSTALL_MARKER"

echo "Installed $APP_BUNDLE"
echo "Use Start on Login in the MacEntire menu to control login startup."
open "$APP_BUNDLE"
