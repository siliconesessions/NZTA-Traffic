#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="NZTA Traffic"
EXECUTABLE_NAME="NZTATraffic"
BUILD_DIR="$SCRIPT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
INFO_PLIST="$SCRIPT_DIR/Resources/Info.plist"
ICON_FILE="$SCRIPT_DIR/Resources/NZTATraffic.icns"
ARCHS="${ARCHS:-arm64 x86_64}"
MIN_MACOS="${MACOSX_DEPLOYMENT_TARGET:-15.0}"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
MODULE_CACHE="${TMPDIR:-/tmp}/nzta-traffic-mac-module-cache"
CLANG_MODULE_CACHE="${TMPDIR:-/tmp}/nzta-traffic-mac-clang-cache"

rm -rf "$APP_BUNDLE" "$MODULE_CACHE" "$CLANG_MODULE_CACHE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$MODULE_CACHE" "$CLANG_MODULE_CACHE"

read -r -a ARCH_ARRAY <<< "$ARCHS"
ARCH_BINARIES=()

if [[ "${#ARCH_ARRAY[@]}" -gt 1 ]] && ! command -v lipo >/dev/null 2>&1; then
    echo "Error: lipo is required for a multi-architecture build." >&2
    exit 1
fi

for ARCH in "${ARCH_ARRAY[@]}"; do
    ARCH_BINARY="$BUILD_DIR/$EXECUTABLE_NAME-$ARCH"
    ARCH_MODULE_CACHE="$MODULE_CACHE/$ARCH"
    ARCH_CLANG_MODULE_CACHE="$CLANG_MODULE_CACHE/$ARCH"

    mkdir -p "$ARCH_MODULE_CACHE" "$ARCH_CLANG_MODULE_CACHE"

    echo "Building $APP_NAME for $ARCH-apple-macos$MIN_MACOS"

    swiftc \
        -swift-version 5 \
        -O \
        -target "$ARCH-apple-macos$MIN_MACOS" \
        -sdk "$SDK_PATH" \
        -module-cache-path "$ARCH_MODULE_CACHE" \
        -Xcc -fmodules-cache-path="$ARCH_CLANG_MODULE_CACHE" \
        "$SCRIPT_DIR"/Sources/*.swift \
        -o "$ARCH_BINARY"

    ARCH_BINARIES+=("$ARCH_BINARY")
done

if [[ "${#ARCH_BINARIES[@]}" -eq 1 ]]; then
    mv "${ARCH_BINARIES[0]}" "$MACOS_DIR/$EXECUTABLE_NAME"
else
    lipo -create "${ARCH_BINARIES[@]}" -output "$MACOS_DIR/$EXECUTABLE_NAME"
    rm -f "${ARCH_BINARIES[@]}"
fi

cp "$INFO_PLIST" "$CONTENTS_DIR/Info.plist"
if [[ -f "$ICON_FILE" ]]; then
    cp "$ICON_FILE" "$RESOURCES_DIR/NZTATraffic.icns"
fi
chmod +x "$MACOS_DIR/$EXECUTABLE_NAME"

if command -v xattr >/dev/null 2>&1; then
    xattr -cr "$APP_BUNDLE" || true
fi

if command -v codesign >/dev/null 2>&1; then
    if codesign --force --sign - "$APP_BUNDLE" >/dev/null 2>&1; then
        echo "Ad-hoc signed app bundle."
    else
        echo "Warning: codesign failed; leaving unsigned app bundle."
    fi
fi

echo "Built: $APP_BUNDLE"
