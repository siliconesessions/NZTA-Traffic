import CoreLocation
import Foundation

struct Region: Decodable, Hashable {
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

struct TrafficCamera: Decodable, Identifiable, Hashable {
    let id: String
    let rawId: String?
    let name: String?
    let description: String?
    let direction: String?
    let group: String?
    let highway: String?
    let imageUrl: String?
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

    func imageURL(cacheToken: Int) -> URL? {
        trafficNZURL(from: imageUrl ?? thumbUrl, cacheToken: cacheToken)
    }

    func thumbnailURL(cacheToken: Int) -> URL? {
        trafficNZURL(from: thumbUrl ?? imageUrl, cacheToken: cacheToken)
    }

    func matches(region selectedRegion: String, highway selectedHighway: String, search: String) -> Bool {
        matchesRegion(regionName, selectedRegion: selectedRegion)
            && matchesNeedle(selectedHighway, in: highwayHaystack)
            && matchesNeedle(search, in: searchHaystack)
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

struct RoadEvent: Decodable, Identifiable, Hashable {
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
        let locationsValue = cleanText(container.decodeLossyString(forKey: .locations))
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
        status = cleanText(container.decodeLossyString(forKey: .status))
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

    var hasDelays: Bool {
        impact?.range(of: "delay", options: .caseInsensitive) != nil
    }

    var mapCoordinate: CLLocationCoordinate2D? {
        guard let mapLatitude, let mapLongitude else {
            return nil
        }
        return CLLocationCoordinate2D(latitude: mapLatitude, longitude: mapLongitude)
    }

    var alternativeRouteText: String? {
        guard let alternativeRoute else {
            return nil
        }

        if alternativeRoute.caseInsensitiveCompare("Not Applicable") == .orderedSame {
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

    func matches(region selectedRegion: String, highway selectedHighway: String, search: String) -> Bool {
        matchesRegion(regionName, selectedRegion: selectedRegion)
            && matchesNeedle(selectedHighway, in: highwayHaystack)
            && matchesNeedle(search, in: searchHaystack)
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

struct VMSSign: Decodable, Identifiable, Hashable {
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

    func matches(region selectedRegion: String, highway selectedHighway: String, search: String) -> Bool {
        matchesRegion(regionName, selectedRegion: selectedRegion)
            && matchesNeedle(selectedHighway, in: highwayHaystack)
            && matchesNeedle(search, in: searchHaystack)
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        camera = container.decodeFlexibleArray(TrafficCamera.self, forKey: .camera)
    }

    private enum CodingKeys: String, CodingKey {
        case camera
    }
}

struct RoadEventsPayload: Decodable {
    let response: RoadEventResponse
}

struct RoadEventResponse: Decodable {
    let roadevent: [RoadEvent]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let lowerCaseEvents = container.decodeFlexibleArray(RoadEvent.self, forKey: .roadevent)
        roadevent = lowerCaseEvents.isEmpty
            ? container.decodeFlexibleArray(RoadEvent.self, forKey: .roadEvent)
            : lowerCaseEvents
    }

    private enum CodingKeys: String, CodingKey {
        case roadevent
        case roadEvent
    }
}

struct VMSPayload: Decodable {
    let response: VMSResponse
}

struct VMSResponse: Decodable {
    let vms: [VMSSign]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        vms = container.decodeFlexibleArray(VMSSign.self, forKey: .vms)
    }

    private enum CodingKeys: String, CodingKey {
        case vms
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

// Matches "longitude latitude" coordinate pairs inside WKT geometry strings.
// Compiled once at module load and reused — recompiling per call was a hot path.
private let wktCoordinateRegex: NSRegularExpression? = {
    try? NSRegularExpression(pattern: #"(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\s+(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)"#)
}()

func coordinateFromWKTGeometry(_ geometry: String?) -> CLLocationCoordinate2D? {
    guard let geometry = cleanText(geometry) else {
        return nil
    }

    guard let regex = wktCoordinateRegex else {
        return nil
    }

    let source = geometry as NSString
    let matches = regex.matches(in: geometry, range: NSRange(location: 0, length: source.length))

    var minLatitude = Double.greatestFiniteMagnitude
    var maxLatitude = -Double.greatestFiniteMagnitude
    var minLongitude = Double.greatestFiniteMagnitude
    var maxLongitude = -Double.greatestFiniteMagnitude
    var validCoordinateCount = 0

    for match in matches where match.numberOfRanges >= 3 {
        guard let longitude = Double(source.substring(with: match.range(at: 1))),
              let latitude = Double(source.substring(with: match.range(at: 2))),
              validatedCoordinate(latitude: latitude, longitude: longitude) != nil else {
            continue
        }

        minLatitude = min(minLatitude, latitude)
        maxLatitude = max(maxLatitude, latitude)
        minLongitude = min(minLongitude, longitude)
        maxLongitude = max(maxLongitude, longitude)
        validCoordinateCount += 1
    }

    guard validCoordinateCount > 0 else {
        return nil
    }

    return validatedCoordinate(
        latitude: (minLatitude + maxLatitude) / 2,
        longitude: (minLongitude + maxLongitude) / 2
    )
}

func trafficNZURL(from path: String?, cacheToken: Int? = nil) -> URL? {
    guard var path = cleanText(path) else {
        return nil
    }

    if path.lowercased().hasPrefix("http://") {
        path = "https://" + path.dropFirst("http://".count)
    } else if !path.lowercased().hasPrefix("https://") {
        if !path.hasPrefix("/") {
            path = "/" + path
        }
        path = "https://trafficnz.info" + path
    }

    guard var components = URLComponents(string: path) else {
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

private let isoFractionalDateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private let isoDateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()

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
    return formatter
}()

private func parseTrafficDate(_ rawValue: String) -> Date? {
    isoFractionalDateFormatter.date(from: rawValue)
        ?? isoDateFormatter.date(from: rawValue)
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

private let relativeTrafficDateFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = Locale(identifier: "en_NZ")
    formatter.unitsStyle = .full
    return formatter
}()

// Relative phrasing ("2 days ago", "in 3 hours") for timestamps where a
// relative reading is friendlier than the absolute one. Returns nil when the
// value is missing or unparseable so callers can fall back to formatTrafficDate.
func formatRelativeTrafficDate(_ rawValue: String?, relativeTo reference: Date = Date()) -> String? {
    guard let rawValue = cleanText(rawValue),
          let date = parseTrafficDate(rawValue) else {
        return nil
    }

    return relativeTrafficDateFormatter.localizedString(for: date, relativeTo: reference)
}

func matchesRegion(_ itemRegion: String?, selectedRegion: String) -> Bool {
    let selected = selectedRegion.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !selected.isEmpty else {
        return true
    }

    return (itemRegion ?? "").caseInsensitiveCompare(selected) == .orderedSame
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
    fields.compactMap(cleanText).joined(separator: " ").lowercased()
}

func matchesNeedle(_ needle: String, in haystack: String) -> Bool {
    let query = needle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !query.isEmpty else {
        return true
    }
    return haystack.contains(query)
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

func parseWKTLineStringCoords(_ wkt: String?) -> (latitudes: [Double], longitudes: [Double]) {
    guard let wkt = cleanText(wkt), !wkt.isEmpty else {
        return ([], [])
    }
    guard let regex = wktCoordinateRegex else {
        return ([], [])
    }
    let source = wkt as NSString
    let matches = regex.matches(in: wkt, range: NSRange(location: 0, length: source.length))
    var latitudes: [Double] = []
    var longitudes: [Double] = []
    latitudes.reserveCapacity(matches.count)
    longitudes.reserveCapacity(matches.count)
    for match in matches where match.numberOfRanges >= 3 {
        guard let longitude = Double(source.substring(with: match.range(at: 1))),
              let latitude = Double(source.substring(with: match.range(at: 2))),
              latitude.isFinite, longitude.isFinite,
              (-90.0...90.0).contains(latitude),
              (-180.0...180.0).contains(longitude),
              !(latitude == 0 && longitude == 0) else {
            continue
        }
        latitudes.append(latitude)
        longitudes.append(longitude)
    }
    return (latitudes, longitudes)
}

func parseTimeIntervalString(_ raw: String?) -> TimeInterval? {
    guard let raw = cleanText(raw) else {
        return nil
    }
    let parts = raw.split(separator: ":")
    guard parts.count == 3,
          let hours = Int(parts[0]),
          let minutes = Int(parts[1]),
          let seconds = Int(parts[2]) else {
        return nil
    }
    return TimeInterval(hours * 3600 + minutes * 60 + seconds)
}

func formatTimeInterval(_ interval: TimeInterval) -> String {
    let total = max(0, Int(interval.rounded()))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%d:%02d", minutes, seconds)
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

struct TrafficJourney: Decodable, Identifiable {
    let id: String
    let rawId: String?
    let name: String?
    let totalLength: Double?
    let regionInfo: Region?
    let wayInfo: Way?
    let legs: [TrafficJourneyLeg]
    let routePolylineLatitudes: [Double]
    let routePolylineLongitudes: [Double]
    let highwayHaystack: String
    let searchHaystack: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedId = container.decodeLossyString(forKey: .id)
        let nameValue = cleanText(container.decodeLossyString(forKey: .name))
        let totalLengthValue = container.decodeLossyDouble(forKey: .totalLength)
        let regionValue = decodeFirstRegion(container: container, key: .regions)
        let wayValue = decodeFirstWay(container: container, key: .ways)
        let legsValue = container.decodeFlexibleArray(TrafficJourneyLeg.self, forKey: .legs)

        // Journey-level `geometry` is the full route as a WKT MULTILINESTRING.
        // parseWKTLineStringCoords flattens it to one ordered coordinate list.
        let routeCoords = parseWKTLineStringCoords(cleanText(container.decodeLossyString(forKey: .geometry)))
        routePolylineLatitudes = routeCoords.latitudes
        routePolylineLongitudes = routeCoords.longitudes

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

        var legNames: [String?] = []
        legNames.reserveCapacity(legsValue.count)
        for leg in legsValue {
            legNames.append(leg.name)
        }

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

    /// Full journey route, built from the journey-level WKT geometry, for
    /// drawing the whole path as a single overlay on the Flow map layer.
    var routePolyline: [CLLocationCoordinate2D] {
        guard routePolylineLatitudes.count == routePolylineLongitudes.count, !routePolylineLatitudes.isEmpty else {
            return []
        }
        var result: [CLLocationCoordinate2D] = []
        result.reserveCapacity(routePolylineLatitudes.count)
        for index in 0..<routePolylineLatitudes.count {
            result.append(CLLocationCoordinate2D(latitude: routePolylineLatitudes[index], longitude: routePolylineLongitudes[index]))
        }
        return result
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

    var totalCurrentTime: TimeInterval? {
        let times = legs.compactMap(\.currentTimeSeconds).filter { $0 > 0 }
        guard !times.isEmpty else {
            return nil
        }
        return times.reduce(0, +)
    }

    var totalFreeFlowTime: TimeInterval? {
        let times = legs.compactMap(\.freeFlowTime).filter { $0 > 0 }
        guard !times.isEmpty else {
            return nil
        }
        return times.reduce(0, +)
    }

    var congestionDelay: TimeInterval? {
        guard let current = totalCurrentTime,
              let free = totalFreeFlowTime else {
            return nil
        }
        return max(0, current - free)
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

    var averageSpeed: Double? {
        var weightedSum = 0.0
        var totalWeight = 0.0
        for leg in legs {
            guard let speed = leg.speed, speed > 0,
                  let length = leg.totalLength, length > 0 else {
                continue
            }
            weightedSum += speed * length
            totalWeight += length
        }
        guard totalWeight > 0 else {
            return nil
        }
        return weightedSum / totalWeight
    }

    func matches(region selectedRegion: String, highway selectedHighway: String, search: String) -> Bool {
        matchesRegion(regionName, selectedRegion: selectedRegion)
            && matchesNeedle(selectedHighway, in: highwayHaystack)
            && matchesNeedle(search, in: searchHaystack)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case totalLength
        case regions
        case ways
        case legs
        case geometry
    }
}

struct TrafficJourneyLeg: Decodable, Identifiable {
    let id: String
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
    let polylineLatitudes: [Double]
    let polylineLongitudes: [Double]
    let flowKind: FlowKind

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

        let coords = parseWKTLineStringCoords(geometryValue)
        polylineLatitudes = coords.latitudes
        polylineLongitudes = coords.longitudes

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

        let sequenceTag = sequenceValue.map { String($0) } ?? "?"
        let nameTag = nameValue ?? wayValue?.name ?? "leg"
        id = "leg|\(nameTag)|\(sequenceTag)"
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

    var currentTimeSeconds: TimeInterval? {
        guard let value = parseTimeIntervalString(time), value > 0 else {
            return nil
        }
        return value
    }

    var polyline: [CLLocationCoordinate2D] {
        guard polylineLatitudes.count == polylineLongitudes.count, !polylineLatitudes.isEmpty else {
            return []
        }
        var result: [CLLocationCoordinate2D] = []
        result.reserveCapacity(polylineLatitudes.count)
        for index in 0..<polylineLatitudes.count {
            result.append(CLLocationCoordinate2D(latitude: polylineLatitudes[index], longitude: polylineLongitudes[index]))
        }
        return result
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        journey = container.decodeFlexibleArray(TrafficJourney.self, forKey: .journey)
    }

    private enum CodingKeys: String, CodingKey {
        case journey
    }
}

// One line on a TIM travel-time board. The upstream `line` array mixes two
// shapes: `left`(destination) + `right`(estimated time) pairs, and decorative
// `center`-only lines ("ESTIMATED" / "VIA MOTORWAY"). `right` is an Int number
// of minutes OR a pre-formatted string ("29 MINS", "3h 44m"), so it goes
// through the lossy decoders rather than a raw decode. Center-only lines have
// no destination/time and are dropped by `TIMSign`.
struct TIMLine: Decodable, Identifiable, Hashable {
    let id: String
    let destination: String?
    let timeText: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let destinationValue = cleanText(container.decodeLossyString(forKey: .left))
        // Prefer the numeric reading so we can append "min"; fall back to the
        // raw string when `right` is already a units-bearing string.
        let timeValue: String?
        if let minutes = container.decodeLossyInt(forKey: .right) {
            timeValue = "\(minutes) min"
        } else {
            timeValue = cleanText(container.decodeLossyString(forKey: .right))
        }
        destination = destinationValue
        timeText = timeValue
        id = deterministicID(
            decodedId: nil,
            fallback: [destinationValue, timeValue],
            typeTag: "timline"
        )
    }

    private enum CodingKeys: String, CodingKey {
        case left
        case right
    }
}

// One page of a TIM board. A board's `page` field is either a single page
// object or a list of pages it rotates through; each page carries a `line`
// array. Decoded via the flexible array helper so a lone object or a list both
// work, and so does a lone `line` object.
private struct TIMPage: Decodable {
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
// shared `Way` lossy decode). We flatten every page's lines and keep only the
// destination → estimated-time pairs.
struct TIMSign: Decodable, Identifiable, Hashable {
    let id: String
    let rawId: String?
    let name: String?
    let latitude: Double?
    let longitude: Double?
    let mapLatitude: Double?
    let mapLongitude: Double?
    let region: Region?
    let way: Way?
    let lines: [TIMLine]
    let highwayHaystack: String
    let searchHaystack: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedId = container.decodeLossyString(forKey: .id)
        let nameValue = cleanText(container.decodeLossyString(forKey: .name))
        let latitudeValue = container.decodeLossyDouble(forKey: .latitude)
        let longitudeValue = container.decodeLossyDouble(forKey: .longitude)
        let regionValue = try? container.decodeIfPresent(Region.self, forKey: .region)
        let wayValue = try? container.decodeIfPresent(Way.self, forKey: .way)
        let pages = container.decodeFlexibleArray(TIMPage.self, forKey: .page)
        let travelLines = pages
            .flatMap(\.line)
            .filter { $0.destination != nil && $0.timeText != nil }

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
        way = wayValue
        lines = travelLines
        let validatedMap = validatedCoordinate(latitude: latitudeValue, longitude: longitudeValue)
        mapLatitude = validatedMap?.latitude
        mapLongitude = validatedMap?.longitude
        highwayHaystack = searchableHaystack([
            wayValue?.name,
            nameValue
        ] + travelLines.map(\.destination))
        searchHaystack = searchableHaystack([
            nameValue,
            regionValue?.name,
            wayValue?.name
        ] + travelLines.map(\.destination))
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

    var mapCoordinate: CLLocationCoordinate2D? {
        guard let mapLatitude, let mapLongitude else {
            return nil
        }
        return CLLocationCoordinate2D(latitude: mapLatitude, longitude: mapLongitude)
    }

    // Shortest reading — the first destination/time pair — for marker tooltips
    // and the map status text.
    var headline: String? {
        guard let line = lines.first,
              let destination = line.destination,
              let time = line.timeText else {
            return nil
        }
        return "\(destination) \(time)"
    }

    // All destination → time pairs joined for a compact one-line summary.
    var summary: String? {
        let parts = lines.compactMap { line -> String? in
            guard let destination = line.destination, let time = line.timeText else {
                return nil
            }
            return "\(destination) \(time)"
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    func matches(region selectedRegion: String, highway selectedHighway: String, search: String) -> Bool {
        matchesRegion(regionName, selectedRegion: selectedRegion)
            && matchesNeedle(selectedHighway, in: highwayHaystack)
            && matchesNeedle(search, in: searchHaystack)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case latitude
        case longitude
        case region
        case way
        case page
    }
}

struct TIMSignsPayload: Decodable {
    let response: TIMSignsResponse
}

struct TIMSignsResponse: Decodable {
    let tim: [TIMSign]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tim = container.decodeFlexibleArray(TIMSign.self, forKey: .tim)
    }

    private enum CodingKeys: String, CodingKey {
        case tim
    }
}

// /regions/all/10 → the 14 canonical NZTA regions. Only id/name are decoded
// (via the shared `Region` type); the per-region WKT POLYGON `geometry` is
// ignored — the region filter just needs stable, consistently-cased names.
struct RegionsPayload: Decodable {
    let response: RegionsResponse
}

struct RegionsResponse: Decodable {
    let region: [Region]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        region = container.decodeFlexibleArray(Region.self, forKey: .region)
    }

    private enum CodingKeys: String, CodingKey {
        case region
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
    let maxPowerKW: Double?
    let connectorTypes: [String]
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
        maxPowerKW = parsed.maxPowerKW
        connectorTypes = parsed.connectorTypes

        searchHaystack = searchableHaystack([
            nameValue,
            operatorValue,
            addressValue,
            currentTypeValue
        ] + parsed.connectorTypes)
    }

    var displayName: String {
        name ?? "EV Charger"
    }

    // "Mixed" sites carry both AC and DC; treat anything mentioning DC as
    // offering fast charging for the marker tint/legend.
    var isDC: Bool {
        (currentType ?? "").range(of: "DC", options: .caseInsensitive) != nil
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
            return value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
        }
        switch (cleanText(currentType), kw) {
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        features = container.decodeFlexibleArray(EVCharger.self, forKey: .features)
    }

    private enum CodingKeys: String, CodingKey {
        case features
    }
}

// The EV Roam feed packs every connector for a site into one string, e.g.
// "{DC, 75 kW, CHAdeMO, Status: Operative, Count:1},{DC, 50 kW, Type 2 CCS, …}".
// Pull out the highest advertised power (kW) and the distinct connector types
// (order-preserving, case-insensitively de-duplicated).
func parseEVConnectors(_ raw: String?) -> (maxPowerKW: Double?, connectorTypes: [String]) {
    guard let raw = cleanText(raw) else {
        return (nil, [])
    }

    var maxPowerKW: Double?
    var connectorTypes: [String] = []
    var seenTypes = Set<String>()

    let groups = raw
        .replacingOccurrences(of: "{", with: "")
        .components(separatedBy: "}")

    for group in groups {
        let fields = group
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !fields.isEmpty else {
            continue
        }

        // Layout: currentType, "<n> kW", connectorType, "Status: …", "Count:…".
        if fields.count >= 3 {
            let connectorType = fields[2]
            if !connectorType.isEmpty, seenTypes.insert(connectorType.lowercased()).inserted {
                connectorTypes.append(connectorType)
            }
        }

        for field in fields where field.range(of: "kw", options: .caseInsensitive) != nil {
            let number = field
                .replacingOccurrences(of: "kW", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = Double(number), value.isFinite {
                maxPowerKW = max(maxPowerKW ?? 0, value)
            }
        }
    }

    return (maxPowerKW, connectorTypes)
}

extension KeyedDecodingContainer {
    func decodeFlexibleArray<T: Decodable>(_ type: T.Type, forKey key: Key) -> [T] {
        if let array = try? decodeIfPresent([T].self, forKey: key) {
            return array
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
            if value.rounded() == value {
                return String(Int(value))
            }
            return String(value)
        }
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value ? "true" : "false"
        }
        return nil
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
        // Reject NaN/Infinity so every downstream consumer can trust the value
        // is finite (e.g. coordinate validation, Int conversion, formatting).
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
