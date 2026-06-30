import CoreLocation
import Foundation

func runModelTests(_ t: TestRunner) {
    testLossyInt(t)
    testLossyDouble(t)
    testValidatedCoordinate(t)
    testWKTParsing(t)
    testVMSMessage(t)
    testTrafficDate(t)
    testCameraMatching(t)
    testEventFields(t)
    testRegions(t)
    testEVChargers(t)
    testTIMSigns(t)
    testJourneyEnrichment(t)
    testCongestion(t)
    testCacheableSectionDecoding(t)
    testDiagnosticsReport(t)
}

// Help → Export Diagnostics renders a plain-text report. Pins the formatting:
// per-section error lines, error-free sections, and the `nzta.*` preference
// filter that keeps unrelated UserDefaults keys out of the report.
private func testDiagnosticsReport(_ t: TestRunner) {
    t.group("diagnostics report")

    let report = DiagnosticsReport(
        appVersion: "2.1",
        appBuild: "42",
        generatedAt: Date(timeIntervalSince1970: 0),
        lastUpdated: nil,
        isOnline: false,
        sections: [
            .init(name: "Cameras", count: 12, error: nil),
            .init(name: "Road Events", count: 0, error: "NZTA API returned HTTP 503.")
        ],
        preferences: ["nzta.autoRefreshEnabled": "true"]
    )
    let text = report.formattedText()

    t.check(text.contains("App Version:  2.1 (build 42)"), "report includes app version and build")
    t.check(text.contains("Network:      offline"), "report includes network state")
    t.check(text.contains("Last Updated: never"), "report shows never when no last-updated date")
    t.check(text.contains("Cameras: 12"), "error-free section renders as a plain count")
    t.check(
        text.contains("Road Events: 0 — ERROR: NZTA API returned HTTP 503."),
        "section with an error renders its message"
    )
    t.check(text.contains("nzta.autoRefreshEnabled = true"), "report lists app preferences")

    let defaults = UserDefaults(suiteName: "nzta.diagnostics.test")!
    defaults.removePersistentDomain(forName: "nzta.diagnostics.test")
    defaults.set(true, forKey: "nzta.autoRefreshEnabled")
    defaults.set("ignored", forKey: "com.apple.unrelated.key")
    let prefs = DiagnosticsReport.collectPreferences(from: defaults)
    t.equal(prefs["nzta.autoRefreshEnabled"], "1", "collects nzta.* preferences")
    t.check(prefs["com.apple.unrelated.key"] == nil, "ignores non-nzta preference keys")
    defaults.removePersistentDomain(forName: "nzta.diagnostics.test")
}

// The offline cache stores each cacheable section's raw API response bytes and
// replays them through the same payload wrappers on a later launch or fetch
// failure. This pins that re-decode path: the four wrappers must decode the
// full `{"response":{…}}` response shape the cache persists.
private func testCacheableSectionDecoding(_ t: TestRunner) {
    t.group("offline cache re-decode")

    let camerasJSON = #"{"response":{"camera":[{"id":714,"name":"Hinds","highway":"SH1","latitude":-43.9,"longitude":171.5}]}}"#
    let cameras = decodeModel(CamerasPayload.self, camerasJSON, t)?.response.camera
    t.equal(cameras?.count, 1, "cached cameras payload re-decodes")
    t.equal(cameras?.first?.name, "Hinds", "cached camera fields survive re-decode")

    let eventsJSON = #"{"response":{"roadevent":[{"id":"e1","eventDescription":"Slip","impact":"ROAD_CLOSED"}]}}"#
    let events = decodeModel(RoadEventsPayload.self, eventsJSON, t)?.response.roadevent
    t.equal(events?.count, 1, "cached events payload re-decodes")
    t.equal(events?.first?.eventDescription, "Slip", "cached event fields survive re-decode")

    let vmsJSON = #"{"response":{"vms":[{"id":"v1","name":"SH1 Sign","currentMessage":"DRIVE[nl]SAFE"}]}}"#
    let vms = decodeModel(VMSPayload.self, vmsJSON, t)?.response.vms
    t.equal(vms?.count, 1, "cached VMS payload re-decodes")

    let journeysJSON = #"{"response":{"journey":[{"id":339,"name":"CNC","totalLength":1200}]}}"#
    let journeys = decodeModel(JourneysPayload.self, journeysJSON, t)?.response.journey
    t.equal(journeys?.count, 1, "cached journeys payload re-decodes")
    t.equal(journeys?.first?.displayName, "CNC", "cached journey fields survive re-decode")
}

// Auckland congestion XML feed (traffic-conditions/rest/2). Verifies the
// XMLParser-based decode: namespaced `tns:` elements, the shared `name` element
// disambiguated by parent (motorway vs. segment), level-string mapping,
// start/end coordinate parsing into a drawable polyline, and the dropping of
// segments whose only coordinates are invalid (0,0).
private func testCongestion(_ t: TestRunner) {
    t.group("Auckland congestion (XML)")

    let xml = #"""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <tns:getTrafficConditionsResponse xmlns:tns="https://infoconnect.example/schemas/traffic2">
      <tns:trafficConditions>
        <tns:lastUpdated>2026-06-30T17:18:16.235+12:00</tns:lastUpdated>
        <tns:motorways>
          <tns:name>Northern Motorway</tns:name>
          <tns:locations>
            <tns:congestion>Free Flow</tns:congestion>
            <tns:direction>Southbound</tns:direction>
            <tns:endLat>-36.7506</tns:endLat>
            <tns:endLon>174.7260</tns:endLon>
            <tns:id>2</tns:id>
            <tns:inOut>In</tns:inOut>
            <tns:name>Oteha Valley Rd - Upper Harb Hwy</tns:name>
            <tns:order>1</tns:order>
            <tns:startLat>-36.7183</tns:startLat>
            <tns:startLon>174.7126</tns:startLon>
          </tns:locations>
          <tns:locations>
            <tns:congestion>Heavy</tns:congestion>
            <tns:direction>Southbound</tns:direction>
            <tns:endLat>-36.8124</tns:endLat>
            <tns:endLon>174.7533</tns:endLon>
            <tns:id>8</tns:id>
            <tns:inOut>In</tns:inOut>
            <tns:name>Esmonde Rd - Onewa</tns:name>
            <tns:order>4</tns:order>
            <tns:startLat>-36.7993</tns:startLat>
            <tns:startLon>174.7613</tns:startLon>
          </tns:locations>
        </tns:motorways>
        <tns:motorways>
          <tns:name>Southern Motorway</tns:name>
          <tns:locations>
            <tns:congestion>Congested</tns:congestion>
            <tns:direction>Northbound</tns:direction>
            <tns:endLat>0</tns:endLat>
            <tns:endLon>0</tns:endLon>
            <tns:id>40</tns:id>
            <tns:name>Bad Coords</tns:name>
            <tns:startLat>0</tns:startLat>
            <tns:startLon>0</tns:startLon>
          </tns:locations>
        </tns:motorways>
      </tns:trafficConditions>
    </tns:getTrafficConditionsResponse>
    """#

    guard let segments = CongestionXMLParser.parse(Data(xml.utf8)) else {
        t.check(false, "congestion XML parses to a non-nil result")
        return
    }
    t.equal(segments.count, 2, "two valid segments kept, the (0,0) one dropped")

    guard let first = segments.first else { return }
    t.equal(first.motorwayName, "Northern Motorway", "motorway name propagates to its segments")
    t.equal(first.name, "Oteha Valley Rd - Upper Harb Hwy", "segment name from the locations-level name")
    t.equal(first.direction, "Southbound", "segment direction decodes")
    t.check(first.level == .freeFlow, "Free Flow maps to .freeFlow")
    t.equal(first.polyline.count, 2, "both ends present -> 2-point polyline")
    if first.polyline.count == 2 {
        t.nearlyEqual(first.polyline.first?.latitude, -36.7183, "polyline starts at startLat/Lon")
        t.nearlyEqual(first.polyline.last?.longitude, 174.7260, "polyline ends at endLat/Lon")
    }
    t.check(first.mapCoordinate != nil, "valid segment yields a midpoint coordinate")

    let second = segments[1]
    t.check(second.level == .heavy, "Heavy maps to .heavy")
    t.equal(second.motorwayName, "Northern Motorway", "second segment still under the first motorway")

    // The (0,0) Southern Motorway segment is dropped entirely.
    t.check(!segments.contains { $0.motorwayName == "Southern Motorway" }, "invalid-coordinate segment dropped")

    // Level-string mapping in isolation, including the unknown fallback.
    t.check(congestionLevel(from: "Free Flow") == .freeFlow, "Free Flow string")
    t.check(congestionLevel(from: "MODERATE") == .moderate, "Moderate is case-insensitive")
    t.check(congestionLevel(from: "Heavy") == .heavy, "Heavy string")
    t.check(congestionLevel(from: "Congested") == .congested, "Congested string")
    t.check(congestionLevel(from: "weird") == .unknown, "unrecognised value -> unknown")
    t.check(congestionLevel(from: nil) == .unknown, "nil -> unknown")
    t.check(CongestionLevel.congested.severityRank > CongestionLevel.freeFlow.severityRank, "congested ranks worse than free flow")

    // Malformed XML must fail the parse (returns nil) rather than crashing.
    t.check(CongestionXMLParser.parse(Data("not xml <<".utf8)) == nil, "malformed XML -> nil")
}

// Journey-level route geometry (WKT MULTILINESTRING -> single overlay polyline)
// and the "slowest leg" bottleneck (lowest flow among legs with live data).
private func testJourneyEnrichment(_ t: TestRunner) {
    t.group("journey route + slowest leg")
    let json = #"""
    {
      "id": "j1",
      "name": "SH1",
      "geometry": "MULTILINESTRING ((174.0 -41.0, 174.5 -41.5, 175.0 -42.0))",
      "legs": [
        {"name": "A to B", "sequenceNumber": 1, "speed": 90, "flow": 0.95, "coverage": 1, "geometry": "LINESTRING (174.0 -41.0, 174.5 -41.5)"},
        {"name": "B to C", "sequenceNumber": 2, "speed": 22, "flow": 0.24, "coverage": 1, "time": "0:05:30", "geometry": "LINESTRING (174.5 -41.5, 175.0 -42.0)"},
        {"name": "Stale", "sequenceNumber": 3, "speed": -1, "flow": 0, "coverage": 0}
      ]
    }
    """#
    guard let journey = decodeModel(TrafficJourney.self, json, t) else { return }

    t.equal(journey.routePolylineLatitudes.count, 3, "route geometry yields 3 points")
    t.equal(journey.routePolyline.count, 3, "routePolyline builds 3 coordinates")
    if journey.routePolyline.count == 3 {
        t.nearlyEqual(journey.routePolyline[0].latitude, -41.0, "route first latitude")
        t.nearlyEqual(journey.routePolyline[2].longitude, 175.0, "route last longitude")
    }

    let slowest = journey.slowestLeg
    t.equal(slowest?.name, "B to C", "slowest leg is the lowest-flow live leg")
    t.check(slowest?.flowKind == .congested, "slowest leg flowKind reflects congestion")
    t.nearlyEqual(slowest?.currentTimeSeconds ?? -1, 330, "leg time HH:MM:SS parses to cached seconds")
    t.check(journey.slowestLeg?.name != "Stale", "stale (no live data) leg is never the slowest")

    // A journey with no live legs has no bottleneck to surface.
    let deadJson = #"""
    {"id":"j2","name":"Quiet","geometry":"MULTILINESTRING ((174.0 -41.0, 175.0 -42.0))",
     "legs":[{"name":"X","sequenceNumber":1,"speed":-1,"flow":0,"coverage":0}]}
    """#
    guard let dead = decodeModel(TrafficJourney.self, deadJson, t) else { return }
    t.check(dead.slowestLeg == nil, "no live legs -> nil slowestLeg")
    t.equal(dead.routePolyline.count, 2, "route still parses without live legs")
}

// TIM travel-time board decoding. The upstream shape is loose: `page` is a
// single object OR a list of pages OR absent; a line is either left+right
// (destination + minutes, with `right` an Int OR a units-bearing string) or a
// decorative center-only line; `way.id` is int-or-string. Lines without both a
// destination and a time are dropped.
private func testTIMSigns(_ t: TestRunner) {
    t.group("TIM signs")

    // page as a single object, integer `right` (minutes), string `way.id`,
    // and a leading decorative center-only line that must be dropped.
    let dictJson = #"""
    {"response":{"tim":[
      {"id":334,"latitude":-36.999,"longitude":174.788,"way":{"id":"20A","name":"20A"},
       "region":{"id":2,"name":"Auckland"},
       "page":{"line":[{"center":"VIA SH20 R12"},{"left":"SH1 GILLIES","right":70},{"left":"CITY CENTRE","right":79}],"pageTime":5}}
    ]}}
    """#
    guard let payload = decodeModel(TIMSignsPayload.self, dictJson, t) else { return }
    t.equal(payload.response.tim.count, 1, "tim payload decodes one sign")
    guard let sign = payload.response.tim.first else { return }
    t.equal(sign.lines.count, 2, "center-only line dropped, two travel lines kept")
    t.equal(sign.lines.first?.destination, "SH1 GILLIES", "destination from left")
    t.equal(sign.lines.first?.timeText, "70 min", "integer right formats as minutes")
    t.equal(sign.lines.last?.timeText, "79 min", "second integer right formats as minutes")
    t.equal(sign.regionName, "Auckland", "region decodes")
    t.equal(sign.routeName, "20A", "way name decodes (string way.id tolerated)")
    t.equal(sign.headline, "SH1 GILLIES 70 min", "headline is the first destination/time")
    t.check(sign.mapCoordinate != nil, "valid lat/lon yields a map coordinate")

    // page as a LIST of pages, integer `way.id`, a units-bearing string `right`
    // ("29 MINS") passed through verbatim, plus a decorative second page.
    let listJson = #"""
    {"response":{"tim":[
      {"id":350,"name":"Constellation Drive","latitude":-36.78,"longitude":174.73,"way":{"id":54,"name":"020"},
       "page":[{"line":[{"left":"OTEHA","right":4},{"left":"WAINUI","right":"29 MINS"}],"pageTime":6},
               {"line":[{"center":"ESTIMATED"},{"center":"MINUTES"}],"pageTime":1}]}
    ]}}
    """#
    let listSign = decodeModel(TIMSignsPayload.self, listJson, t)?.response.tim.first
    t.equal(listSign?.lines.count, 2, "page-as-list flattens to two travel lines")
    t.equal(listSign?.lines.first?.timeText, "4 min", "list page integer right formats as minutes")
    t.equal(listSign?.lines.last?.timeText, "29 MINS", "string right passed through verbatim")
    t.equal(listSign?.routeName, "020", "way name decodes (integer way.id tolerated)")
    t.equal(listSign?.displayName, "Constellation Drive", "name surfaces as displayName")
    t.check(listSign?.summary?.contains("OTEHA 4 min") == true, "summary joins destination/time pairs")

    // No `page` at all: decodes safely with no lines but still maps.
    let noPageJson = #"{"response":{"tim":[{"id":343,"name":"Site 1","latitude":-36.87,"longitude":174.74}]}}"#
    let noPageSign = decodeModel(TIMSignsPayload.self, noPageJson, t)?.response.tim.first
    t.check(noPageSign?.lines.isEmpty == true, "missing page -> no lines")
    t.check(noPageSign?.headline == nil, "no lines -> nil headline")
    t.check(noPageSign?.mapCoordinate != nil, "sign without page still maps")

    // Single (non-array) tim object still decodes via decodeFlexibleArray.
    let single = #"{"response":{"tim":{"id":1,"name":"Solo","latitude":-41.2,"longitude":174.8,"page":{"line":[{"left":"CBD","right":12}]}}}}"#
    t.equal(decodeModel(TIMSignsPayload.self, single, t)?.response.tim.count, 1, "single tim object decodes as one-element array")

    // Filtering predicate: region/highway(haystack)/search. `sign` is the
    // Auckland board decoded above.
    t.check(sign.matches(region: "auckland", highway: "", search: ""), "region match is case-insensitive")
    t.check(!sign.matches(region: "Otago", highway: "", search: ""), "wrong region excluded")
    t.check(sign.matches(region: "", highway: "20a", search: ""), "highway haystack matches way name")
    t.check(sign.matches(region: "", highway: "", search: "city centre"), "search matches a destination")
    t.check(!sign.matches(region: "", highway: "", search: "zzz"), "non-matching search excluded")
}

// EV Roam GeoJSON FeatureCollection decoding: geometry [lon,lat] coordinate,
// loose-typed "True"/"False" booleans, and the packed connectorsList string
// (max power + distinct connector types).
private func testEVChargers(_ t: TestRunner) {
    t.group("EV chargers")

    let json = #"""
    {"type":"FeatureCollection","features":[
      {"type":"Feature","id":1,"geometry":{"type":"Point","coordinates":[174.7633,-36.8485]},
       "properties":{"OBJECTID":1,"name":"Queen St Hub","operator":"BP","address":"1 Queen St",
        "currentType":"DC","numberOfConnectors":2,
        "connectorsList":"{DC, 50 kW, CHAdeMO, Status: Operative, Count:1},{DC, 75 kW, Type 2 CCS, Status: Operative, Count:1}",
        "is24Hours":"True","hasChargingCost":"False"}}
    ]}
    """#
    guard let payload = decodeModel(EVChargersPayload.self, json, t) else { return }
    t.equal(payload.features.count, 1, "feature collection decodes one charger")
    guard let charger = payload.features.first else { return }
    t.equal(charger.name, "Queen St Hub", "name decodes from properties")
    t.equal(charger.operatorName, "BP", "operator decodes (mapped key)")
    t.equal(charger.currentType, "DC", "currentType decodes")
    t.equal(charger.connectorCount, 2, "numberOfConnectors decodes")
    t.equal(charger.is24Hours, true, "is24Hours True string -> bool")
    t.equal(charger.hasChargingCost, false, "hasChargingCost False string -> bool")
    t.check(charger.isDC, "DC currentType reads as DC")
    t.nearlyEqual(charger.maxPowerKW, 75, "maxPowerKW is the highest advertised power")
    t.check(charger.connectorTypes.contains("CHAdeMO"), "CHAdeMO connector parsed")
    t.check(charger.connectorTypes.contains("Type 2 CCS"), "Type 2 CCS connector parsed")
    t.check(charger.mapCoordinate != nil, "geometry coordinate yields a map coordinate")
    t.nearlyEqual(charger.latitude, -36.8485, "latitude from geometry (2nd coordinate)")
    t.nearlyEqual(charger.longitude, 174.7633, "longitude from geometry (1st coordinate)")
    t.equal(charger.powerSummary, "DC · 75 kW", "powerSummary combines type and max power")

    // Connector parsing in isolation: distinct types de-duped, max kW chosen.
    let parsed = parseEVConnectors("{AC, 22 kW, Type 2 Socketed, Count:2},{AC, 7 kW, Type 2 Socketed, Count:1}")
    t.nearlyEqual(parsed.maxPowerKW, 22, "parseEVConnectors picks the max kW")
    t.equal(parsed.connectorTypes.count, 1, "duplicate connector types are de-duplicated")

    // An AC-only site with a missing power string still decodes safely.
    let acJson = #"{"type":"FeatureCollection","features":[{"type":"Feature","geometry":{"type":"Point","coordinates":[175.0,-37.0]},"properties":{"name":"AC Stop","currentType":"AC","connectorsList":""}}]}"#
    let acCharger = decodeModel(EVChargersPayload.self, acJson, t)?.features.first
    t.check(acCharger?.isDC == false, "AC currentType is not DC")
    t.check(acCharger?.maxPowerKW == nil, "empty connectorsList -> nil maxPowerKW")
    t.equal(acCharger?.powerSummary, "AC", "powerSummary falls back to currentType when no power")
}

// Canonical /regions/all payload decoding + the merge/dedupe that feeds the
// region Picker.
private func testRegions(_ t: TestRunner) {
    t.group("regions")

    let json = #"{"response":{"region":[{"id":1,"name":"Northland","geometry":"POLYGON ((1 2))"},{"id":2,"name":"Bay Of Plenty","geometry":"POLYGON ((3 4))"}]}}"#
    guard let payload = decodeModel(RegionsPayload.self, json, t) else { return }
    t.equal(payload.response.region.count, 2, "regions payload decodes both entries")
    t.equal(payload.response.region.first?.name, "Northland", "region name decodes (geometry ignored)")

    // Single (non-array) region still decodes via decodeFlexibleArray.
    let single = #"{"response":{"region":{"id":"7","name":"Taranaki"}}}"#
    t.equal(decodeModel(RegionsPayload.self, single, t)?.response.region.count, 1, "single region object decodes as one-element array")

    // Merge: canonical casing wins over a differently-cased derived duplicate,
    // novel derived names are added, blanks dropped, result sorted.
    let merged = mergedRegionNames(
        canonical: ["Bay Of Plenty", "Auckland"],
        derived: ["auckland", "  ", "Waikato", "AUCKLAND"]
    )
    t.equal(merged, ["Auckland", "Bay Of Plenty", "Waikato"], "merged regions deduped case-insensitively, canonical cased, sorted")

    // No canonical data yet: picker still works off derived names alone.
    t.equal(mergedRegionNames(canonical: [], derived: ["Otago", "otago"]), ["Otago"], "derived-only merge dedupes")
    t.equal(mergedRegionNames(canonical: ["Southland"], derived: []), ["Southland"], "canonical-only merge is stable before data loads")
}

// B2 — Double->Int conversion must never trap on out-of-range / non-finite.
private func testLossyInt(_ t: TestRunner) {
    t.group("decodeLossyInt")
    t.equal(decodeModel(TrafficCamera.self, #"{"id":"a","sortOrder":7}"#, t)?.sortOrder, 7, "integer passes through")
    t.equal(decodeModel(TrafficCamera.self, #"{"id":"b","sortOrder":"42"}"#, t)?.sortOrder, 42, "numeric string parses")
    // 1e20 overflows Int; old code trapped, new code returns nil.
    t.equal(decodeModel(TrafficCamera.self, #"{"id":"c","sortOrder":1e20}"#, t)?.sortOrder, nil, "overflow double -> nil (no trap)")
    t.equal(decodeModel(TrafficCamera.self, #"{"id":"d","sortOrder":"oops"}"#, t)?.sortOrder, nil, "non-numeric string -> nil")
}

// B4 — non-finite doubles must be rejected.
private func testLossyDouble(_ t: TestRunner) {
    t.group("decodeLossyDouble")
    let nanCam = decodeModel(TrafficCamera.self, #"{"id":"e","latitude":"NaN","longitude":174.0}"#, t)
    t.equal(nanCam?.latitude, nil, "NaN string latitude -> nil")
    t.check(nanCam?.mapCoordinate == nil, "NaN latitude yields no map coordinate")

    let infCam = decodeModel(TrafficCamera.self, #"{"id":"f","latitude":"Infinity","longitude":174.0}"#, t)
    t.equal(infCam?.latitude, nil, "Infinity string latitude -> nil")

    let goodCam = decodeModel(TrafficCamera.self, #"{"id":"g","latitude":-41.25,"longitude":174.81}"#, t)
    t.nearlyEqual(goodCam?.latitude, -41.25, "valid latitude parses")
    t.check(goodCam?.mapCoordinate != nil, "valid coordinates yield a map coordinate")
}

private func testValidatedCoordinate(_ t: TestRunner) {
    t.group("validatedCoordinate")
    t.check(validatedCoordinate(latitude: -41.3, longitude: 174.8) != nil, "valid NZ coordinate accepted")
    t.check(validatedCoordinate(latitude: 0, longitude: 0) == nil, "(0,0) rejected")
    t.check(validatedCoordinate(latitude: 91, longitude: 174) == nil, "latitude out of range rejected")
    t.check(validatedCoordinate(latitude: -41, longitude: 200) == nil, "longitude out of range rejected")
    t.check(validatedCoordinate(latitude: .nan, longitude: 174) == nil, "NaN rejected")
    t.check(validatedCoordinate(latitude: nil, longitude: 174) == nil, "nil rejected")
}

private func testWKTParsing(_ t: TestRunner) {
    t.group("WKT parsing")
    let point = coordinateFromWKTGeometry("POINT (174.76 -41.28)")
    t.nearlyEqual(point?.latitude, -41.28, "POINT latitude (2nd token)")
    t.nearlyEqual(point?.longitude, 174.76, "POINT longitude (1st token)")
    t.check(coordinateFromWKTGeometry(nil) == nil, "nil geometry -> nil")
    t.check(coordinateFromWKTGeometry("not wkt") == nil, "garbage geometry -> nil")

    let line = parseWKTLineStringCoords("LINESTRING (174.0 -41.0, 175.0 -42.0)")
    t.equal(line.latitudes.count, 2, "linestring yields 2 points")
    t.equal(line.longitudes.count, 2, "linestring longitudes count")
    if line.latitudes.count == 2 {
        t.nearlyEqual(line.latitudes[0], -41.0, "first latitude")
        t.nearlyEqual(line.longitudes[1], 175.0, "second longitude")
    }
}

private func testVMSMessage(_ t: TestRunner) {
    t.group("formatVMSMessage")
    let formatted = formatVMSMessage("[nl]DRIVE[nl]SAFELY[jp]")
    t.check(!formatted.contains("["), "display-control tokens stripped")
    t.check(formatted.contains("DRIVE") && formatted.contains("SAFELY"), "message text preserved")
    t.equal(formatVMSMessage(nil), "No message", "nil -> No message")
    t.equal(formatVMSMessage(""), "No message", "empty -> No message")
    t.equal(formatVMSMessage("  [jp]  "), "No message", "tokens-only -> No message")
}

// B1 — date parsing/formatting is pinned to NZ time and stays robust.
private func testTrafficDate(_ t: TestRunner) {
    t.group("formatTrafficDate")
    // 2026-06-15 midnight at +12:00 (NZST) is NZ wall-clock 15 June.
    let display = formatTrafficDate("2026-06-15T00:00:00+12:00")
    t.check(display?.contains("15 Jun") == true, "ISO date formats to NZ day/month (got \(display ?? "nil"))")
    t.equal(formatTrafficDate(nil), nil, "nil -> nil")
    t.equal(formatTrafficDate("garbage"), "garbage", "unparseable string returned as-is")
}

// Surfaced RoadEvent fields the app already downloads: planned flag,
// directLineDistance landmarks, and the eventIsland filter predicate.
private func testEventFields(_ t: TestRunner) {
    t.group("RoadEvent surfaced fields")
    let json = #"{"id":"e1","eventDescription":"Slip","planned":false,"eventIsland":"South Island","directLineDistance1":"1.20 km north of Rapahoe","directLineDistance2":"4.23 km north of Dunollie","directLineDistance3":"4.84 km north of Runanga"}"#
    guard let event = decodeModel(RoadEvent.self, json, t) else { return }
    t.equal(event.directLineDistance1, "1.20 km north of Rapahoe", "directLineDistance1 decodes")
    t.equal(event.directLineDistance2, "4.23 km north of Dunollie", "directLineDistance2 decodes")
    t.equal(event.directLineDistance3, "4.84 km north of Runanga", "directLineDistance3 decodes")
    t.equal(event.nearestLandmark, "1.20 km north of Rapahoe", "nearestLandmark is the closest landmark")
    t.equal(event.planned, false, "planned bool decodes false")
    t.check(!event.isPlanned, "isPlanned is false for an incident")
    t.equal(event.eventIsland, "South Island", "eventIsland decodes")

    let plannedJson = #"{"id":"e2","eventDescription":"Roadworks","planned":true}"#
    guard let planned = decodeModel(RoadEvent.self, plannedJson, t) else { return }
    t.equal(planned.planned, true, "planned bool decodes true")
    t.check(planned.isPlanned, "isPlanned is true for planned works")
    t.check(planned.nearestLandmark == nil, "no directLineDistance -> nil nearestLandmark")

    // Missing planned flag is treated as an unplanned incident.
    let noFlagJson = #"{"id":"e3","eventDescription":"Crash"}"#
    let noFlag = decodeModel(RoadEvent.self, noFlagJson, t)
    t.equal(noFlag?.planned, nil, "absent planned -> nil")
    t.check(noFlag?.isPlanned == false, "absent planned reads as incident")

    // rest/5 carriageway direction fields.
    let dirJson = #"{"id":"e4","eventDescription":"Slip","direction":"Southbound","travelDirection":"ONE_DIRECTION"}"#
    guard let dir = decodeModel(RoadEvent.self, dirJson, t) else { return }
    t.equal(dir.direction, "Southbound", "direction decodes")
    t.equal(dir.travelDirection, "ONE_DIRECTION", "travelDirection decodes")
    t.equal(dir.directionText, "Southbound", "directionText prefers human-readable direction")

    let bothJson = #"{"id":"e5","eventDescription":"Roadworks","direction":"Both Directions","travelDirection":"BOTH_DIRECTIONS"}"#
    t.equal(decodeModel(RoadEvent.self, bothJson, t)?.directionText, "Both Directions", "directionText reads Both Directions")

    // Falls back to a tidied travelDirection token when `direction` is absent.
    let fallbackJson = #"{"id":"e6","eventDescription":"Crash","travelDirection":"BOTH_DIRECTIONS"}"#
    t.equal(decodeModel(RoadEvent.self, fallbackJson, t)?.directionText, "Both Directions", "directionText tidies travelDirection fallback")

    let noDirJson = #"{"id":"e7","eventDescription":"Crash"}"#
    t.check(decodeModel(RoadEvent.self, noDirJson, t)?.directionText == nil, "absent direction -> nil directionText")

    t.check(EventIslandFilter.all.matches("North Island"), "all matches any island")
    t.check(EventIslandFilter.all.matches(nil), "all matches nil island")
    t.check(EventIslandFilter.south.matches("South Island"), "south matches South Island")
    t.check(!EventIslandFilter.south.matches("North Island"), "south excludes North Island")
    t.check(EventIslandFilter.north.matches("North Island"), "north matches North Island")
    t.check(!EventIslandFilter.north.matches(nil), "north excludes nil island")
}

private func testCameraMatching(_ t: TestRunner) {
    t.group("camera matches()")
    let json = #"{"id":"123","name":"Ngauranga Gorge","highway":"SH1","latitude":-41.25,"longitude":174.81,"region":{"id":"1","name":"Wellington"}}"#
    guard let cam = decodeModel(TrafficCamera.self, json, t) else { return }
    t.check(cam.matches(region: "", highway: "", search: ""), "no filters matches everything")
    t.check(cam.matches(region: "wellington", highway: "", search: ""), "region is case-insensitive")
    t.check(!cam.matches(region: "Otago", highway: "", search: ""), "wrong region excluded")
    t.check(cam.matches(region: "", highway: "sh1", search: ""), "highway haystack matches lowercased")
    t.check(cam.matches(region: "", highway: "", search: "ngauranga"), "search matches name substring")
    t.check(!cam.matches(region: "", highway: "", search: "zzz"), "non-matching search excluded")
}
