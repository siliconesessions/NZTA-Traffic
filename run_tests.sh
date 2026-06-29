#!/bin/sh
# Builds and runs the standalone unit tests for the pure logic in
# Sources/Models.swift. No SwiftPM / XCTest — just swiftc, matching the
# project's build approach. Exits non-zero if any test fails.
set -e

ARCH="${ARCHS:-$(uname -m)}"
TARGET="${ARCH}-apple-macos${MACOSX_DEPLOYMENT_TARGET:-15.0}"
SDK="$(xcrun --show-sdk-path --sdk macosx)"
OUT="build/nzta-tests"

mkdir -p build

echo "Compiling tests for ${TARGET}..."
xcrun swiftc \
    -sdk "$SDK" \
    -target "$TARGET" \
    -o "$OUT" \
    Sources/Models.swift \
    Tests/TestHarness.swift \
    Tests/ModelTests.swift \
    Tests/main.swift

"./$OUT"
