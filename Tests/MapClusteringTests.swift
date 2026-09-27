import CoreLocation
import Foundation

// The 2026-09 review's map clustering (E2) and accessibility (E1) logic:
// screen-space clustering at every zoom with stable identities, the picker
// for pins at the same spot, the line styles that don't rely on colour, the
// pin glyphs, and Auckland congestion as a text list.
func runMapClusteringTests(_ t: TestRunner) {
    testClusterCellLevel(t)
    testClusterScreenSpace(t)
    testClusterStability(t)
    testClusterCoLocated(t)
    testClusterAntimeridianAndEdges(t)
    testClusterScale(t)
    testClusterTapAction(t)
    testAccessibleLineStyles(t)
    testMapPinGlyphs(t)
    testCongestionList(t)
}

// Degrees of longitude per point for a map `widthPoints` wide showing
// `spanDegrees` of longitude.
private func scale(span spanDegrees: Double, width widthPoints: Double = 1000) -> Double {
    spanDegrees / widthPoints
}

private func point(_ id: String, _ latitude: Double, _ longitude: Double) -> ClusterPoint {
    ClusterPoint(id: id, coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
}

// Every input index exactly once across the markers.
private func coversEveryPoint(_ clusters: [MapPointCluster], count: Int) -> Bool {
    clusters.flatMap(\.memberIndices).sorted() == Array(0..<count)
}

private func testClusterCellLevel(_ t: TestRunner) {
    t.group("map clustering: grid level from the zoom")
    // 0.01°/pt × 44 pt = 0.44° → the next power of two up is 2^-1.
    t.equal(MapClustering.cellLevel(degreesPerPoint: 0.01), -1, "0.44° cells round up to 0.5°")
    t.equal(
        MapClustering.cellLevel(degreesPerPoint: 0.0105),
        MapClustering.cellLevel(degreesPerPoint: 0.0095),
        "a small zoom keeps the same level"
    )
    t.equal(MapClustering.cellLevel(degreesPerPoint: 0.02), 0, "zooming out 2× moves up a level")
    t.equal(MapClustering.cellLevel(degreesPerPoint: 0), nil, "no scale before the map is laid out")
    t.equal(MapClustering.cellLevel(degreesPerPoint: .nan), nil, "a NaN span has no level")
}

private func testClusterScreenSpace(_ t: TestRunner) {
    t.group("map clustering: grouped by screen distance at every zoom")
    // Two Auckland motorway cameras about 0.004° (≈ 350 m) apart.
    let pair = [point("camera-a", -36.8480, 174.7600), point("camera-b", -36.8480, 174.7640)]

    // Whole country: far under a marker apart → one cluster.
    let national = clusterMapPoints(pair, degreesPerPoint: scale(span: 16))
    t.equal(national.count, 1, "at national zoom the pair shares a marker")
    t.equal(national.first?.memberIndices, [0, 1], "members in input order")
    t.check(national.first?.id == "cluster:camera-a", "a cluster is named after its smallest member id")
    t.check(national.first?.isCoLocated == false, "350 m apart is not the same spot")

    // The old clustering stopped below a 0.2° span; at 0.19° the pair is
    // still 20 pt apart on a 1,000 pt map and must stay grouped.
    let city = clusterMapPoints(pair, degreesPerPoint: scale(span: 0.19))
    t.equal(city.count, 1, "below the old 0.2° cut-off overlapping pins are still grouped")

    // Street level: 0.02° across 1,000 pt puts them 200 pt apart.
    let street = clusterMapPoints(pair, degreesPerPoint: scale(span: 0.02))
    t.equal(street.count, 2, "zoomed in far enough the cluster dissolves")
    t.check(street.allSatisfy(\.isSingle), "both are single pins")
    t.equal(street.map(\.id), ["camera-a", "camera-b"], "single pins keep their own ids")

    if let centre = national.first {
        t.nearlyEqual(centre.longitude, 174.7620, tolerance: 1e-6, "the marker sits at the members' centre")
        t.nearlyEqual(centre.latitude, -36.8480, tolerance: 1e-6, "latitude round-trips the Mercator projection")
    }
}

private func testClusterStability(_ t: TestRunner) {
    t.group("map clustering: identity stable across small camera moves")
    // A deterministic spread of 600 pins over the upper North Island.
    var generator = SplitMix(seed: 42)
    let points = (0..<600).map { index in
        point(
            "pin-\(index)",
            -38.5 + generator.nextUnit() * 3,
            174.0 + generator.nextUnit() * 3.5
        )
    }
    let base = clusterMapPoints(points, degreesPerPoint: scale(span: 1.2))
    t.check(coversEveryPoint(base, count: points.count), "every pin is in exactly one marker")
    t.check(base.count < points.count, "a dense layer is clustered")
    t.equal(Set(base.map(\.id)).count, base.count, "marker ids are unique")

    // Zooming by 10% stays inside the same power-of-two grid: same markers,
    // same ids — nothing is rebuilt.
    let nudged = clusterMapPoints(points, degreesPerPoint: scale(span: 1.2 * 1.08))
    t.check(
        MapClustering.cellLevel(degreesPerPoint: scale(span: 1.2)) == MapClustering.cellLevel(degreesPerPoint: scale(span: 1.2 * 1.08)),
        "the nudged zoom is on the same grid level"
    )
    t.equal(nudged, base, "a small zoom gives exactly the same markers")

    // The grid is anchored to the world, not the viewport: the same scale
    // after a pan gives the same result (the input doesn't change, only the
    // camera does), and reordering the input keeps each marker's id.
    let reversed = clusterMapPoints(Array(points.reversed()), degreesPerPoint: scale(span: 1.2))
    t.equal(Set(reversed.map(\.id)), Set(base.map(\.id)), "input order doesn't change the markers' ids")
    t.equal(
        Set(reversed.map { Set($0.memberIndices.map { points.count - 1 - $0 }) }),
        Set(base.map { Set($0.memberIndices) }),
        "…or their members"
    )

    // Zooming in far enough breaks clusters up; out, they merge.
    let closer = clusterMapPoints(points, degreesPerPoint: scale(span: 0.3))
    let further = clusterMapPoints(points, degreesPerPoint: scale(span: 4))
    t.check(closer.count > base.count && base.count > further.count, "more markers as the map zooms in")
}

private func testClusterCoLocated(_ t: TestRunner) {
    t.group("map clustering: pins at the same spot")
    // Events 561726 'Road Work' and 562379 'Scheduled Road Work' share
    // -38.44977, 176.60265 in the 2026-09-26 feed; a third event sits 2 km
    // away.
    let points = [
        point("event-561726", -38.44977, 176.60265),
        point("event-562379", -38.44977, 176.60265),
        point("event-900001", -38.46777, 176.60265)
    ]
    // Even at the closest zoom the map allows (≈ 0.004° across 1,000 pt),
    // the shared pair can't be split; the third pin stands alone.
    let closest = clusterMapPoints(points, degreesPerPoint: scale(span: 0.004))
    t.equal(closest.count, 2, "the co-located pair stays one marker at maximum zoom")
    let pair = closest.first { !$0.isSingle }
    t.equal(pair?.memberIndices, [0, 1], "the pair is the two shared-coordinate events")
    t.check(pair?.isCoLocated == true, "and is flagged as the same spot, for the picker")
    t.check(closest.contains { $0.id == "event-900001" }, "the event 2 km away is its own pin")

    // Zoomed out, all three share a marker, which is no longer "the same
    // spot": clicking it should zoom.
    let out = clusterMapPoints(points, degreesPerPoint: scale(span: 2))
    t.equal(out.count, 1, "zoomed out all three share a marker")
    t.check(out.first?.isCoLocated == false, "a marker spanning 2 km zooms rather than lists")
}

private func testClusterAntimeridianAndEdges(_ t: TestRunner) {
    t.group("map clustering: the Chathams, edges and bad input")
    // Two Chatham Islands pins either side of 180° (as a feed might write
    // them) are neighbours, not a world apart.
    let chathams = [point("a", -43.95, 179.999), point("b", -43.95, -179.999)]
    let grouped = clusterMapPoints(chathams, degreesPerPoint: scale(span: 1))
    t.equal(grouped.count, 1, "pins either side of the antimeridian cluster together")
    if let longitude = grouped.first?.longitude {
        t.check(abs(abs(longitude) - 180) < 0.01, "their marker sits on the antimeridian, not at 0°")
    }

    // Two pins a few points apart that straddle a grid-cell edge are merged
    // by the neighbour pass. 0.5° cells: 174.4999 and 174.5001.
    let straddling = [point("left", -41.0, 174.4999), point("right", -41.0, 174.5001)]
    t.equal(
        clusterMapPoints(straddling, degreesPerPoint: 0.01).count,
        1,
        "pins either side of a cell edge still share a marker"
    )

    // A pin with a non-finite coordinate is kept, alone, so counts add up.
    let withBad = [point("ok-1", -41, 174), point("ok-2", -41, 174.0001), point("bad", .nan, 174)]
    let result = clusterMapPoints(withBad, degreesPerPoint: 0.01)
    t.check(coversEveryPoint(result, count: 3), "a bad coordinate doesn't lose a pin")

    t.equal(clusterMapPoints([], degreesPerPoint: 0.01), [], "no pins, no markers")
    let unscaled = clusterMapPoints(withBad, degreesPerPoint: 0)
    t.check(unscaled.count == 3 && unscaled.allSatisfy(\.isSingle), "with no scale every pin stands alone")
}

private func testClusterScale(_ t: TestRunner) {
    t.group("map clustering: a 2,000-pin layer")
    var generator = SplitMix(seed: 7)
    let points = (0..<2000).map { index in
        point("pin-\(index)", -46.5 + generator.nextUnit() * 12, 166.5 + generator.nextUnit() * 12)
    }
    let start = Date()
    let clusters = clusterMapPoints(points, degreesPerPoint: scale(span: 16))
    let elapsed = Date().timeIntervalSince(start)
    t.check(coversEveryPoint(clusters, count: points.count), "every one of 2,000 pins is placed once")
    t.check(elapsed < 0.5, "clustering 2,000 pins is quick (\(String(format: "%.3f", elapsed)) s)")
    // Markers from different cells never land on top of each other: no two
    // are closer than a quarter of a marker.
    let cell = pow(2.0, Double(MapClustering.cellLevel(degreesPerPoint: scale(span: 16)) ?? 0))
    var closest = Double.greatestFiniteMagnitude
    for i in clusters.indices {
        for j in clusters.indices where j > i {
            let dx = clusters[i].longitude - clusters[j].longitude
            let dy = mercatorY(latitude: clusters[i].latitude) - mercatorY(latitude: clusters[j].latitude)
            closest = min(closest, hypot(dx, dy))
        }
    }
    t.check(closest > cell * 0.25, "markers keep apart on screen (closest \(closest / cell) cells)")
}

private func testClusterTapAction(_ t: TestRunner) {
    t.group("map clustering: clicking a cluster")
    let spread = [
        CLLocationCoordinate2D(latitude: -36.85, longitude: 174.76),
        CLLocationCoordinate2D(latitude: -36.86, longitude: 174.78)
    ]
    // From the whole country, a big step in (half the span at most).
    if case .zoom(let frame) = clusterTapAction(for: spread, visibleLatitudeDelta: 14.5, visibleLongitudeDelta: 16.5) {
        t.nearlyEqual(frame.latitudeDelta, 0.016, tolerance: 1e-9, "zooms to the members' spread × 1.6")
        t.nearlyEqual(frame.longitudeDelta, 0.032, tolerance: 1e-9, "…in both directions")
        t.nearlyEqual(frame.centerLatitude, -36.855, tolerance: 1e-9, "centred on them")
    } else {
        t.check(false, "a spread-out cluster zooms")
    }
    // A wide cluster zooms by at most half each click.
    let wide = [
        CLLocationCoordinate2D(latitude: -36, longitude: 174),
        CLLocationCoordinate2D(latitude: -40, longitude: 176)
    ]
    if case .zoom(let frame) = clusterTapAction(for: wide, visibleLatitudeDelta: 6, visibleLongitudeDelta: 6) {
        t.nearlyEqual(frame.latitudeDelta, 3, tolerance: 1e-9, "never more than half the visible span at once")
    } else {
        t.check(false, "a wide cluster zooms in steps")
    }
    // The same spot: list, whatever the zoom.
    let same = [
        CLLocationCoordinate2D(latitude: -38.44977, longitude: 176.60265),
        CLLocationCoordinate2D(latitude: -38.44977, longitude: 176.60265)
    ]
    t.equal(clusterTapAction(for: same, visibleLatitudeDelta: 5, visibleLongitudeDelta: 5), .pick, "co-located pins are listed")
    // Already as close as a click zooms: list rather than zoom to the same
    // place again (the map may show more in its wider direction).
    let near = [
        CLLocationCoordinate2D(latitude: -41.2800, longitude: 174.7800),
        CLLocationCoordinate2D(latitude: -41.2803, longitude: 174.7805)
    ]
    t.equal(
        clusterTapAction(
            for: near,
            visibleLatitudeDelta: MapClustering.minimumZoomSpan,
            visibleLongitudeDelta: MapClustering.minimumZoomSpan * 1.6
        ),
        .pick,
        "at the closest click-zoom the pins are listed"
    )
    if case .zoom = clusterTapAction(for: near, visibleLatitudeDelta: 0.2, visibleLongitudeDelta: 0.3) {
        t.check(true, "the same pins zoom from further out")
    } else {
        t.check(false, "the same pins zoom from further out")
    }
    // Across the antimeridian the centre stays in the Chathams.
    let chathams = [
        CLLocationCoordinate2D(latitude: -43.9, longitude: 179.9),
        CLLocationCoordinate2D(latitude: -44.0, longitude: -179.9)
    ]
    if case .zoom(let frame) = clusterTapAction(for: chathams, visibleLatitudeDelta: 10, visibleLongitudeDelta: 10) {
        t.check(abs(abs(frame.centerLongitude) - 180) < 0.01, "the Chathams stay centred on 180°")
        t.nearlyEqual(frame.longitudeDelta, 0.32, tolerance: 1e-9, "spanning 0.2° across the antimeridian, not 359.8°")
    } else {
        t.check(false, "a Chathams cluster zooms")
    }
}

private func testAccessibleLineStyles(_ t: TestRunner) {
    t.group("map lines: levels told apart without colour")
    let flow = FlowKind.allCases.map(\.accessibleLineStyle)
    t.equal(Set(flow.map { "\($0.widthScale)|\($0.dash)" }).count, FlowKind.allCases.count, "every flow level has its own line")
    let congestion = CongestionLevel.allCases.map(\.accessibleLineStyle)
    t.equal(
        Set(congestion.map { "\($0.widthScale)|\($0.dash)" }).count,
        CongestionLevel.allCases.count,
        "every congestion level has its own line"
    )
    let ordered = FlowKind.allCases.sorted { $0.drawRank < $1.drawRank }.map(\.accessibleLineStyle.widthScale)
    t.equal(ordered, ordered.sorted(), "worse flow is never drawn thinner")
    t.check(FlowKind.congested.accessibleLineStyle.dash.isEmpty, "Congested is a solid line")
    t.check(CongestionLevel.congested.accessibleLineStyle.dash.isEmpty, "…on both layers")
    t.equal(FlowKind.slow.accessibleLineStyle, CongestionLevel.heavy.accessibleLineStyle, "Slow and Heavy look alike")
    t.equal(
        AccessibleLineStyle(widthScale: 1, dash: [4, 1.4]).dashPattern(lineWidth: 5),
        [20, 7],
        "dashes scale with the drawn width"
    )
}

private func testMapPinGlyphs(_ t: TestRunner) {
    t.group("map pins: a glyph for every status")
    let impacts = EventImpactKind.allCases.map(\.symbol)
    let lifecycle = [EventLifecycleSymbol.upcoming, EventLifecycleSymbol.resolved]
    t.equal(Set(impacts + lifecycle).count, impacts.count + lifecycle.count, "closure, delays, caution, other, upcoming and resolved all differ")
    t.equal(Set(CameraStatusKind.allCases.map(\.symbol)).count, 3, "online, offline and maintenance cameras differ")
    t.equal(CameraStatusKind.maintenance.symbol, "wrench.fill", "maintenance is a wrench, not the offline glyph")

    let base = #"{"id":1,"eventType":"Area Warning","impact":"IMPACT","status":"STATUS","planned":false,"locationArea":"SH 1","region":{"id":9,"name":"Wellington"}}"#
    func event(_ impact: String, _ status: String) -> RoadEvent? {
        decodeModel(
            RoadEvent.self,
            base.replacingOccurrences(of: "IMPACT", with: impact).replacingOccurrences(of: "STATUS", with: status),
            t
        )
    }
    t.equal(event("Road Closed", "Active")?.mapSymbol, EventImpactKind.closure.symbol, "an active closure shows the closure glyph")
    t.equal(event("Delays", "Active")?.mapSymbol, EventImpactKind.delays.symbol, "delays their own")
    t.equal(event("Road Closed", "Scheduled")?.mapSymbol, EventLifecycleSymbol.upcoming, "an upcoming closure shows the calendar")
    t.equal(event("Road Closed", "Resolved")?.mapSymbol, EventLifecycleSymbol.resolved, "a resolved one the tick")
}

private func segment(
    _ id: String,
    motorway: String?,
    name: String,
    direction: String?,
    level: CongestionLevel
) -> CongestionSegment {
    CongestionSegment(
        id: id,
        motorwayName: motorway,
        name: name,
        direction: direction,
        level: level,
        startLatitude: -36.8,
        startLongitude: 174.7,
        endLatitude: -36.81,
        endLongitude: 174.71
    )
}

private func testCongestionList(_ t: TestRunner) {
    t.group("Auckland congestion as a text list")
    // Shaped like the traffic-conditions feed: motorways in feed order, each
    // direction's segments in travel order, directions interleaved.
    let segments = [
        segment("1", motorway: "Northern Motorway", name: "Oteha Valley Rd - Upper Harb Hwy", direction: "Southbound", level: .freeFlow),
        segment("2", motorway: "Northern Motorway", name: "Upper Harb Hwy - Tristram Ave", direction: "Southbound", level: .heavy),
        segment("3", motorway: "Northern Motorway", name: "Tristram Ave - Upper Harb Hwy", direction: "Northbound", level: .congested),
        segment("4", motorway: "Northern Motorway", name: "Tristram Ave - Esmonde Rd", direction: "Southbound", level: .congested),
        segment("5", motorway: "SH20B Puhinui Rd", name: "Campana Rd - SH20", direction: "Eastbound", level: .unknown),
        segment("6", motorway: nil, name: "Somewhere", direction: nil, level: .moderate)
    ]
    let groups = congestionListGroups(segments)
    t.equal(
        groups.map(\.title),
        ["Northern Motorway · Southbound", "Northern Motorway · Northbound", "SH20B Puhinui Rd · Eastbound", "Auckland motorways"],
        "one group per motorway direction, in feed order"
    )
    t.equal(groups.first?.segments.map(\.id), ["1", "2", "4"], "segments keep travel order within a direction")
    t.equal(groups.first?.summary, "1 congested, 1 heavy", "the summary names what is worse than Moderate, worst first")
    t.equal(groups.first?.worstLevel, .congested, "the worst level")
    t.equal(groups[2].summary, "No live data", "all Unknown says so")
    t.equal(groups[3].summary, "Flowing freely", "nothing worse than Moderate is flowing freely")
    t.equal(Set(groups.map(\.id)).count, groups.count, "group ids are unique")

    let filtered = congestionListGroups(segments) { $0.id != "3" && $0.id != "6" }
    t.equal(filtered.map(\.title), ["Northern Motorway · Southbound", "SH20B Puhinui Rd · Eastbound"], "the shared filters drop segments and empty groups")
    t.equal(congestionSummary(segments), "2 congested, 1 heavy", "the section's overall summary")
    t.equal(congestionSummary([]), "No live data", "nothing loaded")
}

// A small deterministic generator, so the spread-out fixtures are the same
// on every run.
private struct SplitMix {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextUnit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
