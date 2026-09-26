#!/usr/bin/env bash
# Builds and runs the standalone unit tests for the pure logic in
# Sources/Models.swift. No SwiftPM / XCTest — just swiftc, matching the
# project's build approach. Exits non-zero if any test fails.
set -euo pipefail

# Anchor every path on the script's own directory so it works from anywhere.
cd "$(dirname "$0")"

# The test executable has to run on this Mac, so it is always built for the
# host architecture. ARCHS (build_app.sh's space-separated list) is deliberately
# ignored; set TEST_ARCH to force a specific slice.
ARCH="${TEST_ARCH:-$(uname -m)}"
TARGET="${ARCH}-apple-macos${MACOSX_DEPLOYMENT_TARGET:-27.0}"
SDK="$(xcrun --show-sdk-path --sdk macosx)"
BUILD_DIR="build"
OUT="$BUILD_DIR/nzta-tests"
MODULE_CACHE="$BUILD_DIR/test-module-cache"

mkdir -p "$BUILD_DIR" "$MODULE_CACHE"

# Language mode and upcoming features match build_app.sh and the Xcode project.
echo "Compiling tests for ${TARGET}..."
xcrun swiftc \
    -swift-version 6 \
    -enable-upcoming-feature MemberImportVisibility \
    -sdk "$SDK" \
    -target "$TARGET" \
    -module-cache-path "$MODULE_CACHE" \
    -o "$OUT" \
    Sources/Models.swift \
    Tests/TestHarness.swift \
    Tests/ModelTests.swift \
    Tests/main.swift

"./$OUT"
