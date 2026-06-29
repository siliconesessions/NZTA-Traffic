# NZTA Traffic — Definitive Best-Practice Improvement Plan

## 1. Executive summary

NZTA Traffic is a well-structured, single-source-of-truth SwiftUI macOS app with a clean layered architecture (`TrafficAPIService` → `TrafficStore` → `Views`), sensible per-section error isolation, and a thoughtfully defensive lossy JSON decoder for a loose upstream API. It is fundamentally healthy — there are no crashes-on-launch class of defects — but it carries three categories of debt that compound as the dataset grows: (1) **real correctness bugs** hiding in the data layer (a timezone-less NZ date formatter, an unguarded `Double`→`Int` conversion that can trap, and a refresh path that wipes good data on a transient network blip); (2) **a performance model that recomputes everything on every `body` pass** — filtering, sorting, coordinate validation, regex compilation, and a global image-cache token that re-downloads all ~100+ camera images every auto-refresh; and (3) **a visual and accessibility layer that reads as "iOS ported to Mac"** — segmented pickers, rounded-border text fields, fixed font sizes, color-only status encoding, and an inconsistent card system. The biggest, cheapest levers are: **memoize the filter/derived pipeline** (one change fixes a dozen findings), **stop globally cache-busting images** (kills the dominant network cost), **fix the three data-layer bugs**, and **adopt semantic fonts + accessibility labels** (unblocks VoiceOver and Dynamic Type for free). The larger but high-value bets are migrating `TrafficStore` to `@Observable`, decomposing the 2,240-line `Views.swift`, adding a test target, and introducing an offline cache so the app degrades gracefully. Most fixes are small and localized; the architecture work is what makes the rest cheap to maintain.

A cross-cutting enabler appears in nearly every section: **introduce a design-token / theme module and a memoized filter layer first** — they convert dozens of scattered edits into single-point changes.

---

## 2. Visuals

### V1 — Modernize the app chrome to native macOS navigation `[High impact]`
**Files:** `Sources/Views.swift` — `ContentView` (45–59), `header` (86–143), `filters` (152–189), `tabPicker` (234–245), `scopedFilterBar` (301–309), `DataSectionPill` (2119–2179), map layer picker (338).

- **Segmented picker as primary navigation (high).** `tabPicker` uses `.pickerStyle(.segmented)` for the six top-level tabs — an iOS idiom. Replace with a native macOS `TabView` (default toolbar-grouped style, or `.tabViewStyle(.sidebarAdaptable)` for a sidebar). The same applies to the map layer picker at 338. Do **not** use `.pickerStyle(.automatic)` (popup) or `.palette`. If a larger redesign is on the table, `NavigationSplitView` is the idiomatic shell. *Severity high / impact high / effort medium.*
- **Excessive `Divider()`s (high).** Four dividers (47, 49, 51, 54) compartmentalize the window vertically. Set the outer `VStack(spacing: 0)` and let section padding create separation; keep at most one `Divider()` where there's a true semantic boundary (global filters vs. tab-scoped filters). *Small / high.*
- **Inconsistent backgrounds (high, nuanced).** The main container uses `Color.primary.opacity(0.025)` (59) while sections use `.background(.background)` (142, 188, 244, 308) — neither flat nor layered. Standardize all on the semantic `.background`. If depth is wanted, apply `.thinMaterial` **only** to the header (true elevated toolbar), not to filters/picker which are core navigation. *Small / high.*
- **Uniform-blue pill icons (medium/high, nuanced).** `DataSectionPill` icons are all `.blue` (2156). Add a per-type semantic color following the existing `FlowKind.color` pattern: green = cameras (online semantics), orange = events (alert), blue = travel times (informational), a distinct hue for VMS. *Small / high.*
- **Header/filter materials (medium).** Optional follow-on: apply `.background(.thinMaterial)` to the header only (not all four bars) for subtle elevation; do not pass `in: Rectangle()` (redundant). *Small / medium.*

### V2 — Make the filter bar responsive and native `[Medium impact]`
**Files:** `Sources/Views.swift` — `filters` (161–169), `scopedFilterBar` (307), `mapTabFilterBar` (329–362).

- **Fixed-width controls (medium).** Region `.frame(width: 180)`, Highway `.frame(width: 160)`, Search `.frame(minWidth: 220)` bunch/clip on resize. Use ranges: e.g. highway `.frame(minWidth: 120, maxWidth: 200)`, search `.frame(minWidth: 150, maxWidth: .infinity)` so it grows with the window. *Small / medium.*
- **Arbitrary fixed height (medium).** Remove `.frame(height: 48)` on `scopedFilterBar` (307); use `.frame(minHeight: 48, alignment: .center)` if vertical centering is needed, so tabs with more chips aren't clipped. *Small / medium.*
- **iOS rounded-border text fields (medium, nuanced).** `.textFieldStyle(.roundedBorder)` (164, 168) looks non-native. Prefer `.textFieldStyle(.automatic)`, or `.plain` with `@FocusState`-driven border overlays so the field responds to focus rather than showing a constant border. *Small / medium.*
- **Map filter-bar density (medium, nuanced).** The single `HStack(spacing: 12)` mixes layer selection, visibility chips, status counts, and reset. It's less broken than it looks (a `Spacer()` already separates groups), but: wrap the conditional `mapLayerFilters` row in its own subtly-bordered container and add an explicit `Divider()` after the filter group. Consider moving non-critical counts into a popover. *Medium / medium.*

### V3 — Unify the card component family `[High impact]`
**Files:** `Sources/Views.swift` — `CameraCard` (1500–1570), `JourneyCard` (1321–1371), `RoadEventCard` (1635–1702), `VMSCard` (1740–1778), `StatCard` (1971–1989), `Badge` (1992–2005), `ErrorBanner` (2181–2200).

This is the most visible inconsistency in the app and several findings overlap here; treat as one workstream backed by the design tokens in **F1**.

- **VMSCard breaks the language (high).** It uses hardcoded `Color(red: 0.09, green: 0.13, blue: 0.18)` background (1772), 3px stroke (1776), `.system(size: 21, …, .monospaced)` font (1759), and hardcoded orange `Color(red: 1.0, green: 0.74, blue: 0.18)` text (1760). Keep its *intentional* sign-like dark look but route the magic numbers through named semantic constants (`Color.vmsCardBackground`, `Color.vmsCardMessage`, `Color.vmsCardSubtitle`) following the `FlowKind` extension pattern; reduce stroke to 1px; use `.system(.title2, design: .monospaced, weight: .bold)` so the message scales with Dynamic Type (see A2). Keep the opaque background — do **not** switch to `.thinMaterial` (it would crush contrast). *High / high / medium.*
- **StatCard reads as a pill, not a card (medium).** `.background(stat.tint)` with white text (1987) diverges from the family. Re-skin to match: `.background(.background)`, a 5px left accent bar tinted `stat.tint` (mirroring RoadEventCard), `.foregroundStyle(.primary)` value text, and a `RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12), lineWidth: 1)` overlay. *Medium / medium.*
- **Standardize corner radius (medium/high).** `Badge` uses radius 6 (2004); all cards use 8. Set Badge to 8 and reference a single `Radii.card` token. *Small / high.*
- **Standardize padding & internal spacing (medium).** Card padding varies 14/16/18px; internal `VStack` spacing varies 0→9, 11, 12. Adopt a base of 16px content padding and 12px between major card sections; document StatCard's asymmetric padding as an intentional exception if kept. *Small–medium / medium.*
- **Add subtle depth (medium, nuanced).** Cards are flat `.background(.background)` + 1px stroke. For CameraCard/JourneyCard/RoadEventCard add `.shadow(color: .black.opacity(0.15), radius: 4, y: 2)` and soften stroke to `Color.primary.opacity(0.08)`. Keep `.thinMaterial` reserved for floating overlays (e.g. status pill at 777) — adding it under scroll views risks content bleed-through. *Small / high.*
- **Consistent accent-bar pattern (low).** Extend RoadEventCard's 5px left accent bar to JourneyCard (color by flow state) and CameraCard (color by online/offline) so the information-dense card family shares one status idiom; exclude StatCard/VMSCard. *Medium / low.*
- **ErrorBanner under-emphasized (medium, nuanced).** `Color.red.opacity(0.09)` (2194) reads as a soft notice and may fail WCAG. Either bump background to 0.15–0.20 and stroke to 0.4, **or** adopt the 5px red accent-bar pattern. *Small / medium.*

### V4 — Polish the map layer `[High impact]`
**Files:** `Sources/Views.swift` — Map container (798–826), `MapPolyline` (801–802), `mapStatusOverlay` (753–786), `TrafficMapMarker` (1082–1099), `TrafficMapClusterMarker` (1115–1139), `TrafficMapDetailView` (1183), `TrafficMapLayer` (557–605), `zoomIn` (862–896).

- **No hover/selection feedback on markers (medium).** Plain-style buttons give no affordance. Add `@State private var isHovered` + `.onHover { isHovered = $0 }` with `.scaleEffect(isHovered ? 1.1 : 1.0)`; add an `isSelected: Bool` parameter and draw a `.stroke(feature.tint, lineWidth: 2)` ring when selected (compare `feature.id` to `selectedDetail`). For yellow caution markers, switch the white glyph to `.black`/`.gray` to hit 4.5:1 contrast. *Small / high.*
- **Specify `MapStyle` (medium).** Add `.mapStyle(.standard)` after the `Map` (826) for explicit cartography. System marker colors already adapt to light/dark; only add `@Environment(\.colorScheme)` logic if fine-tuning custom tints. *Small / high.*
- **No legend (medium).** Color encodes meaning with no key. Add an `.overlay(alignment: .topTrailing)` legend that swaps swatches per `selectedLayer` (cameras: green/orange/red; events: red/orange/yellow; VMS: blue/gray). *Medium / high.*
- **Adaptive detail sheet (medium, nuanced).** `TrafficMapDetailView` is a fixed `720×520`. Use `.frame(minWidth: 600, idealWidth: 720, maxWidth: .infinity, minHeight: 400, idealHeight: 520)` + `.presentationBackground(.ultraThinMaterial)`. Do **not** use `.presentationDetents` — that's an iOS sheet API, not how macOS sizes sheets. *Small / high.*
- **Cluster count legibility (medium).** 13pt white count text lacks contrast on red/indigo. Add a stroked-text outline (overlay an offset darker copy) or a larger shadow (radius 1.5–2, y 0.5); test on red/indigo. *Small / medium.*
- **Cluster preview on click (low).** On cluster **click** (not hover) show a popover listing first 3–4 member titles before zooming; keep the existing easeInOut(0.45) zoom. *Medium / medium.*
- **Lower-priority map depth (low):** zoom-aware polyline width (`max(3, min(8, 5 * span.longitudeDelta / 10))`, no shadow — overlays don't support it); zoom-aware cluster diameter (clamp 32–60); `MapCircle` glow rings for online cameras; per-state tinting + safe-area padding for `mapStatusOverlay`. Bundle these as a single "map depth" pass. *Medium / medium each.*
- **Marker hit target (medium).** See **U1** (touch target) — circular `contentShape` + 44×44 frame.

---

## 3. Performance

### P1 — Memoize the filter/derived pipeline (the single biggest win) `[High impact]`
**Files:** `Sources/Views.swift` — `ContentView` scoped methods (416–481), `mapCounts` (395–414), `allowedEventImpacts`/`allowedCameraStatuses` (433–448), `scopedFilterBar`/`scopedFilterContent` (301–327), per-tab stat counts (517–519, 1201–1207, 1278–1286); `Sources/TrafficStore.swift` `filteredCameras/Events/VMSSigns/Journeys` (88–127).

The root cause behind ~8 findings: `scopedCameras/Events/VMSSigns/Journeys` are computed properties that run **O(n) filter+sort twice per update** (once in `tabContent`, once in `mapCounts`), and they re-run whenever *any* `@Published` value changes — including `isRefreshing` and toggling an unrelated camera-status chip. `mapCounts` runs all four filters just to populate "X mapped" badge labels.

- **Fix:** Centralize filtering in one place that recomputes only when inputs change. Two acceptable approaches:
  - *Modern (recommended):* extract a `@Observable final class FilterModel` (macOS 14+) holding the three filter strings + the visibility-flag set, exposing `filteredCameras`/`filteredEvents`/… as computed properties with automatic, scoped dependency tracking. `@Observable` won't invalidate when unrelated store state (`isRefreshing`) changes.
  - *Pragmatic:* cache results in `@State` arrays in `ContentView`, refreshed by a single `updateCaches()` called from `.onChange` of every dependency (`store.cameras/events/vmsSigns/journeys`, `selectedRegion`, `highwayFilter`, `searchFilter`, and the visibility flags). Compute `mapCounts` once from the cached arrays, not from source data.
  - Avoid `@Computed` (not a real API) and don't call `scoped*()` more than once per render.
- **Also:** rebuild `allowedEventImpacts`/`allowedCameraStatuses` `Set`s only on toggle change (or replace with predicate functions to avoid allocation — for 3–5 element sets this is negligible, so gate on profiling). Extract `scopedFilterBar`'s `@ViewBuilder` switch into separate `CameraFilterBar`/`EventFilterBar`/… views so hidden tabs' filter UI isn't built every pass. *Severity high / impact high / effort medium.*

### P2 — Image pipeline overhaul `[High impact]`
**Files:** `Sources/TrafficStore.swift` `imageCacheToken` (25, 47–62); `Sources/Models.swift` `trafficNZURL`/`imageURL`/`thumbnailURL` (173–179, 633–659); `Sources/Views.swift` `CameraCard` (1508), `CameraPreviewView` (1609, 1628), `CamerasTabView` LazyVGrid (522–549).

- **Stop globally cache-busting (high).** `imageCacheToken` is reset to `Int(Date().timeIntervalSince1970)` on **every** `loadAllData()` (every auto-refresh) and appended as `?t=` to all image URLs, forcing ~100+ re-downloads every 120s and defeating `URLCache` entirely. Configure a bounded `URLCache` at startup (`URLSession.shared.configuration.urlCache = URLCache(memoryCapacity: 50_000_000, diskCapacity: 200_000_000, diskPath: "images")`) and rely on HTTP `Cache-Control`/`ETag`. Only bump the token on **explicit user refresh**, or make it per-camera keyed on a hash of mutable fields (`offline`, `underMaintenance`). Note: `.environment(\.urlCache, …)` and "inject a custom session into AsyncImage" are **not** valid APIs — configure `URLSession.shared` or wrap your own loader. *High / high / medium.*
- **Preview loads full-resolution (medium).** `CameraPreviewView` requests `camera.imageURL()` (full server JPEG, possibly 4K) shown at ~1000×600. Switch line 1609 to `camera.thumbnailURL(cacheToken:)` (already proven in `CameraCard`). Only pursue server size params / ImageIO downsampling if true detail inspection is required. *Medium / medium.*
- **Server-side downsampling (high, nuanced).** *Verify first* that `trafficnz.info` honors width/height query params; if so, add optional size hints to `trafficNZURL()` (~280×170 thumbnail, ~470×760 preview). This is a bandwidth optimization, not a SwiftUI requirement — validate the saving justifies the URL complexity. *Small / high (if supported).*
- **Smoother loads (medium).** Add `.transition(.opacity.combined(with: .scale))` to the success case and `.transition(.opacity)` to the failure placeholder of the `AsyncImage` phases; consider `ProgressView().controlSize(.small)` to cut render pressure in dense grids. For prefetch, use macOS 15's `.onScrollVisibilityChange(threshold: 0.3)` to warm images 1–2 rows ahead. Add explicit `.id(camera.id)` to the grid `ForEach` and `.animation(.easeInOut(duration: 0.3), value: cameras)` to smooth filter-driven relayout (do **not** use `matchedGeometryEffect` for membership changes). *Small / medium.*

### P3 — Optimize model decoding & parsing hot paths `[High impact]`
**Files:** `Sources/Models.swift` — `coordinateFromWKTGeometry` (590–631), `parseWKTLineStringCoords` (890–917), `formatVMSMessage` (661–686), `mapCoordinate` computed vars (164–166, 344–347, 479–481), `TrafficJourneyLeg.currentTimeSeconds` (1167–1172) / `parseTimeIntervalString` (919–931), lossy decoders (1232–1296), `computeAllRegions` in `TrafficStore.swift` (143–148).

- **Cache compiled regex (high).** The identical WKT coordinate pattern is recompiled on every `coordinateFromWKTGeometry`/`parseWKTLineStringCoords` call, and `formatVMSMessage` recompiles its pattern per VMS sign. Hoist to a module-level `private let wktCoordinateRegex = try! NSRegularExpression(pattern: #"(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\s+(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)"#)` and reuse in both functions; cache VMS patterns similarly. *Small / high.*
- **Cache `mapCoordinate` in init (high).** All three models recompute `validatedCoordinate()` on every access; map filtering checks `mapCoordinate != nil` across 1000+ items per render. Make it a stored `let mapCoordinate: CLLocationCoordinate2D?` assigned in `init(from:)`. *Small / high.* (Also dedupes the double mapCoordinate scan between `mapCounts` and `features` at 627–653.)
- **Pre-parse `currentTimeSeconds` (medium).** Store as `let currentTimeSeconds: TimeInterval?` parsed once in init rather than re-parsing the string on each access. *Small / low–medium.*
- **Lossy decoder coercion (medium, nuanced).** Each `decodeLossy*` makes 4–5 `try?` attempts per field. Decode each field once into an `AnyCodable`-style intermediate, branch on the underlying JSON type, then convert — cutting parser invocations ~5×. *Medium / medium.*
- **Consolidate VMS string processing (medium).** `formatVMSMessage` makes many sequential `.replacingOccurrences` passes plus a `while` loop. Combine bracket substitutions, split-once on newlines, clean, rejoin. *Medium / low.*
- **`computeAllRegions` (low).** Replace concatenate→Set→Array→sort with a single-pass `Set` accumulator. *Small / low.*

### P4 — Move work off the main thread & tune the network layer `[High impact]`
**Files:** `Sources/TrafficAPIService.swift` — `request()` (49–87), `init()`/timeout (8–11, 54–58).

- **JSON decode blocks main actor (high).** `decoder.decode(T.self, from: data)` (82) runs on the caller's thread; called from `@MainActor` it parses thousands of objects on the UI thread. Simplest fix: mark `request()` `nonisolated` so it executes off-main and only returns to the main actor at the `await` boundary. (Alternative: `withCheckedThrowingContinuation` + `Task.detached(priority: .userInitiated)` for the decode.) *Small / high.*
- **URLSession config (medium).** Keep the injectable `session` (testability), but build a configuration with `timeoutIntervalForRequest = 30`, `timeoutIntervalForResource = 120`, `httpShouldSetCookies = false`, `httpMaximumConnectionsPerHost = 6`, and `waitsForConnectivity = true` (safe given the resource timeout). Drop the per-request `timeoutInterval = 30` once session-level is set. *Small / medium.*

### P5 — Debounce text filters `[High impact]`
**File:** `Sources/Views.swift` — `searchFilter`/`highwayFilter` (36–37), consumed in scoped methods (450–481).

Every keystroke re-filters/sorts all sections. Debounce with cancellable tasks:
```swift
@State private var debounceTask: Task<Void, Never>?
.onChange(of: searchFilter) { _, newValue in
    debounceTask?.cancel()
    debounceTask = Task {
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        debouncedSearch = newValue
    }
}
```
Feed `debouncedSearch`/`debouncedHighway` into the (now memoized — see P1) filters. *Medium / high / medium.*

> *Lower-priority perf items folded in:* memoize `TrafficStore.filtered*()` via a `[FilterKey: [Result]]` cache cleared in `apply()`; drop the `Array(…)` wrapper in `JourneyCard`'s `ForEach(journey.legs.enumerated())` (1354); avoid recomputing `thumbnailURL`/`imageURL` per frame via `.task(id: cacheToken)`. All small effort, low–medium impact — sweep them in during P1/P2.

---

## 4. Usability & Accessibility

### U1 — Filtering transparency & control `[High impact]`
**Files:** `Sources/Views.swift` — `tabPicker` (234–245), `filters` (152–189, 163–169), `EmptyStateView` (2217–2232), `CamerasTabView` (531).

- **No active-filter indication (high).** After filtering, a tab silently shows 12 of 150 items with no cue. Add `private var hasActiveFilters: Bool { !selectedRegion.isEmpty || !highwayFilter.isEmpty || !searchFilter.isEmpty }` and append " (filtered)" to tab labels (more reliable than `.badge()` on segmented controls). *Small / high.*
- **No clear-all (medium).** Add one button near Refresh: `Button { selectedRegion=""; highwayFilter=""; searchFilter="" } label: { Image(systemName: "xmark.circle") }.disabled(!hasActiveFilters).help("Clear all filters")`. Map to ⌘E (see U3). *Small / medium.*
- **No per-field clear button (medium).** Highway/Search fields need the macOS-standard inline clear. Use a trailing overlay (not `.searchable()`, which is wrong for generic filter fields):
  ```swift
  .overlay(alignment: .trailing) {
      if !highwayFilter.isEmpty {
          Button { highwayFilter = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
              .buttonStyle(.plain).padding(.trailing, 6)
      }
  }
  ```
  *Small / medium.*
- **Unhelpful empty states (medium).** "No cameras found matching your filters" doesn't say why. Pass active-filter context into `EmptyStateView` and branch the message (text-only vs. status-only vs. both vs. none) plus an "Adjust filters" action; apply the same pattern across all tabs. *Medium / medium.*
- **Tab picker doesn't scale narrow (medium).** Six segments truncate below ~1100px. Wrap in `GeometryReader` and use `.pickerStyle(.segmented)` when wide, `.radioGroup` or a `Menu` when narrow. (Largely subsumed if V1's `TabView` migration lands.) *Medium / medium.*

### U2 — Data freshness, offline state & refresh feedback `[High impact]`
**Files:** `Sources/Views.swift` — `lastUpdatedText` (145–150), `header` (86–143, 134), `filters` (179–180); ties to **F4** offline cache.

- **Absolute, ambiguous timestamp (high).** "Updated 2:34 PM" / "Not yet" gives no staleness sense. Use relative time: `lastUpdated.formatted(.relative(presentation: .named))` → "3 minutes ago". Add a `staleDataWarning()` returning a string when `Date().timeIntervalSince(lastUpdated) > 600`, shown as a banner. *Small / high.*
- **Prominent offline / stale-cache indicator (medium, critic gap).** When network is unreachable or cached data is being served (see F4), show a top banner: "Offline — showing cached data from [relative time]", and visually de-emphasize stale content (grayed cards or a "stale" `Badge`). *Medium / medium.*
- **Subtle refresh feedback (medium).** The thin `ProgressView` (134) is easy to miss. Add `if store.isRefreshing { Text("Refreshing…").font(.caption).foregroundStyle(.blue) }` and make the button tooltip dynamic: `.help(store.isRefreshing ? "Refreshing…" : "Refresh now (⌘R)")`. *Small / medium.*

### U3 — Keyboard, menus & shortcuts `[Medium impact]`
**Files:** `Sources/NZTATrafficApp.swift` — `NZTATrafficCommands` (37); `Sources/Views.swift` — `CameraCard` (1500–1570), `FilterChip` (2008–2032), `CameraStatusFilterRow` (2064–2078); critic gaps (navigation shortcuts, focus management, onboarding).

- **Non-standard Help shortcut (medium).** ⌘⇧/ should be ⌘?. Change to `.keyboardShortcut("?", modifiers: .command)` inside the existing `CommandGroup(replacing: .help)`. *Small / medium.*
- **Navigation shortcuts (medium, critic gap).** Add ⌘1–6 for tabs (via `.keyboardShortcut("1", modifiers: .command)` etc. bound to `selectedTab`), ⌘E to clear filters, ⌘, for Preferences (F-section). Document them in `AppHelpView`. *Small / medium.*
- **Cards/chips not keyboard-reachable (medium).** `CameraCard` and `FilterChip` use `.buttonStyle(.plain)`, which strips focus rings. For cards prefer `.buttonStyle(.bordered)` (restores focus ring; do **not** add `.focusable()` to a styled Button — it breaks Space activation). For chips, ensure Tab focus + Space toggling works; optionally add `.keyboardShortcut` accelerators (a UX nicety, not a WCAG requirement). *Medium / medium.*
- **Focus management & tab order (medium, critic gap).** Use `@FocusState` to define and document an explicit tab order (filter fields → chips → list); make camera cards/event rows `.focusable()` and add ↑/↓ list navigation within filtered results. Document the order in CLAUDE.md. *Medium / medium.*
- **First-run onboarding (medium, critic gap).** On first launch (gated by an `@AppStorage` flag) show a brief modal explaining tabs/filters/Help, offer to enable auto-refresh at 120s, with "Don't show again." *Medium / medium.*

### U4 — System integration `[Medium impact]`
**Files:** `Sources/NZTATrafficApp.swift`; ties to F-section.

- **Dock / menu-bar status (medium, critic gap).** Add a Dock badge for critical alerts (closures / major delays) and/or a refresh indicator; optionally a Dock menu with quick actions or a `MenuBarExtra` for at-a-glance traffic health (polish). *Medium / medium.*
- **Diagnostics export (medium, critic gap).** Add Help → "Export Diagnostics" that bundles recent API responses, per-section errors, preferences, and app version into a zip/text file. Gate verbose logging behind a debug default key. *Medium / medium.*
- **Error recovery / retry (low–medium).** ErrorBanner shows no recourse. Pass a `DataSection` into ErrorBanner for a targeted message ("Road Events failed to load") and add a Retry button calling a new `TrafficStore.reloadSection(_:)` (or `loadAllData()`). Combine with F5 backoff. *Small / medium.*

### A1 — Eliminate color-only status encoding `[High impact, WCAG 1.4.1]`
**Files:** `Sources/Views.swift` — `JourneyLegRow` flow circle (1402–1404) and direction icon (1408–1410); `RoadEventCard` accent bar (1640–1642); `DataSectionPill` indicator (2144–2158).

- **Flow status circle (high).** A 10×10 colored circle is the only flow indicator. Add a visible text label: `HStack(spacing: 4) { Circle().fill(leg.flowKind.color).frame(width: 10, height: 10); Text(leg.flowKind.label).font(.caption2).foregroundStyle(.secondary) }`. A bare `.accessibilityLabel` only helps screen readers, not color-blind sighted users. *Small / high.*
- **Event impact bar (medium).** The 5px color bar is redundant with the text Badge — mark it `.accessibilityHidden(true)`. *Small / medium.*
- **Direction icon (low).** Add `.accessibilityLabel(directionText)` ("Increasing"/"Decreasing"/"Unknown") to the arrow `Image`. *Small / low.*

### A2 — Dynamic Type & VoiceOver labels `[High impact]`
**Files:** `Sources/Views.swift` — fixed fonts (1085, 1090, 1116, 1759, 1977, 2224); `CameraCard`/`CameraPreviewView` images (1508, 1609); `DataSectionPill` (2119–2179); map markers (1099, 1125); `FilterChip` (2008–2032); `VMSCard` (1760).

- **Fixed font sizes (high, nuanced).** Replace fixed sizes on **content text** with semantic styles: StatCard value (1977) → `.largeTitle`; VMS message (1759) → `.system(.title2, design: .monospaced, weight: .bold)`. Keep fixed sizes on **layout-critical chrome** (marker glyph 1085, cluster count 1116, empty-state icon 2224); if runaway scaling is a concern there, clamp with `.dynamicTypeSize(...DynamicTypeSize.xxxLarge)`. Don't blanket-replace. *Medium / high.*
- **Image alt text (high).** AsyncImages have no labels. Add `.accessibilityLabel("\(camera.displayName) camera image")` to both card and preview; add `.accessibilityHint(...)` and `.accessibilityElement(children: .combine)` in the preview. *Small / high.*
- **Status-indicator VoiceOver (medium).** On `DataSectionPill`: `.accessibilityElement(children: .ignore)` + `.accessibilityLabel(label)` + `.accessibilityValue(displayCount + (isLoading ? " loading" : hasError ? " error" : ""))`. On markers: label = what it is, hint = what happens ("Zoom in to see individual markers" for clusters). On `FilterChip`: `.accessibilityValue(isOn ? "On" : "Off")` + `.accessibilityAddTraits(.isToggle)`. *Small / medium.*
- **VMS contrast (resolved).** The amber-on-dark ratio is ~9.7:1 — already passing; no color change needed. The real fix is the Dynamic Type font above. *Small / low.*

### A3 — Reduce Motion `[Medium impact]`
**File:** `Sources/Views.swift` — progress animation (138), map zoom (890).

Declare `@Environment(\.accessibilityReduceMotion) private var reduceMotion` and gate both: `.animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: store.isRefreshing)` and `withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.45)) { … }`. *Small / medium.*

### A4 — Map marker hit target (medium)
`TrafficMapMarker` (1094–1095): change `contentShape` from `Rectangle()` to `Circle()` to match the visual, and grow the frame toward 44×44 for trackpad/cursor precision. *Small / medium.*

---

## 5. Foundational (architecture & correctness)

> **Real bugs first.** Fix these before cosmetic work — they produce wrong data or data loss.

### F0 — Correctness bugs `[Fix immediately]`

| # | Bug | File / line | Effect | Fix |
|---|-----|-------------|--------|-----|
| B1 | **NZ date formatters have no time zone** | `Models.swift` `nzInputDateFormatter` (700–705), `nzDisplayDateFormatter` (707–712) | On a Mac set to a non-NZ zone, NZ-time strings parse/display in the device zone → wrong times shown. | Set `formatter.timeZone = TimeZone(identifier: "Pacific/Auckland")!` on **both**. *High/high/small.* |
| B2 | **`Double`→`Int` can trap** | `Models.swift` `decodeLossyInt` (1291) | `Int(value)` traps in debug / UB in release for out-of-range doubles (1e20, Infinity) from the loose API → crash or corrupt `sortOrder`/`sequenceNumber`. | Guard before converting: `guard value.isFinite, value >= Double(Int.min), value <= Double(Int.max) else { return nil }; return Int(value)`. *High/high/small.* |
| B3 | **Failed fetch wipes good data** | `TrafficStore.swift` `apply` (138) | On a transient network failure, the section array is set to `[]`, so the user loses the data they were just viewing. | Remove `self[keyPath: keyPath] = []` in the `.failure` case; keep stale data and only set `errors[section]`. Pairs with U2 stale indicator. *Medium/medium/medium.* |
| B4 | **`decodeLossyDouble` accepts NaN/Infinity** | `Models.swift` (1281) | `Double("NaN"/"Infinity")` succeeds; relies on every caller to re-validate (fragile contract). | After parsing add `guard value.isFinite else { return nil }`. *Medium/medium/small.* |
| B5 | **`imageCacheToken` changes mid-render with sheet open** | `Views.swift` (78), `TrafficStore` (60) | Refresh during an open `CameraPreviewView` mutates the live token → URL changes mid-load, interrupting the in-flight request. | Capture the token into `@State` at sheet-presentation time and use that stable value in the sheet. (Largely moot once P2 stops per-refresh token bumps.) *Medium/low/medium.* |
| B6 | **Auto-refresh Task lifecycle** | `Views.swift` `configureAutoRefresh()` (483–507) | `while !Task.isCancelled` loop with `Task.sleep(nanoseconds:)` math, redundant post-sleep cancel check, silent empty catch; no clean stop guarantee on reschedule. | Use `try await Task.sleep(for: .seconds(interval))`, drop the redundant check, catch `CancellationError` to exit cleanly. Keep `loadAllData()`'s own error handling. *High/high/medium.* |

Two robustness items in the same files (do alongside): **NZ bounds check** — add a *separate* `isInNewZealandBounds(lat:lon:)` (lat −47…−34, lon 166…178) applied at the business layer, leaving `validatedCoordinate` (576–588) as pure format validation; and **WKT sentinel min/max** (604–631) — replace `greatestFiniteMagnitude` sentinels with collecting valid coords into an array and averaging (guard non-empty). Also **document & reuse** `validatedCoordinate` (explain why (0,0) and non-finite are rejected) and have `parseWKTLineStringCoords` call it instead of inlining the checks.

### F1 — Design-token / theme module `[Enables all of §2]`
**New file:** `Sources/Theme.swift` (or `DesignTokens.swift`). Hard-coded spacing/padding/radius/color/font literals are scattered across `Views.swift` (e.g. Badge 1992–2005, StatCard 1971–1989, dozens of `padding`/`cornerRadius`/RGB values). Create namespaced tokens:
```swift
enum Spacing { static let xs = 4.0, sm = 8.0, md = 12.0, lg = 16.0, xl = 24.0 }
enum Radii   { static let card = 8.0 }
extension Color { static let vmsCardBackground = Color(red: 0.09, green: 0.13, blue: 0.18) /* … */ }
```
Then replace literals with references. This is the single-point-of-change that makes V1–V4's spacing/radius/color standardization cheap and keeps them from drifting again. *Low/low/medium — but a force multiplier; do early.*

### F2 — Migrate `TrafficStore` to `@Observable` `[High impact]`
**File:** `TrafficStore.swift` (15–32). The current `@MainActor` + `ObservableObject` + `@Published` model invalidates *all* observing views on *any* property change (the structural cause behind P1's redundant recomputation). Apply the macro: `@Observable @MainActor final class TrafficStore`, remove every `@Published`, drop `ObservableObject` conformance. Keep `@MainActor` (Observation does not provide main-thread isolation). Update views to `@State`/`@Bindable` as needed. Provides fine-grained, property-level invalidation. *Medium/high/medium.*

### F3 — Decompose `Views.swift` & extract filtering `[Maintainability]`
The 2,240-line `Views.swift` mixes container, six tab views, cards, filter rows, and shared chrome. Split by **feature/domain**: `Features/Cameras/` (CamerasTab, CameraCard, CameraStatusFilter), `Features/Events/`, `Features/VMS/`, `Features/TravelTimes/`, `Features/Map/`, and `Shared/Components/` (Badge, ErrorBanner, LoadingView, StatCard); move `TrafficTab`/`TrafficMapLayer`/`TrafficMapDetail` enums to a models/constants file. **Each new `.swift` must be added to `NZTATraffic.xcodeproj` and is picked up automatically by `build_app.sh`'s `swiftc` glob** — verify both build paths after the split. Pair with extracting the filter logic into the `@Observable FilterModel` from P1 (the proper home for "what to filter," vs. the view's "what to show"). Also replace `ContentView`'s `@StateObject = TrafficStore()` (18) with environment injection so previews/tests can pass a `TrafficStore(service: MockTrafficAPIService())`. Optionally consolidate the 15 scattered `@AppStorage` filter flags into a `FilterPreferences` struct — but treat this as a deliberate, child-view-touching refactor, not a quick swap (they're already namespaced `nzta.event.*`, etc.). *Medium/medium/large.*

### F4 — Persistent offline cache `[High impact, critic gap]`
**New:** a small disk cache (JSON files under Application Support, keyed per section) written after each successful `loadAllData()`. On launch and on fetch failure, fall back to cache; combine with `NWPathMonitor` reachability to drive the U2 offline banner ("showing cached data from [time]"). This is the architectural backing for B3, U2's stale indicator, and the offline-prominence critic gap. The CLAUDE.md "only NZTA, no caching layer" note should be updated to record this deliberate exception. *High severity / high impact / large effort.*

### F5 — Retry & resilience `[Medium impact, critic gap]`
**File:** `TrafficAPIService.swift`. Add exponential-backoff retry for transient failures (3 attempts, 1s/2s/4s) inside `request()` or a wrapper; on connectivity restore (NWPathMonitor) auto-retry failed sections. Surface a manual Retry on the per-section ErrorBanner (U4). Document the strategy in CLAUDE.md. *Medium/medium/medium.*

### F6 — Test target & fixtures `[High impact, critic gap]`
**New:** an XCTest target in `NZTATraffic.xcodeproj` plus a `run_tests.sh` (or a step in `build_app.sh`). Cover the highest-risk pure logic: lossy decoders (NaN/Infinity/overflow — directly exercising B2/B4), `formatTrafficDate` (B1 timezone), `validatedCoordinate` + NZ bounds, WKT parsing, `formatVMSMessage`, and `matches(region:highway:search:)` filtering/sorting. Add captured API-payload fixtures. This is the safety net that makes F2/F3 refactors safe. *High/high/medium.*

### F7 — Preferences/Settings window `[Medium impact, critic gap]`
**File:** `NZTATrafficApp.swift`. Add a `Settings { … }` scene (⌘, automatically) with grouped sections: Auto-refresh (enable + interval), Display (sort/show-hide), and Export/Import settings. Migrate the scattered tab-level `@AppStorage` toggles into this centralized UI (reading the same keys, so persistence is unchanged). *Medium/medium/medium.*

### F8 — State & window restoration `[High impact, critic gap]`
**File:** `Views.swift` `ContentView`. Persist UI context across restarts with `@SceneStorage` for `selectedTab`, the three filter strings, and the map camera position; the `WindowGroup` restores frame automatically when scene restoration is enabled. On launch, users return to where they left off. *Medium severity / high impact / small–medium.*

---

## 6. Prioritized roadmap

Ordered from quick wins (small effort / high impact) down to large refactors. Tier 1 = do first.

### Tier 1 — Quick wins (small effort, high impact)
| # | Item | §Ref | Effort | Impact |
|---|------|------|--------|--------|
| 1 | Set `Pacific/Auckland` time zone on NZ date formatters | F0/B1 | S | High (correctness) |
| 2 | Guard `Double`→`Int` overflow in `decodeLossyInt` | F0/B2 | S | High (crash) |
| 3 | Validate `isFinite` in `decodeLossyDouble` | F0/B4 | S | Med (correctness) |
| 4 | Stop wiping section data on fetch failure | F0/B3 | S–M | Med (data loss) |
| 5 | Stop global per-refresh image cache-busting; bounded `URLCache` | P2 | M | High (network) |
| 6 | Cache compiled WKT regex at module scope | P3 | S | High (CPU) |
| 7 | Cache `mapCoordinate` as stored property | P3 | S | High (CPU) |
| 8 | Mark `request()` `nonisolated` (decode off main thread) | P4 | S | High (responsiveness) |
| 9 | Relative "Updated X ago" timestamp + stale warning | U2 | S | High (clarity) |
| 10 | "(filtered)" tab labels + clear-all-filters button | U1 | S | High (clarity) |
| 11 | Image accessibility labels + flow-circle text label | A2/A1 | S | High (a11y) |
| 12 | Fix Help shortcut to ⌘? ; add ⌘1–6 tab shortcuts | U3 | S | Med |
| 13 | Reduce Motion gating on the two animations | A3 | S | Med |
| 14 | `@SceneStorage` tab/filter/map restoration | F8 | S–M | High (UX) |

### Tier 2 — High-value, modest effort
| # | Item | §Ref | Effort | Impact |
|---|------|------|--------|--------|
| 15 | Design-token / theme module | F1 | M | High (enables §2) |
| 16 | Memoize filter/derived pipeline (`mapCounts`, scoped*) | P1 | M | High (perf) |
| 17 | Debounce search/highway filters | P5 | M | High (perf) |
| 18 | Migrate `TrafficStore` to `@Observable` | F2 | M | High |
| 19 | Preview uses thumbnail; AsyncImage transitions + prefetch | P2 | S–M | Med |
| 20 | Replace segmented picker with native `TabView` | V1 | M | High (native feel) |
| 21 | Responsive filter bar (flexible widths, drop fixed height, clear buttons, native field style) | V2/U1 | S–M | Med |
| 22 | Unify card family (VMSCard, StatCard, radius, padding, depth) | V3 | M | High (cohesion) |
| 23 | Semantic Dynamic Type fonts on content text | A2 | M | High (a11y) |
| 24 | VoiceOver labels/values on pills, markers, chips | A2 | S | Med (a11y) |
| 25 | Map polish: hover/selection, `mapStyle`, legend, adaptive sheet, marker hit target | V4/A4 | M | High |
| 26 | Fix auto-refresh Task lifecycle | F0/B6 | M | High (correctness) |
| 27 | Context-aware empty states + refresh feedback | U1/U2 | M | Med |
| 28 | Settings window (⌘,) consolidating `@AppStorage` | F7 | M | Med |
| 29 | URLSession config + retry/backoff | P4/F5 | M | Med |

### Tier 3 — Larger refactors & infrastructure (high payoff, plan deliberately)
| # | Item | §Ref | Effort | Impact |
|---|------|------|--------|--------|
| 30 | Test target + payload fixtures + `run_tests.sh` | F6 | M | High (safety net) |
| 31 | Persistent offline cache + reachability + offline banner | F4/U2 | L | High (resilience) |
| 32 | Decompose `Views.swift` by feature; extract `FilterModel`; DI the store | F3/P1 | L | Med (maintainability) |
| 33 | Onboarding, focus management/tab order, keyboard list nav | U3 | M–L | Med |
| 34 | Dock badge / `MenuBarExtra` / diagnostics export | U4 | M–L | Med (polish) |
| 35 | Lower-priority map depth (zoom-aware polylines/clusters, `MapCircle` rings), icon/spacing micro-consistency, lossy-decoder & VMS-string consolidation | V4/V3/P3 | M | Low–Med |

### Sequencing notes & trade-offs
- **Do F1 (tokens) and P1+F2 (memoization + `@Observable`) before the visual card/chrome work** — otherwise V3/V4 spread literals that the token system later has to chase down, and per-render cost masks any perceived UX improvement.
- **F6 (tests) should ideally precede F2/F3** so the architecture refactors have a regression net; at minimum land it before F3's file split.
- **Trade-off — offline cache (F4) vs. project ethos:** CLAUDE.md explicitly says "no caching layer." F4 is a justified, documented exception (it directly fixes the data-loss bug B3 and the no-graceful-degradation gap), but it adds disk I/O and a freshness contract; if scope must be cut, B3's in-memory "keep stale data" fix (Tier 1 #4) delivers 70% of the value for near-zero cost.
- **Trade-off — `TabView` migration (V1 #20):** highest "native feel" payoff but touches the navigation backbone and interacts with the narrow-window picker concern; bundle with state restoration (F8) so tab identity persists, and keep the change isolated in one PR.
- **Trade-off — server-side image downsampling (P2):** gated on unverified server support; treat as opportunistic, not a committed line item.
- **Build hygiene:** every new file (Theme.swift, feature files, test target) must be added to `NZTATraffic.xcodeproj`; verify both `xcodebuild` and `./build_app.sh` after F1/F3/F6.

**Key source files:** `/Users/mikegencic/Documents/GitHub/NZTA-Traffic/Sources/Views.swift`, `/Users/mikegencic/Documents/GitHub/NZTA-Traffic/Sources/Models.swift`, `/Users/mikegencic/Documents/GitHub/NZTA-Traffic/Sources/TrafficStore.swift`, `/Users/mikegencic/Documents/GitHub/NZTA-Traffic/Sources/TrafficAPIService.swift`, `/Users/mikegencic/Documents/GitHub/NZTA-Traffic/Sources/NZTATrafficApp.swift`.


=== STATS ===
{
  "reviewers": 10,
  "findingsVerified": 105,
  "findingsKept": 97,
  "findingsRefuted": 8,
  "gapsFolded": 11
}
=== LOGS ===
Findings: 105 verified, 97 kept, 8 refuted.
Completeness critic found 11 gap(s) to fold in.
