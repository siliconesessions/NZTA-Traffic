# NZTA Traffic for macOS

Native SwiftUI macOS app for live NZTA traffic cameras, road events, and VMS signs.

## Build

```sh
./build_app.sh
```

The script compiles the Swift sources with the active Command Line Tools SDK, writes module caches under `/tmp`, creates `build/NZTA Traffic.app`, and ad-hoc signs the bundle when `codesign` is available.

The app icon is stored as `Resources/NZTATraffic.icns` with a 1024px PNG source at `Resources/AppIcon.png`.

To override the deployment target:

```sh
MACOSX_DEPLOYMENT_TARGET=15.0 ./build_app.sh
```

## Run

```sh
open "build/NZTA Traffic.app"
```

The app requires internet access for live NZTA data and camera images. It uses the NZTA Traffic and Travel REST API v4 directly with `URLSession` and `Accept: application/json`; it does not use the browser CORS proxy from `web/nzta_traffic.html`.

## Endpoints

- `https://trafficnz.info/service/traffic/rest/4/cameras/all`
- `https://trafficnz.info/service/traffic/rest/4/events/all/-1`
- `https://trafficnz.info/service/traffic/rest/4/signs/vms/all`

## Features

- Cameras, road events, VMS signs, and About tabs.
- Region, highway, and search filters shared across the data tabs.
- Manual refresh and persisted auto-refresh interval.
- Camera thumbnail grid with larger preview sheet.
- Road event severity sorting, closure and delay stats, comments, routes, dates, and metadata.
- VMS sign cards with `[nl]` and `[np]` message tokens rendered as line breaks.
