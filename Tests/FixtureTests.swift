import CoreLocation
import Foundation

// E3 — real payloads. Tests/Fixtures holds verbatim records copied from the
// 2026-09-26 live snapshots (a few per feed, chosen for the shapes that broke
// the app: resolved and scheduled closures, `locations` as an array,
// multi-part geometry, TIM pages as a dict / a list / absent, VIA lines,
// per-direction journey legs with implausible times, flow 1.0000000000000002
// and -1, Mixed and out-of-service EV sites, the congestion XML with its
// namespace). Records are frozen copies, not ids to look up: NZTA re-issues
// ids (EV OBJECTIDs changed on 09-26) and events leave the feed within days.
// Two journeys are trimmed to a few of their legs (journey-level fields and
// each kept leg verbatim) to keep the fixtures small.
//
// Everything decodes through the app's own payload types, and the asserts are
// aimed at the mutations the old hand-written JSON let survive (closure
// counting, severity/impact, camera status, flow thresholds, direction totals,
// the event map pin, TIM page shapes, EV status).
@MainActor
func runFixtureTests(_ t: TestRunner) async {
    testFixtureCameras(t)
    testFixtureEvents(t)
    testFixtureEventMapPins(t)
    testFixtureVMS(t)
    testFixtureJourneys(t)
    testFixtureTIM(t)
    testFixtureEVChargers(t)
    testFixtureCongestion(t)
    testFixtureRegions(t)
    testModelEdgeCases(t)
    await testFixturesThroughTheService(t)
    await testFixturesThroughTheStore(t)
}

// MARK: - Loading

enum Fixture {
    /// run_tests.sh exports the folder; otherwise it is found next to this
    /// file (swiftc is invoked from the repository root with relative paths).
    static let directory: URL = {
        if let path = ProcessInfo.processInfo.environment["NZ_TRAFFIC_FIXTURES"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
    }()

    static func data(_ name: String) -> Data? {
        try? Data(contentsOf: directory.appendingPathComponent(name))
    }

    static func text(_ name: String) -> String {
        data(name).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// The fixture's records as JSON objects, for tests that reshape one field.
    static func records(_ name: String, key: String) -> [[String: Any]] {
        guard let data = data(name),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["response"] as? [String: Any] else {
            return []
        }
        return response[key] as? [[String: Any]] ?? []
    }
}

private func decodeFixture<T: Decodable>(_ type: T.Type, _ name: String, _ t: TestRunner) -> T? {
    guard let data = Fixture.data(name) else {
        t.check(false, "fixture \(name) is missing from \(Fixture.directory.path)")
        return nil
    }
    do {
        return try JSONDecoder().decode(T.self, from: data)
    } catch {
        t.check(false, "fixture \(name) doesn't decode as \(T.self): \(error)")
        return nil
    }
}

private func decodeObject<T: Decodable>(_ type: T.Type, _ object: [String: Any], _ t: TestRunner) -> T? {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else {
        t.check(false, "re-encoding a fixture record failed")
        return nil
    }
    return try? JSONDecoder().decode(T.self, from: data)
}

private func byID<T: Identifiable>(_ items: [T]) -> [T.ID: T] {
    Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
}

// MARK: - Cameras

private func testFixtureCameras(_ t: TestRunner) {
    t.group("fixtures: cameras")
    guard let payload = decodeFixture(CamerasPayload.self, "cameras.json", t) else { return }
    let cameras = payload.response.camera
    t.equal(cameras.map(\.id), ["714", "214", "704", "840"], "every record decodes, in feed order")
    t.equal(payload.response.droppedCount, 0, "nothing dropped")
    let camera = byID(cameras)

    // 714: the name has a trailing space upstream.
    t.equal(camera["714"]?.displayName, "SH1 Tinwald", "names are trimmed")
    t.equal(camera["714"]?.statusKind, .online, "an online camera")
    t.equal(camera["714"]?.imageURL(cacheToken: 3)?.absoluteString, "https://trafficnz.info/camera/714.jpg?t=3", "relative image path → https with the cache token")
    t.equal(camera["714"]?.stillThumbnailURL?.absoluteString, "https://trafficnz.info/camera/thumb/714.jpg", "still thumbnail has no token")
    t.equal(camera["714"]?.routeLine, "SH1 - Southbound", "route line")

    // 214: latitude arrives as a whole number (-37).
    t.equal(camera["214"]?.mapCoordinate?.latitude, -37, "integer latitude decodes")
    t.equal(camera["214"]?.mapCoordinate?.longitude, 174.892, "longitude")
    t.equal(camera["214"]?.highwayKeys, ["1", "20"], "SH1/SH20 interchange sits on both highways")

    // 704: offline *and* under maintenance — maintenance wins.
    t.equal(camera["704"]?.statusKind, .maintenance, "offline + maintenance reads Maintenance")
    t.equal(camera["704"]?.isOnline, false, "and isn't online")

    // 840: no `highway` field at all.
    t.equal(camera["840"]?.highway, nil, "no highway field")
    t.equal(camera["840"]?.highwayKeys, ["77"], "SH77 comes from the name / journey")
    t.equal(camera["840"]?.routeLine, "SH77 - Westbound", "route falls back to the journey name")

    let canterburySH1 = cameras.filter { $0.matches(region: "Canterbury", highway: "SH1", search: "") }
    t.equal(canterburySH1.map(\.id), ["714", "704"], "region + highway filter")
    t.equal(cameras.filter { $0.matches(region: "canterbury", highway: "", search: "") }.count, 3, "region matches case-insensitively")
    t.equal(cameras.filter { $0.matches(region: "Canter", highway: "", search: "") }.count, 0, "but as a whole name, not a prefix")
    t.equal(cameras.filter { $0.matches(region: "", highway: "", search: "rakaia") }.map(\.id), ["840"], "search is a case-insensitive substring")
}

// MARK: - Road events

private func testFixtureEvents(_ t: TestRunner) {
    t.group("fixtures: road events")
    guard let payload = decodeFixture(RoadEventsPayload.self, "events.json", t) else { return }
    let events = payload.response.roadevent
    t.equal(events.count, 9, "every record decodes")
    t.equal(payload.response.droppedCount, 0, "nothing dropped")
    let event = byID(events)

    t.equal(events.filter(\.isActive).count, 7, "7 Active")
    t.equal(events.filter(\.isUpcoming).map(\.id), ["562553"], "1 Scheduled (Upcoming)")
    t.equal(events.filter(\.isResolved).map(\.id), ["562605"], "1 Resolved")
    t.equal(Set(events.filter(\.isClosure).map(\.id)), ["560690", "562315", "541001", "562553", "562605", "559462"], "six closures in all")
    t.equal(Set(events.filter(\.isActiveClosure).map(\.id)), ["560690", "562315", "541001", "559462"], "four are active (Dock badge / menu bar)")
    t.equal(event["562553"]?.statusKind.label, "Upcoming", "Scheduled reads Upcoming")
    t.equal(event["562605"]?.isVisible(showResolved: false), false, "Resolved is hidden by default")
    t.equal(event["562605"]?.isVisible(showResolved: true), true, "and shown on request")

    t.equal(event["560690"]?.impactKind, .closure, "Road Closed → closure")
    t.equal(event["560690"]?.severityRank, 0, "closures rank first")
    t.equal(event["554258"]?.impactKind, .caution, "Caution")
    t.equal(event["554258"]?.severityRank, 2, "caution ranks after delays")
    t.equal(event["562610"]?.impactKind, .other, "Vehicle Restrictions → other")
    t.equal(event["562610"]?.severityRank, 50, "and ranks last")
    t.equal(event["562610"]?.restrictions, "Chains essential", "its restriction text")

    // Current first (closures, caution, other; then by title), then
    // upcoming, then resolved.
    t.equal(
        events.sorted(by: roadEventSortsBefore).map(\.id),
        ["559462", "560690", "562315", "541001", "554258", "561526", "562610", "562553", "562605"],
        "Road Events order"
    )

    // `locations` arrives as an array on two live events.
    let locations = event["554258"]?.locations ?? ""
    t.check(locations.contains("CEMETERY ENTRANCE TO JED RIVER BRIDGE"), "array locations keep the first entry")
    t.check(locations.contains("SPEED DERESTRICTION TO OCEAN RIDGE"), "and the second")

    t.equal(event["554258"]?.alternativeRouteText, nil, "'Not applicable' is no detour")
    t.equal(event["562610"]?.alternativeRouteText, nil, "nor is 'Not Applicable'")
    t.equal(event["562315"]?.alternativeRouteText, "Eastbound traffic, detour via Saddle Road", "a real detour is kept")
    t.equal(event["554258"]?.directionText, "Both Directions", "direction")

    t.equal(event["560690"]?.highwayKeys, ["2"], "SH2 from the way code")
    t.equal(event["541001"]?.highwayKeys, ["26"], "SH26")
    t.equal(events.filter { $0.matches(region: "Wellington", highway: "SH2", search: "") }.map(\.id), ["560690"], "region + highway filter")

    // Dates: expectedResolution is "dd/MM/yyyy HH:mm" NZ time or free text.
    t.equal(formatTrafficDate(event["562315"]?.expectedResolution), "27 Sep, 10:00 pm", "dd/MM expected resolution")
    t.equal(formatTrafficDate(event["560690"]?.expectedResolution), "Until further notice", "free text passes through")
    t.equal(formatTrafficDate(event["562553"]?.eventCreated), "26 Sep, 2:54 pm", "fractional eventCreated")
    if let before = parseTrafficDate("2026-09-27T07:00:00+13:00"), let after = parseTrafficDate("2026-09-28T00:00:00+13:00") {
        t.equal(event["562605"]?.hasEnded(before: before), false, "not ended before its end date")
        t.equal(event["562605"]?.hasEnded(before: after), true, "ended after it")
        t.equal(event["554258"]?.hasEnded(before: after), false, "no end date never ends")
    } else {
        t.check(false, "reference dates parse")
    }
}

// The pin sits on the event's line: the point of the geometry nearest its
// bounding-box centre.
private func testFixtureEventMapPins(_ t: TestRunner) {
    t.group("fixtures: event map pins")
    guard let events = decodeFixture(RoadEventsPayload.self, "events.json", t)?.response.roadevent else { return }
    let event = byID(events)
    t.check(events.allSatisfy { $0.mapCoordinate != nil }, "every event is placed (rest/5 sends no lat/long, only WKT)")

    let point = event["559462"]?.mapCoordinate
    t.equal(point?.latitude, -39.540066309284306, "a POINT event sits on its point (latitude)")
    t.equal(point?.longitude, 176.86000952425, "(longitude)")

    let parts = parseWKTParts(event["541001"]?.geometry)
    t.equal(parts.count, 2, "the multi-part closure keeps its two parts")
    if let pin = event["541001"]?.mapCoordinate {
        t.check(distanceToParts(pin, parts) < 1e-9, "its pin lies on one of the parts")
        let lats = parts.flatMap(\.latitudes)
        let lons = parts.flatMap(\.longitudes)
        t.check(pin.latitude >= lats.min()! && pin.latitude <= lats.max()! && pin.longitude >= lons.min()! && pin.longitude <= lons.max()!, "inside the geometry's bounds")
    } else {
        t.check(false, "the multi-part closure has a pin")
    }

    // A straight east–west line: the pin is its midpoint (the bounding-box
    // centre projected onto the line), not an end.
    let line = pinCoordinate(on: parseWKTParts("LINESTRING (170 -45, 172 -45)"))
    t.nearlyEqual(line?.longitude, 171, tolerance: 1e-9, "a straight line's pin is its middle")
    t.nearlyEqual(line?.latitude, -45, tolerance: 1e-9, "on the line")
    // An L: the centre (171, -44) projects onto the corner leg, not an end.
    let corner = pinCoordinate(on: parseWKTParts("LINESTRING (170 -45, 172 -45, 172 -43)"))
    t.nearlyEqual(corner?.longitude, 172, tolerance: 1e-6, "an L's pin is on the leg nearest the centre")
    t.nearlyEqual(corner?.latitude, -44, tolerance: 1e-6, "halfway up it")
}

// Smallest planar distance (degrees) from `point` to any segment of `parts`.
private func distanceToParts(_ point: CLLocationCoordinate2D, _ parts: [GeoPolyline]) -> Double {
    var best = Double.greatestFiniteMagnitude
    for part in parts where part.count >= 2 {
        for index in 1..<part.count {
            let ax = part.longitudes[index - 1], ay = part.latitudes[index - 1]
            let bx = part.longitudes[index], by = part.latitudes[index]
            let dx = bx - ax, dy = by - ay
            let lengthSquared = dx * dx + dy * dy
            let fraction = lengthSquared > 0
                ? min(1, max(0, ((point.longitude - ax) * dx + (point.latitude - ay) * dy) / lengthSquared))
                : 0
            let px = ax + fraction * dx - point.longitude
            let py = ay + fraction * dy - point.latitude
            best = min(best, (px * px + py * py).squareRoot())
        }
    }
    return best
}

// MARK: - VMS

private func testFixtureVMS(_ t: TestRunner) {
    t.group("fixtures: VMS signs")
    guard let signs = decodeFixture(VMSPayload.self, "vms.json", t)?.response.vms else { return }
    let sign = byID(signs)
    t.equal(signs.count, 3, "every record decodes")
    t.equal(sign["1"]?.formattedMessage, "CLEARWAY\nNOT\nOPERATING\n\nALL\nVEHICLES\nKEEP RIGHT", "[nl] is a line, [np] a blank line between pages")
    t.equal(sign["1"]?.hasDisplayMessage, true, "a showing sign")
    t.equal(sign["2"]?.currentMessage, nil, "an empty message decodes to nil")
    t.equal(sign["2"]?.hasDisplayMessage, false, "and counts as blank")
    t.equal(sign["2"]?.formattedMessage, "No message", "shown as No message")
    t.equal(sign["6"]?.formattedMessage, "SH3 TO WOODVILLE\nROAD CLOSED\n\nSH3 TO WOODVILLE\nUSE SADDLE ROAD", "a two-page closure message")
    t.equal(sign["1"]?.highwayKeys, ["59"], "SH59 from the way code")
    t.equal(signs.filter { $0.matches(region: "", highway: "", search: "saddle road") }.map(\.id), ["6"], "search reads the message")
}

// MARK: - Journeys

private func testFixtureJourneys(_ t: TestRunner) {
    t.group("fixtures: journeys")
    guard let journeys = decodeFixture(JourneysPayload.self, "journeys.json", t)?.response.journey else { return }
    let journey = byID(journeys)
    t.equal(journeys.map(\.id), ["2", "11", "10", "3", "42"], "every record decodes")

    // SH18 (journey 2): both directions live, totals per direction.
    if let sh18 = journey["2"] {
        t.equal(sh18.directions.map(\.label), ["Constellation → SH16 / SH18 Interchange", "SH16 / SH18 Interchange → Constellation"], "one line per direction, named by its end legs")
        t.equal(sh18.directions.map(\.currentTime), [688, 505], "current times sum each direction's legs (8:20 + 3:08, 5:14 + 3:11)")
        t.nearlyEqual(sh18.directions.first?.freeFlowTime, 434.305, "free-flow total")
        t.nearlyEqual(sh18.directions.first?.delay, 253.695, "delay is current minus free flow")
        t.equal(sh18.directions.first?.detailText, "Now 11m · free flow 7m · delay +4m · avg 69 km/h · 12.0 km", "the card's direction line")
        t.equal(sh18.legs.map(\.flowKind), [.slow, .moderate, .freeFlow, .freeFlow], "flow 0.51 slow, 0.80 moderate, 0.96/0.94 free flow")
        t.equal(sh18.overallFlowKind, .moderate, "length-weighted overall flow")
        t.equal(sh18.slowestLeg?.name, "Constellation to Greenhithe", "the bottleneck leg")
        t.equal(sh18.highwayKeys, ["18"], "SH18")
    }

    // SH53 (journey 11): flow -1, coverage 0 — no live data.
    if let sh53 = journey["11"] {
        t.equal(sh53.legs.map(\.flowKind), [.noData, .noData], "flow -1 is no data")
        t.equal(sh53.hasLiveData, false, "no live data")
        t.equal(sh53.overallFlowKind, .noData, "overall no data")
        t.equal(sh53.directions.map(\.detailText), ["No live times · 17.7 km", "No live times · 17.7 km"], "each direction says so")
        t.equal(sh53.worstDelay, nil, "nothing to sort by")
    }

    // SH1 Kāpiti/Wellington (journey 10, four legs): flow 1.0000000000000002.
    if let kapiti = journey["10"] {
        t.equal(kapiti.legs.map(\.flowKind), [.freeFlow, .noData, .freeFlow, .slow], "flow just over 1 (and 1.28) is free flow; 0.5 is slow")
        t.equal(Set(kapiti.legs.map(\.id)).count, 4, "same-named legs in each direction get distinct ids")
        t.equal(kapiti.directions.last?.detailText, "Now 1m · free flow <1m · avg 50 km/h · 6.8 km · live on 1 of 2 legs", "a partly live direction says how many legs are live")
        t.check(kapiti.legs.allSatisfy(\.hasMapGeometry), "every leg has a line to draw")
    }

    // SH1 Redoubt Rd–Papakura (journey 3): both directions share a name, and
    // the decreasing leg's 52-minute time for 10 km contradicts its 79 km/h.
    if let redoubt = journey["3"] {
        t.equal(redoubt.legs.map(\.name), ["Redoubt Rd to Papakura", "Redoubt Rd to Papakura"], "NZTA reuses the name both ways")
        t.equal(redoubt.legs.map(\.dataIssue), [nil, .timeContradictsSpeed], "the implausible leg is flagged")
        t.equal(redoubt.directions.map(\.label), ["Redoubt Rd → Papakura", "Papakura → Redoubt Rd"], "the decreasing direction is the increasing one reversed")
        t.equal(redoubt.directions.last?.currentTime, nil, "the bad leg is left out of the totals")
        t.equal(redoubt.dataIssueLegCount, 1, "and counted")
        t.equal(redoubt.directions.last?.detailText, "No reliable live times · avg 79 km/h · 10.1 km · 1 leg left out (data issue)", "and explained")
        t.nearlyEqual(redoubt.worstDelay, 168.485, "the sort key uses the reliable direction")
    }

    // SH2 (journey 42, six legs): "Tauranga to Tauranga" twice per direction.
    if let sh2 = journey["42"] {
        t.equal(sh2.legs.count, 6, "all legs kept")
        t.equal(Set(sh2.legs.map(\.id)).count, 6, "repeated leg names still get unique ids")
        t.equal(sh2.directions.map(\.label), ["Wairoa → Tauranga", "Tauranga → Wairoa"], "loop legs don't confuse the end points")
    }

    // `regions` as an array (older feed shape) reads the same as the object.
    if var record = Fixture.records("journeys.json", key: "journey").first(where: { ($0["id"] as? Int) == 11 }) {
        let region = record["regions"]
        record["regions"] = [region]
        let reshaped = decodeObject(TrafficJourney.self, record, t)
        t.equal(reshaped?.regionName, journey["11"]?.regionName, "regions as an array")
        t.check(reshaped?.regionName != nil, "gives the region")
    } else {
        t.check(false, "journey 11 record found")
    }
}

// MARK: - TIM boards

private func testFixtureTIM(_ t: TestRunner) {
    t.group("fixtures: TIM boards")
    guard let signs = decodeFixture(TIMSignsPayload.self, "tim.json", t)?.response.tim else { return }
    let sign = byID(signs)
    t.equal(signs.count, 3, "every record decodes")

    // 334: `page` is one object; the VIA line is a header.
    t.equal(sign["334"]?.pages.count, 1, "a single page object")
    t.equal(sign["334"]?.pages.first?.header, ["VIA SH20 R12"], "the VIA line (double space collapsed)")
    t.equal(sign["334"]?.pages.first?.rows.map(\.text), ["SH1 GILLIES 21 min", "CITY CENTRE 25 min"], "numeric times read as minutes")
    t.equal(sign["334"]?.headline, "SH1 GILLIES 21 min", "headline is the first row")
    t.equal(sign["334"]?.highwayKeys, ["20A"], "SH20A")

    // 343: no `page` at all (257 of 270 live boards).
    t.equal(sign["343"]?.pages.count, 0, "no page → no pages")
    t.equal(sign["343"]?.headline, nil, "and no headline")

    // 446: `page` is a list; page two is boilerplate plus a VIA line.
    t.equal(sign["446"]?.pages.count, 2, "a list of pages")
    t.equal(sign["446"]?.pages.first?.rows.map(\.text), ["QUEENSTN 9 min", "DOMINION 12 min", "MAIORO ST 14 min"], "first page rows")
    t.equal(sign["446"]?.pages.last?.header, ["VIA MOTORWAY"], "ESTIMATED / MINUTES dropped, VIA kept")
    t.equal(sign["446"]?.pages.last?.isTextOnly, true, "a text-only page")
    t.equal(sign["446"]?.summary, "QUEENSTN 9 min · DOMINION 12 min · MAIORO ST 14 min · VIA MOTORWAY", "summary")
}

// MARK: - EV chargers

private func testFixtureEVChargers(_ t: TestRunner) {
    t.group("fixtures: EV chargers")
    guard let payload = decodeFixture(EVChargersPayload.self, "ev.geojson", t) else { return }
    let chargers = payload.features
    let charger = byID(chargers)
    t.equal(chargers.count, 6, "every feature decodes")
    t.equal(payload.droppedCount, 0, "nothing dropped")

    t.equal(charger["713628"]?.isDC, false, "an AC site isn't DC")
    t.equal(charger["713635"]?.isDC, true, "a DC site is")
    t.equal(charger["713751"]?.currentType, "Mixed", "Mixed site")
    t.equal(charger["713751"]?.isDC, true, "Mixed counts as DC (it has a DC connector)")
    t.equal(charger["713751"]?.maxPowerKW, 47, "the most powerful connector")
    t.equal(charger["713628"]?.connectors.totalCount, 14, "connector counts add up")
    t.equal(charger["713628"]?.is24Hours, true, "\"True\" reads as true")
    t.equal(charger["713628"]?.hasChargingCost, false, "\"False\" reads as false")

    t.equal(charger["713628"]?.availability, .available, "all operative → available")
    t.equal(charger["713628"]?.statusSummary, "14 of 14 connectors working", "summary")
    t.equal(charger["713963"]?.availability, .outOfService, "all inoperative → out of service")
    t.equal(charger["713963"]?.isOutOfService, true, "flagged")
    t.equal(charger["713963"]?.statusSummary, "Out of service — 2 connectors down", "summary")
    t.equal(charger["713781"]?.availability, .available, "some working → available")
    t.equal(charger["713781"]?.statusSummary, "4 of 8 connectors working (2 not reported)", "with the down and unreported ones counted")
    t.equal(charger["713730"]?.availability, .unknown, "all unknown → unknown")
    t.equal(charger["713730"]?.statusSummary, "Status not reported", "summary")
    t.equal(
        ["713628", "713781", "713963", "713730"].map { charger[$0]?.statusSymbol },
        ["checkmark.circle", "exclamationmark.circle", "xmark.octagon", "questionmark.circle"],
        "map/list status symbols: all working, some down, out of service, unknown"
    )
    t.equal(charger["713635"]?.connectorSummary, "Type 2 CCS, CHAdeMO", "connector types listed once each")

    t.equal(charger["713628"]?.mapCoordinate?.latitude, -36.9648860419307, "GeoJSON [lon, lat] order")
    // A feature without geometry falls back to the properties' lat/long.
    if let data = Fixture.data("ev.geojson"),
       let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       var feature = (root["features"] as? [[String: Any]])?.first {
        feature["geometry"] = NSNull()
        let reshaped = decodeObject(EVCharger.self, feature, t)
        t.equal(reshaped?.mapCoordinate?.latitude, -36.9648860428412, "no geometry → properties latitude")
        t.equal(reshaped?.mapCoordinate?.longitude, 174.912617279983, "and longitude")
    } else {
        t.check(false, "EV feature record found")
    }
}

// MARK: - Congestion

private func testFixtureCongestion(_ t: TestRunner) {
    t.group("fixtures: Auckland congestion XML")
    guard let data = Fixture.data("congestion.xml"), let segments = CongestionXMLParser.parse(data) else {
        t.check(false, "congestion.xml parses")
        return
    }
    t.equal(segments.count, 78, "every location with coordinates")
    let levels = Dictionary(grouping: segments, by: \.level).mapValues(\.count)
    t.equal(levels, [.freeFlow: 59, .moderate: 14, .heavy: 4, .congested: 1], "levels read through the tns: namespace")
    t.equal(segments.first?.name, "Oteha Valley Rd - Upper Harb Hwy", "location name, not the motorway's")
    t.equal(segments.first?.motorwayName, "Northern Motorway", "motorway name")
    t.equal(segments.first?.direction, "Southbound", "direction")
    t.check(segments.allSatisfy { $0.startCoordinate != nil && $0.endCoordinate != nil }, "every segment has both ends")
    t.equal(Set(segments.map(\.id)).count, segments.count, "ids are unique")

    func keys(_ motorway: String) -> Set<String> {
        segments.first { $0.motorwayName == motorway }?.highwayKeys ?? []
    }
    t.equal(keys("Northern Motorway"), ["1"], "Northern Motorway is SH1")
    t.equal(keys("North-Western Motorway"), ["16"], "North-Western is SH16")
    t.equal(keys("South-Western Motorway"), ["20"], "South-Western is SH20")
    t.equal(keys("SH20B Puhinui Rd"), ["20B"], "SH20B")
}

// MARK: - Regions

private func testFixtureRegions(_ t: TestRunner) {
    t.group("fixtures: regions")
    guard let regions = decodeFixture(RegionsPayload.self, "regions.json", t)?.response.region else { return }
    t.equal(regions.count, 14, "all 14 regions")
    t.equal(regions.first?.name, "Northland", "north first")
    t.equal(regions.last?.name, "Southland", "south last")
    t.check(regions.allSatisfy { !$0.boundary.isEmpty && $0.boundary.allSatisfy(\.isDrawable) }, "each has a drawable outline")
}

// MARK: - Model edge cases the mutation run found untested

private struct LossyBoolProbe: Decodable {
    let value: Bool?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = container.decodeLossyBool(forKey: .value)
    }

    private enum CodingKeys: String, CodingKey {
        case value
    }
}

private func testModelEdgeCases(_ t: TestRunner) {
    t.group("model edge cases")
    // Flow thresholds: free flow ≥ 0.85, moderate ≥ 0.60, slow ≥ 0.35.
    t.equal(computeFlowKind(flow: 0.85, coverage: 1), .freeFlow, "0.85 is free flow")
    t.equal(computeFlowKind(flow: 0.8499, coverage: 1), .moderate, "just under is moderate")
    t.equal(computeFlowKind(flow: 0.60, coverage: 1), .moderate, "0.60 is moderate")
    t.equal(computeFlowKind(flow: 0.5999, coverage: 1), .slow, "just under is slow")
    t.equal(computeFlowKind(flow: 0.35, coverage: 1), .slow, "0.35 is slow")
    t.equal(computeFlowKind(flow: 0.3499, coverage: 1), .congested, "just under is congested")
    t.equal(computeFlowKind(flow: 1.0000000000000002, coverage: 1), .freeFlow, "a hair over 1 is free flow")
    t.equal(computeFlowKind(flow: 0, coverage: 1), .congested, "0 with coverage is congested")
    t.equal(computeFlowKind(flow: -1, coverage: 1), .noData, "-1 is no data")
    t.equal(computeFlowKind(flow: 0.9, coverage: 0), .noData, "no coverage is no data")
    t.equal(computeFlowKind(flow: nil, coverage: 1), .noData, "missing flow is no data")

    // A journey's overall flow weighs legs by length: 10 km at 0.95 and 1 km
    // at 0.20 average 0.88 (free flow), not 0.575 (slow).
    let weighted = #"""
    {"id":1,"name":"SH1","legs":[
    {"name":"A to B","totalLength":10,"flow":0.95,"coverage":1,"direction":"I","sequenceNumber":0},
    {"name":"B to C","totalLength":1,"flow":0.2,"coverage":1,"direction":"I","sequenceNumber":1},
    {"name":"C to D","totalLength":50,"flow":-1,"coverage":0,"direction":"I","sequenceNumber":2}
    ]}
    """#
    t.equal(decodeModel(TrafficJourney.self, weighted, t)?.overallFlowKind, .freeFlow, "overall flow is length-weighted, ignoring legs without data")
    // Legs without an I/D direction are summarised on their own line.
    let undirected = #"{"id":2,"name":"SH2","legs":[{"name":"Somewhere","totalLength":3,"sequenceNumber":0}]}"#
    t.equal(decodeModel(TrafficJourney.self, undirected, t)?.directions.map(\.label), ["Other legs"], "no direction and no 'A to B' name → Other legs")

    // Camera status truth table.
    t.equal(computeCameraStatusKind(offline: false, underMaintenance: false), .online, "online")
    t.equal(computeCameraStatusKind(offline: true, underMaintenance: false), .offline, "offline")
    t.equal(computeCameraStatusKind(offline: false, underMaintenance: true), .maintenance, "maintenance")
    t.equal(computeCameraStatusKind(offline: true, underMaintenance: true), .maintenance, "maintenance wins over offline")

    // Impact wording.
    t.equal(computeImpactKind(impact: "Road Closed"), .closure, "Road Closed")
    t.equal(computeImpactKind(impact: "Delays"), .delays, "Delays")
    t.equal(computeImpactKind(impact: "Caution"), .caution, "Caution")
    t.equal(computeImpactKind(impact: "Vehicle Restrictions"), .other, "anything else")
    t.equal(computeImpactKind(impact: nil), .other, "missing")
    t.equal(computeSeverityRank(impact: "Delays"), 1, "delays rank 1")
    t.equal(computeSeverityRank(impact: nil), 99, "missing ranks after everything")

    // Stable ids when the feed sends none.
    t.equal(deterministicID(decodedId: "42", fallback: ["x"], typeTag: "cam"), "42", "a real id wins")
    t.equal(deterministicID(decodedId: "", fallback: [" SH1 ", nil, "Tinwald"], typeTag: "cam"), "cam|SH1|Tinwald", "no id → type tag plus the cleaned fields")
    t.equal(deterministicID(decodedId: nil, fallback: [nil, "  "], typeTag: "cam"), "cam-noid", "nothing to go on")

    // Loose booleans (EV "True"/"False", and the other spellings seen).
    func lossyBool(_ json: String) -> Bool? {
        (try? JSONDecoder().decode(LossyBoolProbe.self, from: Data(json.utf8)))?.value
    }
    t.equal(lossyBool(#"{"value":true}"#), true, "JSON true")
    t.equal(lossyBool(#"{"value":"True"}"#), true, "\"True\"")
    t.equal(lossyBool(#"{"value":"yes"}"#), true, "\"yes\"")
    t.equal(lossyBool(#"{"value":"No"}"#), false, "\"No\"")
    t.equal(lossyBool(#"{"value":0}"#), false, "0")
    t.equal(lossyBool(#"{"value":"maybe"}"#), nil, "unknown word → nil")
    t.equal(lossyBool(#"{}"#), nil, "missing → nil")

    // The events list under its older key.
    let oldKey = #"{"response":{"roadEvent":[{"id":1,"impact":"Road Closed","status":"Active"}]}}"#
    let events = try? JSONDecoder().decode(RoadEventsPayload.self, from: Data(oldKey.utf8))
    t.equal(events?.response.roadevent.map(\.isActiveClosure), [true], "\"roadEvent\" is read too")
}

// MARK: - Through the service and the store

// The fixtures served over the stub network come out of the API client — and
// out of its offline-cache replay — exactly as decoded directly.
@MainActor
private func testFixturesThroughTheService(_ t: TestRunner) async {
    t.group("fixtures: through the API client")
    StubServer.reset()
    StubServer.route("/cameras/all", .json(Fixture.text("cameras.json")))
    StubServer.route("/events/all/10", .json(Fixture.text("events.json")))
    StubServer.route("/signs/vms/all", .json(Fixture.text("vms.json")))
    StubServer.route("/journeys/all/10", .json(Fixture.text("journeys.json")))
    StubServer.route("/signs/tim/all", .json(Fixture.text("tim.json")))
    StubServer.route("services.arcgis.com", .json(Fixture.text("ev.geojson")))
    StubServer.route("traffic-conditions/rest/2", .json(Fixture.text("congestion.xml")))
    let service = makeStubService()

    let cameras = try? await service.fetchCamerasResult().get()
    t.equal(cameras?.value.map(\.id), ["714", "214", "704", "840"], "cameras")
    t.equal(cameras?.data, Fixture.data("cameras.json"), "the raw bytes come back for the offline cache")
    let events = try? await service.fetchRoadEventsResult().get()
    t.equal(events?.value.count, 9, "events")
    t.equal(await service.decodeCachedRoadEvents(events?.data ?? Data())?.map(\.id), events?.value.map(\.id), "the cached bytes replay to the same events")
    t.equal((try? await service.fetchVMSSignsResult().get())?.value.count, 3, "VMS")
    let journeys = try? await service.fetchJourneysResult().get()
    t.equal(journeys?.value.count, 5, "journeys")
    t.equal(await service.decodeCachedJourneys(journeys?.data ?? Data())?.first?.directions.map(\.currentTime), [688, 505], "replayed journeys keep their derived totals")
    t.equal((try? await service.fetchTIMSignsResult().get())?.value.count, 3, "TIM")
    t.equal((try? await service.fetchEVChargersResult().get())?.value.count, 6, "EV")
    t.equal((try? await service.fetchCongestionResult().get())?.value.count, 78, "congestion")
}

@MainActor
private func testFixturesThroughTheStore(_ t: TestRunner) async {
    t.group("fixtures: through the store")
    StubServer.reset()
    StubFixtures.routeAllEndpoints()
    StubServer.route("/cameras/all", .json(Fixture.text("cameras.json")))
    StubServer.route("/events/all/10", .json(Fixture.text("events.json")))
    StubServer.route("/signs/vms/all", .json(Fixture.text("vms.json")))
    StubServer.route("/journeys/all/10", .json(Fixture.text("journeys.json")))
    StubServer.route("/signs/tim/all", .json(Fixture.text("tim.json")))
    let folder = makeTemporaryFolder()
    defer { removeTemporaryFolder(folder) }
    let store = TrafficStore(
        service: makeStubService(),
        cache: OfflineCache(directory: folder),
        imageCache: nil,
        monitorsNetwork: false,
        reconnectDelay: .zero
    )
    await store.loadAllData()
    t.check(await waitUntil { store.loadingSections.isEmpty && !store.isRefreshing }, "the refresh settles")

    t.equal(store.criticalAlertCount, 4, "four active closures")
    t.equal(store.dockBadgeLabel, "4", "on the Dock badge")
    t.equal(
        store.filteredEvents(region: "", highway: "", search: "", showResolved: false).map(\.id),
        ["559462", "560690", "562315", "541001", "554258", "561526", "562610", "562553"],
        "Road Events lists current, then upcoming, and hides the resolved closure"
    )
    t.equal(store.filteredEvents(region: "", highway: "", search: "", showResolved: true).last?.id, "562605", "shown last on request")
    t.equal(store.filteredCameras(region: "Canterbury", highway: "SH1", search: "").map(\.id), ["714", "704"], "camera filter")
    t.equal(store.scopedTIMSigns(region: "", highway: "", search: "", hideBlank: true).map(\.id).sorted(), ["334", "446"], "boards without a page are hidden as blank")
}
