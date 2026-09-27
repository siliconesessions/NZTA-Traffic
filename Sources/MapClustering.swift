import CoreLocation
import Foundation

// Screen-space clustering for the map's pin layers, Foundation-only so
// run_tests.sh can test it.
//
// Pins are bucketed into a grid measured in screen points: a cell is about
// one marker wide (`radiusPoints`) at the current zoom, so pins that would
// overlap on screen share a marker at every zoom level, and clusters dissolve
// by themselves once zooming in has pulled their pins apart. The grid is
// anchored to the world (Web Mercator, the map's own projection), not to the
// viewport, and its cell size is rounded to a power of two, so panning, or
// zooming by less than a factor of two, gives exactly the same clusters with
// the same identities. A second pass merges neighbouring cells whose centres
// are closer than a cell, so two pins either side of a cell edge don't sit on
// top of each other. Linear in the number of pins (a few thousand at most).

/// One pin to cluster: its stable id and where it is.
struct ClusterPoint: Sendable {
    let id: String
    let coordinate: CLLocationCoordinate2D
}

/// A marker on the map: one pin, or several drawn as one.
struct MapPointCluster: Equatable, Sendable {
    /// The pin's own id for a single pin; for a group, "cluster:" plus its
    /// smallest member id, which stays the same while the group keeps that
    /// member, whatever else joins or leaves it.
    let id: String
    /// Indices into the input, in input order.
    let memberIndices: [Int]
    /// The members' centre, for placing the marker.
    let latitude: Double
    let longitude: Double
    /// Every member is within `coLocatedDegrees` of the others: they sit at
    /// the same spot, so no amount of zooming will separate them.
    let isCoLocated: Bool

    var isSingle: Bool {
        memberIndices.count == 1
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

enum MapClustering {
    /// A cluster marker's footprint in points: pins closer than this on
    /// screen are grouped. About one 44 pt marker.
    static let radiusPoints = 44.0

    /// Members this close (in degrees, about 30 m) are "at the same place":
    /// even the closest zoom the map allows puts them under one marker.
    static let coLocatedDegrees = 0.0003

    /// The smallest span (degrees, about 1 km) a click on a cluster zooms
    /// to. Comfortably above the closest the map camera may go (250 m, see
    /// trafficMapCameraBounds), so the zoom always lands where asked and a
    /// second click on a cluster still there lists it instead of zooming to
    /// the same place again. The user can still zoom closer by hand.
    static let minimumZoomSpan = 0.01

    /// The grid level for a zoom: the cell is 2^level degrees, the smallest
    /// power of two covering `radiusPoints`. Only a change of level changes
    /// the clusters, so the view reclusters when this changes, not on every
    /// camera move. nil when the map has no size yet.
    static func cellLevel(degreesPerPoint: Double, radiusPoints: Double = radiusPoints) -> Int? {
        let cell = degreesPerPoint * radiusPoints
        guard cell.isFinite, cell > 0 else {
            return nil
        }
        return Int(log2(cell).rounded(.up))
    }
}

/// Groups `points` into markers for a map showing `degreesPerPoint` degrees
/// of longitude per screen point. Every input index appears in exactly one
/// result; the result is ordered by each marker's first member, so it is the
/// same for the same input. With no usable scale, every pin stands alone.
func clusterMapPoints(
    _ points: [ClusterPoint],
    degreesPerPoint: Double,
    radiusPoints: Double = MapClustering.radiusPoints,
    coLocatedDegrees: Double = MapClustering.coLocatedDegrees
) -> [MapPointCluster] {
    guard let level = MapClustering.cellLevel(degreesPerPoint: degreesPerPoint, radiusPoints: radiusPoints),
          points.count > 1 else {
        return points.indices.map { singleCluster(points, index: $0) }
    }
    let cellSize = pow(2.0, Double(level))

    // Project once: x is longitude east of 0° (so the Chathams sit beside
    // the mainland rather than across the antimeridian), y the Mercator
    // northing in the same degree units, so a cell is square on screen.
    let projected: [(x: Double, y: Double)] = points.map { point in
        let longitude = point.coordinate.longitude
        return (longitude < 0 ? longitude + 360 : longitude, mercatorY(latitude: point.coordinate.latitude))
    }

    struct Cell: Hashable, Comparable {
        let x: Int
        let y: Int

        static func < (lhs: Cell, rhs: Cell) -> Bool {
            (lhs.x, lhs.y) < (rhs.x, rhs.y)
        }
    }

    var buckets: [Cell: [Int]] = [:]
    for (index, position) in projected.enumerated() {
        guard position.x.isFinite, position.y.isFinite else {
            continue
        }
        let cell = Cell(x: Int((position.x / cellSize).rounded(.down)), y: Int((position.y / cellSize).rounded(.down)))
        buckets[cell, default: []].append(index)
    }

    var centres: [Cell: (x: Double, y: Double)] = [:]
    for (cell, members) in buckets {
        let count = Double(members.count)
        centres[cell] = (
            members.reduce(0.0) { $0 + projected[$1].x } / count,
            members.reduce(0.0) { $0 + projected[$1].y } / count
        )
    }

    // Busiest cells first, so a crowded cell absorbs the stragglers beside
    // it rather than the other way round; ties broken by position so the
    // result never depends on dictionary order.
    let order = buckets.keys.sorted { lhs, rhs in
        let lhsCount = buckets[lhs]?.count ?? 0
        let rhsCount = buckets[rhs]?.count ?? 0
        return lhsCount != rhsCount ? lhsCount > rhsCount : lhs < rhs
    }

    var absorbed = Set<Cell>()
    var groups: [[Int]] = []
    for cell in order where !absorbed.contains(cell) {
        absorbed.insert(cell)
        var members = buckets[cell] ?? []
        guard let centre = centres[cell] else {
            continue
        }
        for dx in -1...1 {
            for dy in -1...1 where dx != 0 || dy != 0 {
                let neighbour = Cell(x: cell.x + dx, y: cell.y + dy)
                guard !absorbed.contains(neighbour),
                      let other = centres[neighbour],
                      hypot(other.x - centre.x, other.y - centre.y) < cellSize else {
                    continue
                }
                absorbed.insert(neighbour)
                members += buckets[neighbour] ?? []
            }
        }
        groups.append(members.sorted())
    }

    // Points with a non-finite coordinate never reach a cell; they still
    // come back, alone, so the caller's counts stay whole.
    var placed = Set(groups.joined())
    for index in points.indices where !placed.contains(index) {
        groups.append([index])
        placed.insert(index)
    }

    return groups
        .sorted { ($0.first ?? 0) < ($1.first ?? 0) }
        .map { members in
            members.count == 1
                ? singleCluster(points, index: members[0])
                : groupCluster(points, projected: projected, members: members, coLocatedDegrees: coLocatedDegrees)
        }
}

private func singleCluster(_ points: [ClusterPoint], index: Int) -> MapPointCluster {
    let point = points[index]
    return MapPointCluster(
        id: point.id,
        memberIndices: [index],
        latitude: point.coordinate.latitude,
        longitude: point.coordinate.longitude,
        isCoLocated: false
    )
}

private func groupCluster(
    _ points: [ClusterPoint],
    projected: [(x: Double, y: Double)],
    members: [Int],
    coLocatedDegrees: Double
) -> MapPointCluster {
    let count = Double(members.count)
    let x = members.reduce(0.0) { $0 + projected[$1].x } / count
    let y = members.reduce(0.0) { $0 + projected[$1].y } / count
    let extent = coordinateExtent(members.map { points[$0].coordinate })
    let smallestID = members.map { points[$0].id }.min() ?? ""
    return MapPointCluster(
        id: "cluster:\(smallestID)",
        memberIndices: members,
        latitude: latitude(mercatorY: y),
        longitude: x > 180 ? x - 360 : x,
        isCoLocated: extent.latitude < coLocatedDegrees && extent.longitude < coLocatedDegrees
    )
}

// MARK: - Clicking a cluster

/// What clicking a cluster does: zoom to where its members separate, or —
/// when they can't be separated (the same spot, or the map is already as
/// close as it goes) — list them to pick from.
enum ClusterTapAction: Equatable {
    case zoom(MapFrame)
    case pick
}

/// The region that spreads `coordinates` across most of the map, never more
/// than halfway in from `visibleSpan` at once (so a big cluster zooms in
/// steps) nor closer than `minimumSpan`. `.pick` when that region wouldn't be
/// meaningfully closer than what is on screen, or the members share a spot.
func clusterTapAction(
    for coordinates: [CLLocationCoordinate2D],
    visibleLatitudeDelta: Double,
    visibleLongitudeDelta: Double,
    minimumSpan: Double = MapClustering.minimumZoomSpan,
    coLocatedDegrees: Double = MapClustering.coLocatedDegrees
) -> ClusterTapAction {
    guard !coordinates.isEmpty else {
        return .pick
    }
    let extent = coordinateExtent(coordinates)
    if coordinates.count > 1, extent.latitude < coLocatedDegrees, extent.longitude < coLocatedDegrees {
        return .pick
    }
    let targetLatitude = max(min(extent.latitude * 1.6, visibleLatitudeDelta * 0.5), minimumSpan)
    let targetLongitude = max(min(extent.longitude * 1.6, visibleLongitudeDelta * 0.5), minimumSpan)
    // The map fits the whole target region, so the zoom is set by whichever
    // direction shrinks least. Barely closer (or not at all) than what's on
    // screen: zooming again won't help.
    let zoomFactor = max(targetLatitude / visibleLatitudeDelta, targetLongitude / visibleLongitudeDelta)
    guard zoomFactor < 0.9 else {
        return .pick
    }
    var centreLongitude = extent.centreEastLongitude
    if centreLongitude > 180 {
        centreLongitude -= 360
    }
    return .zoom(
        MapFrame(
            centerLatitude: extent.centreLatitude,
            centerLongitude: centreLongitude,
            latitudeDelta: targetLatitude,
            longitudeDelta: targetLongitude
        )
    )
}

// MARK: - Helpers

private struct CoordinateExtent {
    let latitude: Double
    let longitude: Double
    let centreLatitude: Double
    let centreEastLongitude: Double
}

// Latitude and (antimeridian-safe) longitude spread of some coordinates.
private func coordinateExtent(_ coordinates: [CLLocationCoordinate2D]) -> CoordinateExtent {
    var minLatitude = Double.greatestFiniteMagnitude
    var maxLatitude = -Double.greatestFiniteMagnitude
    var minLongitude = Double.greatestFiniteMagnitude
    var maxLongitude = -Double.greatestFiniteMagnitude
    for coordinate in coordinates where coordinate.latitude.isFinite && coordinate.longitude.isFinite {
        let east = coordinate.longitude < 0 ? coordinate.longitude + 360 : coordinate.longitude
        minLatitude = min(minLatitude, coordinate.latitude)
        maxLatitude = max(maxLatitude, coordinate.latitude)
        minLongitude = min(minLongitude, east)
        maxLongitude = max(maxLongitude, east)
    }
    guard minLatitude <= maxLatitude else {
        return CoordinateExtent(latitude: 0, longitude: 0, centreLatitude: 0, centreEastLongitude: 0)
    }
    return CoordinateExtent(
        latitude: maxLatitude - minLatitude,
        longitude: maxLongitude - minLongitude,
        centreLatitude: (minLatitude + maxLatitude) / 2,
        centreEastLongitude: (minLongitude + maxLongitude) / 2
    )
}
