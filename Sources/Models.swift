import CoreLocation
import Foundation
import Synchronization

struct Region: Decodable, Hashable {
    let id: String?
    let name: String?
    // The region's outline: only /regions/all carries one (a coarse WKT
    // POLYGON of 8–17 points); the regions embedded in features don't. Used
    // to place EV chargers, which have no region of their own, in a region.
    let boundary: [GeoPolyline]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeLossyString(forKey: .id)
        name = cleanText(container.decodeLossyString(forKey: .name))
        boundary = parseWKTParts(container.decodeLossyString(forKey: .geometry))
            .filter { $0.count >= 3 }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case geometry
    }
}

struct Journey: Decodable, Hashable {
    let id: String?
    let name: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeLossyString(forKey: .id)
        name = cleanText(container.decodeLossyString(forKey: .name))
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
    }
}

struct JourneyLeg: Decodable, Hashable {
    let name: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = cleanText(container.decodeLossyString(forKey: .name))
    }

    private enum CodingKeys: String, CodingKey {
        case name
    }
}

struct Way: Decodable, Hashable {
    let id: String?
    let name: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeLossyString(forKey: .id)
        name = cleanText(container.decodeLossyString(forKey: .name))
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
    }
}

struct TrafficCamera: Decodable, Identifiable, Hashable, TrafficFilterable {
    let id: String
    let rawId: String?
    let name: String?
    let description: String?
    let direction: String?
    let group: String?
    let highway: String?
    /// The live frame (`/camera/<id>.jpg`), rewritten about once a minute
    /// with a burned-in timestamp.
    let imageUrl: String?
    /// `/camera/thumb/<id>.jpg`: a 100×74 still NZTA never refreshes — most
    /// were last written between 2021 and 2025 and show old scenes (daylight
    /// at night, finished roadworks). Only a fallback for when the live frame
    /// can't load, and never presented as the current view.
    let thumbUrl: String?
    /// Legacy `/camera/view/<id>` page path. trafficnz.info now redirects to
    /// journeys.nzta.govt.nz and this path 404s, so don't surface it as a link —
    /// use `imageURL(cacheToken:)` (the working image path) for "open larger view".
    let viewUrl: String?
    let latitude: Double?
    let longitude: Double?
    let offline: Bool
    let underMaintenance: Bool
    let sortOrder: Int?
    let region: Region?
    let journey: Journey?
    let journeyLeg: JourneyLeg?
    let way: Way?
    let mapLatitude: Double?
    let mapLongitude: Double?
    let statusKind: CameraStatusKind
    let highwayKeys: Set<String>
    let highwayHaystack: String
    let searchHaystack: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedId = container.decodeLossyString(forKey: .id)
        let nameValue = cleanText(container.decodeLossyString(forKey: .name))
        let descriptionValue = cleanText(container.decodeLossyString(forKey: .description))
        let directionValue = cleanText(container.decodeLossyString(forKey: .direction))
        let highwayValue = cleanText(container.decodeLossyString(forKey: .highway))
        let imageUrlValue = cleanText(container.decodeLossyString(forKey: .imageUrl))
        let thumbUrlValue = cleanText(container.decodeLossyString(forKey: .thumbUrl))
        let latitudeValue = container.decodeLossyDouble(forKey: .latitude)
        let longitudeValue = container.decodeLossyDouble(forKey: .longitude)
        let regionValue = try? container.decodeIfPresent(Region.self, forKey: .region)
        let journeyValue = try? container.decodeIfPresent(Journey.self, forKey: .journey)
        let wayValue = try? container.decodeIfPresent(Way.self, forKey: .way)
        let offlineValue = container.decodeLossyBool(forKey: .offline) ?? false
        let underMaintenanceValue = container.decodeLossyBool(forKey: .underMaintenance) ?? false

        rawId = decodedId
        id = deterministicID(
            decodedId: decodedId,
            fallback: [
                imageUrlValue,
                thumbUrlValue,
                nameValue,
                latitudeValue.map { String($0) },
                longitudeValue.map { String($0) }
            ],
            typeTag: "camera"
        )
        name = nameValue
        description = descriptionValue
        direction = directionValue
        group = cleanText(container.decodeLossyString(forKey: .group))
        highway = highwayValue
        imageUrl = imageUrlValue
        thumbUrl = thumbUrlValue
        viewUrl = cleanText(container.decodeLossyString(forKey: .viewUrl))
        latitude = latitudeValue
        longitude = longitudeValue
        offline = offlineValue
        underMaintenance = underMaintenanceValue
        sortOrder = container.decodeLossyInt(forKey: .sortOrder)
        region = regionValue
        journey = journeyValue
        journeyLeg = try? container.decodeIfPresent(JourneyLeg.self, forKey: .journeyLeg)
        way = wayValue
        let validatedMap = validatedCoordinate(latitude: latitudeValue, longitude: longitudeValue)
        mapLatitude = validatedMap?.latitude
        mapLongitude = validatedMap?.longitude
        statusKind = computeCameraStatusKind(offline: offlineValue, underMaintenance: underMaintenanceValue)
        // Camera names/descriptions carry junction mentions ("SH16/20
        // Interchange", "SH1/SH18 Interchange"), so those count too.
        highwayKeys = highwayKeySet(
            structured: [highwayValue, journeyValue?.name, wayValue?.name],
            text: [nameValue, descriptionValue]
        )
        highwayHaystack = searchableHaystack([
            highwayValue,
            journeyValue?.name,
            wayValue?.name,
            nameValue,
            descriptionValue
        ])
        searchHaystack = searchableHaystack([
            nameValue,
            descriptionValue,
            highwayValue,
            directionValue,
            regionValue?.name
        ])
    }

    var displayName: String {
        name ?? "Traffic Camera"
    }

    var regionName: String? {
        region?.name
    }

    var isOnline: Bool {
        !offline && !underMaintenance
    }

    var mapCoordinate: CLLocationCoordinate2D? {
        guard let mapLatitude, let mapLongitude else {
            return nil
        }
        return CLLocationCoordinate2D(latitude: mapLatitude, longitude: mapLongitude)
    }

    var routeLine: String? {
        let route = highway ?? journey?.name ?? way?.name
        return joinNonEmpty([route, direction], separator: " - ")
    }

    // The preview sheet and "Open full image": the live frame, or the old
    // still when a camera has no live path.
    func imageURL(cacheToken: Int) -> URL? {
        trafficNZURL(from: imageUrl ?? thumbUrl, cacheToken: cacheToken)
    }

    // The camera grid's image: the live frame only, so a card never shows
    // the static thumbnail as if it were current.
    func liveImageURL(cacheToken: Int) -> URL? {
        trafficNZURL(from: imageUrl, cacheToken: cacheToken)
    }

    // The static thumbnail (see `thumbUrl`), for the grid to fall back on —
    // labelled as not live — when the live frame fails. No cache token: the
    // file never changes.
    var stillThumbnailURL: URL? {
        trafficNZURL(from: thumbUrl)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case direction
        case group
        case highway
        case imageUrl
        case thumbUrl
        case viewUrl
        case latitude
        case longitude
        case offline
        case underMaintenance
        case sortOrder
        case region
        case journey
        case journeyLeg
        case way
    }
}

struct RoadEvent: Decodable, Identifiable, Hashable, TrafficFilterable {
    let id: String
    let rawId: String?
    let alternativeRoute: String?
    let endDate: String?
    let eventComments: String?
    let eventCreated: String?
    let eventDescription: String?
    let eventIsland: String?
    let eventModified: String?
    let eventType: String?
    let expectedResolution: String?
    let geometry: String?
    let impact: String?
    let informationSource: String?
    let latitude: Double?
    let longitude: Double?
    let locationArea: String?
    let locations: String?
    let planned: Bool?
    let restrictions: String?
    let status: String?
    let supplier: String?
    let startDate: String?
    let direction: String?
    let travelDirection: String?
    let directLineDistance1: String?
    let directLineDistance2: String?
    let directLineDistance3: String?
    let region: Region?
    let journey: Journey?
    let journeyLeg: JourneyLeg?
    let way: Way?
    let geometryLatitude: Double?
    let geometryLongitude: Double?
    let mapLatitude: Double?
    let mapLongitude: Double?
    let severityRank: Int
    let impactKind: EventImpactKind
    let statusKind: EventStatus
    let highwayKeys: Set<String>
    let highwayHaystack: String
    let searchHaystack: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedId = container.decodeLossyString(forKey: .id)
        let alternativeRouteValue = cleanText(container.decodeLossyString(forKey: .alternativeRoute))
        let eventCommentsValue = cleanText(container.decodeLossyString(forKey: .eventComments))
        let eventDescriptionValue = cleanText(container.decodeLossyString(forKey: .eventDescription))
        let eventTypeValue = cleanText(container.decodeLossyString(forKey: .eventType))
        let geometryValue = cleanText(container.decodeLossyString(forKey: .geometry))
        let impactValue = cleanText(container.decodeLossyString(forKey: .impact))
        let latitudeValue = container.decodeLossyDouble(forKey: .latitude)
        let longitudeValue = container.decodeLossyDouble(forKey: .longitude)
        let locationAreaValue = cleanText(container.decodeLossyString(forKey: .locationArea))
        // `locations` is usually a string but occasionally a list of segment
        // descriptions (e.g. a multi-bridge flooding event); keep both.
        let locationsValue = cleanText(container.decodeLossyStringOrArray(forKey: .locations))
        let restrictionsValue = cleanText(container.decodeLossyString(forKey: .restrictions))
        let statusValue = cleanText(container.decodeLossyString(forKey: .status))
        let startDateValue = cleanText(container.decodeLossyString(forKey: .startDate))
        let eventCreatedValue = cleanText(container.decodeLossyString(forKey: .eventCreated))
        let regionValue = try? container.decodeIfPresent(Region.self, forKey: .region)
        let journeyValue = try? container.decodeIfPresent(Journey.self, forKey: .journey)
        let wayValue = try? container.decodeIfPresent(Way.self, forKey: .way)

        rawId = decodedId
        id = deterministicID(
            decodedId: decodedId,
            fallback: [
                eventDescriptionValue,
                locationsValue,
                locationAreaValue,
                startDateValue,
                eventCreatedValue,
                latitudeValue.map { String($0) },
                longitudeValue.map { String($0) }
            ],
            typeTag: "event"
        )
        alternativeRoute = alternativeRouteValue
        endDate = cleanText(container.decodeLossyString(forKey: .endDate))
        eventComments = eventCommentsValue
        eventCreated = eventCreatedValue
        eventDescription = eventDescriptionValue
        eventIsland = cleanText(container.decodeLossyString(forKey: .eventIsland))
        eventModified = cleanText(container.decodeLossyString(forKey: .eventModified))
        eventType = eventTypeValue
        expectedResolution = cleanText(container.decodeLossyString(forKey: .expectedResolution))
        geometry = geometryValue
        impact = impactValue
        informationSource = cleanText(container.decodeLossyString(forKey: .informationSource))
        latitude = latitudeValue
        longitude = longitudeValue
        locationArea = locationAreaValue
        locations = locationsValue
        planned = container.decodeLossyBool(forKey: .planned)
        restrictions = restrictionsValue
        status = statusValue
        statusKind = EventStatus(raw: statusValue)
        supplier = cleanText(container.decodeLossyString(forKey: .supplier))
        startDate = startDateValue
        direction = cleanText(container.decodeLossyString(forKey: .direction))
        travelDirection = cleanText(container.decodeLossyString(forKey: .travelDirection))
        directLineDistance1 = cleanText(container.decodeLossyString(forKey: .directLineDistance1))
        directLineDistance2 = cleanText(container.decodeLossyString(forKey: .directLineDistance2))
        directLineDistance3 = cleanText(container.decodeLossyString(forKey: .directLineDistance3))
        region = regionValue
        journey = journeyValue
        journeyLeg = try? container.decodeIfPresent(JourneyLeg.self, forKey: .journeyLeg)
        way = wayValue

        if let parsed = coordinateFromWKTGeometry(geometryValue) {
            geometryLatitude = parsed.latitude
            geometryLongitude = parsed.longitude
        } else {
            geometryLatitude = nil
            geometryLongitude = nil
        }
        let validatedMap = validatedCoordinate(latitude: latitudeValue, longitude: longitudeValue)
            ?? validatedCoordinate(latitude: geometryLatitude, longitude: geometryLongitude)
        mapLatitude = validatedMap?.latitude
        mapLongitude = validatedMap?.longitude
        severityRank = computeSeverityRank(impact: impactValue)
        impactKind = computeImpactKind(impact: impactValue)
        // The event's own location text names the highway(s) it sits on
        // ("SH 1 Invercargill to Awarua", "SH1/SH90 intersection"). Comments
        // and alternative routes are left out: they mention detour highways.
        highwayKeys = highwayKeySet(
            structured: [journeyValue?.name, wayValue?.name],
            text: [locationAreaValue, locationsValue]
        )
        highwayHaystack = searchableHaystack([
            journeyValue?.name,
            wayValue?.name,
            locationsValue,
            locationAreaValue,
            eventDescriptionValue
        ])
        searchHaystack = searchableHaystack([
            locationAreaValue,
            locationsValue,
            eventDescriptionValue,
            eventCommentsValue,
            alternativeRouteValue,
            restrictionsValue,
            eventTypeValue,
            regionValue?.name
        ])
    }

    var displayTitle: String {
        eventDescription ?? eventType ?? "Road Event"
    }

    var regionName: String? {
        region?.name
    }

    var isClosure: Bool {
        impact?.range(of: "closed", options: .caseInsensitive) != nil
    }

    /// In force now: status Active, or a missing/unrecognised status (see
    /// `EventStatus`). Scheduled and Resolved events are not current.
    var isActive: Bool {
        statusKind.isCurrent
    }

    /// Scheduled for the future — shown as "Upcoming".
    var isUpcoming: Bool {
        statusKind == .scheduled
    }

    /// Already over. NZTA keeps these in the feed for about a day; they are
    /// hidden unless the user turns on "Show resolved".
    var isResolved: Bool {
        statusKind == .resolved
    }

    /// A road closure in force now. This is what the Dock badge, the menu bar
    /// "Active closures" line and the Road Events stat count — upcoming and
    /// resolved closures are not live.
    var isActiveClosure: Bool {
        isClosure && isActive
    }

    /// Whether the event is listed at all, given the "Show resolved" setting.
    func isVisible(showResolved: Bool) -> Bool {
        showResolved || !isResolved
    }

    /// The event's end date has passed. Used to leave finished events out
    /// when the offline cache is replayed, so old saved data can't show (or
    /// badge) them as current. No end date, or an unreadable one, means not
    /// ended.
    func hasEnded(before reference: Date) -> Bool {
        guard let endDate, let date = parseTrafficDate(endDate) else {
            return false
        }
        return date < reference
    }

    var hasDelays: Bool {
        impact?.range(of: "delay", options: .caseInsensitive) != nil
    }

    var mapCoordinate: CLLocationCoordinate2D? {
        guard let mapLatitude, let mapLongitude else {
            return nil
        }
        return CLLocationCoordinate2D(latitude: mapLatitude, longitude: mapLongitude)
    }

    // Placeholder values the feed uses when there is no detour ("Not
    // Applicable", "Not applicable.", "N/A", "N/a", …), compared after
    // trimming whitespace/punctuation, collapsing spaces and lowercasing.
    private static let noAlternativeRoutePlaceholders: Set<String> = [
        "", "n/a", "na", "not applicable", "none", "nil"
    ]

    var alternativeRouteText: String? {
        guard let alternativeRoute else {
            return nil
        }

        let normalized = alternativeRoute
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
        if Self.noAlternativeRoutePlaceholders.contains(normalized) {
            return nil
        }
        return alternativeRoute
    }

    // Planned roadworks vs. an unplanned incident. The API omits `planned` on a
    // handful of records; treat a missing flag as an incident (the safer read).
    var isPlanned: Bool {
        planned ?? false
    }

    // Friendly "near" reference, e.g. "1.20 km north of Rapahoe". The API ranks
    // these closest-first, so the lowest-numbered present value is the nearest.
    var nearestLandmark: String? {
        directLineDistance1 ?? directLineDistance2 ?? directLineDistance3
    }

    // Carriageway affected, e.g. "Southbound" or "Both Directions" (rest/5).
    // Prefer the human-readable `direction`; fall back to a tidied
    // `travelDirection` enum token ("BOTH_DIRECTIONS" -> "Both Directions").
    var directionText: String? {
        if let direction {
            return direction
        }
        guard let travelDirection else {
            return nil
        }
        return travelDirection
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case alternativeRoute
        case endDate
        case eventComments
        case eventCreated
        case eventDescription
        case eventIsland
        case eventModified
        case eventType
        case expectedResolution
        case geometry
        case impact
        case informationSource
        case latitude
        case longitude
        case locationArea
        case locations
        case planned
        case restrictions
        case status
        case supplier
        case startDate
        case direction
        case travelDirection
        case directLineDistance1
        case directLineDistance2
        case directLineDistance3
        case region
        case journey
        case journeyLeg
        case way
    }
}

struct VMSSign: Decodable, Identifiable, Hashable, TrafficFilterable {
    let id: String
    let rawId: String?
    let currentMessage: String?
    let description: String?
    let direction: String?
    let identifier: String?
    let lastMessageUpdate: String?
    let lastUpdate: String?
    let latitude: Double?
    let longitude: Double?
    let name: String?
    let region: Region?
    let journey: Journey?
    let journeyLeg: JourneyLeg?
    let way: Way?
    let mapLatitude: Double?
    let mapLongitude: Double?
    let formattedMessage: String
    let hasDisplayMessage: Bool
    let highwayKeys: Set<String>
    let highwayHaystack: String
    let searchHaystack: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedId = container.decodeLossyString(forKey: .id)
        let identifierValue = cleanText(container.decodeLossyString(forKey: .identifier))
        let currentMessageValue = cleanText(container.decodeLossyString(forKey: .currentMessage))
        let descriptionValue = cleanText(container.decodeLossyString(forKey: .description))
        let nameValue = cleanText(container.decodeLossyString(forKey: .name))
        let latitudeValue = container.decodeLossyDouble(forKey: .latitude)
        let longitudeValue = container.decodeLossyDouble(forKey: .longitude)
        let regionValue = try? container.decodeIfPresent(Region.self, forKey: .region)
        let journeyValue = try? container.decodeIfPresent(Journey.self, forKey: .journey)
        let wayValue = try? container.decodeIfPresent(Way.self, forKey: .way)

        rawId = decodedId
        id = deterministicID(
            decodedId: decodedId ?? identifierValue,
            fallback: [
                nameValue,
                descriptionValue,
                latitudeValue.map { String($0) },
                longitudeValue.map { String($0) }
            ],
            typeTag: "vms"
        )
        currentMessage = currentMessageValue
        description = descriptionValue
        direction = cleanText(container.decodeLossyString(forKey: .direction))
        identifier = identifierValue
        lastMessageUpdate = cleanText(container.decodeLossyString(forKey: .lastMessageUpdate))
        lastUpdate = cleanText(container.decodeLossyString(forKey: .lastUpdate))
        latitude = latitudeValue
        longitude = longitudeValue
        name = nameValue
        region = regionValue
        journey = journeyValue
        journeyLeg = try? container.decodeIfPresent(JourneyLeg.self, forKey: .journeyLeg)
        way = wayValue
        let validatedMap = validatedCoordinate(latitude: latitudeValue, longitude: longitudeValue)
        mapLatitude = validatedMap?.latitude
        mapLongitude = validatedMap?.longitude

        let formatted = formatVMSMessage(currentMessageValue)
        formattedMessage = formatted
        hasDisplayMessage = formatted.caseInsensitiveCompare("No message") != .orderedSame
        // Sign names lead with their highway ("SH74 Belfast South"), which
        // matters where the journey is a corridor code such as "CNC".
        highwayKeys = highwayKeySet(
            structured: [journeyValue?.name, wayValue?.name],
            text: [nameValue, descriptionValue]
        )
        highwayHaystack = searchableHaystack([
            journeyValue?.name,
            wayValue?.name,
            nameValue,
            descriptionValue
        ])
        searchHaystack = searchableHaystack([
            nameValue,
            descriptionValue,
            formatted,
            regionValue?.name
        ])
    }

    var displayName: String {
        name ?? description ?? "VMS Sign"
    }

    var regionName: String? {
        region?.name
    }

    var mapCoordinate: CLLocationCoordinate2D? {
        guard let mapLatitude, let mapLongitude else {
            return nil
        }
        return CLLocationCoordinate2D(latitude: mapLatitude, longitude: mapLongitude)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case currentMessage
        case description
        case direction
        case identifier
        case lastMessageUpdate
        case lastUpdate
        case latitude
        case longitude
        case name
        case region
        case journey
        case journeyLeg
        case way
    }
}

struct CamerasPayload: Decodable {
    let response: CameraResponse
}

struct CameraResponse: Decodable {
    let camera: [TrafficCamera]
    // Unreadable elements skipped by the lenient decode (see decodeSectionList).
    let droppedCount: Int

    init(from decoder: Decoder) throws {
        let list = try decodeSectionList(TrafficCamera.self, from: decoder, keys: ["camera"])
        camera = list.elements
        droppedCount = list.droppedCount
    }
}

struct RoadEventsPayload: Decodable {
    let response: RoadEventResponse
}

struct RoadEventResponse: Decodable {
    let roadevent: [RoadEvent]
    let droppedCount: Int

    init(from decoder: Decoder) throws {
        // The feed has spelled the list both ways over the years.
        let list = try decodeSectionList(RoadEvent.self, from: decoder, keys: ["roadevent", "roadEvent"])
        roadevent = list.elements
        droppedCount = list.droppedCount
    }
}

struct VMSPayload: Decodable {
    let response: VMSResponse
}

struct VMSResponse: Decodable {
    let vms: [VMSSign]
    let droppedCount: Int

    init(from decoder: Decoder) throws {
        let list = try decodeSectionList(VMSSign.self, from: decoder, keys: ["vms"])
        vms = list.elements
        droppedCount = list.droppedCount
    }
}

func cleanText(_ value: String?) -> String? {
    guard let value else {
        return nil
    }

    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

func joinNonEmpty(_ values: [String?], separator: String = " ") -> String? {
    let parts = values.compactMap(cleanText)
    return parts.isEmpty ? nil : parts.joined(separator: separator)
}

func validatedCoordinate(latitude: Double?, longitude: Double?) -> CLLocationCoordinate2D? {
    guard let latitude,
          let longitude,
          latitude.isFinite,
          longitude.isFinite,
          (-90.0...90.0).contains(latitude),
          (-180.0...180.0).contains(longitude),
          !(latitude == 0 && longitude == 0) else {
        return nil
    }

    return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
}

// MARK: - WKT geometry

// One connected run of coordinates from a WKT geometry: a LINESTRING, one part
// of a MULTILINESTRING, or a POINT. Parts are kept apart so the gap between two
// of them is never drawn as a straight chord (journey MULTILINESTRINGs jump up
// to 97 km between parts). Parallel latitude/longitude arrays keep the type
// Hashable and Sendable, which CLLocationCoordinate2D is not.
struct GeoPolyline: Hashable, Sendable {
    let latitudes: [Double]
    let longitudes: [Double]

    var count: Int {
        min(latitudes.count, longitudes.count)
    }

    // A lone point can be pinned but not drawn as a line.
    var isDrawable: Bool {
        count >= 2
    }

    var coordinates: [CLLocationCoordinate2D] {
        var result: [CLLocationCoordinate2D] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            result.append(CLLocationCoordinate2D(latitude: latitudes[index], longitude: longitudes[index]))
        }
        return result
    }
}

// Splits a WKT geometry ("POINT (x y)", "LINESTRING (x y, …)",
// "MULTILINESTRING ((x y, …), (x y, …))") into its coordinate runs, one per
// innermost parenthesised group. WKT orders each pair "longitude latitude";
// a Z/M value after the pair is ignored. Pairs that fail validatedCoordinate
// (non-finite, out of range, the 0,0 placeholder) or contain a malformed
// number are skipped. A single forward scan over the UTF-8 bytes, so the cost
// is linear in the input — the backtracking regex it replaced took minutes on
// a long run of digits.
func parseWKTParts(_ wkt: String?) -> [GeoPolyline] {
    guard let wkt = cleanText(wkt) else {
        return []
    }

    var parts: [GeoPolyline] = []
    var latitudes: [Double] = []
    var longitudes: [Double] = []
    // The current coordinate tuple: its first two numbers, how many numbers it
    // has held, and whether any of them failed to parse.
    var first = 0.0
    var second = 0.0
    var numberCount = 0
    var tupleIsMalformed = false

    func endTuple() {
        if numberCount >= 2, !tupleIsMalformed,
           let coordinate = validatedCoordinate(latitude: second, longitude: first) {
            latitudes.append(coordinate.latitude)
            longitudes.append(coordinate.longitude)
        }
        numberCount = 0
        tupleIsMalformed = false
    }

    func endPart() {
        endTuple()
        if !latitudes.isEmpty {
            parts.append(GeoPolyline(latitudes: latitudes, longitudes: longitudes))
            latitudes = []
            longitudes = []
        }
    }

    let bytes = wkt.utf8
    var index = bytes.startIndex
    while index < bytes.endIndex {
        let byte = bytes[index]
        if byte == UInt8(ascii: "(") || byte == UInt8(ascii: ")") {
            endPart()
            index = bytes.index(after: index)
        } else if byte == UInt8(ascii: ",") {
            endTuple()
            index = bytes.index(after: index)
        } else if isWKTNumberStart(byte) {
            let start = index
            repeat {
                index = bytes.index(after: index)
            } while index < bytes.endIndex && isWKTNumberByte(bytes[index])
            if let value = Double(Substring(bytes[start..<index])), value.isFinite {
                if numberCount == 0 {
                    first = value
                } else if numberCount == 1 {
                    second = value
                }
            } else {
                tupleIsMalformed = true
            }
            numberCount += 1
        } else {
            // Whitespace and the geometry keywords ("MULTILINESTRING", "Z").
            index = bytes.index(after: index)
        }
    }
    endPart()
    return parts
}

private func isWKTNumberStart(_ byte: UInt8) -> Bool {
    (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
        || byte == UInt8(ascii: "-")
        || byte == UInt8(ascii: "+")
        || byte == UInt8(ascii: ".")
}

private func isWKTNumberByte(_ byte: UInt8) -> Bool {
    isWKTNumberStart(byte) || byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E")
}

// Where to pin a WKT geometry on the map. A POINT is its own coordinate; a line
// is pinned ON the line, at the point closest to the centre of its bounding
// box. (Road events carry no lat/lon in rest/5, so every event pin comes from
// here; the bounding-box centre itself sat up to 9 km off a winding road such
// as SH6 Paringa–Haast.)
func coordinateFromWKTGeometry(_ geometry: String?) -> CLLocationCoordinate2D? {
    pinCoordinate(on: parseWKTParts(geometry))
}

// The point on `parts` nearest their bounding-box centre: each segment is
// projected onto with a local equirectangular approximation (longitude scaled
// by cos(latitude)), which is ample at road-event scale. Single-point parts
// count as points. nil when there are no coordinates.
func pinCoordinate(on parts: [GeoPolyline]) -> CLLocationCoordinate2D? {
    var minLatitude = Double.greatestFiniteMagnitude
    var maxLatitude = -Double.greatestFiniteMagnitude
    var minLongitude = Double.greatestFiniteMagnitude
    var maxLongitude = -Double.greatestFiniteMagnitude
    var coordinateCount = 0
    for part in parts {
        for index in 0..<part.count {
            minLatitude = min(minLatitude, part.latitudes[index])
            maxLatitude = max(maxLatitude, part.latitudes[index])
            minLongitude = min(minLongitude, part.longitudes[index])
            maxLongitude = max(maxLongitude, part.longitudes[index])
            coordinateCount += 1
        }
    }
    guard coordinateCount > 0 else {
        return nil
    }

    let centreLatitude = (minLatitude + maxLatitude) / 2
    let centreLongitude = (minLongitude + maxLongitude) / 2
    let xScale = cos(centreLatitude * .pi / 180)

    var best: (latitude: Double, longitude: Double, distance: Double)?
    func consider(latitude: Double, longitude: Double) {
        let dx = (longitude - centreLongitude) * xScale
        let dy = latitude - centreLatitude
        let distance = dx * dx + dy * dy
        if best == nil || distance < best!.distance {
            best = (latitude, longitude, distance)
        }
    }

    for part in parts {
        guard part.count >= 2 else {
            if part.count == 1 {
                consider(latitude: part.latitudes[0], longitude: part.longitudes[0])
            }
            continue
        }
        for index in 1..<part.count {
            let startLatitude = part.latitudes[index - 1]
            let startLongitude = part.longitudes[index - 1]
            let segmentX = (part.longitudes[index] - startLongitude) * xScale
            let segmentY = part.latitudes[index] - startLatitude
            let lengthSquared = segmentX * segmentX + segmentY * segmentY
            var fraction = 0.0
            if lengthSquared > 0 {
                let offsetX = (centreLongitude - startLongitude) * xScale
                let offsetY = centreLatitude - startLatitude
                fraction = min(1, max(0, (offsetX * segmentX + offsetY * segmentY) / lengthSquared))
            }
            consider(
                latitude: startLatitude + fraction * (part.latitudes[index] - startLatitude),
                longitude: startLongitude + fraction * (part.longitudes[index] - startLongitude)
            )
        }
    }

    guard let best else {
        return nil
    }
    return validatedCoordinate(latitude: best.latitude, longitude: best.longitude)
}

// Hosts an image/page URL from the feed may point at: trafficnz.info and
// NZTA's own domain, including subdomains. The feed sends relative paths
// today (pinned to trafficnz.info below); an absolute URL on any other host —
// including lookalikes such as "trafficnz.info.evil.example" — is refused, so
// a tampered feed can't make the app fetch from, or open in the browser, an
// arbitrary site.
func isAllowedTrafficNZHost(_ host: String?) -> Bool {
    guard let host = host?.lowercased(), !host.isEmpty else {
        return false
    }
    return ["trafficnz.info", "nzta.govt.nz"].contains { domain in
        host == domain || host.hasSuffix("." + domain)
    }
}

// Resolves a camera image/thumbnail path from the feed to an https URL on an
// allowed host. Relative paths resolve against trafficnz.info, http is
// upgraded, protocol-relative ("//host/…") URLs get https, and any other
// scheme ("javascript:", "file:", "data:", …) or host returns nil.
func trafficNZURL(from path: String?, cacheToken: Int? = nil) -> URL? {
    guard var path = cleanText(path) else {
        return nil
    }

    let lowercased = path.lowercased()
    if lowercased.hasPrefix("http://") {
        path = "https://" + path.dropFirst("http://".count)
    } else if lowercased.hasPrefix("//") {
        path = "https:" + path
    } else if !lowercased.hasPrefix("https://") {
        if hasURLScheme(path) {
            return nil
        }
        if !path.hasPrefix("/") {
            path = "/" + path
        }
        path = "https://trafficnz.info" + path
    }

    guard var components = URLComponents(string: path),
          components.scheme?.lowercased() == "https",
          isAllowedTrafficNZHost(components.host),
          components.user == nil,
          components.password == nil else {
        return nil
    }

    if let cacheToken {
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "t" }
        items.append(URLQueryItem(name: "t", value: String(cacheToken)))
        components.queryItems = items
    }

    return components.url
}

// RFC 3986 scheme prefix ("javascript:", "file:", "data:") — a letter, then
// letters, digits, "+", "-" or ".", then a colon.
private func hasURLScheme(_ value: String) -> Bool {
    guard let colon = value.firstIndex(of: ":") else {
        return false
    }
    let scheme = value[..<colon]
    guard let first = scheme.first, first.isASCII, first.isLetter else {
        return false
    }
    return scheme.allSatisfy { character in
        character.isASCII && (character.isLetter || character.isNumber || "+-.".contains(character))
    }
}

func formatVMSMessage(_ message: String?) -> String {
    var formatted = cleanText(message) ?? ""
    formatted = formatted.replacingOccurrences(of: "[nl]", with: "\n", options: .caseInsensitive)
    formatted = formatted.replacingOccurrences(of: "[np]", with: "\n\n", options: .caseInsensitive)
    formatted = formatted.replacingOccurrences(
        of: #"\[[a-z]+\d*\]"#,
        with: " ",
        options: [.regularExpression, .caseInsensitive]
    )
    formatted = formatted.replacingOccurrences(of: "\r\n", with: "\n")
    formatted = formatted.replacingOccurrences(of: "\r", with: "\n")
    formatted = formatted
        .components(separatedBy: "\n")
        .map { line in
            line
                .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .joined(separator: "\n")

    while formatted.contains("\n\n\n") {
        formatted = formatted.replacingOccurrences(of: "\n\n\n", with: "\n\n")
    }

    return cleanText(formatted) ?? "No message"
}

// ISO 8601 parse strategy for the API's `2026-09-26T17:29:14.757+12:00`
// (fractional) and `…T17:29:00+12:00` (whole-second) timestamps: the default
// style parses both, keeping the fraction. A Sendable value type, so unlike
// ISO8601DateFormatter it is safe as a global under Swift 6 strict
// concurrency. Parsing matches the previous ISO8601DateFormatter chain on
// every timestamp in the live feeds.
private let isoDateStyle = Date.ISO8601FormatStyle()

// NZTA timestamps are New Zealand local time. Pin both the parse and the
// display formatter to Pacific/Auckland so the app shows correct NZ times
// regardless of the Mac's configured time zone.
private let nzTimeZone = TimeZone(identifier: "Pacific/Auckland")

private let nzInputDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_NZ")
    formatter.timeZone = nzTimeZone
    formatter.dateFormat = "dd/MM/yyyy HH:mm"
    return formatter
}()

private let nzDisplayDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_NZ")
    formatter.timeZone = nzTimeZone
    formatter.dateFormat = "d MMM, h:mm a"
    // NZ style: "5:30 pm" rather than "5:30 PM".
    formatter.amSymbol = "am"
    formatter.pmSymbol = "pm"
    return formatter
}()

// Absolute NZ time with the weekday ("Sun 27 Sep, 8:00 pm") for future event
// dates, where "in 1 day" alone doesn't say when the work actually starts.
private let nzWeekdayDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_NZ")
    formatter.timeZone = nzTimeZone
    formatter.dateFormat = "EEE d MMM, h:mm a"
    formatter.amSymbol = "am"
    formatter.pmSymbol = "pm"
    return formatter
}()

// Internal (not private) so the test runner can pin the exact instants.
func parseTrafficDate(_ rawValue: String) -> Date? {
    (try? isoDateStyle.parse(rawValue))
        ?? nzInputDateFormatter.date(from: rawValue)
}

func formatTrafficDate(_ rawValue: String?) -> String? {
    guard let rawValue = cleanText(rawValue) else {
        return nil
    }

    guard let date = parseTrafficDate(rawValue) else {
        return rawValue
    }

    return nzDisplayDateFormatter.string(from: date)
}

// RelativeDateTimeFormatter isn't Sendable, so the shared instance lives behind
// a Mutex rather than as a bare global. (Date.AnchoredRelativeFormatStyle is
// Sendable but rounds differently — "2 minutes ago" for 90 s where this says
// "1 minute ago" — so it isn't a drop-in replacement.)
private let relativeTrafficDateFormatter = Mutex<RelativeDateTimeFormatter>(makeRelativeTrafficDateFormatter())

private func makeRelativeTrafficDateFormatter() -> RelativeDateTimeFormatter {
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = Locale(identifier: "en_NZ")
    formatter.unitsStyle = .full
    return formatter
}

// Relative phrasing ("2 days ago", "in 3 hours") for timestamps where a
// relative reading is friendlier than the absolute one. Returns nil when the
// value is missing or unparseable so callers can fall back to formatTrafficDate.
func formatRelativeTrafficDate(_ rawValue: String?, relativeTo reference: Date = Date()) -> String? {
    guard let rawValue = cleanText(rawValue),
          let date = parseTrafficDate(rawValue) else {
        return nil
    }

    return relativeTrafficDateFormatter.withLock { formatter in
        formatter.localizedString(for: date, relativeTo: reference)
    }
}

// Tense-aware event date line: "Started 2 hours ago" / "Ended 5 hours ago"
// for past instants, and "Starts in 1 day · Sun 27 Sep, 8:00 pm" for future
// ones (Scheduled events), so the verb always agrees with the relative phrase.
// nil when the value is missing or unparseable, so callers can fall back to
// the absolute formatTrafficDate reading.
func eventDatePhrase(
    _ rawValue: String?,
    past pastVerb: String,
    future futureVerb: String,
    relativeTo reference: Date = Date()
) -> String? {
    guard let rawValue = cleanText(rawValue),
          let date = parseTrafficDate(rawValue),
          let relative = formatRelativeTrafficDate(rawValue, relativeTo: reference) else {
        return nil
    }
    guard date > reference else {
        return "\(pastVerb) \(relative)"
    }
    return "\(futureVerb) \(relative) · \(nzWeekdayDateFormatter.string(from: date))"
}

func matchesRegion(_ itemRegion: String?, selectedRegion: String) -> Bool {
    let selected = selectedRegion.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !selected.isEmpty else {
        return true
    }

    return (itemRegion ?? "").caseInsensitiveCompare(selected) == .orderedSame
}

/// The display form of an NZTA region name. The feeds and /regions/all spell
/// some regions without their macron or apostrophe ("Manawatu-Whanganui",
/// "Hawkes Bay", "Bay Of Plenty"); labels show the proper names. Display
/// only: the raw name stays the picker tag, the filter key and the search
/// text, so `matchesRegion` keeps comparing like with like.
func regionDisplayName(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    switch trimmed.lowercased() {
    case "manawatu-whanganui", "manawatu-wanganui", "manawatu whanganui":
        return "Manawatū-Whanganui"
    case "hawkes bay", "hawke's bay", "hawke\u{2019}s bay":
        return "Hawke\u{2019}s Bay"
    case "bay of plenty":
        return "Bay of Plenty"
    default:
        return trimmed
    }
}

/// Merges the canonical NZTA region names with any region names derived from
/// the loaded feature data, de-duplicating case-insensitively (canonical
/// casing wins because it is listed first) so the region Picker stays stable
/// before data loads and consistently named afterwards. Sorted case-
/// insensitively to match the picker's previous ordering.
func mergedRegionNames(canonical: [String], derived: [String]) -> [String] {
    var seen = Set<String>()
    var merged: [String] = []
    for name in canonical + derived {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else {
            continue
        }
        merged.append(trimmed)
    }
    return merged.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
}

func searchableHaystack(_ fields: [String?]) -> String {
    foldedForSearch(fields.compactMap(cleanText).joined(separator: " "))
}

// Lowercased with diacritics removed, applied to both the haystacks and the
// query, so "otaki" finds "Ōtaki" and "whangarei" finds "Whangārei" (the
// feeds mix macron and plain spellings of the same place).
// Apostrophes are dropped too, so "hawke's bay" (as the label reads) finds
// the feeds' "Hawkes Bay".
func foldedForSearch(_ text: String) -> String {
    text.folding(options: .diacriticInsensitive, locale: nil)
        .lowercased()
        .replacingOccurrences(of: "'", with: "")
        .replacingOccurrences(of: "\u{2019}", with: "")
}

func matchesNeedle(_ needle: String, in haystack: String) -> Bool {
    let query = foldedForSearch(needle.trimmingCharacters(in: .whitespacesAndNewlines))
    guard !query.isEmpty else {
        return true
    }
    return haystack.contains(query)
}

// MARK: - Highway filter

// NZ state highways are written several ways across the feeds and by users:
// "SH1" (camera.highway, journey.name), "SH 1" (event locationArea), "State
// Highway 1", "SH1N" (journey names for SH1's North Island section) and the
// way codes "01N" / "01S" / "020" / "20A". This maps each of them to one key —
// the highway number without leading zeros plus any spur letter ("1", "20",
// "20A", "1B") — so the Highway filter compares whole highways instead of
// substrings: SH1 must not match SH10–SH18 or the SH1B spur. SH1 is the only
// highway split by island, so a trailing N/S is dropped for highway 1 only;
// on every other number a letter is a distinct spur route. Returns nil for
// anything that isn't a highway reference ("ART", "CNC", "", "SH").
func canonicalHighwayKey(_ raw: String?) -> String? {
    guard let raw else {
        return nil
    }
    var token = compactHighwayToken(raw)
    for prefix in ["STATEHIGHWAY", "HIGHWAY", "HWY", "SH"] where token.hasPrefix(prefix) {
        token.removeFirst(prefix.count)
        break
    }
    let digits = token.prefix { $0.isASCII && $0.isNumber }
    let suffix = token.dropFirst(digits.count)
    guard (1...3).contains(digits.count),
          suffix.count <= 1,
          suffix.allSatisfy({ $0.isASCII && $0.isLetter }),
          let number = Int(digits),
          number > 0 else {
        return nil
    }
    if number == 1, suffix == "N" || suffix == "S" {
        return "1"
    }
    return "\(number)\(suffix)"
}

// Uppercased with spaces, hyphens and underscores removed: "sh-1" and
// "State Highway 1" become "SH1" and "STATEHIGHWAY1".
private func compactHighwayToken(_ raw: String) -> String {
    raw.uppercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "_" }
}

// Highway mentions inside free text: "SH 1", "SH1B", "STATE HIGHWAY 34", and
// slash-joined junction forms ("SH1/SH90", "SH16/20"). Only "SH"/"State
// Highway" prefixes count, so a board name such as "12 Auckland Airport" or a
// bare "Route 70" is not read as a highway. Compiled once, like the WKT regex.
private let highwayMentionRegex: NSRegularExpression? = {
    try? NSRegularExpression(
        pattern: #"\b(?:state\s+highway|sh)\s*-?\s*(\d{1,3}[a-z]?)\b((?:\s*/\s*(?:sh\s*)?\d{1,3}[a-z]?\b)*)"#,
        options: [.caseInsensitive]
    )
}()

func highwayMentions(in text: String?) -> Set<String> {
    guard let text = cleanText(text), let regex = highwayMentionRegex else {
        return []
    }
    let source = text as NSString
    var keys = Set<String>()
    for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
        if let key = canonicalHighwayKey(source.substring(with: match.range(at: 1))) {
            keys.insert(key)
        }
        let tail = match.range(at: 2)
        guard tail.location != NSNotFound, tail.length > 0 else {
            continue
        }
        for part in source.substring(with: tail).split(separator: "/") {
            if let key = canonicalHighwayKey(String(part)) {
                keys.insert(key)
            }
        }
    }
    return keys
}

// Precomputed at decode time for each filterable feature: the highways it is
// on, from its structured highway fields (highway / journey / way names) plus
// any "SH n" mentions in its own name or location text. A structured value
// that isn't a plain highway reference ("Old SH1") is scanned as text instead.
func highwayKeySet(structured: [String?], text: [String?]) -> Set<String> {
    var keys = Set<String>()
    for field in structured {
        if let key = canonicalHighwayKey(field) {
            keys.insert(key)
        } else {
            keys.formUnion(highwayMentions(in: field))
        }
    }
    for field in text {
        keys.formUnion(highwayMentions(in: field))
    }
    return keys
}

// The Highway filter's input, parsed once per filter pass rather than once
// per item. A query that names a highway ("SH1", "sh 1", "State Highway 1",
// "01N", "1") matches by key. A bare "SH" / "State Highway" — or any start
// of one while it's being typed ("S", "Sta", "State H", "Hw") — matches
// anything on a state highway, so the list doesn't empty out mid-word. Anything else (e.g. the "CNC" corridor
// code) falls back to a whole-word match on the item's route text, so "art"
// finds the "ART" route but not "Arthurs Pass".
struct HighwayQuery: Hashable, Sendable {
    let text: String
    let key: String?
    let isHighwayPrefixOnly: Bool

    private static let highwayWords = ["SH", "STATEHIGHWAY", "HIGHWAY", "HWY"]

    init(_ raw: String) {
        text = foldedForSearch(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        key = text.isEmpty ? nil : canonicalHighwayKey(text)
        let token = compactHighwayToken(text)
        isHighwayPrefixOnly = !token.isEmpty && Self.highwayWords.contains { $0.hasPrefix(token) }
    }

    var isEmpty: Bool {
        text.isEmpty
    }

    func matches(keys: Set<String>, haystack: String) -> Bool {
        guard !text.isEmpty else {
            return true
        }
        if let key {
            return keys.contains(key)
        }
        if isHighwayPrefixOnly {
            return !keys.isEmpty
        }
        return containsWholeWords(text, in: haystack)
    }
}

// True when `needle` occurs in `haystack` with a non-alphanumeric character
// (or the string edge) on both sides. Both are expected lowercased.
func containsWholeWords(_ needle: String, in haystack: String) -> Bool {
    guard !needle.isEmpty else {
        return true
    }
    var searchStart = haystack.startIndex
    while searchStart < haystack.endIndex,
          let found = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
        let startsWord = found.lowerBound == haystack.startIndex
            || !isWordCharacter(haystack[haystack.index(before: found.lowerBound)])
        let endsWord = found.upperBound == haystack.endIndex
            || !isWordCharacter(haystack[found.upperBound])
        if startsWord && endsWord {
            return true
        }
        searchStart = haystack.index(after: found.lowerBound)
    }
    return false
}

private func isWordCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber
}

// The shared Region / Highway / Search predicate. Each filterable feature
// precomputes its region name, highway keys and lowercased haystacks at decode
// time, so filtering is set lookups and substring checks. The store calls the
// `HighwayQuery` overload with a query parsed once per pass.
protocol TrafficFilterable {
    var regionName: String? { get }
    var highwayKeys: Set<String> { get }
    var highwayHaystack: String { get }
    var searchHaystack: String { get }
}

extension TrafficFilterable {
    func matches(region selectedRegion: String, highway selectedHighway: String, search: String) -> Bool {
        matches(region: selectedRegion, highway: HighwayQuery(selectedHighway), search: search)
    }

    func matches(region selectedRegion: String, highway: HighwayQuery, search: String) -> Bool {
        matchesRegion(regionName, selectedRegion: selectedRegion)
            && highway.matches(keys: highwayKeys, haystack: highwayHaystack)
            && matchesNeedle(search, in: searchHaystack)
    }
}

func deterministicID(decodedId: String?, fallback: [String?], typeTag: String) -> String {
    if let decodedId, !decodedId.isEmpty {
        return decodedId
    }
    let parts = fallback.compactMap(cleanText).filter { !$0.isEmpty }
    return parts.isEmpty ? "\(typeTag)-noid" : "\(typeTag)|" + parts.joined(separator: "|")
}

func computeSeverityRank(impact: String?) -> Int {
    guard let impact else {
        return 99
    }
    if impact.range(of: "closed", options: .caseInsensitive) != nil {
        return 0
    }
    if impact.range(of: "delay", options: .caseInsensitive) != nil {
        return 1
    }
    if impact.range(of: "caution", options: .caseInsensitive) != nil {
        return 2
    }
    return 50
}

// Lifecycle of a road event, from the API's `status`: every event in the
// 2026-09 v4/v5 snapshots is "Active", "Scheduled" (all start in the future)
// or "Resolved" (all ended within the last ~24 h). Parsed from the string
// alone — never against Date() at decode time, because the offline cache
// replays old bytes. Anything else, including a missing status, is kept raw
// as `.unknown` and treated like Active: if NZTA renames or drops the field,
// closures keep counting and showing (fail safe) rather than disappearing.
enum EventStatus: Hashable, Sendable {
    case active
    case scheduled
    case resolved
    case unknown(String?)

    init(raw: String?) {
        let value = cleanText(raw)
        switch value?.lowercased() {
        case "active":
            self = .active
        case "scheduled":
            self = .scheduled
        case "resolved":
            self = .resolved
        default:
            self = .unknown(value)
        }
    }

    /// In force now (Active, or an unrecognised/missing status).
    var isCurrent: Bool {
        switch self {
        case .active, .unknown:
            return true
        case .scheduled, .resolved:
            return false
        }
    }

    /// Road Events order: current, then upcoming, then resolved.
    var sortRank: Int {
        switch self {
        case .active, .unknown:
            return 0
        case .scheduled:
            return 1
        case .resolved:
            return 2
        }
    }

    /// User-facing label. Scheduled reads "Upcoming"; an unrecognised value
    /// shows as sent; nil when the feed sent no status at all.
    var label: String? {
        switch self {
        case .active:
            return "Active"
        case .scheduled:
            return "Upcoming"
        case .resolved:
            return "Resolved"
        case .unknown(let raw):
            return raw
        }
    }
}

// Road Events display order: current events first, then upcoming, then
// resolved; within each group closures → delays → caution → other, then by
// title. The store's filteredEvents sorts with this.
func roadEventSortsBefore(_ lhs: RoadEvent, _ rhs: RoadEvent) -> Bool {
    if lhs.statusKind.sortRank != rhs.statusKind.sortRank {
        return lhs.statusKind.sortRank < rhs.statusKind.sortRank
    }
    if lhs.severityRank != rhs.severityRank {
        return lhs.severityRank < rhs.severityRank
    }
    return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
}

enum CameraStatusKind: String, CaseIterable, Identifiable, Hashable {
    case online
    case offline
    case maintenance

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .online:
            return "Online"
        case .offline:
            return "Offline"
        case .maintenance:
            return "Maintenance"
        }
    }
}

func computeCameraStatusKind(offline: Bool, underMaintenance: Bool) -> CameraStatusKind {
    if underMaintenance {
        return .maintenance
    }
    if offline {
        return .offline
    }
    return .online
}

enum EventImpactKind: String, CaseIterable, Identifiable, Hashable {
    case closure
    case delays
    case caution
    case other

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .closure:
            return "Closures"
        case .delays:
            return "Delays"
        case .caution:
            return "Caution"
        case .other:
            return "Other"
        }
    }
}

func computeImpactKind(impact: String?) -> EventImpactKind {
    guard let impact else {
        return .other
    }
    if impact.range(of: "closed", options: .caseInsensitive) != nil {
        return .closure
    }
    if impact.range(of: "delay", options: .caseInsensitive) != nil {
        return .delays
    }
    if impact.range(of: "caution", options: .caseInsensitive) != nil {
        return .caution
    }
    return .other
}

// Filter events by the island they sit on. Stored as a String rawValue so it
// can back an @AppStorage value in the views.
enum EventIslandFilter: String, CaseIterable, Identifiable, Hashable {
    case all
    case north
    case south

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .all:
            return "All Islands"
        case .north:
            return "North Island"
        case .south:
            return "South Island"
        }
    }

    func matches(_ island: String?) -> Bool {
        switch self {
        case .all:
            return true
        case .north:
            return (island ?? "").range(of: "north", options: .caseInsensitive) != nil
        case .south:
            return (island ?? "").range(of: "south", options: .caseInsensitive) != nil
        }
    }
}

enum FlowKind: String, CaseIterable, Identifiable, Hashable {
    case freeFlow
    case moderate
    case slow
    case congested
    case noData

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .freeFlow:
            return "Free Flow"
        case .moderate:
            return "Moderate"
        case .slow:
            return "Slow"
        case .congested:
            return "Congested"
        case .noData:
            return "No Data"
        }
    }
}

func computeFlowKind(flow: Double?, coverage: Double?) -> FlowKind {
    guard let coverage, coverage > 0,
          let flow, flow >= 0 else {
        return .noData
    }
    if flow >= 0.85 {
        return .freeFlow
    }
    if flow >= 0.60 {
        return .moderate
    }
    if flow >= 0.35 {
        return .slow
    }
    return .congested
}

// Congestion severity for the Auckland motorway conditions feed
// (traffic-conditions/rest/2). The feed reports four named levels; `unknown`
// covers any value we do not recognise so an unexpected token never crashes the
// parse. Stored as a String rawValue so it can back an @AppStorage/SceneStorage
// value and so the map legend can iterate `allCases`.
enum CongestionLevel: String, CaseIterable, Identifiable, Hashable {
    case freeFlow
    case moderate
    case heavy
    case congested
    case unknown

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .freeFlow:
            return "Free Flow"
        case .moderate:
            return "Moderate"
        case .heavy:
            return "Heavy"
        case .congested:
            return "Congested"
        case .unknown:
            return "Unknown"
        }
    }

    // Higher == worse traffic, for ordering/emphasis. `unknown` sorts below
    // everything real.
    var severityRank: Int {
        switch self {
        case .unknown:
            return -1
        case .freeFlow:
            return 0
        case .moderate:
            return 1
        case .heavy:
            return 2
        case .congested:
            return 3
        }
    }
}

// Maps a raw congestion string ("Free Flow", "Heavy", …) from the XML feed to a
// CongestionLevel, case- and whitespace-insensitively. Unrecognised/missing
// values become `.unknown`.
func congestionLevel(from raw: String?) -> CongestionLevel {
    guard let value = cleanText(raw)?.lowercased() else {
        return .unknown
    }
    switch value {
    case "free flow", "freeflow":
        return .freeFlow
    case "moderate":
        return .moderate
    case "heavy":
        return .heavy
    case "congested":
        return .congested
    default:
        return .unknown
    }
}

// One motorway segment ("location") from the Auckland traffic-conditions feed:
// a directional stretch of motorway with start/end coordinates and a congestion
// level. Rendered on the map as a colour-coded polyline. Coordinates are stored
// pre-validated (invalid/(0,0) pairs are dropped during parsing).
struct CongestionSegment: Identifiable, Hashable {
    let id: String
    let motorwayName: String?
    let name: String?
    let direction: String?
    let level: CongestionLevel
    let startLatitude: Double?
    let startLongitude: Double?
    let endLatitude: Double?
    let endLongitude: Double?

    var startCoordinate: CLLocationCoordinate2D? {
        validatedCoordinate(latitude: startLatitude, longitude: startLongitude)
    }

    var endCoordinate: CLLocationCoordinate2D? {
        validatedCoordinate(latitude: endLatitude, longitude: endLongitude)
    }

    // Ordered start -> end coordinates, dropping either end that is missing.
    // A segment with both ends yields a drawable 2-point polyline.
    var polyline: [CLLocationCoordinate2D] {
        [startCoordinate, endCoordinate].compactMap { $0 }
    }

    // Representative point (midpoint when both ends are present) for labels.
    var mapCoordinate: CLLocationCoordinate2D? {
        if let start = startCoordinate, let end = endCoordinate {
            return validatedCoordinate(
                latitude: (start.latitude + end.latitude) / 2,
                longitude: (start.longitude + end.longitude) / 2
            )
        }
        return startCoordinate ?? endCoordinate
    }

    var displayName: String {
        name ?? motorwayName ?? "Motorway segment"
    }

    var routeLine: String? {
        joinNonEmpty([motorwayName, direction], separator: " · ")
    }
}

// The shared Region / Highway / Search filter for the congestion layer. The
// feed covers Auckland's motorways only, so every segment is in Auckland, and
// its highway is the one its motorway carries (the segment names only mention
// the highways it meets at each end). Computed rather than stored: the feed
// is about 80 segments and the store memoizes the filtered result.
extension CongestionSegment: TrafficFilterable {
    var regionName: String? {
        "Auckland"
    }

    var highwayKeys: Set<String> {
        highwayKeySet(structured: [aucklandMotorwayHighway(motorwayName) ?? motorwayName], text: [])
    }

    var highwayHaystack: String {
        searchableHaystack([motorwayName, name])
    }

    var searchHaystack: String {
        searchableHaystack([motorwayName, name, direction, level.label])
    }
}

// Named Auckland motorways and the state highway each one is. The feed's
// other "motorways" are named by their highway already ("SH20A George Bolt
// Memorial Dr") or aren't state highways ("Route 12").
func aucklandMotorwayHighway(_ motorwayName: String?) -> String? {
    guard let name = motorwayName?.lowercased().replacingOccurrences(of: "-", with: "") else {
        return nil
    }
    switch name.trimmingCharacters(in: .whitespaces) {
    case "northern motorway", "southern motorway", "central motorway junction":
        return "SH1"
    case "northwestern motorway":
        return "SH16"
    case "southwestern motorway":
        return "SH20"
    case "upper harbour motorway":
        return "SH18"
    default:
        return nil
    }
}

// XMLParser-based decoder for the Auckland traffic-conditions feed
// (traffic-conditions/rest/2) — the one NZTA endpoint that is XML, not JSON.
// The shape is:
//   getTrafficConditionsResponse > trafficConditions > motorways* >
//     name (motorway), locations* > { congestion, direction, name (segment),
//     startLat/Lon, endLat/Lon, id, … }
// Note both `motorways` and `locations` carry a `name` child, so the delegate
// tracks the parent element to disambiguate. Element names are matched by their
// local part so the `tns:` namespace prefix is irrelevant. Foundation only.
final class CongestionXMLParser: NSObject, XMLParserDelegate {
    // Returns nil only when the document is not well-formed XML; an empty list
    // is a valid (if unexpected) successful parse.
    static func parse(_ data: Data) -> [CongestionSegment]? {
        let delegate = CongestionXMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            return nil
        }
        return delegate.segments
    }

    private var segments: [CongestionSegment] = []
    private var elementStack: [String] = []
    private var buffer = ""
    private var currentMotorwayName: String?

    // Fields for the `locations` element currently being parsed.
    private var locId: String?
    private var locName: String?
    private var locCongestion: String?
    private var locDirection: String?
    private var locStartLat: Double?
    private var locStartLon: Double?
    private var locEndLat: Double?
    private var locEndLon: Double?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let local = localName(elementName)
        elementStack.append(local)
        buffer = ""
        switch local {
        case "motorways":
            currentMotorwayName = nil
        case "locations":
            locId = nil
            locName = nil
            locCongestion = nil
            locDirection = nil
            locStartLat = nil
            locStartLon = nil
            locEndLat = nil
            locEndLon = nil
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let local = localName(elementName)
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = elementStack.count >= 2 ? elementStack[elementStack.count - 2] : ""

        switch local {
        case "name":
            if parent == "locations" {
                locName = text.isEmpty ? nil : text
            } else if parent == "motorways" {
                currentMotorwayName = text.isEmpty ? nil : text
            }
        case "id" where parent == "locations":
            locId = text.isEmpty ? nil : text
        case "congestion":
            locCongestion = text
        case "direction" where parent == "locations":
            locDirection = text.isEmpty ? nil : text
        case "startLat":
            locStartLat = Double(text)
        case "startLon":
            locStartLon = Double(text)
        case "endLat":
            locEndLat = Double(text)
        case "endLon":
            locEndLon = Double(text)
        case "locations":
            appendCurrentSegment()
        default:
            break
        }

        if !elementStack.isEmpty {
            elementStack.removeLast()
        }
        buffer = ""
    }

    private func appendCurrentSegment() {
        // Keep only segments with at least one usable coordinate; everything
        // else cannot be drawn on the map.
        let start = validatedCoordinate(latitude: locStartLat, longitude: locStartLon)
        let end = validatedCoordinate(latitude: locEndLat, longitude: locEndLon)
        guard start != nil || end != nil else {
            return
        }
        let identifier = deterministicID(
            decodedId: nil,
            fallback: [locId, currentMotorwayName, locName, locDirection],
            typeTag: "congestion"
        )
        segments.append(
            CongestionSegment(
                id: identifier,
                motorwayName: currentMotorwayName,
                name: locName,
                direction: locDirection,
                level: congestionLevel(from: locCongestion),
                startLatitude: start?.latitude,
                startLongitude: start?.longitude,
                endLatitude: end?.latitude,
                endLongitude: end?.longitude
            )
        )
    }

    // Strips any namespace prefix ("tns:congestion" -> "congestion") so matching
    // does not depend on XMLParser's namespace-processing configuration.
    private func localName(_ elementName: String) -> String {
        if let colon = elementName.lastIndex(of: ":") {
            return String(elementName[elementName.index(after: colon)...])
        }
        return elementName
    }
}

// Parses the journey feeds' "HH:MM:SS" durations. Every field must be a
// non-negative whole number and minutes/seconds must be under 60. The sum is
// done in Double: with Int arithmetic an absurd hours field such as
// "3000000000000000" overflowed and trapped during decode.
func parseTimeIntervalString(_ raw: String?) -> TimeInterval? {
    guard let raw = cleanText(raw) else {
        return nil
    }
    let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 3,
          let hours = Int(parts[0]), hours >= 0,
          let minutes = Int(parts[1]), (0..<60).contains(minutes),
          let seconds = Int(parts[2]), (0..<60).contains(seconds) else {
        return nil
    }
    return Double(hours) * 3600 + Double(minutes) * 60 + Double(seconds)
}

// A value rounded to a whole number for display ("82" km/h), or nil when it
// isn't finite or doesn't fit in an Int. `Int(_:)` traps on those, and a
// loose upstream number (a 1e19 speed, or a NaN average from lengths near
// 1e308) must never crash a render.
func formatWholeNumber(_ value: Double) -> String? {
    guard value.isFinite, let whole = Int(exactly: value.rounded()) else {
        return nil
    }
    return String(whole)
}

// Travel-time durations in the compact style NZTA's own TIM boards use —
// "18m", "1h 34m", "2h" — rounded to the nearest minute. (The old m:ss form,
// "Now 17:55" / "Delay +4:22", read like a clock time or like hours.) A
// positive duration under half a minute reads "<1m" rather than "0m".
// Hand-formatted rather than via DateComponentsFormatter so the output is
// locale-independent, needs no shared non-Sendable formatter, and can't trap
// on a non-finite or huge value from the loose upstream feed.
func formatTimeInterval(_ interval: TimeInterval) -> String {
    guard interval.isFinite, interval > 0 else {
        return "0m"
    }
    let totalMinutes = roundedMinutes(interval)
    guard totalMinutes > 0 else {
        return "<1m"
    }
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if hours == 0 {
        return "\(minutes)m"
    }
    return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
}

// Whole minutes as formatTimeInterval shows them (0 for anything unusable).
func roundedMinutes(_ interval: TimeInterval) -> Int {
    guard interval.isFinite, interval > 0 else {
        return 0
    }
    // Clamp before converting so an absurd upstream value can't overflow Int.
    return Int(min(interval / 60, 1_000_000).rounded())
}

private func decodeFirstRegion<K>(container: KeyedDecodingContainer<K>, key: K) -> Region? where K: CodingKey {
    if let single = try? container.decodeIfPresent(Region.self, forKey: key) {
        return single
    }
    if let array = try? container.decodeIfPresent([Region].self, forKey: key) {
        return array.first
    }
    return nil
}

private func decodeFirstWay<K>(container: KeyedDecodingContainer<K>, key: K) -> Way? where K: CodingKey {
    if let single = try? container.decodeIfPresent(Way.self, forKey: key) {
        return single
    }
    if let array = try? container.decodeIfPresent([Way].self, forKey: key) {
        return array.first
    }
    return nil
}

struct TrafficJourney: Decodable, Identifiable, TrafficFilterable {
    let id: String
    let rawId: String?
    let name: String?
    // The API's journey length covers BOTH directions (the I and D legs), so it
    // is not a trip length; each entry in `directions` carries its own.
    let totalLength: Double?
    let regionInfo: Region?
    let wayInfo: Way?
    let legs: [TrafficJourneyLeg]
    // Per-direction totals (increasing first), computed once at decode.
    let directions: [JourneyDirectionSummary]
    let highwayKeys: Set<String>
    let highwayHaystack: String
    let searchHaystack: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedId = container.decodeLossyString(forKey: .id)
        let nameValue = cleanText(container.decodeLossyString(forKey: .name))
        let totalLengthValue = container.decodeLossyDouble(forKey: .totalLength)
        let regionValue = decodeFirstRegion(container: container, key: .regions)
        let wayValue = decodeFirstWay(container: container, key: .ways)
        let legsValue = uniquingLegIDs(container.decodeFlexibleArray(TrafficJourneyLeg.self, forKey: .legs))
        // The journey-level `geometry` MULTILINESTRING is deliberately not
        // decoded: its parts are exactly the legs' LINESTRINGs, which the Flow
        // map draws leg by leg. Joined into one line it drew straight chords
        // (up to 97 km) between the ends of consecutive parts.

        rawId = decodedId
        id = deterministicID(
            decodedId: decodedId,
            fallback: [nameValue, regionValue?.name],
            typeTag: "journey"
        )
        name = nameValue
        totalLength = totalLengthValue
        regionInfo = regionValue
        wayInfo = wayValue
        legs = legsValue
        directions = summarizeJourneyDirections(legsValue)

        var legNames: [String?] = []
        legNames.reserveCapacity(legsValue.count)
        for leg in legsValue {
            legNames.append(leg.name)
        }

        // A journey is one highway: its name ("SH1", "SH1N") and way code
        // ("01N"). Leg names are left out of the keys because they mention the
        // junctions at each end ("SH16 / SH18"), not the road itself.
        highwayKeys = highwayKeySet(structured: [nameValue, wayValue?.name], text: [])
        highwayHaystack = searchableHaystack([
            nameValue,
            wayValue?.name
        ] + legNames)
        searchHaystack = searchableHaystack([
            nameValue,
            regionValue?.name,
            wayValue?.name
        ] + legNames)
    }

    var displayName: String {
        name ?? "Journey"
    }

    var regionName: String? {
        regionInfo?.name
    }

    var hasLiveData: Bool {
        legs.contains(where: \.hasLiveData)
    }

    /// The leg carrying the heaviest congestion (lowest flow) among legs that
    /// have live data — the journey's bottleneck. nil when nothing is live.
    var slowestLeg: TrafficJourneyLeg? {
        legs
            .filter { $0.hasLiveData && ($0.flow ?? -1) >= 0 }
            .min { lhs, rhs in
                (lhs.flow ?? .greatestFiniteMagnitude) < (rhs.flow ?? .greatestFiniteMagnitude)
            }
    }

    /// The larger of the directions' delays: the Travel Times sort key. nil
    /// when neither direction has comparable live times.
    var worstDelay: TimeInterval? {
        directions.compactMap(\.delay).max()
    }

    /// Live legs whose upstream times were implausible and left out of the
    /// totals (Export Diagnostics reports the feed-wide count).
    var dataIssueLegCount: Int {
        directions.reduce(0) { $0 + $1.dataIssueLegCount }
    }

    var overallFlowKind: FlowKind {
        var weightedSum = 0.0
        var totalWeight = 0.0
        for leg in legs {
            guard let flow = leg.flow, flow >= 0,
                  let coverage = leg.coverage, coverage > 0,
                  let length = leg.totalLength, length > 0 else {
                continue
            }
            weightedSum += flow * length
            totalWeight += length
        }
        guard totalWeight > 0 else {
            return .noData
        }
        return computeFlowKind(flow: weightedSum / totalWeight, coverage: 1.0)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case totalLength
        case regions
        case ways
        case legs
    }
}

// Leg ids already carry direction and way (see TrafficJourneyLeg), but the Flow
// map keys its overlays on them, so any duplicate that is still left within one
// journey gets an occurrence suffix instead of a colliding ForEach identity.
private func uniquingLegIDs(_ legs: [TrafficJourneyLeg]) -> [TrafficJourneyLeg] {
    var used = Set<String>()
    return legs.map { leg in
        var candidate = leg.id
        var occurrence = 1
        while !used.insert(candidate).inserted {
            occurrence += 1
            candidate = "\(leg.id)#\(occurrence)"
        }
        guard candidate != leg.id else {
            return leg
        }
        var renamed = leg
        renamed.id = candidate
        return renamed
    }
}

// NZTA's reference direction for a journey leg: "I" (increasing) runs the way
// the highway's route positions count up, "D" (decreasing) runs back.
enum JourneyDirection: String, CaseIterable, Hashable {
    case increasing = "I"
    case decreasing = "D"
    case unspecified = "?"

    init(code: String?) {
        switch code?.trimmingCharacters(in: .whitespaces).uppercased() {
        case "I":
            self = .increasing
        case "D":
            self = .decreasing
        default:
            self = .unspecified
        }
    }

    // NZTA's own names, used when the legs' "A to B" names can't label a
    // direction by its end points.
    var fallbackLabel: String {
        switch self {
        case .increasing:
            return "Increasing direction"
        case .decreasing:
            return "Decreasing direction"
        case .unspecified:
            return "Other legs"
        }
    }
}

// One direction of a journey. The feed interleaves both directions' legs (I, D,
// I, D…) and its totalLength covers both, so travel time, delay and length are
// only meaningful per direction. Current and free-flow times are summed over
// the SAME legs — those reporting both times with no data issue — so the delay
// compares like with like; the other legs show up as partial coverage.
struct JourneyDirectionSummary: Identifiable {
    let direction: JourneyDirection
    // Where the direction starts and ends, read from its end legs' "A to B"
    // names; nil when a name doesn't follow that pattern.
    let origin: String?
    let destination: String?
    // The direction's legs in travel order.
    let legs: [TrafficJourneyLeg]
    // km: every leg in this direction, live or not.
    let length: Double
    // Legs whose current and free-flow times are both in the totals.
    let timedLegCount: Int
    // Live legs left out because their upstream times are implausible.
    let dataIssueLegCount: Int
    let currentTime: TimeInterval?
    let freeFlowTime: TimeInterval?
    // km/h, length-weighted over the legs reporting a speed.
    let averageSpeed: Double?

    var id: String {
        direction.rawValue
    }

    var legCount: Int {
        legs.count
    }

    var delay: TimeInterval? {
        guard let currentTime, let freeFlowTime else {
            return nil
        }
        return max(0, currentTime - freeFlowTime)
    }

    // Some legs are missing from the time totals.
    var isPartial: Bool {
        timedLegCount < legCount
    }

    // "Northland Boundary → Waikato Boundary", or NZTA's direction name when
    // the end points can't be read (or coincide, as on a loop).
    var label: String {
        if let origin, let destination, origin.caseInsensitiveCompare(destination) != .orderedSame {
            return "\(origin) → \(destination)"
        }
        return direction.fallbackLabel
    }

    // The per-direction line on a journey card, e.g. "Now 42m · free flow 28m
    // · delay +14m · avg 61 km/h · 85.6 km · live on 9 of 14 legs".
    var detailText: String {
        var parts: [String] = []
        if let currentTime, let freeFlowTime {
            parts.append("Now \(formatTimeInterval(currentTime))")
            parts.append("free flow \(formatTimeInterval(freeFlowTime))")
            // The difference of the two times as shown, so the line adds up
            // ("Now 48m · free flow 41m · delay +7m", not "+8m").
            let delayMinutes = roundedMinutes(currentTime) - roundedMinutes(freeFlowTime)
            // Under half a minute of real delay is nothing worth showing.
            if let delay, delay >= 30, delayMinutes > 0 {
                parts.append("delay +\(formatTimeInterval(TimeInterval(delayMinutes * 60)))")
            }
        } else {
            parts.append(dataIssueLegCount > 0 ? "No reliable live times" : "No live times")
        }
        if let speed = averageSpeed.flatMap(formatWholeNumber) {
            parts.append("avg \(speed) km/h")
        }
        if length > 0, length.isFinite {
            parts.append(String(format: "%.1f km", length))
        }
        if timedLegCount > 0, isPartial {
            parts.append("live on \(timedLegCount) of \(legCount) legs")
        }
        if dataIssueLegCount > 0 {
            parts.append(dataIssueLegCount == 1
                ? "1 leg left out (data issue)"
                : "\(dataIssueLegCount) legs left out (data issue)")
        }
        return parts.joined(separator: " · ")
    }
}

// Groups a journey's legs by direction (increasing, then decreasing, then any
// without a direction), orders each group in travel order — increasing legs by
// ascending sequence number, decreasing legs descending — and totals it.
func summarizeJourneyDirections(_ legs: [TrafficJourneyLeg]) -> [JourneyDirectionSummary] {
    var grouped: [JourneyDirection: [(offset: Int, leg: TrafficJourneyLeg)]] = [:]
    for (offset, leg) in legs.enumerated() {
        grouped[leg.journeyDirection, default: []].append((offset, leg))
    }
    let increasing = legsInTravelOrder(grouped[.increasing] ?? [], descending: false)
    let decreasing = legsInTravelOrder(grouped[.decreasing] ?? [], descending: true)
    let unspecified = legsInTravelOrder(grouped[.unspecified] ?? [], descending: false)

    // Decreasing legs often reuse the increasing leg's name ("Redoubt Rd to
    // Papakura" both ways), so when both directions exist the decreasing end
    // points are the increasing ones reversed rather than read from its names.
    let increasingEnds = journeyEndpoints(increasing)
    let decreasingEnds: (origin: String?, destination: String?) = increasing.isEmpty
        ? journeyEndpoints(decreasing)
        : (increasingEnds.destination, increasingEnds.origin)

    var summaries: [JourneyDirectionSummary] = []
    if !increasing.isEmpty {
        summaries.append(summarizeDirection(.increasing, legs: increasing, ends: increasingEnds))
    }
    if !decreasing.isEmpty {
        summaries.append(summarizeDirection(.decreasing, legs: decreasing, ends: decreasingEnds))
    }
    if !unspecified.isEmpty {
        summaries.append(summarizeDirection(.unspecified, legs: unspecified, ends: journeyEndpoints(unspecified)))
    }
    return summaries
}

private func legsInTravelOrder(
    _ legs: [(offset: Int, leg: TrafficJourneyLeg)],
    descending: Bool
) -> [TrafficJourneyLeg] {
    legs.sorted { lhs, rhs in
        switch (lhs.leg.sequenceNumber, rhs.leg.sequenceNumber) {
        case let (left?, right?) where left != right:
            return descending ? left > right : left < right
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            return lhs.offset < rhs.offset
        }
    }
    .map(\.leg)
}

// Start of the first leg and end of the last, from their "A to B" names.
private func journeyEndpoints(_ legs: [TrafficJourneyLeg]) -> (origin: String?, destination: String?) {
    (journeyLegEndpoints(legs.first?.name)?.from, journeyLegEndpoints(legs.last?.name)?.to)
}

// Splits a leg name such as "Hibiscus Coast HW to Silverdale" at its first
// " to ". nil when the name doesn't follow that pattern.
func journeyLegEndpoints(_ name: String?) -> (from: String, to: String)? {
    guard let name, let separator = name.range(of: " to ", options: .caseInsensitive) else {
        return nil
    }
    guard let from = cleanText(String(name[..<separator.lowerBound])),
          let to = cleanText(String(name[separator.upperBound...])) else {
        return nil
    }
    return (from, to)
}

private func summarizeDirection(
    _ direction: JourneyDirection,
    legs: [TrafficJourneyLeg],
    ends: (origin: String?, destination: String?)
) -> JourneyDirectionSummary {
    var length = 0.0
    var currentTotal = 0.0
    var freeFlowTotal = 0.0
    var timedLegCount = 0
    var dataIssueLegCount = 0
    var speedWeightedSum = 0.0
    var speedWeight = 0.0

    for leg in legs {
        if let legLength = leg.totalLength, legLength > 0 {
            length += legLength
            if let speed = leg.speed, speed > 0 {
                speedWeightedSum += speed * legLength
                speedWeight += legLength
            }
        }
        if leg.dataIssue != nil {
            dataIssueLegCount += 1
        } else if let current = leg.currentTimeSeconds, let free = leg.freeFlowTime, free > 0 {
            currentTotal += current
            freeFlowTotal += free
            timedLegCount += 1
        }
    }

    // Sums of loose upstream numbers can overflow to infinity; a non-finite
    // total is reported as missing rather than drawn.
    let hasTimes = timedLegCount > 0 && currentTotal.isFinite && freeFlowTotal.isFinite
    let averageSpeed = speedWeight > 0 ? speedWeightedSum / speedWeight : nil
    return JourneyDirectionSummary(
        direction: direction,
        origin: ends.origin,
        destination: ends.destination,
        legs: legs,
        length: length,
        timedLegCount: hasTimes ? timedLegCount : 0,
        dataIssueLegCount: dataIssueLegCount,
        currentTime: hasTimes ? currentTotal : nil,
        freeFlowTime: hasTimes ? freeFlowTotal : nil,
        averageSpeed: averageSpeed.flatMap { $0.isFinite ? $0 : nil }
    )
}

// Why a live leg's upstream times can't be used. NZTA sometimes reports a leg
// time that contradicts the leg's own length and measured speed: a duplicated
// link list makes "Redoubt Rd to Papakura" (10 km at 77 km/h) take 53 minutes,
// and a single-link record makes "Oteha to SH18 Interchange" (9 km) take 11
// seconds. The free-flow time is inflated the same way, so these legs drove the
// "most delayed" ranking (up to about 18× the real delay). They are left out of
// the journey totals and flagged on their row instead.
enum JourneyLegDataIssue: String, Hashable {
    case impossibleSpeed
    case timeContradictsSpeed
    case freeFlowContradictsLimit
    case freeFlowExceedsCurrent

    var explanation: String {
        switch self {
        case .impossibleSpeed:
            return "NZTA's times for this leg imply an impossible speed."
        case .timeContradictsSpeed:
            return "NZTA's travel time for this leg doesn't match its length and measured speed."
        case .freeFlowContradictsLimit:
            return "NZTA's free-flow time for this leg doesn't match its length and speed limit."
        case .freeFlowExceedsCurrent:
            return "NZTA's free-flow time for this leg is far longer than its current travel time."
        }
    }
}

// A leg's time should imply roughly the speed NZTA measured on it, and its
// free-flow time roughly its speed limit: within 2× either way. (In the
// 2026-09 feed real legs sit within 0.6–1.4×; the bad ones are 2.4–35× off.)
// Nothing on a New Zealand state highway averages over 200 km/h.
private let legTimeTolerance = 2.0
private let maxPlausibleLegSpeed = 200.0

// Sanity-checks one leg's upstream times against its length, measured speed
// and speed limit. nil when the times are plausible or there is nothing to
// check (no time, no length).
func journeyLegDataIssue(
    length: Double?,
    speed: Double?,
    speedLimit: Double?,
    currentTime: TimeInterval?,
    freeFlowTime: TimeInterval?
) -> JourneyLegDataIssue? {
    func impliedSpeed(_ seconds: TimeInterval?) -> Double? {
        guard let length, length > 0, let seconds, seconds > 0 else {
            return nil
        }
        let kilometresPerHour = length / (seconds / 3600)
        return kilometresPerHour.isFinite ? kilometresPerHour : nil
    }
    func contradicts(_ implied: Double, _ reference: Double?) -> Bool {
        guard let reference, reference > 0 else {
            return false
        }
        let ratio = implied / reference
        return !(ratio >= 1 / legTimeTolerance && ratio <= legTimeTolerance)
    }

    if let implied = impliedSpeed(currentTime) {
        if implied > maxPlausibleLegSpeed {
            return .impossibleSpeed
        }
        if contradicts(implied, speed) {
            return .timeContradictsSpeed
        }
    }
    if let implied = impliedSpeed(freeFlowTime) {
        if implied > maxPlausibleLegSpeed {
            return .impossibleSpeed
        }
        if contradicts(implied, speedLimit) {
            return .freeFlowContradictsLimit
        }
    }
    // Free flow is the uncongested time, so it can't be much longer than the
    // current one (that would mean traffic moving at over twice free-flow speed).
    if let currentTime, currentTime > 0, let freeFlowTime, freeFlowTime > legTimeTolerance * currentTime {
        return .freeFlowExceedsCurrent
    }
    return nil
}

struct TrafficJourneyLeg: Decodable, Identifiable {
    // Unique within its journey. Direction and way are part of it because NZTA
    // often gives the I and D legs of a stretch the same name and sequence
    // number (41 collisions in the 2026-09 feed), which gave the Flow map
    // duplicate ForEach identities. Settable only so TrafficJourney can
    // suffix any duplicate still left.
    fileprivate(set) var id: String
    let name: String?
    let totalLength: Double?
    let speed: Double?
    let flow: Double?
    let time: String?
    let freeFlowTime: Double?
    let coverage: Double?
    let direction: String?
    let sequenceNumber: Int?
    let effectiveSpeedLimit: Double?
    let way: Way?
    // The leg's WKT geometry as separate runs (a LINESTRING is one part), so
    // a multi-part leg never gets a chord drawn between its parts.
    let polylineParts: [GeoPolyline]
    let flowKind: FlowKind
    // Parsed once at decode time rather than re-running parseTimeIntervalString
    // every access — leg time is read repeatedly when aggregating journeys.
    let currentTimeSeconds: TimeInterval?
    // Set when the upstream times are implausible; the leg is then left out of
    // its journey's totals (see journeyLegDataIssue).
    let dataIssue: JourneyLegDataIssue?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let nameValue = cleanText(container.decodeLossyString(forKey: .name))
        let geometryValue = cleanText(container.decodeLossyString(forKey: .geometry))
        let speedValue = container.decodeLossyDouble(forKey: .speed)
        let flowValue = container.decodeLossyDouble(forKey: .flow)
        let timeValue = cleanText(container.decodeLossyString(forKey: .time))
        let freeFlowValue = container.decodeLossyDouble(forKey: .freeFlowTime)
        let coverageValue = container.decodeLossyDouble(forKey: .coverage)
        let directionValue = cleanText(container.decodeLossyString(forKey: .direction))
        let sequenceValue = container.decodeLossyInt(forKey: .sequenceNumber)
        let speedLimitValue = container.decodeLossyDouble(forKey: .effectiveSpeedLimit)
        let totalLengthValue = container.decodeLossyDouble(forKey: .totalLength)
        let wayValue = try? container.decodeIfPresent(Way.self, forKey: .way)

        polylineParts = parseWKTParts(geometryValue)

        name = nameValue
        totalLength = totalLengthValue
        speed = speedValue
        flow = flowValue
        time = timeValue
        freeFlowTime = freeFlowValue
        coverage = coverageValue
        direction = directionValue
        sequenceNumber = sequenceValue
        effectiveSpeedLimit = speedLimitValue
        way = wayValue
        flowKind = computeFlowKind(flow: flowValue, coverage: coverageValue)

        let currentTimeValue: TimeInterval?
        if let parsedTime = parseTimeIntervalString(timeValue), parsedTime > 0 {
            currentTimeValue = parsedTime
        } else {
            currentTimeValue = nil
        }
        currentTimeSeconds = currentTimeValue
        dataIssue = journeyLegDataIssue(
            length: totalLengthValue,
            speed: speedValue,
            speedLimit: speedLimitValue,
            currentTime: currentTimeValue,
            freeFlowTime: freeFlowValue
        )

        let directionTag = directionValue?.uppercased() ?? "?"
        let wayTag = wayValue?.id ?? "?"
        let sequenceTag = sequenceValue.map { String($0) } ?? "?"
        let nameTag = nameValue ?? wayValue?.name ?? "leg"
        id = "leg|\(directionTag)|\(wayTag)|\(nameTag)|\(sequenceTag)"
    }

    var journeyDirection: JourneyDirection {
        JourneyDirection(code: direction)
    }

    var hasLiveData: Bool {
        if let coverage = coverage, coverage > 0 {
            return true
        }
        if let speed = speed, speed > 0 {
            return true
        }
        if let flow = flow, flow > 0 {
            return true
        }
        return false
    }

    // Has at least one part the Flow map can draw.
    var hasMapGeometry: Bool {
        polylineParts.contains(where: \.isDrawable)
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case geometry
        case totalLength
        case speed
        case flow
        case time
        case freeFlowTime
        case coverage
        case direction
        case sequenceNumber
        case effectiveSpeedLimit
        case way
    }
}

struct JourneysPayload: Decodable {
    let response: JourneysResponse
}

struct JourneysResponse: Decodable {
    let journey: [TrafficJourney]
    let droppedCount: Int

    init(from decoder: Decoder) throws {
        let list = try decodeSectionList(TrafficJourney.self, from: decoder, keys: ["journey"])
        journey = list.elements
        droppedCount = list.droppedCount
    }
}

// One line on a TIM travel-time board. The upstream `line` array mixes two
// shapes: `left`(destination) + `right`(estimated time) pairs, and `center`
// text lines — a route qualifier ("VIA SH20 R12", "BEALEY AVE VIA"), a whole
// message on an all-text board ("CITY CENTRE" / "VIA GRT NORTH" / "16
// MINUTES"), or boilerplate ("ESTIMATED" / "MINUTES"). `right` is an Int number
// of minutes OR a pre-formatted string ("29 MINS", "3h 44m"), so it goes
// through the lossy decoders rather than a raw decode. `TIMSign` sorts the
// lines into each page's header text and destination rows.
struct TIMLine: Decodable, Identifiable, Hashable {
    let id: String
    let destination: String?
    let timeText: String?
    // The `center` text, whitespace collapsed ("VIA SH20  R12" → "VIA SH20 R12").
    let center: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let destinationValue = collapsedTIMText(container.decodeLossyString(forKey: .left))
        // Prefer the numeric reading so we can append "min"; fall back to the
        // raw string when `right` is already a units-bearing string.
        let timeValue: String?
        if let minutes = container.decodeLossyInt(forKey: .right) {
            timeValue = "\(minutes) min"
        } else {
            timeValue = cleanText(container.decodeLossyString(forKey: .right))
        }
        let centerValue = collapsedTIMText(container.decodeLossyString(forKey: .center))
        destination = destinationValue
        timeText = timeValue
        center = centerValue
        id = deterministicID(
            decodedId: nil,
            fallback: [destinationValue, timeValue, centerValue],
            typeTag: "timline"
        )
    }

    /// A destination → time row (as opposed to a `center` text line).
    var isTravelRow: Bool {
        destination != nil && timeText != nil
    }

    private enum CodingKeys: String, CodingKey {
        case left
        case right
        case center
    }
}

// Trimmed, with runs of whitespace collapsed to one space and any stray
// "|" separators at either end dropped (the feed has sent "EAST TAMAK|");
// nil when empty.
func collapsedTIMText(_ raw: String?) -> String? {
    guard let text = cleanText(raw) else {
        return nil
    }
    let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        .trimmingCharacters(in: CharacterSet(charactersIn: "|").union(.whitespaces))
    return collapsed.isEmpty ? nil : collapsed
}

// Center lines that only label the board's format ("ESTIMATED" / "MINUTES"
// on a page of their own); they carry no route information.
private let timBoilerplateText: Set<String> = [
    "ESTIMATED", "MINUTES", "MINS", "TRAVEL TIMES", "TRAVEL TIME",
    "ESTIMATED TRAVEL TIMES", "ESTIMATED TRAVEL TIME"
]

func isTIMBoilerplate(_ text: String) -> Bool {
    timBoilerplateText.contains(text.uppercased())
}

// One page a TIM board shows (boards rotate through up to a few): the
// `center` text above its rows — typically the route the times are for
// ("VIA SH20 R12") — and its destination → time rows. A page with header
// text and no rows is a text-only message ("CITY CENTRE / VIA GRT NORTH /
// 16 MINUTES").
struct TIMBoardPage: Hashable, Identifiable, Sendable {
    let id: Int
    let header: [String]
    let rows: [TIMBoardRow]

    var isTextOnly: Bool {
        rows.isEmpty && !header.isEmpty
    }

    /// The header as one caption, e.g. "VIA SH20 R12".
    var caption: String? {
        header.isEmpty ? nil : header.joined(separator: " · ")
    }
}

struct TIMBoardRow: Hashable, Sendable {
    let destination: String
    let timeText: String

    var text: String {
        "\(destination) \(timeText)"
    }
}

// Sorts each raw page's lines into header text and rows. Boilerplate and
// blank center lines are dropped, as are lines with neither a destination and
// time nor text, and then any page left with nothing to show.
func timBoardPages(_ rawPages: [[TIMLine]]) -> [TIMBoardPage] {
    var pages: [TIMBoardPage] = []
    for lines in rawPages {
        var header: [String] = []
        var rows: [TIMBoardRow] = []
        for line in lines {
            if let destination = line.destination, let time = line.timeText {
                rows.append(TIMBoardRow(destination: destination, timeText: time))
            } else if let center = line.center, !isTIMBoilerplate(center) {
                header.append(center)
            }
        }
        guard !header.isEmpty || !rows.isEmpty else {
            continue
        }
        pages.append(TIMBoardPage(id: pages.count, header: header, rows: rows))
    }
    return pages
}

// One page of a TIM board as it arrives. A board's `page` field is either a
// single page object or a list of pages it rotates through; each page carries
// a `line` array. Decoded via the flexible array helper so a lone object or a
// list both work, and so does a lone `line` object.
private struct TIMRawPage: Decodable {
    let line: [TIMLine]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        line = container.decodeFlexibleArray(TIMLine.self, forKey: .line)
    }

    private enum CodingKeys: String, CodingKey {
        case line
    }
}

// A TIM (Traffic Information Monitor) roadside travel-time board from
// /signs/tim/all — ~270 of them, every one carrying lat/lon. `page` may be a
// single object OR a list of pages; `way.id` is int-or-string (handled by the
// shared `Way` lossy decode). Each page keeps its route text (the `center`
// lines) with its destination → time rows, so two "PAPANUI" rows on different
// routes stay distinguishable.
struct TIMSign: Decodable, Identifiable, Hashable, TrafficFilterable {
    let id: String
    let rawId: String?
    let name: String?
    let latitude: Double?
    let longitude: Double?
    let mapLatitude: Double?
    let mapLongitude: Double?
    let region: Region?
    let journey: Journey?
    let way: Way?
    let pages: [TIMBoardPage]
    let highwayKeys: Set<String>
    let highwayHaystack: String
    let searchHaystack: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedId = container.decodeLossyString(forKey: .id)
        let nameValue = cleanText(container.decodeLossyString(forKey: .name))
        let latitudeValue = container.decodeLossyDouble(forKey: .latitude)
        let longitudeValue = container.decodeLossyDouble(forKey: .longitude)
        let regionValue = try? container.decodeIfPresent(Region.self, forKey: .region)
        let journeyValue = try? container.decodeIfPresent(Journey.self, forKey: .journey)
        let wayValue = try? container.decodeIfPresent(Way.self, forKey: .way)
        let rawPages = container.decodeFlexibleArray(TIMRawPage.self, forKey: .page)
        let boardPages = timBoardPages(rawPages.map(\.line))

        rawId = decodedId
        id = deterministicID(
            decodedId: decodedId,
            fallback: [
                nameValue,
                latitudeValue.map { String($0) },
                longitudeValue.map { String($0) }
            ],
            typeTag: "tim"
        )
        name = nameValue
        latitude = latitudeValue
        longitude = longitudeValue
        region = regionValue
        journey = journeyValue
        way = wayValue
        pages = boardPages
        let validatedMap = validatedCoordinate(latitude: latitudeValue, longitude: longitudeValue)
        mapLatitude = validatedMap?.latitude
        mapLongitude = validatedMap?.longitude
        // TIM way codes carry no "SH" ("01N", "020"), so `journey.name`
        // ("SH1") is what ties most boards to a highway. Destinations stay out
        // of the highway fields: "SH1 GILLIES" is where a board points, not
        // the road it stands on.
        highwayKeys = highwayKeySet(
            structured: [journeyValue?.name, wayValue?.name],
            text: [nameValue]
        )
        highwayHaystack = searchableHaystack([
            journeyValue?.name,
            wayValue?.name,
            nameValue
        ])
        searchHaystack = searchableHaystack(
            [nameValue, regionValue?.name, journeyValue?.name, wayValue?.name]
                + boardPages.flatMap(\.header)
                + boardPages.flatMap { $0.rows.map(\.destination) }
        )
    }

    var displayName: String {
        name ?? "Travel Time Sign"
    }

    var regionName: String? {
        region?.name
    }

    var routeName: String? {
        way?.name
    }

    /// Every destination → time row, across pages.
    var lines: [TIMBoardRow] {
        pages.flatMap(\.rows)
    }

    var mapCoordinate: CLLocationCoordinate2D? {
        guard let mapLatitude, let mapLongitude else {
            return nil
        }
        return CLLocationCoordinate2D(latitude: mapLatitude, longitude: mapLongitude)
    }

    // Shortest reading for marker tooltips and the map status text: the first
    // destination/time pair, or a text-only board's message.
    var headline: String? {
        if let row = lines.first {
            return row.text
        }
        return pages.first?.header.joined(separator: " ")
    }

    // Everything the board shows on one line, each page's route text before
    // its rows: "VIA SH20 R12 · SH1 GILLIES 27 min · CITY CENTRE 32 min".
    var summary: String? {
        let parts = pages.flatMap { page in
            page.header + page.rows.map(\.text)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case latitude
        case longitude
        case region
        case journey
        case way
        case page
    }
}

struct TIMSignsPayload: Decodable {
    let response: TIMSignsResponse
}

struct TIMSignsResponse: Decodable {
    let tim: [TIMSign]
    let droppedCount: Int

    init(from decoder: Decoder) throws {
        let list = try decodeSectionList(TIMSign.self, from: decoder, keys: ["tim"])
        tim = list.elements
        droppedCount = list.droppedCount
    }
}

// /regions/all/10 → the 14 canonical NZTA regions: stable, consistently-cased
// names for the region filter, and each region's coarse WKT POLYGON outline
// (`Region.boundary`), used to place EV chargers in a region.
struct RegionsPayload: Decodable {
    let response: RegionsResponse
}

struct RegionsResponse: Decodable {
    let region: [Region]

    init(from decoder: Decoder) throws {
        region = try decodeSectionList(Region.self, from: decoder, keys: ["region"]).elements
    }
}

// EV Roam public charging stations, served as an ArcGIS GeoJSON
// FeatureCollection (external host — not the NZTA traffic API). Static
// reference data, so no image cache token applies. The upstream is loose-typed
// like the NZTA feeds: booleans arrive as "True"/"False" strings and the
// per-connector detail is packed into one `connectorsList` string, so values go
// through the lossy decoders and `parseEVConnectors` rather than raw `decode`.
struct EVCharger: Decodable, Identifiable, Hashable {
    let id: String
    let name: String?
    let operatorName: String?
    let address: String?
    let currentType: String?
    let connectorCount: Int?
    let is24Hours: Bool?
    let hasChargingCost: Bool?
    let latitude: Double?
    let longitude: Double?
    let mapLatitude: Double?
    let mapLongitude: Double?
    // Parsed `connectorsList`: power, types and per-status connector counts.
    let connectors: EVConnectorSummary
    let highwayKeys: Set<String>
    let highwayHaystack: String
    let searchHaystack: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let featureId = container.decodeLossyString(forKey: .id)

        // GeoJSON geometry: coordinates are [longitude, latitude].
        var geometryLongitude: Double?
        var geometryLatitude: Double?
        if let geometry = try? container.nestedContainer(keyedBy: GeometryKeys.self, forKey: .geometry),
           var coordinates = try? geometry.nestedUnkeyedContainer(forKey: .coordinates) {
            geometryLongitude = try? coordinates.decode(Double.self)
            geometryLatitude = try? coordinates.decode(Double.self)
        }

        let properties = try? container.nestedContainer(keyedBy: PropertyKeys.self, forKey: .properties)
        let nameValue = cleanText(properties?.decodeLossyString(forKey: .name))
        let operatorValue = cleanText(properties?.decodeLossyString(forKey: .operatorName))
        let addressValue = cleanText(properties?.decodeLossyString(forKey: .address))
        let currentTypeValue = cleanText(properties?.decodeLossyString(forKey: .currentType))
        let connectorsListValue = cleanText(properties?.decodeLossyString(forKey: .connectorsList))
        let propLatitude = properties?.decodeLossyDouble(forKey: .latitude)
        let propLongitude = properties?.decodeLossyDouble(forKey: .longitude)
        let objectIdValue = properties?.decodeLossyString(forKey: .objectId)
        let globalIdValue = properties?.decodeLossyString(forKey: .globalId)

        let longitudeValue = geometryLongitude ?? propLongitude
        let latitudeValue = geometryLatitude ?? propLatitude

        id = deterministicID(
            decodedId: featureId ?? objectIdValue ?? globalIdValue,
            fallback: [
                nameValue,
                latitudeValue.map { String($0) },
                longitudeValue.map { String($0) }
            ],
            typeTag: "evcharger"
        )
        name = nameValue
        operatorName = operatorValue
        address = addressValue
        currentType = currentTypeValue
        connectorCount = properties?.decodeLossyInt(forKey: .numberOfConnectors)
        is24Hours = properties?.decodeLossyBool(forKey: .is24Hours)
        hasChargingCost = properties?.decodeLossyBool(forKey: .hasChargingCost)
        latitude = latitudeValue
        longitude = longitudeValue
        let validatedMap = validatedCoordinate(latitude: latitudeValue, longitude: longitudeValue)
        mapLatitude = validatedMap?.latitude
        mapLongitude = validatedMap?.longitude

        let parsed = parseEVConnectors(connectorsListValue)
        connectors = parsed

        // A charger isn't on a highway record; an address on a state highway
        // ("85379 State Highway 2") ties it to that highway.
        highwayKeys = highwayKeySet(structured: [], text: [nameValue, addressValue])
        highwayHaystack = searchableHaystack([nameValue, addressValue])
        // Folded like every haystack, so "whangarei" finds "Whangārei".
        searchHaystack = searchableHaystack([
            nameValue,
            operatorValue,
            addressValue,
            currentTypeValue
        ] + parsed.connectorTypes)
    }

    // Highway and Search. The feed has no region: the store places each
    // charger in one from its location (see regionName(containing:in:)).
    func matches(highway: HighwayQuery, search: String) -> Bool {
        highway.matches(keys: highwayKeys, haystack: highwayHaystack)
            && matchesNeedle(search, in: searchHaystack)
    }

    var displayName: String {
        name ?? "EV Charger"
    }

    /// The highest advertised power among connectors that may work (see
    /// `EVConnectorSummary`).
    var maxPowerKW: Double? {
        connectors.maxPowerKW
    }

    var connectorTypes: [String] {
        connectors.connectorTypes
    }

    var hasDCConnector: Bool {
        connectors.hasDCConnector
    }

    // Offers DC fast charging (the marker tint/legend and card badge): a DC
    // connector group that may work. With no connector list, the site type
    // decides: DC, or "Mixed" — Mixed sites carry both AC and DC, but the word
    // itself contains no "DC". A Mixed site whose DC units are all down is
    // not DC.
    var isDC: Bool {
        if connectors.totalCount > 0 {
            return connectors.hasDCConnector
        }
        guard let type = currentType?.lowercased() else {
            return false
        }
        return type.contains("dc") || type == "mixed"
    }

    var availability: EVAvailability {
        if connectors.operativeCount > 0 {
            return .available
        }
        if connectors.inoperativeCount > 0 {
            return .outOfService
        }
        return connectors.unknownCount > 0 ? .unknown : .notReported
    }

    var isOutOfService: Bool {
        availability == .outOfService
    }

    /// "2 of 4 connectors working", "Out of service — 2 connectors down",
    /// "Status not reported"; nil when the feed listed no connectors.
    var statusSummary: String? {
        let total = connectors.totalCount
        let noun = total == 1 ? "connector" : "connectors"
        switch availability {
        case .available:
            var text = "\(connectors.operativeCount) of \(total) \(noun) working"
            if connectors.unknownCount > 0 {
                text += " (\(connectors.unknownCount) not reported)"
            }
            return text
        case .outOfService:
            let down = connectors.inoperativeCount
            return "Out of service — \(down) \(down == 1 ? "connector" : "connectors") down"
        case .unknown:
            return "Status not reported"
        case .notReported:
            return nil
        }
    }

    var mapCoordinate: CLLocationCoordinate2D? {
        guard let mapLatitude, let mapLongitude else {
            return nil
        }
        return CLLocationCoordinate2D(latitude: mapLatitude, longitude: mapLongitude)
    }

    // Compact "DC · 75 kW" style summary for marker subtitles and the legend.
    var powerSummary: String? {
        let kw = maxPowerKW.flatMap { value -> String? in
            guard value > 0 else {
                return nil
            }
            // formatWholeNumber, not Int(_:): an absurd advertised power
            // ("1e19 kW") must not trap; it just isn't shown.
            return value.rounded() == value ? formatWholeNumber(value) : String(format: "%.1f", value)
        }
        switch (currentTypeLabel, kw) {
        case let (type?, power?):
            return "\(type) · \(power) kW"
        case let (type?, nil):
            return type
        case let (nil, power?):
            return "\(power) kW"
        default:
            return nil
        }
    }

    var connectorSummary: String? {
        connectorTypes.isEmpty ? nil : connectorTypes.joined(separator: ", ")
    }

    // AC / DC / Mixed from the connectors that may work, so a Mixed site
    // whose DC units are down reads "AC · 22 kW"; the feed's site type when
    // it listed no connectors.
    private var currentTypeLabel: String? {
        switch (connectors.hasACConnector, connectors.hasDCConnector) {
        case (true, true):
            return "Mixed"
        case (false, true):
            return "DC"
        case (true, false):
            return "AC"
        case (false, false):
            return cleanText(currentType)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case geometry
        case properties
    }

    private enum GeometryKeys: String, CodingKey {
        case coordinates
    }

    private enum PropertyKeys: String, CodingKey {
        case objectId = "OBJECTID"
        case globalId = "GlobalID"
        case name
        case operatorName = "operator"
        case address
        case currentType
        case numberOfConnectors
        case connectorsList
        case is24Hours
        case hasChargingCost
        case latitude
        case longitude
    }
}

struct EVChargersPayload: Decodable {
    let features: [EVCharger]
    let droppedCount: Int

    init(from decoder: Decoder) throws {
        // ArcGIS reports failures as {"error":{…}} with HTTP 200; with no
        // `features` key that now throws instead of reading as zero chargers.
        let list = try decodeSectionList(EVCharger.self, from: decoder, keys: ["features"])
        features = list.elements
        droppedCount = list.droppedCount
    }
}

// A charging site's connectors as the EV Roam feed reports them, packed into
// one string: "{DC, 75 kW, CHAdeMO, Status: Operative, Count:1},{AC, 22 kW,
// Type 2 Socketed, Status: Inoperative, Count:2}". Each group's status is
// Operative, Inoperative or Unknown (not reported — not the same as broken);
// a group without one counts as Unknown, and without a count as 1 connector.
// The headline power, the DC flag and the AC/DC/Mixed label describe the
// groups that may work (Operative or Unknown), so a site whose DC units are
// down isn't advertised as DC fast charging; a site with nothing that may
// work falls back to every group, to still say what it has.
struct EVConnectorSummary: Hashable, Sendable {
    var maxPowerKW: Double?
    // Distinct connector types (order-preserving, case-insensitively
    // de-duplicated) across every group.
    var connectorTypes: [String] = []
    var hasDCConnector = false
    var hasACConnector = false
    var operativeCount = 0
    var inoperativeCount = 0
    var unknownCount = 0

    var totalCount: Int {
        operativeCount + inoperativeCount + unknownCount
    }
}

enum EVConnectorStatus: Hashable, Sendable {
    case operative
    case inoperative
    case unknown

    init(raw: String?) {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "operative", "operational", "available":
            self = .operative
        case "inoperative", "out of service", "faulted", "unavailable":
            self = .inoperative
        default:
            self = .unknown
        }
    }
}

// Whether a site can be expected to charge, from its connectors' statuses.
enum EVAvailability: Hashable, Sendable {
    // At least one connector is Operative.
    case available
    // None is Operative and at least one is Inoperative (the rest, if any,
    // Unknown): shown greyed out as "Out of service".
    case outOfService
    // Every connector's status is Unknown — not reported, which isn't the
    // same as broken, so the site is shown normally.
    case unknown
    // The feed listed no connectors.
    case notReported
}

private struct EVConnectorGroup {
    var isDC = false
    var isAC = false
    var powerKW: Double?
    var type: String?
    var status = EVConnectorStatus.unknown
    var count = 1
}

func parseEVConnectors(_ raw: String?) -> EVConnectorSummary {
    guard let raw = cleanText(raw) else {
        return EVConnectorSummary()
    }

    var groups: [EVConnectorGroup] = []
    let texts = raw
        .replacingOccurrences(of: "{", with: "")
        .components(separatedBy: "}")
    for text in texts {
        let fields = text
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !fields.isEmpty else {
            continue
        }
        groups.append(parseEVConnectorGroup(fields))
    }

    var summary = EVConnectorSummary()
    var seenTypes = Set<String>()
    for group in groups {
        if let type = group.type, seenTypes.insert(type.lowercased()).inserted {
            summary.connectorTypes.append(type)
        }
        switch group.status {
        case .operative:
            summary.operativeCount += group.count
        case .inoperative:
            summary.inoperativeCount += group.count
        case .unknown:
            summary.unknownCount += group.count
        }
    }

    let mayWork = groups.filter { $0.status != .inoperative }
    for group in mayWork.isEmpty ? groups : mayWork {
        summary.hasDCConnector = summary.hasDCConnector || group.isDC
        summary.hasACConnector = summary.hasACConnector || group.isAC
        if let power = group.powerKW {
            summary.maxPowerKW = max(summary.maxPowerKW ?? 0, power)
        }
    }
    return summary
}

// Layout: currentType, "<n> kW", connectorType, "Status: …", "Count:…" —
// read by content rather than position where it can be.
private func parseEVConnectorGroup(_ fields: [String]) -> EVConnectorGroup {
    var group = EVConnectorGroup()
    let current = fields[0].uppercased()
    group.isDC = current == "DC"
    group.isAC = current == "AC"
    if fields.count >= 3 {
        let type = fields[2]
        if !type.isEmpty, !type.lowercased().hasPrefix("status"), !type.lowercased().hasPrefix("count") {
            group.type = type
        }
    }
    for field in fields {
        let lowered = field.lowercased()
        if lowered.hasPrefix("status") {
            group.status = EVConnectorStatus(raw: labelledValue(field))
        } else if lowered.hasPrefix("count") {
            if let count = labelledValue(field).flatMap({ Int($0) }), count > 0, count < 10_000 {
                group.count = count
            }
        } else if lowered.hasSuffix("kw") {
            let number = field
                .replacingOccurrences(of: "kW", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = Double(number), value.isFinite {
                group.powerKW = max(group.powerKW ?? 0, value)
            }
        }
    }
    return group
}

// "Status: Operative" → "Operative", "Count:3" → "3".
private func labelledValue(_ field: String) -> String? {
    guard let colon = field.firstIndex(of: ":") else {
        return nil
    }
    return cleanText(String(field[field.index(after: colon)...]))
}

// MARK: - Lenient arrays

// One element of a feed array, decoded on its own: an element that fails (a
// null, a stray string, a malformed record) becomes nil instead of failing,
// and so emptying, the whole array.
struct LossyElement<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

// A feed's top-level list plus how many of its elements were unreadable and
// skipped (reported by Export Diagnostics).
struct SectionList<Element> {
    let elements: [Element]
    let droppedCount: Int
}

// A coding key for whatever keys a JSON object actually has. (A CodingKeys
// enum's `allKeys` only lists the keys it already knows.)
struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

// Decodes the list a feed response carries under the first of `keys` present,
// element by element. It accepts the feeds' Jettison-style shapes: a lone
// object for a one-element list, and an empty object or a null for an empty
// one. It THROWS when the response is structurally wrong, so the store keeps
// its last good data and offline cache instead of "succeeding" with nothing:
// - the object has keys but none of `keys` (a renamed list, or an error body
//   such as ArcGIS's {"error":{…}} on HTTP 200);
// - the value is neither a list nor an object (a string or number);
// - the list isn't empty but not one of its elements decodes.
func decodeSectionList<T: Decodable>(
    _ type: T.Type,
    from decoder: Decoder,
    keys: [String]
) throws -> SectionList<T> {
    let container = try decoder.container(keyedBy: AnyCodingKey.self)
    guard let key = keys.lazy.map(AnyCodingKey.init).first(where: { container.contains($0) }) else {
        let found = container.allKeys.map(\.stringValue).sorted()
        guard found.isEmpty else {
            throw DecodingError.keyNotFound(
                AnyCodingKey(keys.first ?? "?"),
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Expected \(keys.map { "\"\($0)\"" }.joined(separator: " or ")) "
                        + "but the response has \(found.map { "\"\($0)\"" }.joined(separator: ", "))"
                )
            )
        }
        return SectionList(elements: [], droppedCount: 0)
    }
    if (try? container.decodeNil(forKey: key)) == true {
        return SectionList(elements: [], droppedCount: 0)
    }
    if let array = try? container.decode([LossyElement<T>].self, forKey: key) {
        let elements = array.compactMap(\.value)
        if elements.isEmpty && !array.isEmpty {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath + [key],
                    debugDescription: "None of the \(array.count) \"\(key.stringValue)\" entries could be read"
                )
            )
        }
        return SectionList(elements: elements, droppedCount: array.count - elements.count)
    }
    if let single = try? container.decode(LossyElement<T>.self, forKey: key), let value = single.value {
        return SectionList(elements: [value], droppedCount: 0)
    }
    throw DecodingError.typeMismatch(
        [T].self,
        DecodingError.Context(
            codingPath: container.codingPath + [key],
            debugDescription: "\"\(key.stringValue)\" is neither a list nor a readable entry"
        )
    )
}

// One element of a loosely typed JSON array: a string or number becomes text;
// anything else (object, array, null, bool) decodes to nil instead of failing
// the whole array.
private struct LossyTextElement: Decodable {
    let value: String?

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.singleValueContainer() else {
            value = nil
            return
        }
        if let text = try? container.decode(String.self) {
            value = text
        } else if let number = try? container.decode(Int.self) {
            value = String(number)
        } else if let number = try? container.decode(Double.self), number.isFinite {
            value = String(number)
        } else {
            value = nil
        }
    }
}

extension KeyedDecodingContainer {
    // A nested list that may arrive as a list, a lone object or not at all
    // (legs, TIM pages and lines). Elements decode one by one, so a bad entry
    // is skipped rather than emptying the list. Top-level feed lists go
    // through decodeSectionList, which also rejects broken shapes.
    func decodeFlexibleArray<T: Decodable>(_ type: T.Type, forKey key: Key) -> [T] {
        if let array = try? decodeIfPresent([LossyElement<T>].self, forKey: key) {
            return array.compactMap(\.value)
        }

        if let value = try? decodeIfPresent(T.self, forKey: key) {
            return [value]
        }

        return []
    }

    func decodeLossyString(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            // Whole numbers read without a ".0" ("42"), but only when they fit
            // in an Int: `Int(_:)` traps on 1e20, so larger values keep their
            // Double spelling ("1e+20").
            if let whole = Int(exactly: value) {
                return String(whole)
            }
            return String(value)
        }
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value ? "true" : "false"
        }
        return nil
    }

    // Like decodeLossyString, but also accepts a JSON array of strings or
    // numbers, joining the non-empty entries with "; ". (The events feed
    // occasionally sends `locations` as a list.) Non-text elements are skipped.
    func decodeLossyStringOrArray(forKey key: Key) -> String? {
        if let value = decodeLossyString(forKey: key) {
            return value
        }
        guard let elements = try? decodeIfPresent([LossyTextElement].self, forKey: key) else {
            return nil
        }
        return joinNonEmpty(elements.map(\.value), separator: "; ")
    }

    func decodeLossyBool(forKey key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value != 0
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value != 0
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            let lowercased = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "yes", "1"].contains(lowercased) {
                return true
            }
            if ["false", "no", "0"].contains(lowercased) {
                return false
            }
        }
        return nil
    }

    func decodeLossyDouble(forKey key: Key) -> Double? {
        // Reject NaN/Infinity so downstream consumers can trust the value is
        // finite. Finite is not the same as small: 1e19 still overflows Int,
        // so Int conversions go through Int(exactly:) / formatWholeNumber.
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value.isFinite ? value : nil
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key),
           let parsed = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return parsed.isFinite ? parsed : nil
        }
        return nil
    }

    func decodeLossyInt(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            // `Int(_:)` traps on NaN/Infinity and out-of-range doubles, which
            // the loose upstream API can deliver. Guard before converting.
            guard value.isFinite, value >= Double(Int.min), value < Double(Int.max) else {
                return nil
            }
            return Int(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}

// What the store does with a freshly fetched, successfully decoded section.
// An empty list arriving where the app already holds data is treated as
// suspect (a feed hiccup, not every camera vanishing at once): the last good
// data stays on screen and in the offline cache, and the section reports an
// error. An empty list is never written to the offline cache either, so it
// can't replace a useful offline copy.
enum SectionRefreshDecision: Equatable {
    case replace(persist: Bool)
    case keepPrevious
}

func sectionRefreshDecision(fetchedCount: Int, currentCount: Int) -> SectionRefreshDecision {
    guard fetchedCount == 0 else {
        return .replace(persist: true)
    }
    return currentCount > 0 ? .keepPrevious : .replace(persist: false)
}

// Plain-text diagnostics snapshot for Help → Export Diagnostics. Pure /
// Foundation-only so it can be unit-tested; the store gathers the live inputs
// (section counts and status, recent per-section errors, the offline cache's
// files, refresh and API state, preferences, app and OS version) and the view
// layer writes the rendered text to disk via NSSavePanel. Carries no personal
// data — only counts, statuses, error strings, file sizes/dates, and the app's
// own `nzta.*` preference keys.
struct DiagnosticsReport {
    struct SectionStat {
        let name: String
        let count: Int
        let error: String?
        // Unreadable feed entries the lenient decode skipped last time.
        var droppedCount = 0
        // Where the data on screen came from ("live", "saved data (offline
        // cache)", "last fetch failed", …) and when it was last fetched live.
        var status: String?
        var lastSuccess: Date?
    }

    struct CacheFile {
        let name: String
        let byteCount: Int
        let savedAt: Date?
    }

    let appVersion: String
    let appBuild: String
    let generatedAt: Date
    let lastUpdated: Date?
    let isOnline: Bool
    let sections: [SectionStat]
    let preferences: [String: String]
    // macOS version and architecture (see systemDescription()).
    var system: String?
    // The freshness banner's text, if one is showing.
    var freshness: String?
    // Auto-refresh cadence and refresh state, one line each.
    var refresh: [String] = []
    var cacheFiles: [CacheFile] = []
    // Traffic API paths that fell back from rest/5 to rest/4 this session.
    var apiFallbacks: [String] = []

    // Collects the app's own persisted preferences (the `nzta.*` @AppStorage
    // keys) from UserDefaults, stringified for the report.
    static func collectPreferences(from defaults: UserDefaults = .standard) -> [String: String] {
        collectPreferences(from: defaults.dictionaryRepresentation())
    }

    // Pure filter over a defaults snapshot — the seam the tests use, so they
    // never read or write a real (on-disk) UserDefaults domain.
    static func collectPreferences(from values: [String: Any]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in values where key.hasPrefix("nzta.") {
            if key == Watchlist.defaultsKey {
                // Only how much is watched: which roads someone follows can
                // say where they live or work.
                let watchlist = Watchlist.decoded(from: value as? Data)
                result[key] = "highways: \(watchlist.highways.count), cameras: \(watchlist.cameraIDs.count), journeys: \(watchlist.journeyIDs.count)"
            } else {
                result[key] = String(describing: value)
            }
        }
        return result
    }

    /// "macOS Version 27.0 (Build 27A266a), arm64".
    static func systemDescription(
        operatingSystem: String = ProcessInfo.processInfo.operatingSystemVersionString
    ) -> String {
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown architecture"
        #endif
        return "macOS \(operatingSystem), \(architecture)"
    }

    func formattedText() -> String {
        let isoFormatter = ISO8601DateFormatter()
        var lines: [String] = []
        let title = "\(AppIdentity.productName) — Diagnostics Report"
        lines.append(title)
        lines.append(String(repeating: "=", count: title.count))
        lines.append("Generated:    \(isoFormatter.string(from: generatedAt))")
        lines.append("App Version:  \(appVersion) (build \(appBuild))")
        if let system {
            lines.append("System:       \(system)")
        }
        lines.append("Network:      \(isOnline ? "online" : "offline")")
        if let lastUpdated {
            lines.append("Last Updated: \(isoFormatter.string(from: lastUpdated))")
        } else {
            lines.append("Last Updated: never")
        }
        if let freshness {
            lines.append("Banner:       \(freshness)")
        }
        for line in refresh {
            lines.append(line)
        }
        lines.append("")
        lines.append("Data Sections")
        lines.append("-------------")
        for section in sections {
            var line = "\(section.name): \(section.count)"
            if section.droppedCount > 0 {
                let noun = section.droppedCount == 1 ? "entry" : "entries"
                line += " (\(section.droppedCount) unreadable \(noun) skipped)"
            }
            if let error = section.error, !error.isEmpty {
                line += " — ERROR: \(error)"
            }
            lines.append(line)
            if let status = section.status {
                let success = section.lastSuccess.map(isoFormatter.string(from:)) ?? "never"
                lines.append("    \(status); last live fetch: \(success)")
            }
        }
        lines.append("")
        lines.append("Offline Cache")
        lines.append("-------------")
        if cacheFiles.isEmpty {
            lines.append("(empty)")
        } else {
            for file in cacheFiles {
                let saved = file.savedAt.map(isoFormatter.string(from:)) ?? "unknown date"
                lines.append("\(file.name): \(file.byteCount) bytes, saved \(saved)")
            }
        }
        lines.append("")
        lines.append("API")
        lines.append("---")
        if apiFallbacks.isEmpty {
            lines.append("Traffic API: rest/5")
        } else {
            lines.append("Traffic API: rest/5, falling back to rest/4 for \(apiFallbacks.joined(separator: ", "))")
        }
        lines.append("")
        lines.append("Preferences")
        lines.append("-----------")
        if preferences.isEmpty {
            lines.append("(none)")
        } else {
            for key in preferences.keys.sorted() {
                lines.append("\(key) = \(preferences[key] ?? "")")
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }
}
