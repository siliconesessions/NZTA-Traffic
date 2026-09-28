# NZ Traffic for macOS

A native SwiftUI Mac app for live New Zealand traffic information: traffic cameras, road events, electronic message signs, travel times and a map, with a menu-bar summary and a Dock badge for active road closures.

NZ Traffic is an independent viewer for public data from NZ Transport Agency Waka Kotahi (NZTA). It is not affiliated with or endorsed by NZTA.

Requires **macOS 27 or later** on a Mac with **Apple silicon**.

## Install

1. Download the latest `NZ-Traffic-<version>-macOS-arm64.dmg` from [GitHub Releases](https://github.com/siliconesessions/NZTA-Traffic/releases). Each release also has a `.sha256` checksum (`shasum -a 256 -c NZ-Traffic-<version>-macOS-arm64.dmg.sha256` in the download folder) and a dSYM zip for crash reports.
2. Open the DMG and drag **NZ Traffic** to the **Applications** folder.

NZ Traffic is ad-hoc signed and **not notarized** (it isn't signed with an Apple Developer ID), so macOS blocks the first launch of a downloaded copy. Since macOS 15 the old Control-click › Open shortcut no longer works; instead:

1. Open NZ Traffic once. macOS says Apple could not verify it is free of malware; click **Done**.
2. Open **System Settings › Privacy & Security**, scroll down to **Security**, and click **Open Anyway** next to the message about NZ Traffic.
3. Enter your password (or use Touch ID), then click **Open Anyway** again when macOS asks. You only need to do this once per download.

Or, in Terminal, remove the download quarantine flag before opening the app:

```sh
xattr -dr com.apple.quarantine "/Applications/NZ Traffic.app"
```

### Upgrading from "NZTA Traffic"

Version 3.0 renamed the app from "NZTA Traffic" to "NZ Traffic", with a new bundle ID (`io.github.siliconesessions.nztraffic`). On its first launch it copies your settings and offline cache from the old app, so you can then delete `NZTA Traffic.app`. Versions before 3.0 were universal builds for macOS 15; they are no longer kept in the repository.

## Features

- **Traffic Cameras** — the latest image from every camera, with status (online, offline, maintenance), region and route, and a larger preview.
- **Road Events** — closures, delays and caution notices in force now, sorted by severity, then upcoming (scheduled) events; direction, location, comments, alternative routes, restrictions and dates. Resolved events are hidden unless you turn them on.
- **VMS Signs** — what the roadside electronic message signs are showing, with display codes cleaned up; blank signs hidden by default.
- **Travel Times** — NZTA's highway journeys, one line per direction with travel time, free-flow time and delay; the roadside travel time boards (with their "VIA …" route lines), grouped by region; and Auckland motorway congestion as text.
- **Map** — seven layers: cameras, road events, VMS signs, traffic flow, travel time signs, EV chargers (with connector status) and Auckland congestion, with clustering, legends and colour-independent glyphs.
- **Filters** — region, whole-highway (SH1 = State Highway 1 = 01N) and free-text search shared across every tab and map layer, plus per-tab chips.
- **Watchlist** — watch highways, cameras and journeys; a Watching filter; optional notifications about new closures on watched roads.
- **Always current** — auto-refresh every 1–10 minutes that keeps running with the window closed; a menu-bar extra with counts and Refresh Now; a Dock badge with the number of active closures.
- **Offline** — the last good data is saved and shown, with its age, when NZTA can't be reached.
- Keyboard shortcuts (⌘1–6 tabs, ⌘F search, ⌘E clear filters, ⌘R refresh, ⌘? help), VoiceOver rotors for closures and delays, in-app Help, and Help › Export Diagnostics… for bug reports.

## Data sources and privacy

NZ Traffic fetches data directly from these feeds — there is no app backend, no analytics and no account:

| Data | Source |
|---|---|
| Cameras | `https://trafficnz.info/service/traffic/rest/5/cameras/all` |
| Road events | `https://trafficnz.info/service/traffic/rest/5/events/all/10` |
| VMS signs | `https://trafficnz.info/service/traffic/rest/5/signs/vms/all` |
| Travel times (journeys) | `https://trafficnz.info/service/traffic/rest/5/journeys/all/10` |
| Travel time signs (TIM) | `https://trafficnz.info/service/traffic/rest/5/signs/tim/all` |
| Regions | `https://trafficnz.info/service/traffic/rest/5/regions/all/10` |
| Auckland motorway congestion (XML) | `https://trafficnz.info/service/traffic-conditions/rest/2` |
| EV charging stations (EV Roam, GeoJSON) | `https://services.arcgis.com/CXBb7LAjgIIdcsPt/arcgis/rest/services/EV_Roam_charging_stations/FeatureServer/0/query` |

REST v5 is undocumented; if an endpoint stops answering there, the app falls back to the documented REST v4 for the rest of the session. Camera images come from trafficnz.info and the map uses Apple MapKit.

The last successful camera, road event, VMS and journey responses are saved in `~/Library/Application Support/NZTraffic/OfflineCache` for offline use, and camera images are cached (up to 200 MB) in the app's Caches folder. **Clear Offline Cache** (Settings or the Help menu) deletes both. Settings and the watchlist are stored in the app's preferences.

**Road events cover notable events** — ones that may cause delays or need caution — and are published only once NZTA or another official source has verified them, so not every incident on the road is listed. Traffic information can lag behind conditions; always follow official road signs and instructions.

### Attribution and licences

- Traffic and travel information: NZ Transport Agency Waka Kotahi (NZTA) and participating regional councils, used under the [Creative Commons Attribution 4.0 International licence (CC BY 4.0)](https://creativecommons.org/licenses/by/4.0/) and NZTA's [Traffic and Travel data terms of use](https://www.nzta.govt.nz/traffic-and-travel-information/use-our-data/terms-of-use). Text is reformatted for display.
- EV charging station data: EV Roam, NZ Transport Agency Waka Kotahi, licensed under CC BY 4.0. Connector details are reformatted for display.

## Build from source

Needs Xcode 27 (macOS 27 SDK) on an Apple silicon Mac. There are no dependencies and no package manager.

### Xcode

Open `NZTraffic.xcodeproj` and run the shared **NZ Traffic** scheme, or from Terminal:

```sh
xcodebuild -project NZTraffic.xcodeproj -scheme "NZ Traffic" -configuration Release -destination 'generic/platform=macOS' build
```

`Sources/` is a synchronized folder: any `.swift` file added there (flat, no subfolders) is built by both Xcode and the shell script.

### Shell script

```sh
./build_app.sh
open "build/NZ Traffic.app"
```

Compiles `Sources/*.swift` with `swiftc` from the selected Xcode (`xcrun --sdk macosx`) — Swift 6 language mode, `-O` whole-module, debug info — compiles the Icon Composer icon (`Resources/AppIcon.icon`) with `actool`, and ad-hoc signs `build/NZ Traffic.app` with the hardened runtime, next to `build/NZ Traffic.app.dSYM`. Module caches go under `$TMPDIR`. Options:

```sh
MACOSX_DEPLOYMENT_TARGET=27.1 ./build_app.sh   # raise the minimum macOS (also stamped into LSMinimumSystemVersion)
```

Builds are Apple silicon (`arm64`) only: macOS 27 doesn't run on Intel Macs. The script still accepts a space-separated `ARCHS` list for a lipo'd binary, but that isn't a supported configuration.

### Tests

```sh
./run_tests.sh
```

Compiles the Foundation-level sources (models, identity, refresh policy, API client, offline cache, store, view logic, map clustering, watchlist) with `Tests/*.swift` into a standalone executable (no XCTest) and runs it against an in-process stub network, temporary folders and trimmed real-payload fixtures in `Tests/Fixtures/`. The suite runs in the Mac's time zone, UTC and America/Los_Angeles, so NZ-time handling is checked wherever the Mac is set. GitHub Actions (`.github/workflows/ci.yml`) runs the tests and both builds on every push and pull request.

### Package a release

```sh
./package_dmg.sh
```

Runs the tests, rebuilds with `build_app.sh`, checks the signature, and writes `dist/NZ-Traffic-<version>-macOS-arm64.dmg` (ULMO-compressed, verified with `hdiutil verify`), its `.sha256` checksum and a zipped dSYM. The version comes from `Resources/Info.plist` (`CFBundleShortVersionString` / `CFBundleVersion` — bump both there). `dist/` is git-ignored: upload the three files to a GitHub Release, e.g.

```sh
gh release create v3.0.0 dist/NZ-Traffic-3.0.0-macOS-arm64.dmg dist/NZ-Traffic-3.0.0-macOS-arm64.dmg.sha256 dist/NZ-Traffic-3.0.0-macOS-arm64.dSYM.zip
```
