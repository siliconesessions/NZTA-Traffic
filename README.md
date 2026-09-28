# NZ Traffic for macOS

Native SwiftUI macOS app for live NZTA traffic cameras, road events, and VMS signs.

## Install

An installable DMG is checked in at:

```sh
dist/NZTA-Traffic-1.0-macOS-universal.dmg
```

To install, open the DMG and drag `NZ Traffic.app` to the `Applications` shortcut in the installer window.

Current builds are Apple silicon (`arm64`) only and require macOS 27.0 or later. (The older 1.x–2.1.1 DMGs in `dist/` are universal builds for macOS 15.) The app is ad-hoc signed but not notarized with an Apple Developer ID, so macOS Gatekeeper may block the first launch. If that happens, Control-click `NZ Traffic.app`, choose `Open`, and confirm that you want to open it.

Version 3.0 renames the app from "NZTA Traffic" to "NZ Traffic", with a new bundle ID (`io.github.siliconesessions.nztraffic`). On its first launch it copies your settings and offline cache from the old app automatically, so you can then delete `NZTA Traffic.app`. NZ Traffic is an independent viewer and is not affiliated with or endorsed by NZ Transport Agency Waka Kotahi (NZTA), which provides the traffic data.

## Build

### Xcode

Open `NZTraffic.xcodeproj` in Xcode and run the shared `NZ Traffic` scheme.

To build from Terminal with Xcode:

```sh
xcodebuild -project NZTraffic.xcodeproj -scheme "NZ Traffic" -configuration Release -destination 'generic/platform=macOS' build
```

The Xcode project uses the existing Swift files in `Sources/`, `Resources/Info.plist`, and the Icon Composer icon `Resources/AppIcon.icon`. Both build paths produce `NZ Traffic.app` with executable name `NZTraffic` and bundle ID `io.github.siliconesessions.nztraffic`.

### Shell Script

```sh
./build_app.sh
```

The script compiles the Swift sources (Swift 6 language mode, `-O` whole-module, with debug info) with the active SDK, writes module caches under `$TMPDIR`, creates `build/NZ Traffic.app` plus `build/NZ Traffic.app.dSYM`, and ad-hoc signs the bundle with the hardened runtime when `codesign` is available. By default it builds for Apple silicon (`arm64`) only, matching the Xcode project.

The app icon is an Icon Composer document, `Resources/AppIcon.icon` (one full-bleed layer cropped from the 1024px source `Resources/AppIcon.png`; the system applies the icon mask, glass and dark/clear/tinted styles). Both build paths compile it with `actool` into `Assets.car` plus an `AppIcon.icns` fallback, and actool supplies `CFBundleIconName` / `CFBundleIconFile` — so `Resources/Info.plist` deliberately sets neither. To change the icon, edit `AppIcon.icon` in Icon Composer (Xcode › Open Developer Tool).

To override the deployment target (default `27.0`; the bundled `LSMinimumSystemVersion` follows it):

```sh
MACOSX_DEPLOYMENT_TARGET=27.0 ./build_app.sh
```

To build a universal binary instead:

```sh
ARCHS="arm64 x86_64" ./build_app.sh
```

## Tests

```sh
./run_tests.sh
```

Compiles `Sources/Models.swift` with the files in `Tests/` into a standalone executable (no XCTest) and runs it for the host architecture.

## Package DMG

```sh
./package_dmg.sh
```

The packaging script rebuilds the app, stages it with an `Applications` shortcut, verifies the staged app signature (including the hardened runtime), and creates a compressed read-only DMG under `dist/`, plus a zipped dSYM beside it. The filename includes the app version (from `Resources/Info.plist`) and the architecture label from the built executable, e.g. `NZ-Traffic-3.0.0-macOS-arm64.dmg`.

## Run

```sh
open "build/NZ Traffic.app"
```

The app requires internet access for live NZTA data and camera images. It uses the NZTA Traffic and Travel REST API v4 directly with `URLSession` and `Accept: application/json`; it does not use the browser CORS proxy from `web/nzta_traffic.html`.

## Endpoints

- `https://trafficnz.info/service/traffic/rest/4/cameras/all`
- `https://trafficnz.info/service/traffic/rest/4/events/all/10`
- `https://trafficnz.info/service/traffic/rest/4/signs/vms/all`

## Features

- Cameras, road events, VMS signs, and About tabs.
- Map tab with switchable camera, road event, and VMS sign layers.
- macOS Help menu item with detailed in-app help.
- Region, highway, and search filters shared across the data tabs.
- Manual refresh and persisted auto-refresh interval.
- Camera thumbnail grid with larger preview sheet.
- Road event severity sorting, closure and delay stats, comments, routes, dates, and metadata.
- VMS sign cards with source display-control tokens rendered as readable messages.
- Travel Times shows NZTA's highway journeys or the roadside travel-time boards (with their "VIA …" route lines), grouped by region.
- EV charger layer with per-connector status: out-of-service sites greyed out, "n of m connectors working" on each charger.
- Watchlist of highways, cameras and journeys (star or Control-click a card), a Watching filter, and optional notifications for new closures on watched roads.
