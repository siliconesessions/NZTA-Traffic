#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="NZTA Traffic"
EXECUTABLE_NAME="NZTATraffic"
APP_BUNDLE="$SCRIPT_DIR/build/$APP_NAME.app"
DSYM_BUNDLE="$APP_BUNDLE.dSYM"
INFO_PLIST="$SCRIPT_DIR/Resources/Info.plist"
DIST_DIR="$SCRIPT_DIR/dist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$INFO_PLIST" 2>/dev/null || echo "1.0")"
VOLUME_NAME="NZTA Traffic $VERSION"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nzta-traffic-dmg.XXXXXX")"

cleanup() {
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

if ! command -v hdiutil >/dev/null 2>&1; then
    echo "Error: hdiutil is required to create a macOS DMG." >&2
    exit 1
fi

"$SCRIPT_DIR/build_app.sh"

# Label the DMG with the architectures actually in the binary: "arm64" for the
# default Apple-silicon build, "universal" only for an ARCHS="arm64 x86_64"
# override.
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
ARCHS="$(lipo -archs "$APP_EXECUTABLE" 2>/dev/null || uname -m)"
if [[ "$ARCHS" == *"arm64"* && "$ARCHS" == *"x86_64"* ]]; then
    ARCH_LABEL="universal"
else
    ARCH_LABEL="${ARCHS// /-}"
fi
DMG_BASENAME="NZTA-Traffic-$VERSION-macOS-$ARCH_LABEL"
DMG_NAME="$DMG_BASENAME.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"

mkdir -p "$STAGING_DIR" "$DIST_DIR"

ditto --noextattr --noqtn "$APP_BUNDLE" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

if command -v xattr >/dev/null 2>&1; then
    xattr -cr "$STAGING_DIR/$APP_NAME.app" || true
fi

if command -v codesign >/dev/null 2>&1; then
    codesign --verify --deep --strict "$STAGING_DIR/$APP_NAME.app"
    # build_app.sh signs ad-hoc with the hardened runtime (parity with Xcode's
    # Release build); refuse to package a bundle that lost it.
    SIGNATURE_INFO="$(codesign --display --verbose=2 "$STAGING_DIR/$APP_NAME.app" 2>&1)"
    if [[ "$SIGNATURE_INFO" != *"flags="*"runtime"* ]]; then
        echo "Error: staged app is not signed with the hardened runtime." >&2
        exit 1
    fi
fi

hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

echo "Created: $DMG_PATH"

# Keep the matching dSYM beside the DMG so crash reports from this exact build
# can be symbolicated (the UUIDs match the shipped binary).
if [[ -d "$DSYM_BUNDLE" ]]; then
    DSYM_ZIP="$DIST_DIR/$DMG_BASENAME.dSYM.zip"
    rm -f "$DSYM_ZIP"
    ditto -c -k --keepParent "$DSYM_BUNDLE" "$DSYM_ZIP"
    echo "dSYM:    $DSYM_ZIP"
fi
