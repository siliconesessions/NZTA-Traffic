# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Native SwiftUI macOS app (10.15+ deployment target is **15.0**) for live NZ Transport Agency traffic cameras, road events, and VMS signs. No tests, no package manager, no analytics, no backend — just `swiftc` against the macOS SDK plus an Xcode project that points at the same sources.

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

## Architecture

Five Swift files under `Sources/`, organized by layer not feature:

- `NZTATrafficApp.swift` — `@main` entry, `WindowGroup` + secondary `Window(id: "help")`, and `NZTATrafficCommands` which replaces the standard About panel and Help menu items.
- `TrafficAPIService.swift` — thin `URLSession` wrapper over three NZTA REST v4 endpoints (`/cameras/all`, `/events/all/10`, `/signs/vms/all`) at `https://trafficnz.info/service/traffic/rest/4`. Each fetch has a `…Result()` variant that converts throws to `Result` so the store can surface per-section errors without one failure killing the others.
- `TrafficStore.swift` — `@MainActor` `ObservableObject` holding cameras / events / VMS / per-section loading state / per-section errors / `lastUpdated` / `imageCacheToken`. `loadAllData()` fans out the three fetches concurrently with `async let` and applies them independently. The `imageCacheToken` is bumped on every refresh and appended to camera image URLs to bust `URLCache`.
- `Models.swift` — all decodable types plus payload wrappers (`CamerasPayload` → `CameraResponse` → `[TrafficCamera]`, etc., matching the NZTA JSON shape). Helpers `cleanText(_:)`, `formatVMSMessage(_:)`, and the `KeyedDecodingContainer` extension at the bottom (`decodeLossyString`, `decodeLossyDouble`) exist because the upstream API is loose-typed (numbers as strings, missing fields, embedded display-control tokens). New decoded fields should reuse these helpers rather than calling `decode` directly.
- `Views.swift` — single 1300-line file containing `ContentView` (header / filter bar / segmented tab picker / tab content), one view per `TrafficTab` (`CamerasTabView`, `RoadEventsTabView`, `VMSTabView`, `TrafficMapTabView`, `AboutView`), plus the `AppHelpView` shown in the secondary window and shared chrome (`ErrorBanner`, `LoadingView`, `EmptyStateView`, `Badge`, `StatCard`).

### Data flow

`ContentView` owns the single `TrafficStore` and the three filter strings (region / highway / search), then asks the store for filtered/sorted slices per tab via `filteredCameras`/`filteredEvents`/`filteredVMSSigns`. Filtering and sorting live in the store, not in the views — when extending filters, add the predicate to the model's `matches(region:highway:search:)` method and to the relevant store accessor.

The map tab (`TrafficMapTabView`) consumes the same filtered slices and renders them through a `TrafficMapLayer` enum (cameras / events / vms) using MapKit. Coordinate parsing lives on each model as `mapCoordinate` — features without coordinates are silently dropped from the map and counted as `unmappedCount`.

### Refresh model

Manual refresh: ⌘R or the toolbar button calls `store.loadAllData()`. Auto-refresh: `@AppStorage("nzta.autoRefreshEnabled")` and `@AppStorage("nzta.refreshIntervalSeconds")` (clamped 30–600) drive a `Task` loop in `ContentView.configureAutoRefresh()`. Toggling either `@AppStorage` value cancels and reschedules the task — don't bypass `configureAutoRefresh`.

## Conventions worth knowing

- The NZTA API is the only data source. There is no proxy, no caching layer, no auth. Don't add one without reason.
- VMS message strings arrive with embedded display-control tokens; always run them through `formatVMSMessage` before showing.
- String/number fields from the API can be either type or absent — go through `decodeLossyString` / `decodeLossyDouble` and `cleanText`, not the raw `decode` calls.
- Errors are per-section by design (`store.errors[.cameras]` etc.) and rendered via `ErrorBanner` inside each tab. A failed fetch zeroes that section's array but leaves the others intact.
- Camera image URLs must be suffixed with `?t=\(store.imageCacheToken)` to bust the system URL cache after a refresh.
