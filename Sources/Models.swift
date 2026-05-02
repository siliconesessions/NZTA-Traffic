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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedId = container.decodeLossyString(forKey: .id)

        rawId = decodedId
        id = decodedId ?? container.decodeLossyString(forKey: .imageUrl) ?? UUID().uuidString
        name = cleanText(container.decodeLossyString(forKey: .name))
        description = cleanText(container.decodeLossyString(forKey: .description))
        direction = cleanText(container.decodeLossyString(forKey: .direction))
        group = cleanText(container.decodeLossyString(forKey: .group))
        highway = cleanText(container.decodeLossyString(forKey: .highway))
        imageUrl = cleanText(container.decodeLossyString(forKey: .imageUrl))
        thumbUrl = cleanText(container.decodeLossyString(forKey: .thumbUrl))
        viewUrl = cleanText(container.decodeLossyString(forKey: .viewUrl))
        latitude = container.decodeLossyDouble(forKey: .latitude)
        longitude = container.decodeLossyDouble(forKey: .longitude)
        offline = container.decodeLossyBool(forKey: .offline) ?? false
        underMaintenance = container.decodeLossyBool(forKey: .underMaintenance) ?? false
        sortOrder = container.decodeLossyInt(forKey: .sortOrder)
        region = try? container.decodeIfPresent(Region.self, forKey: .region)
        journey = try? container.decodeIfPresent(Journey.self, forKey: .journey)
        journeyLeg = try? container.decodeIfPresent(JourneyLeg.self, forKey: .journeyLeg)
        way = try? container.decodeIfPresent(Way.self, forKey: .way)
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
            && matchesHighway(selectedHighway, fields: [
                highway,
                journey?.name,
                way?.name,
                name,
                description
            ])
            && matchesSearch(search, fields: [
                name,
                description,
                highway,
                direction,
                region?.name
            ])
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
    let impact: String?
    let informationSource: String?
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedId = container.decodeLossyString(forKey: .id)

        rawId = decodedId
        id = decodedId ?? UUID().uuidString
        alternativeRoute = cleanText(container.decodeLossyString(forKey: .alternativeRoute))
        endDate = cleanText(container.decodeLossyString(forKey: .endDate))
        eventComments = cleanText(container.decodeLossyString(forKey: .eventComments))
        eventCreated = cleanText(container.decodeLossyString(forKey: .eventCreated))
        eventDescription = cleanText(container.decodeLossyString(forKey: .eventDescription))
        eventIsland = cleanText(container.decodeLossyString(forKey: .eventIsland))
        eventModified = cleanText(container.decodeLossyString(forKey: .eventModified))
        eventType = cleanText(container.decodeLossyString(forKey: .eventType))
        expectedResolution = cleanText(container.decodeLossyString(forKey: .expectedResolution))
        impact = cleanText(container.decodeLossyString(forKey: .impact))
        informationSource = cleanText(container.decodeLossyString(forKey: .informationSource))
        locationArea = cleanText(container.decodeLossyString(forKey: .locationArea))
        locations = cleanText(container.decodeLossyString(forKey: .locations))
        planned = container.decodeLossyBool(forKey: .planned)
        status = cleanText(container.decodeLossyString(forKey: .status))
        supplier = cleanText(container.decodeLossyString(forKey: .supplier))
        startDate = cleanText(container.decodeLossyString(forKey: .startDate))
        region = try? container.decodeIfPresent(Region.self, forKey: .region)
        journey = try? container.decodeIfPresent(Journey.self, forKey: .journey)
        journeyLeg = try? container.decodeIfPresent(JourneyLeg.self, forKey: .journeyLeg)
        way = try? container.decodeIfPresent(Way.self, forKey: .way)
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

    var severityRank: Int {
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
            && matchesHighway(selectedHighway, fields: [
                journey?.name,
                way?.name,
                locations,
                locationArea,
                eventDescription
            ])
            && matchesSearch(search, fields: [
                locationArea,
                locations,
                eventDescription,
                eventComments,
                alternativeRoute,
                eventType,
                region?.name
            ])
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
        case impact
        case informationSource
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedId = container.decodeLossyString(forKey: .id)

        rawId = decodedId
        id = decodedId ?? container.decodeLossyString(forKey: .identifier) ?? UUID().uuidString
        currentMessage = cleanText(container.decodeLossyString(forKey: .currentMessage))
        description = cleanText(container.decodeLossyString(forKey: .description))
        direction = cleanText(container.decodeLossyString(forKey: .direction))
        identifier = cleanText(container.decodeLossyString(forKey: .identifier))
        lastMessageUpdate = cleanText(container.decodeLossyString(forKey: .lastMessageUpdate))
        lastUpdate = cleanText(container.decodeLossyString(forKey: .lastUpdate))
        latitude = container.decodeLossyDouble(forKey: .latitude)
        longitude = container.decodeLossyDouble(forKey: .longitude)
        name = cleanText(container.decodeLossyString(forKey: .name))
        region = try? container.decodeIfPresent(Region.self, forKey: .region)
        journey = try? container.decodeIfPresent(Journey.self, forKey: .journey)
        journeyLeg = try? container.decodeIfPresent(JourneyLeg.self, forKey: .journeyLeg)
        way = try? container.decodeIfPresent(Way.self, forKey: .way)
    }

    var displayName: String {
        name ?? description ?? "VMS Sign"
    }

    var regionName: String? {
        region?.name
    }

    var formattedMessage: String {
        formatVMSMessage(currentMessage)
    }

    func matches(region selectedRegion: String, highway selectedHighway: String, search: String) -> Bool {
        matchesRegion(regionName, selectedRegion: selectedRegion)
            && matchesHighway(selectedHighway, fields: [
                journey?.name,
                way?.name,
                name,
                description
            ])
            && matchesSearch(search, fields: [
                name,
                description,
                formattedMessage,
                region?.name
            ])
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
    formatted = formatted.replacingOccurrences(of: "\r\n", with: "\n")
    formatted = formatted.replacingOccurrences(of: "\r", with: "\n")
    formatted = formatted
        .components(separatedBy: "\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .joined(separator: "\n")

    while formatted.contains("\n\n\n") {
        formatted = formatted.replacingOccurrences(of: "\n\n\n", with: "\n\n")
    }

    return cleanText(formatted) ?? "No message"
}

func formatTrafficDate(_ rawValue: String?) -> String? {
    guard let rawValue = cleanText(rawValue) else {
        return nil
    }

    let isoWithFractionalSeconds = ISO8601DateFormatter()
    isoWithFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]

    let dateFormatter = DateFormatter()
    dateFormatter.locale = Locale(identifier: "en_NZ")
    dateFormatter.dateFormat = "dd/MM/yyyy HH:mm"

    let date = isoWithFractionalSeconds.date(from: rawValue)
        ?? iso.date(from: rawValue)
        ?? dateFormatter.date(from: rawValue)

    guard let date else {
        return rawValue
    }

    let displayFormatter = DateFormatter()
    displayFormatter.locale = Locale(identifier: "en_NZ")
    displayFormatter.dateFormat = "d MMM, h:mm a"
    return displayFormatter.string(from: date)
}

func matchesRegion(_ itemRegion: String?, selectedRegion: String) -> Bool {
    let selected = selectedRegion.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !selected.isEmpty else {
        return true
    }

    return (itemRegion ?? "").caseInsensitiveCompare(selected) == .orderedSame
}

func matchesHighway(_ highway: String, fields: [String?]) -> Bool {
    let query = highway.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !query.isEmpty else {
        return true
    }

    return fields
        .compactMap(cleanText)
        .joined(separator: " ")
        .lowercased()
        .contains(query)
}

func matchesSearch(_ search: String, fields: [String?]) -> Bool {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !query.isEmpty else {
        return true
    }

    return fields
        .compactMap(cleanText)
        .joined(separator: " ")
        .lowercased()
        .contains(query)
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
