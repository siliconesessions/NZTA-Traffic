# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Native SwiftUI macOS app (deployment target **macOS 27.0**, Apple silicon / `arm64` only, **Swift 6 language mode**) for live NZ Transport Agency traffic cameras, road events, VMS signs, and travel times. No package manager, no analytics, no backend — just `swiftc` against the macOS SDK plus an Xcode project that points at the same sources. Model-layer unit tests run via `./run_tests.sh` (a standalone swiftc executable, no SwiftPM/XCTest). Don't add `#available` / `@available` gates for anything macOS 27 already has.

## Build / run

Two parallel build paths exist; both must keep working:

- **Xcode**: `NZTraffic.xcodeproj` (objectVersion 77), shared scheme `NZ Traffic`. `Sources/` is a **file-system synchronized folder** attached to the app target, so any `.swift` file dropped into `Sources/` (flat, matching `build_app.sh`'s `Sources/*.swift` glob) joins the build automatically — no pbxproj edit needed. Keep non-source files out of `Sources/` (a synchronized folder would bundle them as resources). `Resources/Info.plist` and `Resources/NZTraffic.icns` are explicit references; `Tests/` is a synchronized folder with **no** target membership (navigator only), and `CLAUDE.md` / `README.md` / the scripts are navigator-only file references.
- **Shell**: `./build_app.sh` — invokes `swiftc` directly (no SwiftPM), produces `build/NZ Traffic.app` plus a matching `build/NZ Traffic.app.dSYM`. `arm64` only by default; `ARCHS` still takes a space-separated list (e.g. `ARCHS="arm64 x86_64"` for a lipo'd universal binary + merged dSYM). `MACOSX_DEPLOYMENT_TARGET` overrides the min OS (default `27.0`) and is also stamped into the bundled Info.plist's `LSMinimumSystemVersion`, so the Mach-O `minos` and the plist always agree.

The two paths are kept equivalent to the Xcode Release configuration: Swift 6 language mode + `MemberImportVisibility` upcoming feature, `-O` with whole-module optimisation, debug info → dSYM, dead-code stripping, deployment target 27.0, `arm64`, and an ad-hoc signature **with the hardened runtime** (`codesign --options runtime --sign -`). Remaining differences: Xcode's Info.plist processing adds the `DT*` / `BuildMachineOSBuild` / `CFBundleSupportedPlatforms` keys and uses explicit module builds; the DMG still packages the `build_app.sh` output. Neither path is notarized (ad-hoc signatures can't be) — distribution is ad-hoc signed DMGs on GitHub Releases. If you change a compiler flag or deployment setting, change it in `build_app.sh`, `run_tests.sh` **and** the pbxproj.

Concurrency settings are deliberate: Swift 6 strict checking is on, but **Approachable Concurrency is off** (`SWIFT_APPROACHABLE_CONCURRENCY = NO`) and default actor isolation stays `nonisolated` (no `SWIFT_DEFAULT_ACTOR_ISOLATION`). The async entry points in `TrafficAPIService` are `@concurrent` so decoding stays off the main actor even if that changes; keep new async fetch/decode helpers `@concurrent` too.

CLI release build:

```sh
xcodebuild -project NZTraffic.xcodeproj -scheme "NZ Traffic" -configuration Release -destination 'generic/platform=macOS' build
```

`./package_dmg.sh` rebuilds via `build_app.sh`, stages with an `Applications` symlink, checks the staged signature (including the hardened-runtime flag), and emits `dist/NZ-Traffic-<version>-macOS-arm64.dmg` (the arch label comes from the built binary; a universal override is labelled `universal`) plus a matching `…dSYM.zip` for symbolicating crash reports. `Resources/Info.plist` is the **single source of truth** for `CFBundleShortVersionString` and `CFBundleVersion` — bump both there. The pbxproj deliberately has no `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`, so editing the version in Xcode's General tab is not the way to do it.

Run the built app: `open "build/NZ Traffic.app"`.

### Tests

`./run_tests.sh` compiles `Sources/Models.swift` and `Sources/AppIdentity.swift` (both Foundation-only) plus `Tests/*.swift` into a standalone executable and runs it (exits non-zero on failure). It can be run from any directory, uses the same Swift 6 / `MemberImportVisibility` flags as the app, always builds for the host architecture (`ARCHS` is ignored; `TEST_ARCH` forces a slice), and prints each test group name to stderr so a trap is easy to locate. Tests cover the pure model logic only — lossy decoders, coordinate validation, WKT parsing, VMS message formatting, NZ date parsing/formatting, and `matches(region:highway:search:)`. They deliberately avoid SwiftPM/XCTest and do **not** compile the SwiftUI layer, so keep `Models.swift` free of `SwiftUI`/`AppKit` imports (Foundation, CoreLocation and Synchronization are fine). Tests must never read or write the real user's defaults or Application Support — use pure in-memory seams (e.g. `DiagnosticsReport.collectPreferences(from: [String: Any])`). `Tests/` is not part of either app build path; new test files must be added to the `swiftc` invocation in `run_tests.sh`.

## Architecture

Six Swift files under `Sources/`, organized by layer not feature:

- `NZTrafficApp.swift` — `@main` entry, `WindowGroup` + secondary `Window(id: "help")` + a `Settings` scene (`SettingsView`, ⌘,), and `NZTrafficCommands` which replaces the standard About panel and Help menu items. `init()` installs a bounded shared `URLCache`.
- `TrafficAPIService.swift` — thin `URLSession` wrapper over four NZTA REST v4 endpoints (`/cameras/all`, `/events/all/10`, `/signs/vms/all`, `/journeys/all/10`) at `https://trafficnz.info/service/traffic/rest/4`. Uses a configured session (timeouts, `waitsForConnectivity`) and retries transient/5xx failures with exponential backoff (`isRetriable`). Each fetch has a `…Result()` variant (`@concurrent`, so decode always runs off the main actor) that converts throws to `Result` so the store can surface per-section errors without one failure killing the others.
- `TrafficStore.swift` — `@Observable @MainActor` class holding cameras / events / VMS / journeys / per-section loading state / per-section errors / `lastUpdated` / `imageCacheToken` / reachability (`isOnline`) + offline-cache state (`isServingCachedData`, `cacheTimestamp`). `loadAllData(bustImageCache:)` fans out the four fetches concurrently with `async let` and applies them independently; a failed section keeps its last-known-good data. `imageCacheToken` is bumped **only on an explicit user refresh** (not auto-refresh) and appended to camera image URLs to bust the cache. `filtered*` results are memoized behind a `FilterKey` cache (`@ObservationIgnored`), cleared when section data changes. Also owns the `OfflineCache` actor (see the offline-cache exception below) and an `NWPathMonitor` (Network framework) whose updates set `isOnline` back on the main actor. `TrafficStore(service:cache:)` takes both dependencies; `OfflineCache(directory: nil)` is a no-op cache.
- `PreviewSupport.swift` — `#if DEBUG` only. `TrafficStore.preview()` returns a store whose `URLSession` is answered in-process by `PreviewURLProtocol` (small canned fixtures per endpoint, no image URLs) with a disabled `OfflineCache`, so `#Preview`s never hit the network or the user's real cache. Previews must use it rather than a live `TrafficStore()`.
- `Models.swift` — all decodable types plus payload wrappers (`CamerasPayload` → `CameraResponse` → `[TrafficCamera]`, etc., matching the NZTA JSON shape). Helpers `cleanText(_:)`, `formatVMSMessage(_:)`, and the `KeyedDecodingContainer` extension at the bottom (`decodeLossyString`, `decodeLossyDouble`, `decodeLossyInt`) exist because the upstream API is loose-typed (numbers as strings, missing fields, embedded display-control tokens). New decoded fields should reuse these helpers rather than calling `decode` directly. Keep this file free of `SwiftUI`/`AppKit` so the test runner can compile it standalone.
- `Theme.swift` — design tokens (`Spacing`, `Radii`, and semantic `Color` extensions for the VMS palette + card stroke). Prefer these over scattered literals.
- `Views.swift` — `ContentView` (header / global filter bar / native `TabView` with per-tab scoped filter bars), one view per `TrafficTab` (`CamerasTabView`, `RoadEventsTabView`, `VMSTabView`, `TravelTimesTabView`, `TrafficMapTabView`, `AboutView`), `SettingsView`, the `AppHelpView` shown in the secondary window, and shared chrome (`ErrorBanner`, `LoadingView`, `FilterableEmptyState` (a `ContentUnavailableView`), `Badge`, `StatCard`).

### Data flow

`ContentView` owns the single `TrafficStore` and the three filter strings (region / highway / search), then asks the store for filtered/sorted slices per tab via `filteredCameras`/`filteredEvents`/`filteredVMSSigns`. Filtering and sorting live in the store, not in the views — when extending filters, add the predicate to the shared `matches(region:highway:search:)` (the `TrafficFilterable` protocol extension in `Models.swift`) and to the relevant store accessor, and add any new input to the store's `FilterKey` so the memoized results stay correct.

- **Highway filter** matches whole highways, not substrings: `canonicalHighwayKey` maps "SH1" / "SH 1" / "State Highway 1" / "01N" / "SH1N" / "1" to the key "1" (spurs such as "1B" / "20A" stay distinct), and each model precomputes `highwayKeys` at decode time from its structured highway/journey/way fields plus "SH n" mentions in its own name/location text (not comments, detours or TIM destinations). A query that isn't a highway falls back to a whole-word match on `highwayHaystack`. Free-text search stays a substring match.
- **Road event status** is parsed into `EventStatus` (active / scheduled / resolved / unknown-raw; unknown counts as active). Only `isActiveClosure` feeds the Dock badge, the menu bar "Active closures" and the red map pins; Scheduled events show as "Upcoming"; Resolved events are hidden everywhere unless `@AppStorage("nzta.showResolvedEvents")` is on.

The map tab (`TrafficMapTabView`) consumes the same filtered slices and renders them through a `TrafficMapLayer` enum (cameras / events / vms) using MapKit. Coordinate parsing lives on each model as `mapCoordinate` — features without coordinates are silently dropped from the map and counted as `unmappedCount`.

### Refresh model

Manual refresh: ⌘R or the toolbar button calls `store.loadAllData(bustImageCache: true)` (forces fresh camera images). Auto-refresh: `@AppStorage("nzta.autoRefreshEnabled")` and `@AppStorage("nzta.refreshIntervalSeconds")` (clamped 30–600) drive a `Task` loop in `ContentView.configureAutoRefresh()` that calls `loadAllData()` (no cache bust — relies on `URLCache` + HTTP revalidation). Toggling either `@AppStorage` value (from the filter bar menu or the Settings window) cancels and reschedules the task — don't bypass `configureAutoRefresh`.

### Offline cache (deliberate exception to "no caching layer")

The four primary sections (cameras / events / vms / journeys) are persisted to disk for offline use — a deliberate, documented exception to the "no caching layer" convention below. How it works:

- The cacheable fetchers in `TrafficAPIService` return `(value, data)` so the store gets both the decoded models **and** the raw response bytes. The store persists the **raw JSON bytes** (not re-encoded models — the models have derived stored fields and `CodingKeys` that are a strict subset, so they don't round-trip via `Encodable`). On replay the bytes go back through the same `CamerasPayload`/etc. wrappers (`decodeCached*`), preserving every derived field.
- `OfflineCache` (an `actor` at the bottom of `TrafficStore.swift`) does all file IO off the main actor, writing one `<section>.json` per section under `Application Support/NZTraffic/OfflineCache/`. Every operation is best-effort and silently no-ops on failure.
- `ContentView.task` calls `store.primeFromCache()` (fills empty sections from disk on launch) before `loadAllData()`. On a fetch failure the store falls back to the cached copy and marks the section cache-served; on success it overwrites both memory and disk.
- `store.shouldShowOfflineBanner` (`!isOnline || isServingCachedData`) drives the `OfflineBanner` rendered under the header in `ContentView`. Normal online behaviour is unchanged apart from the background cache writes.

## Conventions worth knowing

- The NZTA API is the only data source. There is no proxy and no auth. The **one** persistence exception is the offline cache described under "Refresh model" above (raw section JSON in Application Support); don't add other caching layers without reason.
- VMS message strings arrive with embedded display-control tokens; always run them through `formatVMSMessage` before showing.
- String/number fields from the API can be either type or absent — go through `decodeLossyString` / `decodeLossyDouble` and `cleanText`, not the raw `decode` calls.
- Errors are per-section by design (`store.errors[.cameras]` etc.) and rendered via `ErrorBanner` inside each tab. A failed fetch records the error but **keeps the section's last-known-good data** (it no longer zeroes the array), so other sections — and stale data — stay intact.
- Camera image URLs are suffixed with `?t=\(store.imageCacheToken)`; the token only changes on an explicit refresh, so auto-refresh reuses the bounded `URLCache` and revalidates via HTTP rather than re-downloading every image.
- New decoded fields and parsing logic should get a case in `Tests/ModelTests.swift`; run `./run_tests.sh` before committing model changes.
