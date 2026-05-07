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
        validatedCoordinate(latitude: latitude, longitude: longitude)
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
    let region: Region?
    let journey: Journey?
    let journeyLeg: JourneyLeg?
    let way: Way?
    let geometryLatitude: Double?
    let geometryLongitude: Double?
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
        validatedCoordinate(latitude: latitude, longitude: longitude)
            ?? validatedCoordinate(latitude: geometryLatitude, longitude: geometryLongitude)
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
        validatedCoordinate(latitude: latitude, longitude: longitude)
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

func coordinateFromWKTGeometry(_ geometry: String?) -> CLLocationCoordinate2D? {
    guard let geometry = cleanText(geometry) else {
        return nil
    }

    let pattern = #"(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\s+(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
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

private let nzInputDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_NZ")
    formatter.dateFormat = "dd/MM/yyyy HH:mm"
    return formatter
}()

private let nzDisplayDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_NZ")
    formatter.dateFormat = "d MMM, h:mm a"
    return formatter
}()

func formatTrafficDate(_ rawValue: String?) -> String? {
    guard let rawValue = cleanText(rawValue) else {
        return nil
    }

    let date = isoFractionalDateFormatter.date(from: rawValue)
        ?? isoDateFormatter.date(from: rawValue)
        ?? nzInputDateFormatter.date(from: rawValue)

    guard let date else {
        return rawValue
    }

    return nzDisplayDateFormatter.string(from: date)
}

func matchesRegion(_ itemRegion: String?, selectedRegion: String) -> Bool {
    let selected = selectedRegion.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !selected.isEmpty else {
        return true
    }

    return (itemRegion ?? "").caseInsensitiveCompare(selected) == .orderedSame
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

func parseWKTLineStringCoords(_ wkt: String?) -> (latitudes: [Double], longitudes: [Double]) {
    guard let wkt = cleanText(wkt), !wkt.isEmpty else {
        return ([], [])
    }
    let pattern = #"(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\s+(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
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
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    func decodeLossyInt(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return Int(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}
