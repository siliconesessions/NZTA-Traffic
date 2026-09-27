#!/usr/bin/env bash
# Builds and runs the standalone unit tests. They cover the Foundation-level
# layers — the models (Models.swift), app identity and migration
# (AppIdentity.swift), the refresh policy (RefreshPolicy.swift), the views'
# Foundation-only logic (ViewLogic.swift, MapClustering.swift), and the API
# client, offline cache and store (TrafficAPIService.swift, OfflineCache.swift,
# TrafficStore.swift) against an in-process stub network and temporary cache
# folders. No SwiftPM / XCTest — just swiftc, matching the project's build
# approach. The SwiftUI/AppKit layer isn't compiled. Exits non-zero if any
# test fails.
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
OUT="$BUILD_DIR/nz-traffic-tests"
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
    Sources/AppIdentity.swift \
    Sources/RefreshPolicy.swift \
    Sources/OfflineCache.swift \
    Sources/TrafficAPIService.swift \
    Sources/TrafficStore.swift \
    Sources/ViewLogic.swift \
    Sources/MapClustering.swift \
    Tests/TestHarness.swift \
    Tests/StubNetwork.swift \
    Tests/ModelTests.swift \
    Tests/EventFilterTests.swift \
    Tests/JourneyGeometryTests.swift \
    Tests/IdentityTests.swift \
    Tests/RefreshPolicyTests.swift \
    Tests/NetworkTests.swift \
    Tests/StoreTests.swift \
    Tests/ViewLogicTests.swift \
    Tests/MapClusteringTests.swift \
    Tests/main.swift

# Run with a throwaway home folder, so nothing the frameworks might persist
# (preferences, caches) can reach the real ~/Library. The tests themselves use
# in-memory values, a stubbed URLSession and temporary cache folders.
TEST_HOME="$BUILD_DIR/test-home"
rm -rf "$TEST_HOME"
mkdir -p "$TEST_HOME"
CFFIXED_USER_HOME="$PWD/$TEST_HOME" "./$OUT"
