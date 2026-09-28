import CoreLocation
import Foundation

// Foundation-only logic behind the views: what the Flow and congestion map
// layers draw, in which order and — without colour — in which line style,
// the congestion layer as a text list, the side-by-side offset for opposite
// directions, placing EV chargers in a region, map pin glyphs and which
// member tints a map cluster (the clustering itself is in
// MapClustering.swift), grid keyboard navigation, the region picker's
// restored selection, the Travel Times "hidden journeys" caption and its
// travel-time board list. Kept out of the SwiftUI files so run_tests.sh can
// compile and test it.

// MARK: - Flow and congestion layers

extension FlowKind {
    /// Draw order on the Flow map: higher draws later, on top. No Data is
    /// lowest so a grey leg never covers a live one, and Congested is highest
    /// so the worst traffic is never hidden under better traffic.
    var drawRank: Int {
        switch self {
        case .noData:
            return -1
        case .freeFlow:
            return 0
        case .moderate:
            return 1
        case .slow:
            return 2
        case .congested:
            return 3
        }
    }
}

/// One drawable run of a journey leg on the Flow map.
struct FlowMapSegment: Identifiable {
    let id: String
    let coordinates: [CLLocationCoordinate2D]
    let flowKind: FlowKind
}

/// The Flow map's lines. Filtered per leg on the leg's own flow — not the
/// journey's average, which hid slow legs inside mostly free-flowing journeys
/// and drew grey No Data legs with No Data turned off — then ordered bottom to
/// top by `drawRank`, keeping feed order within a rank so the result is the
/// same on every render. Leg ids are unique within a journey and parts are
/// never joined, so `journey|leg|part` is a unique, stable id.
func flowMapSegments(for journeys: [TrafficJourney], allowedKinds: Set<FlowKind>) -> [FlowMapSegment] {
    var segments: [FlowMapSegment] = []
    for journey in journeys {
        for leg in journey.legs where allowedKinds.contains(leg.flowKind) {
            for (partIndex, part) in leg.polylineParts.enumerated() where part.isDrawable {
                segments.append(
                    FlowMapSegment(
                        id: "\(journey.id)|\(leg.id)|\(partIndex)",
                        coordinates: part.coordinates,
                        flowKind: leg.flowKind
                    )
                )
            }
        }
    }
    return stableSorted(segments) { $0.flowKind.drawRank }
}

/// The Flow layer's "mapped / off-map" counts, over the same per-leg filter
/// the map draws: legs whose flow is allowed, and how many of those can be
/// drawn.
func flowMapLegCounts(for journeys: [TrafficJourney], allowedKinds: Set<FlowKind>) -> (mapped: Int, total: Int) {
    var mapped = 0
    var total = 0
    for journey in journeys {
        for leg in journey.legs where allowedKinds.contains(leg.flowKind) {
            total += 1
            if leg.hasMapGeometry {
                mapped += 1
            }
        }
    }
    return (mapped, total)
}

/// Congestion segments that can be drawn, worst on top (Unknown lowest),
/// keeping feed order within a level. Opposite directions share the same two
/// end points, so without this a Heavy segment could sit under a Free Flow one
/// at every zoom.
func congestionDrawOrder(_ segments: [CongestionSegment]) -> [CongestionSegment] {
    stableSorted(segments.filter { $0.polyline.count >= 2 }) { $0.level.severityRank }
}

// Sorted ascending by `rank`, ties kept in their original order.
private func stableSorted<T>(_ items: [T], by rank: (T) -> Int) -> [T] {
    items.enumerated()
        .sorted { lhs, rhs in
            let lhsRank = rank(lhs.element)
            let rhsRank = rank(rhs.element)
            return lhsRank != rhsRank ? lhsRank < rhsRank : lhs.offset < rhs.offset
        }
        .map(\.element)
}

/// How a Flow or congestion line is drawn when colour can't be relied on
/// (Differentiate Without Colour): worse traffic is wider and more solid —
/// Congested a wide solid line, Slow / Heavy long dashes, Moderate short
/// dashes, Free Flow dots and No Data / Unknown thin, sparse dots — so every
/// level reads from its shape alone. `widthScale` multiplies the layer's line
/// width; `dash` is in multiples of the drawn width (empty = solid) and is
/// meant for a round line cap, which turns the near-zero dashes into dots.
struct AccessibleLineStyle: Equatable {
    let widthScale: Double
    let dash: [Double]

    /// By severity rank: -1 no data / unknown … 3 congested.
    init(severityRank: Int) {
        switch severityRank {
        case ..<0:
            self.init(widthScale: 0.6, dash: [0.01, 2.6])
        case 0:
            self.init(widthScale: 0.8, dash: [0.01, 1.8])
        case 1:
            self.init(widthScale: 1.0, dash: [1.6, 1.6])
        case 2:
            self.init(widthScale: 1.2, dash: [4, 1.4])
        default:
            self.init(widthScale: 1.45, dash: [])
        }
    }

    init(widthScale: Double, dash: [Double]) {
        self.widthScale = widthScale
        self.dash = dash
    }

    /// The dash pattern in points for a line `width` points wide.
    func dashPattern(lineWidth width: Double) -> [Double] {
        dash.map { $0 * width }
    }
}

extension FlowKind {
    var accessibleLineStyle: AccessibleLineStyle {
        AccessibleLineStyle(severityRank: drawRank)
    }
}

extension CongestionLevel {
    var accessibleLineStyle: AccessibleLineStyle {
        AccessibleLineStyle(severityRank: severityRank)
    }
}

// MARK: - Congestion as text

/// One motorway direction in the Auckland congestion list: "Northern
/// Motorway · Southbound" with its segments in feed (travel) order.
struct CongestionListGroup: Identifiable, Equatable {
    let motorway: String
    let direction: String?
    let segments: [CongestionSegment]

    var id: String {
        "\(motorway)|\(direction ?? "")"
    }

    var title: String {
        joinNonEmpty([motorway, direction], separator: " · ") ?? motorway
    }

    /// The worst level any segment reports (Unknown only if all are).
    var worstLevel: CongestionLevel {
        segments.map(\.level).max { $0.severityRank < $1.severityRank } ?? .unknown
    }

    /// "2 congested, 1 heavy" — the segments worse than Moderate — or
    /// "Flowing freely" / "No live data".
    var summary: String {
        congestionSummary(segments)
    }
}

/// The congestion segments as a text list — the map layer's equivalent for
/// VoiceOver and anyone who can't tell its colours apart. Grouped by motorway
/// and direction in the order the feed lists them (which is travel order),
/// keeping only `segments` that pass `isIncluded` (the shared filters).
func congestionListGroups(
    _ segments: [CongestionSegment],
    isIncluded: (CongestionSegment) -> Bool = { _ in true }
) -> [CongestionListGroup] {
    var order: [String] = []
    var grouped: [String: (motorway: String, direction: String?, segments: [CongestionSegment])] = [:]
    for segment in segments where isIncluded(segment) {
        let motorway = segment.motorwayName ?? "Auckland motorways"
        let key = "\(motorway)|\(segment.direction ?? "")"
        if grouped[key] == nil {
            order.append(key)
            grouped[key] = (motorway, segment.direction, [])
        }
        grouped[key]?.segments.append(segment)
    }
    return order.compactMap { key in
        grouped[key].map { CongestionListGroup(motorway: $0.motorway, direction: $0.direction, segments: $0.segments) }
    }
}

/// "3 congested, 2 heavy" for the segments worse than Moderate, worst first;
/// "Flowing freely" when there are none; "No live data" when no segment has
/// a level at all.
func congestionSummary(_ segments: [CongestionSegment]) -> String {
    let known = segments.filter { $0.level != .unknown }
    guard !known.isEmpty else {
        return "No live data"
    }
    let parts = [CongestionLevel.congested, .heavy].compactMap { level -> String? in
        let count = known.filter { $0.level == level }.count
        return count > 0 ? "\(count) \(level.label.lowercased())" : nil
    }
    return parts.isEmpty ? "Flowing freely" : parts.joined(separator: ", ")
}


// MARK: - Side-by-side directions

/// `coordinates` moved `points` screen points to the left of their direction
/// of travel, on a map showing `degreesLongitudePerPoint`. NZ drives on the
/// left, and both the journey legs and the congestion segments run in their
/// own direction of travel, so the two directions of a road land side by
/// side — as their carriageways do — instead of one covering the other. The
/// offset is worked out in Web Mercator, where a point is the same distance
/// in x and y, so it is `points` wide on screen at any latitude. Joins are
/// mitred (limited to twice the offset) so the line keeps its width around
/// bends. Anything that can't be offset comes back unchanged.
func offsetPolyline(
    _ coordinates: [CLLocationCoordinate2D],
    points: Double,
    degreesLongitudePerPoint: Double
) -> [CLLocationCoordinate2D] {
    let distance = points * degreesLongitudePerPoint
    guard coordinates.count >= 2, distance.isFinite, distance != 0 else {
        return coordinates
    }

    let xs = coordinates.map(\.longitude)
    let ys = coordinates.map { mercatorY(latitude: $0.latitude) }
    let count = coordinates.count

    // The left-hand unit normal of each segment, nil for a zero-length one.
    var normals: [(x: Double, y: Double)?] = []
    normals.reserveCapacity(count - 1)
    for index in 0..<(count - 1) {
        let dx = xs[index + 1] - xs[index]
        let dy = ys[index + 1] - ys[index]
        let length = (dx * dx + dy * dy).squareRoot()
        normals.append(length > 1e-12 && length.isFinite ? (-dy / length, dx / length) : nil)
    }

    var result: [CLLocationCoordinate2D] = []
    result.reserveCapacity(count)
    for index in 0..<count {
        // The nearest real segment on each side of this vertex.
        let before = index > 0 ? normals[..<index].last(where: { $0 != nil }) ?? nil : nil
        let after = index < count - 1 ? normals[index...].first(where: { $0 != nil }) ?? nil : nil
        let offset: (x: Double, y: Double)
        switch (before, after) {
        case let (incoming?, outgoing?):
            let sumX = incoming.x + outgoing.x
            let sumY = incoming.y + outgoing.y
            let sumLength = (sumX * sumX + sumY * sumY).squareRoot()
            if sumLength < 1e-9 {
                // The line doubles back on itself: follow the new direction.
                offset = outgoing
            } else {
                let bisector = (x: sumX / sumLength, y: sumY / sumLength)
                let cosine = max(bisector.x * outgoing.x + bisector.y * outgoing.y, 0.5)
                offset = (bisector.x / cosine, bisector.y / cosine)
            }
        case let (incoming?, nil):
            offset = incoming
        case let (nil, outgoing?):
            offset = outgoing
        case (nil, nil):
            offset = (0, 0)
        }
        result.append(
            CLLocationCoordinate2D(
                latitude: latitude(mercatorY: ys[index] + offset.y * distance),
                longitude: xs[index] + offset.x * distance
            )
        )
    }
    return result
}

// Web Mercator northing in degrees (so it shares units with longitude).
func mercatorY(latitude: Double) -> Double {
    let clamped = min(max(latitude, -85), 85) * .pi / 180
    return log(tan(.pi / 4 + clamped / 2)) * 180 / .pi
}

func latitude(mercatorY y: Double) -> Double {
    (2 * atan(exp(y * .pi / 180)) - .pi / 2) * 180 / .pi
}

// MARK: - Regions for EV chargers

/// A region's name and outline (from /regions/all).
struct RegionOutline: Hashable, Sendable {
    let name: String
    let rings: [GeoPolyline]
}

/// The region `coordinate` is in, from the NZTA region outlines: the one it is
/// inside (the most deeply, where the coarse outlines overlap), or else the
/// nearest within `maxDistanceKm` — the outlines are coarse, so many coastal
/// sites (central Wellington, Waiheke, Akaroa) fall just outside every one.
/// nil when no outline is that close.
func regionName(
    containing coordinate: CLLocationCoordinate2D,
    in outlines: [RegionOutline],
    maxDistanceKm: Double = 60
) -> String? {
    var bestInside: (name: String, depth: Double)?
    var bestNearby: (name: String, distance: Double)?
    for outline in outlines {
        let distance = outline.rings.map { distanceKm(from: coordinate, toRing: $0) }.min() ?? .infinity
        if outline.rings.contains(where: { ringContains($0, coordinate) }) {
            if bestInside == nil || distance > bestInside!.depth {
                bestInside = (outline.name, distance)
            }
        } else if distance <= maxDistanceKm, bestNearby == nil || distance < bestNearby!.distance {
            bestNearby = (outline.name, distance)
        }
    }
    return bestInside?.name ?? bestNearby?.name
}

// Even-odd ray cast, longitude as x and latitude as y.
private func ringContains(_ ring: GeoPolyline, _ coordinate: CLLocationCoordinate2D) -> Bool {
    let x = coordinate.longitude
    let y = coordinate.latitude
    var inside = false
    var previous = ring.count - 1
    for index in 0..<ring.count {
        let xi = ring.longitudes[index], yi = ring.latitudes[index]
        let xj = ring.longitudes[previous], yj = ring.latitudes[previous]
        if (yi > y) != (yj > y), x < (xj - xi) * (y - yi) / (yj - yi) + xi {
            inside.toggle()
        }
        previous = index
    }
    return inside
}

// Distance to the nearest edge of `ring`, on a local flat projection — ample
// for choosing between regions a few kilometres apart.
private func distanceKm(from coordinate: CLLocationCoordinate2D, toRing ring: GeoPolyline) -> Double {
    guard ring.count >= 2 else {
        return .infinity
    }
    let kmPerDegree = 111.32
    let xScale = cos(coordinate.latitude * .pi / 180) * kmPerDegree
    let px = coordinate.longitude * xScale
    let py = coordinate.latitude * kmPerDegree
    var best = Double.infinity
    var previous = ring.count - 1
    for index in 0..<ring.count {
        let ax = ring.longitudes[previous] * xScale, ay = ring.latitudes[previous] * kmPerDegree
        let bx = ring.longitudes[index] * xScale, by = ring.latitudes[index] * kmPerDegree
        let dx = bx - ax, dy = by - ay
        let lengthSquared = dx * dx + dy * dy
        let t = lengthSquared > 0 ? min(max(((px - ax) * dx + (py - ay) * dy) / lengthSquared, 0), 1) : 0
        let ex = px - (ax + t * dx), ey = py - (ay + t * dy)
        best = min(best, (ex * ex + ey * ey).squareRoot())
        previous = index
    }
    return best
}

// MARK: - Map cluster emphasis

// How much a feature should stand out, for tinting a cluster by its most
// notable member in the colour the legend gives that member (a cluster of
// Caution events is yellow, and red only when it holds an active closure).

extension RoadEvent {
    /// Active closure > delays > caution > other > upcoming > resolved.
    var mapEmphasis: Int {
        if isResolved {
            return 0
        }
        if isUpcoming {
            return 1
        }
        switch impactKind {
        case .other:
            return 2
        case .caution:
            return 3
        case .delays:
            return 4
        case .closure:
            return 5
        }
    }
}

extension TrafficCamera {
    /// Offline > maintenance > online.
    var mapEmphasis: Int {
        switch statusKind {
        case .online:
            return 0
        case .maintenance:
            return 1
        case .offline:
            return 2
        }
    }
}

extension TIMSign {
    /// Shows nothing right now — no destination/time rows and no text. Many
    /// boards blank overnight, and a blank board has nothing to read.
    var isBlank: Bool {
        pages.isEmpty
    }
}

// MARK: - Map pin glyphs

// The glyph inside each map pin and legend swatch. Every status a pin's
// colour shows also has its own glyph, so a closure, a delay and a caution —
// or an offline and a maintenance camera — can be told apart without colour.

extension EventImpactKind {
    var symbol: String {
        switch self {
        case .closure:
            return "xmark.octagon.fill"
        case .delays:
            return "clock.fill"
        case .caution:
            return "exclamationmark.triangle.fill"
        case .other:
            return "info.circle.fill"
        }
    }
}

enum EventLifecycleSymbol {
    static let upcoming = "calendar"
    static let resolved = "checkmark.circle.fill"
}

extension RoadEvent {
    /// Resolved and upcoming events by their lifecycle, events in force now
    /// by their impact.
    var mapSymbol: String {
        if isResolved {
            return EventLifecycleSymbol.resolved
        }
        if isUpcoming {
            return EventLifecycleSymbol.upcoming
        }
        return impactKind.symbol
    }
}

extension CameraStatusKind {
    var symbol: String {
        switch self {
        case .online:
            return "video.fill"
        case .offline:
            return "video.slash.fill"
        case .maintenance:
            return "wrench.fill"
        }
    }
}

enum MapPinSymbol {
    static let vmsMessage = "signpost.right.fill"
    static let blank = "minus"
    static let timTimes = "clock.fill"
    static let evDC = "bolt.fill"
    static let evAC = "powerplug.fill"
    static let evOutOfService = "bolt.slash.fill"
}

extension EVCharger {
    /// Out of service first (its glyph says so, not just its grey), then DC
    /// fast or AC.
    var mapSymbol: String {
        if isOutOfService {
            return MapPinSymbol.evOutOfService
        }
        return isDC ? MapPinSymbol.evDC : MapPinSymbol.evAC
    }

    /// DC fast > AC > out of service, for colouring a cluster: a cluster
    /// is only grey when every charger in it is down.
    var mapEmphasis: Int {
        if isOutOfService {
            return 0
        }
        return isDC ? 2 : 1
    }

    /// The card's status line glyph.
    var statusSymbol: String {
        switch availability {
        case .available:
            return connectors.inoperativeCount > 0 ? "exclamationmark.circle" : "checkmark.circle"
        case .outOfService:
            return "xmark.octagon"
        case .unknown, .notReported:
            return "questionmark.circle"
        }
    }
}

// MARK: - Grid keyboard navigation

enum GridMove {
    case up
    case down
    case left
    case right
}

/// Columns in a `GridItem(.adaptive(minimum:), spacing:)` grid `width` wide:
/// as many `minimum`-wide columns as fit with `spacing` between them.
func adaptiveGridColumnCount(width: Double, minimum: Double, spacing: Double) -> Int {
    guard width.isFinite, minimum > 0, width > minimum else {
        return 1
    }
    return max(1, Int(((width + spacing) / (minimum + spacing)).rounded(.down)))
}

/// Where an arrow key moves keyboard focus in a list or grid of `count` items
/// laid out `columns` wide, row by row. ←/→ step one item; ↑/↓ step a row,
/// and ↓ from the row above a shorter last row lands on its last item. From
/// nothing focused, any arrow enters at the first item. nil when the move
/// would leave the list.
func gridFocusTarget(from index: Int?, count: Int, columns: Int, move: GridMove) -> Int? {
    guard count > 0 else {
        return nil
    }
    guard let index, (0..<count).contains(index) else {
        return 0
    }
    let columns = max(1, columns)
    let target: Int
    switch move {
    case .left:
        target = index - 1
    case .right:
        target = index + 1
    case .up:
        target = index - columns
    case .down:
        let lastRow = (count - 1) / columns
        guard index / columns < lastRow else {
            return nil
        }
        target = min(index + columns, count - 1)
    }
    return (0..<count).contains(target) ? target : nil
}

// MARK: - Region picker

/// The region picker's selection once the region list is known. A restored
/// (or typed-case) selection takes the list's casing; one the list doesn't
/// have falls back to All Regions ("") — but only when `listIsComplete` (the
/// canonical /regions list has loaded). Until then the list is only what the
/// data so far mentions, so the selection is kept.
func normalizedRegionSelection(_ selection: String, available: [String], listIsComplete: Bool) -> String {
    let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return ""
    }
    if let match = available.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
        return match
    }
    return listIsComplete ? "" : selection
}

// MARK: - Travel Times

/// One region's travel-time boards in the Travel Times tab's board list.
struct TIMBoardGroup: Identifiable, Equatable {
    let region: String
    let boards: [TIMSign]

    var id: String {
        region
    }
}

/// The board list: boards showing something, grouped by region, and the
/// blank ones set apart so they don't crowd out the boards with times.
struct TIMBoardListing: Equatable {
    let groups: [TIMBoardGroup]
    let blank: [TIMSign]

    var showingCount: Int {
        groups.reduce(0) { $0 + $1.boards.count }
    }
}

/// Groups boards (already filtered and sorted by the store) by region, in
/// `regionOrder` — the canonical north-to-south order from /regions/all —
/// then any other region alphabetically, and boards with no region last.
/// Order within a region is kept.
func timBoardListing(_ signs: [TIMSign], regionOrder: [String]) -> TIMBoardListing {
    let otherRegion = "Other"
    var rank: [String: Int] = [:]
    for (index, name) in regionOrder.enumerated() where rank[name.lowercased()] == nil {
        rank[name.lowercased()] = index
    }
    var boardsByRegion: [String: [TIMSign]] = [:]
    var displayName: [String: String] = [:]
    var blank: [TIMSign] = []
    for sign in signs {
        guard !sign.isBlank else {
            blank.append(sign)
            continue
        }
        let name = cleanText(sign.regionName) ?? otherRegion
        let key = name.lowercased()
        boardsByRegion[key, default: []].append(sign)
        if displayName[key] == nil {
            displayName[key] = name
        }
    }
    let orderedKeys = boardsByRegion.keys.sorted { lhs, rhs in
        let lhsRank = lhs == otherRegion.lowercased() ? Int.max : rank[lhs] ?? Int.max - 1
        let rhsRank = rhs == otherRegion.lowercased() ? Int.max : rank[rhs] ?? Int.max - 1
        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }
        return lhs < rhs
    }
    let groups = orderedKeys.map { key in
        TIMBoardGroup(region: displayName[key] ?? key, boards: boardsByRegion[key] ?? [])
    }
    return TIMBoardListing(groups: groups, blank: blank)
}

/// The Travel Times caption when the flow filters hide journeys, e.g.
/// "Showing 9 of 131 journeys · 122 with no live data are hidden". nil when
/// nothing is hidden.
func journeyVisibilityCaption(shown: Int, total: Int, hiddenWithoutLiveData: Int) -> String? {
    let hidden = total - shown
    guard hidden > 0 else {
        return nil
    }
    let noData = min(max(hiddenWithoutLiveData, 0), hidden)
    let byFilters = hidden - noData
    let lead = "Showing \(shown) of \(total) journeys"
    switch (noData, byFilters) {
    case (_, 0):
        return "\(lead) · \(noData) with no live data \(noData == 1 ? "is" : "are") hidden"
    case (0, _):
        return "\(lead) · \(byFilters) hidden by the flow filters"
    default:
        return "\(lead) · \(noData) with no live data and \(byFilters) more by the flow filters are hidden"
    }
}

// MARK: - Map framing

/// A map region in plain degrees — MapKit's MKCoordinateRegion without
/// MapKit, so the test runner can check it.
struct MapFrame: Equatable {
    let centerLatitude: Double
    let centerLongitude: Double
    let latitudeDelta: Double
    let longitudeDelta: Double
}

/// New Zealand as the map sees it. Longitudes are measured eastward from 0°
/// to 360° so the Chatham Islands (about 176.5°W, i.e. 183.5°E) sit next to
/// the mainland instead of on the far side of the antimeridian.
enum NZMapArea {
    static let latitudes = -53.0 ... -28.0
    static let eastLongitudes = 165.0 ... 185.0

    /// Where the map camera's centre may go: the mainland, Stewart Island and
    /// the Chathams with a margin, so the map can never be panned away from
    /// New Zealand.
    static let cameraCenterBounds = MapFrame(
        centerLatitude: -41.0,
        centerLongitude: 175.0,
        latitudeDelta: 22.0,
        longitudeDelta: 20.0
    )

    /// The furthest the camera may zoom out, in metres of camera distance:
    /// enough for the whole country with the Chathams, not the planet.
    static let maximumCameraDistance = 4_500_000.0

    /// The longitude in 0°–360° if it is in the NZ area, else nil.
    static func eastLongitude(_ longitude: Double) -> Double? {
        let east = longitude < 0 ? longitude + 360 : longitude
        return eastLongitudes.contains(east) ? east : nil
    }
}

/// The region that shows every coordinate, padded by `padding` (1.3 = 15% on
/// each side), for framing a filter's results on the map. Coordinates outside
/// the NZ area (a bad feed value) are ignored so one stray point can't zoom
/// the map out to the Pacific. A single point, or a tight cluster, gets at
/// least `minimumSpan` degrees. Crossing the antimeridian (the Chathams) is
/// handled; the centre comes back in −180°…180°. nil when nothing is in NZ.
func mapFrame(
    fitting coordinates: [CLLocationCoordinate2D],
    padding: Double = 1.3,
    minimumSpan: Double = 0.08
) -> MapFrame? {
    var minLatitude = Double.greatestFiniteMagnitude
    var maxLatitude = -Double.greatestFiniteMagnitude
    var minLongitude = Double.greatestFiniteMagnitude
    var maxLongitude = -Double.greatestFiniteMagnitude
    var found = false

    for coordinate in coordinates {
        guard coordinate.latitude.isFinite,
              NZMapArea.latitudes.contains(coordinate.latitude),
              coordinate.longitude.isFinite,
              let longitude = NZMapArea.eastLongitude(coordinate.longitude) else {
            continue
        }
        found = true
        minLatitude = min(minLatitude, coordinate.latitude)
        maxLatitude = max(maxLatitude, coordinate.latitude)
        minLongitude = min(minLongitude, longitude)
        maxLongitude = max(maxLongitude, longitude)
    }
    guard found else {
        return nil
    }

    var centerLongitude = (minLongitude + maxLongitude) / 2
    if centerLongitude > 180 {
        centerLongitude -= 360
    }
    return MapFrame(
        centerLatitude: (minLatitude + maxLatitude) / 2,
        centerLongitude: centerLongitude,
        latitudeDelta: max((maxLatitude - minLatitude) * padding, minimumSpan),
        longitudeDelta: max((maxLongitude - minLongitude) * padding, minimumSpan)
    )
}

// MARK: - Sidebar badges

/// A section's sidebar badge: its count, marked "!" when its last fetch
/// failed and older data is still shown; "!" alone when it failed with
/// nothing to show; none while it loads empty (the toolbar status shows the
/// refresh) or when it is simply empty. A retry in flight drops the mark.
func sectionBadgeText(count: Int, isLoading: Bool, hasError: Bool) -> String? {
    if count > 0 {
        return hasError && !isLoading ? "\(count) !" : "\(count)"
    }
    if hasError && !isLoading {
        return "!"
    }
    return nil
}
