# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Native SwiftUI macOS app (10.15+ deployment target is **15.0**) for live NZ Transport Agency traffic cameras, road events, VMS signs, and travel times. No package manager, no analytics, no backend — just `swiftc` against the macOS SDK plus an Xcode project that points at the same sources. Model-layer unit tests run via `./run_tests.sh` (a standalone swiftc executable, no SwiftPM/XCTest).

## Build / run

Two parallel build paths exist; both must keep working:

- **Xcode**: `NZTATraffic.xcodeproj`, shared scheme `NZTA Traffic`. The project references `Sources/*.swift`, `Resources/Info.plist`, and `Resources/NZTATraffic.icns` directly — adding a new `.swift` file means adding it to the Xcode project too.
- **Shell**: `./build_app.sh` — invokes `swiftc` directly (no SwiftPM), produces `build/NZTA Traffic.app`, ad-hoc signs it. Universal `arm64 + x86_64` by default; override with `ARCHS="$(uname -m)" ./build_app.sh` for a single-arch build during local iteration. `MACOSX_DEPLOYMENT_TARGET` overrides the min OS.

CLI release build:

```sh
xcodebuild -project NZTATraffic.xcodeproj -scheme "NZTA Traffic" -configuration Release -destination 'generic/platform=macOS' build
```

`./package_dmg.sh` rebuilds via `build_app.sh`, stages with an `Applications` symlink, and emits `dist/NZTA-Traffic-<version>-macOS-<arch>.dmg`. The version comes from `CFBundleShortVersionString` in `Resources/Info.plist` — bump it there.

Run the built app: `open "build/NZTA Traffic.app"`.

### Tests

`./run_tests.sh` compiles `Sources/Models.swift` plus `Tests/*.swift` into a standalone executable and runs it (exits non-zero on failure). Tests cover the pure model logic only — lossy decoders, coordinate validation, WKT parsing, VMS message formatting, NZ date formatting, and `matches(region:highway:search:)`. They deliberately avoid SwiftPM/XCTest and do **not** compile the SwiftUI layer, so keep `Models.swift` free of `SwiftUI`/`AppKit` imports. `Tests/` is not part of either app build path; new test files must be added to the `swiftc` invocation in `run_tests.sh`.

## Architecture

Six Swift files under `Sources/`, organized by layer not feature:

- `NZTATrafficApp.swift` — `@main` entry, `WindowGroup` + secondary `Window(id: "help")` + a `Settings` scene (`SettingsView`, ⌘,), and `NZTATrafficCommands` which replaces the standard About panel and Help menu items. `init()` installs a bounded shared `URLCache`.
- `TrafficAPIService.swift` — thin `URLSession` wrapper over four NZTA REST v4 endpoints (`/cameras/all`, `/events/all/10`, `/signs/vms/all`, `/journeys/all/10`) at `https://trafficnz.info/service/traffic/rest/4`. Uses a configured session (timeouts, `waitsForConnectivity`) and retries transient/5xx failures with exponential backoff (`isRetriable`). Each fetch has a `…Result()` variant (`nonisolated`, so decode runs off the main actor) that converts throws to `Result` so the store can surface per-section errors without one failure killing the others.
- `TrafficStore.swift` — `@Observable @MainActor` class holding cameras / events / VMS / journeys / per-section loading state / per-section errors / `lastUpdated` / `imageCacheToken` / reachability (`isOnline`) + offline-cache state (`isServingCachedData`, `cacheTimestamp`). `loadAllData(bustImageCache:)` fans out the four fetches concurrently with `async let` and applies them independently; a failed section keeps its last-known-good data. `imageCacheToken` is bumped **only on an explicit user refresh** (not auto-refresh) and appended to camera image URLs to bust the cache. `filtered*` results are memoized behind a `FilterKey` cache (`@ObservationIgnored`), cleared when section data changes. Also owns the `OfflineCache` actor (see the offline-cache exception below) and an `NWPathMonitor` (Network framework) whose updates set `isOnline` back on the main actor.
- `Models.swift` — all decodable types plus payload wrappers (`CamerasPayload` → `CameraResponse` → `[TrafficCamera]`, etc., matching the NZTA JSON shape). Helpers `cleanText(_:)`, `formatVMSMessage(_:)`, and the `KeyedDecodingContainer` extension at the bottom (`decodeLossyString`, `decodeLossyDouble`, `decodeLossyInt`) exist because the upstream API is loose-typed (numbers as strings, missing fields, embedded display-control tokens). New decoded fields should reuse these helpers rather than calling `decode` directly. Keep this file free of `SwiftUI`/`AppKit` so the test runner can compile it standalone.
- `Theme.swift` — design tokens (`Spacing`, `Radii`, and semantic `Color` extensions for the VMS palette + card stroke). Prefer these over scattered literals.
- `Views.swift` — `ContentView` (header / global filter bar / native `TabView` with per-tab scoped filter bars), one view per `TrafficTab` (`CamerasTabView`, `RoadEventsTabView`, `VMSTabView`, `TravelTimesTabView`, `TrafficMapTabView`, `AboutView`), `SettingsView`, the `AppHelpView` shown in the secondary window, and shared chrome (`ErrorBanner`, `LoadingView`, `FilterableEmptyState` (a `ContentUnavailableView`), `Badge`, `StatCard`).

### Data flow

`ContentView` owns the single `TrafficStore` and the three filter strings (region / highway / search), then asks the store for filtered/sorted slices per tab via `filteredCameras`/`filteredEvents`/`filteredVMSSigns`. Filtering and sorting live in the store, not in the views — when extending filters, add the predicate to the model's `matches(region:highway:search:)` method and to the relevant store accessor.

The map tab (`TrafficMapTabView`) consumes the same filtered slices and renders them through a `TrafficMapLayer` enum (cameras / events / vms) using MapKit. Coordinate parsing lives on each model as `mapCoordinate` — features without coordinates are silently dropped from the map and counted as `unmappedCount`.

### Refresh model

Manual refresh: ⌘R or the toolbar button calls `store.loadAllData(bustImageCache: true)` (forces fresh camera images). Auto-refresh: `@AppStorage("nzta.autoRefreshEnabled")` and `@AppStorage("nzta.refreshIntervalSeconds")` (clamped 30–600) drive a `Task` loop in `ContentView.configureAutoRefresh()` that calls `loadAllData()` (no cache bust — relies on `URLCache` + HTTP revalidation). Toggling either `@AppStorage` value (from the filter bar menu or the Settings window) cancels and reschedules the task — don't bypass `configureAutoRefresh`.

### Offline cache (deliberate exception to "no caching layer")

The four primary sections (cameras / events / vms / journeys) are persisted to disk for offline use — a deliberate, documented exception to the "no caching layer" convention below. How it works:

- The cacheable fetchers in `TrafficAPIService` return `(value, data)` so the store gets both the decoded models **and** the raw response bytes. The store persists the **raw JSON bytes** (not re-encoded models — the models have derived stored fields and `CodingKeys` that are a strict subset, so they don't round-trip via `Encodable`). On replay the bytes go back through the same `CamerasPayload`/etc. wrappers (`decodeCached*`), preserving every derived field.
- `OfflineCache` (an `actor` at the bottom of `TrafficStore.swift`) does all file IO off the main actor, writing one `<section>.json` per section under `Application Support/NZTATraffic/OfflineCache/`. Every operation is best-effort and silently no-ops on failure.
- `ContentView.task` calls `store.primeFromCache()` (fills empty sections from disk on launch) before `loadAllData()`. On a fetch failure the store falls back to the cached copy and marks the section cache-served; on success it overwrites both memory and disk.
- `store.shouldShowOfflineBanner` (`!isOnline || isServingCachedData`) drives the `OfflineBanner` rendered under the header in `ContentView`. Normal online behaviour is unchanged apart from the background cache writes.

## Conventions worth knowing

- The NZTA API is the only data source. There is no proxy and no auth. The **one** persistence exception is the offline cache described under "Refresh model" above (raw section JSON in Application Support); don't add other caching layers without reason.
- VMS message strings arrive with embedded display-control tokens; always run them through `formatVMSMessage` before showing.
- String/number fields from the API can be either type or absent — go through `decodeLossyString` / `decodeLossyDouble` and `cleanText`, not the raw `decode` calls.
- Errors are per-section by design (`store.errors[.cameras]` etc.) and rendered via `ErrorBanner` inside each tab. A failed fetch records the error but **keeps the section's last-known-good data** (it no longer zeroes the array), so other sections — and stale data — stay intact.
- Camera image URLs are suffixed with `?t=\(store.imageCacheToken)`; the token only changes on an explicit refresh, so auto-refresh reuses the bounded `URLCache` and revalidates via HTTP rather than re-downloading every image.
- New decoded fields and parsing logic should get a case in `Tests/ModelTests.swift`; run `./run_tests.sh` before committing model changes.
