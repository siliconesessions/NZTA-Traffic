#!/usr/bin/env bash
set -euo pipefail

# Shell build path. Kept equivalent to the Xcode project's Release
# configuration: Swift 6 language mode, -O with whole-module optimisation,
# debug info + dSYM, dead-code stripping, the same deployment target, and an
# ad-hoc signature with the hardened runtime. (Neither path is notarized.)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="NZ Traffic"
EXECUTABLE_NAME="NZTraffic"
BUILD_DIR="$SCRIPT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
DSYM_BUNDLE="$APP_BUNDLE.dSYM"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
INFO_PLIST="$SCRIPT_DIR/Resources/Info.plist"
# Icon Composer icon, compiled by actool into Assets.car (plus an AppIcon.icns
# fallback); actool also supplies CFBundleIconName / CFBundleIconFile.
APP_ICON="$SCRIPT_DIR/Resources/AppIcon.icon"
# Apple silicon only by default (macOS 27 is arm64-only). ARCHS still accepts a
# space-separated list, e.g. ARCHS="arm64 x86_64" for a lipo'd binary.
ARCHS="${ARCHS:-arm64}"
MIN_MACOS="${MACOSX_DEPLOYMENT_TARGET:-27.0}"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
MODULE_CACHE="${TMPDIR:-/tmp}/nz-traffic-module-cache"
CLANG_MODULE_CACHE="${TMPDIR:-/tmp}/nz-traffic-clang-cache"
ARCH_BUILD_DIR="$BUILD_DIR/arch"

rm -rf "$APP_BUNDLE" "$DSYM_BUNDLE" "$ARCH_BUILD_DIR" "$MODULE_CACHE" "$CLANG_MODULE_CACHE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$MODULE_CACHE" "$CLANG_MODULE_CACHE"

read -r -a ARCH_ARRAY <<< "$ARCHS"
ARCH_BINARIES=()
ARCH_DWARF_FILES=()

if [[ "${#ARCH_ARRAY[@]}" -gt 1 ]] && ! command -v lipo >/dev/null 2>&1; then
    echo "Error: lipo is required for a multi-architecture build." >&2
    exit 1
fi

for ARCH in "${ARCH_ARRAY[@]}"; do
    ARCH_OUT_DIR="$ARCH_BUILD_DIR/$ARCH"
    ARCH_BINARY="$ARCH_OUT_DIR/$EXECUTABLE_NAME"
    ARCH_MODULE_CACHE="$MODULE_CACHE/$ARCH"
    ARCH_CLANG_MODULE_CACHE="$CLANG_MODULE_CACHE/$ARCH"

    mkdir -p "$ARCH_OUT_DIR" "$ARCH_MODULE_CACHE" "$ARCH_CLANG_MODULE_CACHE"

    echo "Building $APP_NAME for $ARCH-apple-macos$MIN_MACOS"

    # -g makes the swift driver run dsymutil, leaving $ARCH_BINARY.dSYM beside
    # the binary. Flags mirror the Xcode Release configuration (SWIFT_VERSION,
    # SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY, wholemodule, -O,
    # DEAD_CODE_STRIPPING). swiftc runs from inside the per-arch directory
    # because with -wmo -g the driver writes the debugger's .swiftmodule /
    # .swiftdoc / .abi.json to the *current* directory; this keeps them out of
    # the caller's cwd (e.g. the repo root) and they go when arch/ is removed.
    (
        cd "$ARCH_OUT_DIR"
        swiftc \
            -swift-version 6 \
            -enable-upcoming-feature MemberImportVisibility \
            -O \
            -whole-module-optimization \
            -g \
            -target "$ARCH-apple-macos$MIN_MACOS" \
            -sdk "$SDK_PATH" \
            -module-cache-path "$ARCH_MODULE_CACHE" \
            -Xcc -fmodules-cache-path="$ARCH_CLANG_MODULE_CACHE" \
            -Xlinker -dead_strip \
            "$SCRIPT_DIR"/Sources/*.swift \
            -o "$ARCH_BINARY"
    )

    ARCH_BINARIES+=("$ARCH_BINARY")
    ARCH_DWARF_FILES+=("$ARCH_BINARY.dSYM/Contents/Resources/DWARF/$EXECUTABLE_NAME")
done

# Assemble the executable and a matching dSYM (Xcode's "<App>.app.dSYM" layout)
# for symbolicating crash reports from this exact build.
FIRST_ARCH_DIR="$ARCH_BUILD_DIR/${ARCH_ARRAY[0]}"
if [[ "${#ARCH_BINARIES[@]}" -eq 1 ]]; then
    mv "${ARCH_BINARIES[0]}" "$MACOS_DIR/$EXECUTABLE_NAME"
    mv "$FIRST_ARCH_DIR/$EXECUTABLE_NAME.dSYM" "$DSYM_BUNDLE"
else
    lipo -create "${ARCH_BINARIES[@]}" -output "$MACOS_DIR/$EXECUTABLE_NAME"
    # Merge the per-arch DWARF into one universal file before moving the first
    # arch's dSYM bundle into place (its DWARF is one of the lipo inputs).
    lipo -create "${ARCH_DWARF_FILES[@]}" -output "$ARCH_BUILD_DIR/$EXECUTABLE_NAME.dwarf"
    mv "$FIRST_ARCH_DIR/$EXECUTABLE_NAME.dSYM" "$DSYM_BUNDLE"
    mv "$ARCH_BUILD_DIR/$EXECUTABLE_NAME.dwarf" "$DSYM_BUNDLE/Contents/Resources/DWARF/$EXECUTABLE_NAME"
fi
rm -rf "$ARCH_BUILD_DIR"
# The dSYM now holds the debug info; drop the executable's debug map (STABS
# entries naming this machine's build paths) so it isn't shipped. The UUID
# is unchanged, so the dSYM still matches.
strip -S "$MACOS_DIR/$EXECUTABLE_NAME"

# Info.plist is the single source of truth for the version numbers. Its
# LSMinimumSystemVersion is $(MACOSX_DEPLOYMENT_TARGET), which Xcode expands;
# stamp it here from the same MIN_MACOS the binary was built for, so a
# MACOSX_DEPLOYMENT_TARGET override can't produce a bundle whose plist and
# Mach-O minimum OS disagree.
cp "$INFO_PLIST" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $MIN_MACOS" "$CONTENTS_DIR/Info.plist"
# Compile the Icon Composer icon the way Xcode does for the target's
# ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon: Assets.car (the layered icon)
# and AppIcon.icns into Resources/, and a partial Info.plist carrying
# CFBundleIconName / CFBundleIconFile, merged into the bundle's plist.
# actool's full report goes to build/actool.log; its warnings and errors are
# echoed so an icon problem isn't silently lost.
ICON_PARTIAL_PLIST="$BUILD_DIR/AppIcon-partial.plist"
ACTOOL_LOG="$BUILD_DIR/actool.log"
rm -f "$ICON_PARTIAL_PLIST"
if ! xcrun actool "$APP_ICON" \
    --compile "$RESOURCES_DIR" \
    --platform macosx \
    --minimum-deployment-target "$MIN_MACOS" \
    --app-icon AppIcon \
    --output-partial-info-plist "$ICON_PARTIAL_PLIST" \
    --output-format human-readable-text \
    --errors --warnings --notices >"$ACTOOL_LOG" 2>&1; then
    cat "$ACTOOL_LOG" >&2
    echo "Error: actool failed; see $ACTOOL_LOG." >&2
    exit 1
fi
grep -iE "warning|error" "$ACTOOL_LOG" >&2 || true
if [[ ! -f "$RESOURCES_DIR/Assets.car" || ! -f "$ICON_PARTIAL_PLIST" ]]; then
    echo "Error: actool did not compile $APP_ICON." >&2
    exit 1
fi
/usr/libexec/PlistBuddy -c "Merge $ICON_PARTIAL_PLIST" "$CONTENTS_DIR/Info.plist" >/dev/null
rm -f "$ICON_PARTIAL_PLIST"
chmod +x "$MACOS_DIR/$EXECUTABLE_NAME"

if command -v xattr >/dev/null 2>&1; then
    xattr -cr "$APP_BUNDLE" || true
fi

# Ad-hoc signature with the hardened runtime, matching the Xcode target's
# ENABLE_HARDENED_RUNTIME = YES. This is parity only: an ad-hoc signature can't
# be notarized, so Gatekeeper still treats a downloaded copy as unidentified.
# In a folder synced by a File Provider (e.g. iCloud Drive) the provider can
# re-add com.apple.FinderInfo between `xattr -cr` and codesign, which then
# refuses to sign ("resource fork, Finder information, or similar detritus");
# strip and retry once, and fail the build rather than ship an unsigned app.
if command -v codesign >/dev/null 2>&1; then
    sign_app() {
        codesign --force --options runtime --sign - "$APP_BUNDLE" >/dev/null 2>&1
    }
    if ! sign_app; then
        command -v xattr >/dev/null 2>&1 && { xattr -cr "$APP_BUNDLE" || true; }
        if ! sign_app; then
            codesign --force --options runtime --sign - "$APP_BUNDLE" >&2 || true
            echo "Error: codesign failed; the app bundle is not signed." >&2
            exit 1
        fi
    fi
    echo "Ad-hoc signed app bundle (hardened runtime)."
fi

echo "Built: $APP_BUNDLE"
echo "dSYM:  $DSYM_BUNDLE"
