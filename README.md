# NZTA Traffic for macOS

Native SwiftUI macOS app for live NZTA traffic cameras, road events, and VMS signs.

## Install

An installable DMG is checked in at:

```sh
dist/NZTA-Traffic-1.0-macOS-universal.dmg
```

To install, open the DMG and drag `NZTA Traffic.app` to the `Applications` shortcut in the installer window.

This universal build supports Apple Silicon and Intel Macs and requires macOS 15.0 or later. The app is ad-hoc signed but not notarized with an Apple Developer ID, so macOS Gatekeeper may block the first launch. If that happens, Control-click `NZTA Traffic.app`, choose `Open`, and confirm that you want to open it.

## Build

### Xcode

Open `NZTATraffic.xcodeproj` in Xcode and run the shared `NZTA Traffic` scheme.

To build from Terminal with Xcode:

```sh
xcodebuild -project NZTATraffic.xcodeproj -scheme "NZTA Traffic" -configuration Release -destination 'generic/platform=macOS' build
```

The Xcode project uses the existing Swift files in `Sources/`, `Resources/Info.plist`, and `Resources/NZTATraffic.icns`. It preserves the current bundle name `NZTA Traffic.app` and executable name `NZTATraffic`.

### Shell Script

```sh
./build_app.sh
```

The script compiles the Swift sources with the active Command Line Tools SDK, writes module caches under `/tmp`, creates `build/NZTA Traffic.app`, and ad-hoc signs the bundle when `codesign` is available. By default it creates a universal `arm64` + `x86_64` app.

The app icon is stored as `Resources/NZTATraffic.icns` with a 1024px PNG source at `Resources/AppIcon.png`.

To override the deployment target:

```sh
MACOSX_DEPLOYMENT_TARGET=15.0 ./build_app.sh
```

To build for only the current Mac architecture:

```sh
ARCHS="$(uname -m)" ./build_app.sh
```

## Package DMG

```sh
./package_dmg.sh
```

The packaging script rebuilds the app, stages it with an `Applications` shortcut, verifies the staged app signature, and creates a compressed read-only DMG under `dist/`. The filename includes the app version and architecture label from the built executable.

## Run

```sh
open "build/NZTA Traffic.app"
```

The app requires internet access for live NZTA data and camera images. It uses the NZTA Traffic and Travel REST API v4 directly with `URLSession` and `Accept: application/json`; it does not use the browser CORS proxy from `web/nzta_traffic.html`.

## Endpoints

- `https://trafficnz.info/service/traffic/rest/4/cameras/all`
- `https://trafficnz.info/service/traffic/rest/4/events/all/10`
- `https://trafficnz.info/service/traffic/rest/4/signs/vms/all`

## Features

- Cameras, road events, VMS signs, and About tabs.
- Map tab with switchable camera, road event, and VMS sign layers.
- Region, highway, and search filters shared across the data tabs.
- Manual refresh and persisted auto-refresh interval.
- Camera thumbnail grid with larger preview sheet.
- Road event severity sorting, closure and delay stats, comments, routes, dates, and metadata.
- VMS sign cards with `[nl]` and `[np]` message tokens rendered as line breaks.
