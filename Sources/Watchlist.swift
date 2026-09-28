import Foundation

// The user's watchlist — highways, cameras and journeys they follow — and the
// pure logic behind closure notifications: which active closures are new
// since the last live events refresh and on something watched, and what the
// notifications say. Foundation-only so run_tests.sh can compile and test it;
// posting the notifications (UserNotifications) lives in the app layer.

// MARK: - Watchlist

/// What the user watches. Highways are stored as canonical highway keys (see
/// `canonicalHighwayKey`: "SH1", "State Highway 1", "01N" are all "1"), so a
/// watch matches every feed's spelling of the road. Cameras and journeys are
/// watched by id. Persisted as JSON in UserDefaults under `defaultsKey`.
struct Watchlist: Codable, Hashable, Sendable {
    static let defaultsKey = "nzta.watchlist"

    private(set) var highways: Set<String> = []
    private(set) var cameraIDs: Set<String> = []
    private(set) var journeyIDs: Set<String> = []

    init() {}

    var isEmpty: Bool {
        highways.isEmpty && cameraIDs.isEmpty && journeyIDs.isEmpty
    }

    /// Watched highway keys in road order: 1, 1B, 2, 20, 20A, …
    var sortedHighways: [String] {
        sortedHighwayKeys(highways)
    }

    // MARK: Editing

    /// Watches the highway `raw` names ("SH 1", "state highway 20a", "1").
    /// Returns its key, or nil when `raw` isn't a highway reference.
    @discardableResult
    mutating func watchHighway(_ raw: String) -> String? {
        guard let key = canonicalHighwayKey(raw) else {
            return nil
        }
        highways.insert(key)
        return key
    }

    mutating func unwatchHighway(_ raw: String) {
        if let key = canonicalHighwayKey(raw) {
            highways.remove(key)
        }
    }

    func isWatching(highway raw: String) -> Bool {
        canonicalHighwayKey(raw).map(highways.contains) ?? false
    }

    mutating func setWatching(cameraID id: String, _ isWatched: Bool) {
        if isWatched {
            cameraIDs.insert(id)
        } else {
            cameraIDs.remove(id)
        }
    }

    mutating func setWatching(journeyID id: String, _ isWatched: Bool) {
        if isWatched {
            journeyIDs.insert(id)
        } else {
            journeyIDs.remove(id)
        }
    }

    func isWatching(cameraID id: String) -> Bool {
        cameraIDs.contains(id)
    }

    func isWatching(journeyID id: String) -> Bool {
        journeyIDs.contains(id)
    }

    // MARK: Matching

    /// A watched camera, or one on a watched highway.
    func watches(_ camera: TrafficCamera) -> Bool {
        cameraIDs.contains(camera.id) || !highways.isDisjoint(with: camera.highwayKeys)
    }

    /// A watched journey, or one along a watched highway.
    func watches(_ journey: TrafficJourney) -> Bool {
        journeyIDs.contains(journey.id) || !highways.isDisjoint(with: journey.highwayKeys)
    }

    /// An event on a watched highway, or on a watched journey (events carry
    /// the /journeys id of the journey they sit on).
    func watches(_ event: RoadEvent) -> Bool {
        if !highways.isDisjoint(with: event.highwayKeys) {
            return true
        }
        guard let journeyID = event.journey?.id else {
            return false
        }
        return journeyIDs.contains(journeyID)
    }

    /// The watched highways an event is on, in road order.
    func watchedHighways(of event: RoadEvent) -> [String] {
        sortedHighwayKeys(highways.intersection(event.highwayKeys))
    }

    // MARK: Persistence

    /// Reads a stored watchlist; missing or unreadable data is an empty one.
    static func decoded(from data: Data?) -> Watchlist {
        guard let data, let watchlist = try? JSONDecoder().decode(Watchlist.self, from: data) else {
            return Watchlist()
        }
        return watchlist
    }

    func encodedData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(self)
    }

    // Stored as sorted arrays, so the JSON is stable. Decoding is lenient:
    // any missing list is empty, and highway entries are re-normalised (and
    // dropped when they aren't highways).
    private enum CodingKeys: String, CodingKey {
        case highways
        case cameras
        case journeys
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedHighways = (try? container.decodeIfPresent([String].self, forKey: .highways)) ?? []
        highways = Set(storedHighways.compactMap(canonicalHighwayKey))
        cameraIDs = Set(((try? container.decodeIfPresent([String].self, forKey: .cameras)) ?? []).filter { !$0.isEmpty })
        journeyIDs = Set(((try? container.decodeIfPresent([String].self, forKey: .journeys)) ?? []).filter { !$0.isEmpty })
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sortedHighways, forKey: .highways)
        try container.encode(cameraIDs.sorted(), forKey: .cameras)
        try container.encode(journeyIDs.sorted(), forKey: .journeys)
    }
}

/// How a highway key reads in the UI: "SH1", "SH20A".
func highwayLabel(_ key: String) -> String {
    "SH\(key)"
}

/// Highway keys in road order — by number, then spur letter — rather than
/// as strings ("2" before "20", "1" before "1B").
func sortedHighwayKeys<S: Sequence<String>>(_ keys: S) -> [String] {
    keys.sorted { lhs, rhs in
        let lhsNumber = Int(lhs.prefix { $0.isNumber }) ?? .max
        let rhsNumber = Int(rhs.prefix { $0.isNumber }) ?? .max
        if lhsNumber != rhsNumber {
            return lhsNumber < rhsNumber
        }
        return lhs < rhs
    }
}

// MARK: - New closures on watched roads

/// Finds closures that are new on watched roads, one live events refresh to
/// the next. The first refresh only records a baseline — a closure already in
/// force when the app starts isn't news — and so does a watch added later:
/// the baseline is every active closure, watched or not, so closures already
/// on a newly watched highway don't all announce themselves. The baseline
/// accumulates every active closure seen this session, so each closure is
/// reported at most once per session, even if it drops out of the feed and
/// comes back.
struct WatchedClosureTracker: Sendable {
    private(set) var baseline: Set<String>?

    var hasBaseline: Bool {
        baseline != nil
    }

    /// Feed with every successful live events fetch (never saved data).
    /// Returns the active closures to announce, in feed order.
    mutating func newWatchedClosures(in events: [RoadEvent], watchlist: Watchlist) -> [RoadEvent] {
        let active = events.filter(\.isActiveClosure)
        let activeIDs = Set(active.map(\.id))
        defer { baseline = (baseline ?? []).union(activeIDs) }
        guard let baseline, !watchlist.isEmpty else {
            return []
        }
        var seen = Set<String>()
        return active.filter { event in
            !baseline.contains(event.id)
                && watchlist.watches(event)
                && seen.insert(event.id).inserted
        }
    }
}

/// One notification to post.
struct ClosureNotificationContent: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
}

/// The notifications for newly found closures: one per closure, or — when
/// there are more than `summaryThreshold` — a single summary, so a storm
/// doesn't bury the screen.
func closureNotificationContents(
    for closures: [RoadEvent],
    watchlist: Watchlist,
    summaryThreshold: Int = 3
) -> [ClosureNotificationContent] {
    guard !closures.isEmpty else {
        return []
    }
    if closures.count > summaryThreshold {
        let listed = closures.prefix(summaryThreshold).map { closure in
            joinNonEmpty([closureRoadLabel(closure, watchlist: watchlist), closureWhere(closure)], separator: ": ")
                ?? closure.displayTitle
        }
        let more = closures.count - listed.count
        return [
            ClosureNotificationContent(
                identifier: "closures-" + closures.map(\.id).joined(separator: ","),
                title: "\(closures.count) new closures on roads you watch",
                body: (listed + ["and \(more) more"]).joined(separator: "\n")
            )
        ]
    }
    return closures.map { closure in
        let road = closureRoadLabel(closure, watchlist: watchlist)
        return ClosureNotificationContent(
            identifier: "closure-\(closure.id)",
            title: road.map { "Road closed on \($0)" } ?? "Road closed on a road you watch",
            body: joinNonEmpty(
                [closureWhere(closure), closure.displayTitle, closure.directionText],
                separator: " · "
            ) ?? closure.displayTitle
        )
    }
}

// The watched road a closure is on: its watched highways ("SH1, SH2"), or the
// watched journey's name.
private func closureRoadLabel(_ closure: RoadEvent, watchlist: Watchlist) -> String? {
    let highways = watchlist.watchedHighways(of: closure)
    if !highways.isEmpty {
        return highways.map(highwayLabel).joined(separator: ", ")
    }
    return closure.journey?.name
}

private func closureWhere(_ closure: RoadEvent) -> String? {
    closure.locationArea ?? closure.locations
}
