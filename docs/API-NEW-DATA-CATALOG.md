# NZTA Traffic — Catalog of New Things the App Could Show

*Based on live-probe discovery data (status codes and response shapes observed, not speculated). The app currently consumes 4 of the 24 documented REST v4 resources: `/cameras/all`, `/events/all/10`, `/signs/vms/all`, `/journeys/all/10`.*

> **Journeys `000` status — resolved.** The original `000` from a quick probe of `/journeys/all/10` was **not** a real failure: re-probing returned **HTTP 200** (~1.57 MB JSON, 131 routes). It was a transient timeout (the payload is large and the server is slow). The endpoint lives exactly where expected and the app already uses it correctly. The trailing `N` controls flow-history depth, not journey count (`/all/0` balloons to ~22 MB; keep `/all/10`). A *richer* alternative also exists — see `ssdf-journey/rest/2/journeys` below.

---

## 1. Summary

Beyond the 4 endpoints in use, verified probing found a substantial amount of additional, live, auth-free data:

- **A newer API version (`rest/5`)** that mirrors all four endpoints with identical wrappers and is a drop-in superset — its only incremental value is two new event fields (`direction`, `travelDirection`). Only **v4 and v5 exist** (v1/2/3/6/7 = 404).
- **Metadata endpoints the app never calls**: `regions/all` (14 canonical regions + boundary polygons) and `ways/all` (106 highway corridors + geometry).
- **A whole new sign type**: `signs/tim/all` — 270 TIM (Traveller Information Module) boards showing live destination travel times, distinct from VMS.
- **A separate real-time congestion service**: `traffic-conditions/rest/2` — Auckland motorway congestion (Free Flow / Moderate / Heavy) with no app equivalent. **XML, not JSON.**
- **A richer journey service** (`ssdf-journey/rest/2`): `journeys` (116, ~2.88 MB) with live `averageSpeed` + expected min/max bands, and `links` (5310, ~12 MB) with per-segment speed/volume/occupancy. Both XML-default; send `Accept: application/json`.
- **Server-side filtering variants** (`withinbounds`, `byregion`) to shrink payloads for the map.
- **External NZTA/Waka Kotahi ArcGIS open data** (host `services.arcgis.com`, no auth): EV chargers, traffic-monitoring sites/AADT, daily count telemetry, a road-events mirror with clean point/polyline geometry, and speed-limit zones.
- **Many unused fields already inside the payloads the app downloads** — cheap wins needing no new endpoint (event `planned`/`endDate`/`directLineDistance`, journey `geometry`/`lengths[]`, VMS `identifier` TOC owner, camera `group`/`viewUrl`).

**Confirmed dead ends (do not pursue):** under the REST API, `roadworks/all`, `closures/all`, `incidents/all`, `weather/all`, `restareas/all`, `flow/all`, `speed/all`, `chargers/all`, `ev/all`, `holidays/all`, `conditions/all`, `alerts/all` all return **404**. No per-item detail endpoints (`camera/{id}` etc. = 404). No swagger/OpenAPI doc. The Holiday Journeys hotspot tool (`journeys.nzta.govt.nz`) has **no confirmed public API**.

---

## 2. New endpoints worth adding

| Endpoint | What it shows | Confirmed status | Suggested feature | Effort |
|---|---|---|---|---|
| `…/traffic/rest/5/{cameras\|events\|signs/vms\|journeys}/all[/N]` | Same as v4; **events gain `direction` + `travelDirection`** | **200** (events 242 KB, cameras 339 KB), no auth | Base-URL bump → carriageway badge on events ("Southbound" / "Both Directions") | Trivial |
| `…/traffic/rest/4/regions/all/10` | 14 NZTA regions `{id, name, geometry: WKT POLYGON}` (7 KB) | **200**, no auth | Region **Picker** (replace free-text filter) + optional boundary overlays | Small |
| `…/traffic/rest/4/signs/tim/all` | 270 TIM signs: lat/lon + `page.line[]` destination→minutes (159 KB) | **200**, no auth | New **TIM tab/map layer** (markers + travel-time card) | Medium |
| `…/traffic/rest/4/ways/all/10` | 106 highway corridors: WKT LINESTRING geometry, start/end lat-lon, regions[] (53 KB) | **200**, no auth | Faint highway-network polylines + values for highway filter | Medium |
| `…/traffic-conditions/rest/2` | Auckland 7 motorways, per-segment `congestion` (Free Flow/Moderate/Heavy) + lat-lon (~31 KB) | **200 but XML** (`application/xml`), no auth | **Congestion layer/list**, colour-coded segments | Medium (needs XMLParser) |
| `…/ssdf-journey/rest/2/journeys` | 116 journeys: `averageSpeed`, `lastEstimate`, `expectedMinimum/Maximum`, per-segment speed + lat-lon | **200** w/ `Accept: application/json` (~2.88 MB) | Enrich Journeys with live speed + confidence band | Medium–Large (heavy) |
| `…/ssdf-journey/rest/2/links` | 5310 links: `averageSpeed`, per-segment `averageOccupancy`/`totalVolume`/`defaultSpeed` + lat-lon | **200** w/ `Accept: application/json` (~12 MB) | On-demand traffic-flow heatmap | Large (heavy; client-side bbox filter) |
| `…/traffic/rest/4/cameras/withinbounds/{w}/{s}/{e}/{n}` and `…/byregion/{id}` | Server-side viewport / region-filtered slices (variants exist for events/journeys/vms/tim too) | **200**, no auth | Payload optimization — fetch only the map viewport / selected region | Medium |

*All `trafficnz.info` paths share the host the app already uses (so `trafficNZURL()` applies); the SSDF and traffic-conditions paths are different service roots but same host.*

---

## 3. Unused fields in existing responses (cheap wins, no new endpoint)

### Cameras (`/cameras/all`)
- **`group`** (string, e.g. `"SH20-South-Western"`) — *decoded but never surfaced.* ~33 distinct values (`"NA"` for ungrouped). Use as section headers in the camera list or a secondary grouping/filter dimension.
- **`viewUrl`** (string, e.g. `/camera/view/714`) — *decoded but unused.* Resolves to `https://trafficnz.info/camera/view/714`. Add an "Open on trafficnz.info" button / context-menu in camera detail for the larger official view + history.
- **`journey.id`** (number) — *decoded but unused.* Shares the id space of the Journeys feature → deep-link a camera to its route's live travel time (and back).
- **`journey.startLatitude/startLongitude/endLatitude/endLongitude`** — *not decoded.* Corridor endpoints → "sits on the <start>→<end> route" / draw the corridor.
- **`journeyLeg.name`** (e.g. `"Ashburton to Rangitata"`) — *decoded, not surfaced.* Show as a sublabel in the detail view.
- **`region.id`**, **`journeyLeg.totalLength`** — minor. Other leg fields (`coverage`/`flow`/`freeFlowTime`/`effectiveSpeedLimit`/`time`) are all `0`/`00:00:00` in this payload — **skip** (live values only appear in `/journeys`).

### Events (`/events/all/10`) — the richest cheap wins
- **`planned`** (bool) — *decoded, never displayed (0 refs in Views).* Add a **Planned vs Unplanned/Incident badge + filter** — the single most useful event distinction (roadworks vs live incident).
- **`endDate`** (ISO8601 +12:00) — *decoded, never displayed.* Show "ends 1 Jul 6:00 pm" / "ends in 2h"; use `startDate..endDate` to flag currently-active vs upcoming scheduled work.
- **`eventCreated`** — *decoded, not displayed.* "Reported 3 days ago" freshness.
- **`eventModified`** — *decoded, not displayed.* "Updated X ago"; sort active incidents by recency; badge stale ones.
- **`eventIsland`** (`"North Island"`/`"South Island"`) — *decoded, not displayed.* Cheap N/S Island segmented filter or section grouping.
- **`directLineDistance1` / `2` / `3`** (e.g. `"1.20 km north of Rapahoe"`) — **not decoded at all (no CodingKey).** Human-readable nearest-landmark text — a friendlier secondary location line than the linear-ref location code. Add the three as a "near" context list.
- **`journey.start/end lat-lon`** and **`journeyLeg.totalLength/sequenceNumber/effectiveSpeedLimit/coverage/flow/freeFlowTime`** — *discarded* (shared `JourneyLeg` model decodes only `name`). Could draw the event's affected route extent and show live flow on the leg it sits on.

### VMS (`/signs/vms/all`)
- **`identifier`** (e.g. `$WLG://signs/ACHERON`) — *decoded, used only as an ID fallback, never displayed.* Prefix encodes the operating control centre (`$WLG` = Wellington, 228 signs; `$AKL` = Auckland, 163 signs) plus a station name. Surface a **TOC owner badge** + station name in detail.
- **`journey.id`** — *decoded, unused.* Cross-link the sign to its Journeys travel time.
- **`journey.start/end lat-lon`** — *not decoded.* Corridor the sign monitors (route geometry on map).
- **`journeyLeg.name`** (e.g. `"Plimmerton to Paremata"`) — *decoded, not surfaced.* Segment label in sign detail.
- `region.id`, `way.id` (loosely typed), and leg zero-fields — minor/skip.

### Journeys (`/journeys/all/10`)
- **`geometry`** (WKT `MULTILINESTRING`, journey level) — **not decoded** (model parses geometry per-leg only). The **full route polyline** → draw a whole journey as one overlay / fit-to-route without stitching legs.
- **`startLatitude/startLongitude`** + **`endLatitude/endLongitude`** (journey level) — *not decoded.* Place start/end markers.
- **`leg.lengths[]`** — array of `{linkName, linkSpeed, linkSpeedLimit, linkLength, timeSeconds, proportion, totalLength}` — **not decoded (no model type).** Present on the ~63 live legs. Per-link sub-segment speed vs limit → fine-grained **congestion heatmap**, a **"slowest link" callout** (e.g. named ramp-to-ramp segments), and section labels far richer than the single leg-flow colour.
- **`leg.sequenceNumber`** — decoded only to build a leg id; could explicitly order/number legs in a list.
- **`time`** (journey level) — always `00:00:00`; **ignore** (real travel time is per-leg).

---

## 4. Adjacent NZTA / NZ datasets (external)

All hosted on `services.arcgis.com/CXBb7LAjgIIdcsPt` (**not** `trafficnz.info` — they bypass `trafficNZURL()`), **no auth/token**, return GeoJSON/JSON. Caveats common to all: booleans and some dates arrive as **strings** (`"True"`/`"False"`, epoch-millis) → use the lossy-decode treatment; ArcGIS pages at ≤2000 features (watch `exceededTransferLimit`).

| Dataset | Live access URL (query) | Format / auth | Feature it enables | Confirmed live |
|---|---|---|---|---|
| **EV Roam charging stations** (636) | `…/EV_Roam_charging_stations/FeatureServer/0/query?where=1=1&outFields=*&outSR=4326&f=geojson` | GeoJSON, no auth | **EV Chargers** map layer/tab: operator, AC/DC + max kW, connector counts/availability, 24 h + cost flags. `connectorsList` is a brace-delimited string (not JSON) → custom parse | **Yes** |
| **Road Events** — Highway Information layer 0 (110 active) | `…/NZTA_Highway_Information/FeatureServer/0/query?where=status='Active'&outFields=*&f=geojson` | GeoJSON points, SQL `where` | Clean point coords (no WKT centroid parsing) + a **`restrictions`** field the trafficnz feed lacks → fallback/cross-check or enrich events | **Yes** |
| **Road Area Events** — Highway Information layer 1 (46 active) | `…/NZTA_Highway_Information/FeatureServer/1/query?where=status='Active'&outFields=*&f=geojson` | GeoJSON LineString | Draw affected road **segments as polylines**, colour by impact (closure/delay/caution). Reuses `parseWKTLineStringCoords` + `MapPolyline` | **Yes** |
| **SH Traffic Monitoring Sites (AADT)** (2042 points) | `…/Assets_SHTrafficMonitoringSites/FeatureServer/0/query?where=1=1&outFields=*&outSR=4326&f=geojson` | GeoJSON points | Map layer sized/coloured by AADT volume + 5-year AADT trend + `percentheavy` popup. Also the **location join** for the TMS daily table | **Yes** |
| **TMS daily traffic counts** (`TMS_Telemetry_Sites`, 7.9 M rows) | `…/TMS_Telemetry_Sites/FeatureServer/0/query?where=siteID=39&outFields=startDate,siteID,classWeight,trafficCount,flowDirection&orderByFields=startDate DESC&resultRecordCount=10&f=json` | JSON **table (non-spatial)** | Per-site "volume today / 7-day trend", Light vs Heavy, by direction. Latest data 2026-05-31 (daily). Must use `groupBy`/stats + date filter; join `siteID`/`SiteRef` to AADT layer for location | **Yes** |
| **Speed Limit Zones** (`SpeedLimitZoneFull__View`, 69 088 zones) | `…/SpeedLimitZoneFull__View/FeatureServer/0/query?where=1=1&outFields=*&outSR=4326&f=geojson` | GeoJSON lines/zones | Speed-limit map overlay; **too large to pull whole** → fetch per-viewport via geometry envelope | **Yes** (large) |
| **Holiday Journeys hotspots** | `https://journeys.nzta.govt.nz/` | Web map, **no public API found** | "Best/worst times to travel this long weekend." No drop-in feed; could be approximated from TMS counts by day-of-week/hour | **No** — future R&D |

---

## 5. Recommended additions, ranked (value / effort)

1. **Surface unused event fields** — *Value: High / Effort: Small.*
   **User sees:** a **Planned vs Incident** badge + filter, "ends in 2h" / "reported 3 days ago", a friendly landmark line ("1.2 km N of Rapahoe"), and a North/South Island filter.
   **Source:** existing `/events/all/10` (most already decoded). **Impl:** add CodingKeys for `directLineDistance1-3` (new); add card fields + a `planned` filter predicate to `matches(...)`; format dates relative. No new endpoint. *The cheapest, highest-impact win.*

2. **Bump base URL to `rest/5`** — *Value: Medium / Effort: Trivial.*
   **User sees:** a carriageway badge on events ("Southbound" / "Both Directions").
   **Source:** `rest/5` (drop-in superset). **Impl:** change the base-URL constant in `TrafficAPIService.swift`; add `direction` + `travelDirection` to the event CodingKeys + a badge. Cameras/VMS/journeys unaffected (identical to v4).

3. **Region Picker from `/regions/all`** — *Value: High / Effort: Small.*
   **User sees:** a canonical 14-region dropdown instead of the free-text region field; optionally faint region boundary overlays.
   **Source:** `rest/4/regions/all/10`. **Impl:** small WKT-`POLYGON` parser (→ `[CLLocationCoordinate2D]`), populate the Picker, optional `MapPolygon`. **Caveat:** names are title-cased and inconsistent (`"Bay Of Plenty"`, `"Hawkes Bay"` no apostrophe, `"Nelson/Marlborough"`) — normalize before joining against payload region strings.

4. **Camera "Open on trafficnz.info" + camera↔journey deep-link** — *Value: Medium / Effort: Small.*
   **User sees:** an "Open larger view" button per camera (via `viewUrl`) and a tap-through from a camera to its live travel time in Journeys (via `journey.id`).
   **Source:** existing `/cameras/all`. **Impl:** card button + a lookup keyed on `journey.id`. No new endpoint.

5. **EV Chargers layer/tab** — *Value: High / Effort: Small–Medium.*
   **User sees:** a new map layer / list of 636 chargers with operator, AC/DC + kW, connector availability, 24 h + cost flags, filterable by region/operator.
   **Source:** EV Roam ArcGIS GeoJSON (no auth, single unpaged call covers all 636). **Impl:** new `EVCharger` Decodable (GeoJSON FeatureCollection; lossy `"True"`/`"False"`; parse `connectorsList` brace string), new map layer reusing the `mapCoordinate` pattern. Static data → **no cache token needed**. The most additive, non-redundant road-trip feature.

6. **TIM signs tab/layer** — *Value: High / Effort: Medium.*
   **User sees:** 270 overhead destination-travel-time boards on the map + cards rendering "CITY CENTRE → 27 min".
   **Source:** `rest/4/signs/tim/all`. **Impl:** new `TIMSign` model mirroring the VMS tab. **Caveats (observed):** `page` is usually a dict but can be a list of pages; `right` is int or string; `way.id` is int or string — all need `decodeLossy` + tolerant `page` handling.

7. **Auckland real-time congestion layer** — *Value: High (no app equivalent) / Effort: Medium.*
   **User sees:** colour-coded Free Flow / Moderate / Heavy motorway segments (7 Auckland motorways) as polylines/list.
   **Source:** `traffic-conditions/rest/2`. **Impl:** **requires an `XMLParser`-based decode** — the response is `application/xml`, so it cannot use the existing `JSONDecoder` pipeline (or try the `application/jsonp` variant the WADL lists). Auckland-only.

8. **Enrich Journeys (speed + confidence band + full-route overlay + slowest link)** — *Value: Medium–High / Effort: Medium–Large.*
   **User sees:** live `averageSpeed` and an expected min/max band per journey, the whole route drawn as one overlay, and a "slowest link" callout with named sections.
   **Source:** `ssdf-journey/rest/2/journeys` (`Accept: application/json`, ~2.88 MB) for speed/band; the existing `/journeys` feed's undecoded `geometry` (MULTILINESTRING) and `leg.lengths[]` for the route polyline + per-link speeds. **Impl:** new heavier Decodable; **fetch on-demand, not on every auto-refresh tick.**

9. **Highway corridor polylines + highway filter from `/ways/all`** — *Value: Low–Medium / Effort: Medium.*
   **User sees:** faint highway-network context lines on the map; highway-filter values backed by real corridor names.
   **Source:** `rest/4/ways/all/10`. **Impl:** reuse `parseWKTLineStringCoords` (after swapping lon/lat). **Caveats:** `name` duplicates a numeric `id` (not friendly like "SH1"), and per-way `regions` arrays are coarse.

10. **AADT / traffic-volume context (+ optional TMS daily panel)** — *Value: Medium / Effort: Medium (AADT) to Large (TMS daily).*
    **User sees:** count-site pins sized/coloured by AADT with a 5-year trend + %heavy; optionally "volume today vs normal".
    **Source:** `Assets_SHTrafficMonitoringSites` (map + trend); `TMS_Telemetry_Sites` (daily, **non-spatial** — needs `groupBy` stats + join on `SiteRef`). **Impl:** new ArcGIS models; never pull the 7.9 M-row table unscoped.

11. **SSDF `links` traffic-flow heatmap** — *Value: Medium / Effort: Large.*
    **User sees:** granular network-wide speed/volume/occupancy.
    **Source:** `ssdf-journey/rest/2/links` (~12 MB JSON). **Impl:** on-demand only, client-side bbox/region filter or sampling before display; never on auto-refresh. Lowest priority purely due to weight.

12. **Holiday hotspots** — *skip for now.* No confirmed feed; treat as future R&D approximated from TMS counts.

---

### Notes on availability & auth
- Everything under `trafficnz.info` is **unauthenticated plain GET** (the app's existing pattern). SSDF and traffic-conditions need `Accept: application/json` (else XML); traffic-conditions has **no JSON, only XML/jsonp** at the root.
- All ArcGIS datasets are **anonymous public FeatureServers** on `services.arcgis.com` — no key/token, but a **different host** (won't flow through `trafficNZURL()`), string-typed booleans/dates, and ≤2000-feature paging.
- Only API versions **v4 and v5** exist; no swagger; no roadworks/closures/weather/restareas/per-item-detail REST endpoints (all 404).