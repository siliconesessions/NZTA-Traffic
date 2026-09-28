#!/usr/bin/env bash
# Builds a release DMG for GitHub Releases: runs the tests, rebuilds the app
# with build_app.sh, stages it beside an Applications symlink, checks the
# signature (ad-hoc, hardened runtime), creates a compressed read-only DMG,
# verifies it, and writes a SHA-256 checksum file and the zipped dSYM beside
# it in dist/ (which is git-ignored — DMGs are published as release assets,
# not committed).
#
#   ./package_dmg.sh               # dist/NZ-Traffic-<version>-macOS-arm64.dmg
#   OVERWRITE=1 ./package_dmg.sh   # replace an existing DMG of this version
#   SKIP_TESTS=1 ./package_dmg.sh  # skip ./run_tests.sh (not for releases)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="NZ Traffic"
EXECUTABLE_NAME="NZTraffic"
APP_BUNDLE="$SCRIPT_DIR/build/$APP_NAME.app"
DSYM_BUNDLE="$APP_BUNDLE.dSYM"
INFO_PLIST="$SCRIPT_DIR/Resources/Info.plist"
DIST_DIR="$SCRIPT_DIR/dist"
# Info.plist is the single source of truth for the version. No fallback: a
# DMG named after a made-up version could overwrite a real one.
if ! VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$INFO_PLIST" 2>/dev/null)" || [[ -z "$VERSION" ]]; then
    echo "Error: couldn't read CFBundleShortVersionString from $INFO_PLIST." >&2
    exit 1
fi
VOLUME_NAME="NZ Traffic $VERSION"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nz-traffic-dmg.XXXXXX")"

cleanup() {
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

if ! command -v hdiutil >/dev/null 2>&1; then
    echo "Error: hdiutil is required to create a macOS DMG." >&2
    exit 1
fi

if [[ "${SKIP_TESTS:-0}" != "1" ]]; then
    "$SCRIPT_DIR/run_tests.sh"
else
    echo "Warning: SKIP_TESTS=1 — packaging without running the tests." >&2
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
DMG_BASENAME="NZ-Traffic-$VERSION-macOS-$ARCH_LABEL"
DMG_NAME="$DMG_BASENAME.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"
CHECKSUM_PATH="$DMG_PATH.sha256"

if [[ -e "$DMG_PATH" && "${OVERWRITE:-0}" != "1" ]]; then
    echo "Error: $DMG_PATH already exists. Bump the version in Resources/Info.plist, or set OVERWRITE=1 to replace it." >&2
    exit 1
fi

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

# ULMO (LZMA) is about a quarter smaller than UDZO and opens on macOS 10.15+,
# far below the app's own minimum.
rm -f "$DMG_PATH" "$CHECKSUM_PATH"
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING_DIR" \
    -format ULMO \
    "$DMG_PATH"

hdiutil verify "$DMG_PATH"

# "<hash>  <file name>", so `shasum -a 256 -c <file>.sha256` works from the
# folder the DMG is downloaded to.
(cd "$DIST_DIR" && shasum -a 256 "$DMG_NAME" > "$CHECKSUM_PATH")

echo "Created: $DMG_PATH"
echo "SHA-256: $CHECKSUM_PATH ($(cut -d ' ' -f 1 "$CHECKSUM_PATH"))"

# Keep the matching dSYM beside the DMG so crash reports from this exact build
# can be symbolicated (the UUIDs match the shipped binary).
if [[ -d "$DSYM_BUNDLE" ]]; then
    DSYM_ZIP="$DIST_DIR/$DMG_BASENAME.dSYM.zip"
    rm -f "$DSYM_ZIP"
    ditto -c -k --keepParent "$DSYM_BUNDLE" "$DSYM_ZIP"
    echo "dSYM:    $DSYM_ZIP"
fi
