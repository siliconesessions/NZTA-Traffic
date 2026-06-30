import Foundation

struct TrafficAPIService {
    // rest/5 is a drop-in superset of rest/4 (cameras/VMS/journeys identical
    // wrappers); road events additionally carry `direction`/`travelDirection`.
    private let baseURL = "https://trafficnz.info/service/traffic/rest/5"
    // EV Roam public charging stations (external NZTA ArcGIS host, GeoJSON).
    // Static reference data on a different host than the traffic API, so it is
    // fetched as an absolute URL with no cache-busting token. resultRecordCount
    // covers the full ~636-feature dataset in a single page.
    private let evChargersURL = "https://services.arcgis.com/CXBb7LAjgIIdcsPt/arcgis/rest/services/EV_Roam_charging_stations/FeatureServer/0/query?where=1=1&outFields=*&outSR=4326&f=geojson&resultRecordCount=2000"
    // Auckland motorway congestion conditions. This is the one NZTA endpoint
    // that serves application/xml rather than JSON, so it is fetched as raw Data
    // and decoded with an XMLParser (CongestionXMLParser) instead of JSONDecoder.
    private let congestionURL = "https://trafficnz.info/service/traffic-conditions/rest/2"
    private let session: URLSession
    private let decoder: JSONDecoder

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 120
            configuration.httpMaximumConnectionsPerHost = 6
            configuration.waitsForConnectivity = true
            configuration.httpShouldSetCookies = false
            self.session = URLSession(configuration: configuration)
        }
        decoder = JSONDecoder()
    }

    // The four offline-cacheable JSON sections surface their raw response bytes
    // alongside the decoded value so the store can persist the exact JSON to disk
    // (see TrafficStore.OfflineCache). The same bytes are later re-decoded via the
    // `decodeCached…` helpers through these identical payload wrappers.
    func fetchCameras() async throws -> (value: [TrafficCamera], data: Data) {
        let data = try await requestData(baseURL + "/cameras/all", accept: "application/json")
        return (try decodePayload(CamerasPayload.self, from: data).response.camera, data)
    }

    func fetchRoadEvents() async throws -> (value: [RoadEvent], data: Data) {
        let data = try await requestData(baseURL + "/events/all/10", accept: "application/json")
        return (try decodePayload(RoadEventsPayload.self, from: data).response.roadevent, data)
    }

    func fetchVMSSigns() async throws -> (value: [VMSSign], data: Data) {
        let data = try await requestData(baseURL + "/signs/vms/all", accept: "application/json")
        return (try decodePayload(VMSPayload.self, from: data).response.vms, data)
    }

    func fetchJourneys() async throws -> (value: [TrafficJourney], data: Data) {
        let data = try await requestData(baseURL + "/journeys/all/10", accept: "application/json")
        return (try decodePayload(JourneysPayload.self, from: data).response.journey, data)
    }

    // Re-decode persisted section bytes for offline replay, off the main actor.
    // Returns nil when the cached JSON no longer parses (e.g. the API shape
    // changed since it was written) so the caller can quietly skip that section.
    nonisolated func decodeCachedCameras(_ data: Data) async -> [TrafficCamera]? {
        try? decoder.decode(CamerasPayload.self, from: data).response.camera
    }

    nonisolated func decodeCachedRoadEvents(_ data: Data) async -> [RoadEvent]? {
        try? decoder.decode(RoadEventsPayload.self, from: data).response.roadevent
    }

    nonisolated func decodeCachedVMSSigns(_ data: Data) async -> [VMSSign]? {
        try? decoder.decode(VMSPayload.self, from: data).response.vms
    }

    nonisolated func decodeCachedJourneys(_ data: Data) async -> [TrafficJourney]? {
        try? decoder.decode(JourneysPayload.self, from: data).response.journey
    }

    func fetchTIMSigns() async throws -> [TIMSign] {
        let payload: TIMSignsPayload = try await request("/signs/tim/all")
        return payload.response.tim
    }

    func fetchRegions() async throws -> [Region] {
        let payload: RegionsPayload = try await request("/regions/all/10")
        return payload.response.region
    }

    func fetchEVChargers() async throws -> [EVCharger] {
        let payload: EVChargersPayload = try await requestAbsolute(evChargersURL)
        return payload.features
    }

    func fetchCongestion() async throws -> [CongestionSegment] {
        let data = try await requestData(congestionURL, accept: "application/xml")
        guard let segments = CongestionXMLParser.parse(data) else {
            let prefix = String(data: Data(data.prefix(180)), encoding: .utf8) ?? "unreadable response"
            throw TrafficAPIError.decoding("Unable to parse congestion XML", prefix)
        }
        return segments
    }

    // These entry points are `nonisolated` so that, when called from the
    // @MainActor `TrafficStore`, the network fetch and (notably) the JSON
    // decode of large payloads run on the cooperative thread pool rather than
    // blocking the main thread.
    nonisolated func fetchCamerasResult() async -> Result<(value: [TrafficCamera], data: Data), Error> {
        await result { try await fetchCameras() }
    }

    nonisolated func fetchRoadEventsResult() async -> Result<(value: [RoadEvent], data: Data), Error> {
        await result { try await fetchRoadEvents() }
    }

    nonisolated func fetchVMSSignsResult() async -> Result<(value: [VMSSign], data: Data), Error> {
        await result { try await fetchVMSSigns() }
    }

    nonisolated func fetchJourneysResult() async -> Result<(value: [TrafficJourney], data: Data), Error> {
        await result { try await fetchJourneys() }
    }

    nonisolated func fetchTIMSignsResult() async -> Result<[TIMSign], Error> {
        await result { try await fetchTIMSigns() }
    }

    nonisolated func fetchRegionsResult() async -> Result<[Region], Error> {
        await result { try await fetchRegions() }
    }

    nonisolated func fetchEVChargersResult() async -> Result<[EVCharger], Error> {
        await result { try await fetchEVChargers() }
    }

    nonisolated func fetchCongestionResult() async -> Result<[CongestionSegment], Error> {
        await result { try await fetchCongestion() }
    }

    nonisolated private func request<T: Decodable>(_ path: String) async throws -> T {
        try await requestAbsolute(baseURL + path)
    }

    nonisolated private func requestAbsolute<T: Decodable>(_ urlString: String) async throws -> T {
        guard let url = URL(string: urlString) else {
            throw TrafficAPIError.invalidURL(urlString)
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("NZTA Traffic macOS", forHTTPHeaderField: "User-Agent")

        // Retry transient failures (transport errors, 5xx) with exponential
        // backoff: 1s, 2s before the final attempt. Non-transient errors
        // (4xx, decoding) fail immediately.
        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            do {
                return try await performRequest(urlRequest)
            } catch let error as TrafficAPIError where error.isRetriable && attempt < maxAttempts {
                try? await Task.sleep(for: .seconds(pow(2.0, Double(attempt - 1))))
            }
        }
        throw TrafficAPIError.transport("Exhausted \(maxAttempts) attempts")
    }

    // Raw-Data variant of requestAbsolute for non-JSON endpoints (the XML
    // congestion feed). Shares the same retry/backoff and status-code handling;
    // the caller is responsible for parsing the returned bytes.
    nonisolated private func requestData(_ urlString: String, accept: String) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw TrafficAPIError.invalidURL(urlString)
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue(accept, forHTTPHeaderField: "Accept")
        urlRequest.setValue("NZTA Traffic macOS", forHTTPHeaderField: "User-Agent")

        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            do {
                return try await performDataRequest(urlRequest)
            } catch let error as TrafficAPIError where error.isRetriable && attempt < maxAttempts {
                try? await Task.sleep(for: .seconds(pow(2.0, Double(attempt - 1))))
            }
        }
        throw TrafficAPIError.transport("Exhausted \(maxAttempts) attempts")
    }

    nonisolated private func performDataRequest(_ urlRequest: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw TrafficAPIError.transport(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TrafficAPIError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw TrafficAPIError.httpStatus(httpResponse.statusCode)
        }

        guard !data.isEmpty else {
            throw TrafficAPIError.emptyResponse
        }

        return data
    }

    nonisolated private func performRequest<T: Decodable>(_ urlRequest: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw TrafficAPIError.transport(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TrafficAPIError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw TrafficAPIError.httpStatus(httpResponse.statusCode)
        }

        guard !data.isEmpty else {
            throw TrafficAPIError.emptyResponse
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            let prefix = String(data: Data(data.prefix(180)), encoding: .utf8) ?? "unreadable response"
            throw TrafficAPIError.decoding(error.localizedDescription, prefix)
        }
    }

    // Decode raw bytes that were fetched separately (the cacheable JSON sections
    // go through requestData so they can also persist the bytes), wrapping decode
    // failures the same way performRequest does.
    nonisolated private func decodePayload<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            let prefix = String(data: Data(data.prefix(180)), encoding: .utf8) ?? "unreadable response"
            throw TrafficAPIError.decoding(error.localizedDescription, prefix)
        }
    }

    private func result<T>(_ operation: () async throws -> T) async -> Result<T, Error> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(error)
        }
    }
}

enum TrafficAPIError: LocalizedError {
    case invalidURL(String)
    case invalidResponse
    case httpStatus(Int)
    case emptyResponse
    case transport(String)
    case decoding(String, String)

    /// Transient failures worth retrying: connectivity/transport problems and
    /// server-side 5xx responses. Client errors and decoding failures are not.
    var isRetriable: Bool {
        switch self {
        case .transport:
            return true
        case .httpStatus(let status):
            return status >= 500
        default:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid NZTA API URL: \(url)"
        case .invalidResponse:
            return "NZTA API returned a non-HTTP response."
        case .httpStatus(let status):
            return "NZTA API returned HTTP \(status)."
        case .emptyResponse:
            return "NZTA API returned an empty response."
        case .transport(let message):
            return "Unable to reach NZTA API: \(message)"
        case .decoding(let message, let prefix):
            return "Unable to read NZTA API JSON: \(message). Response began with: \(prefix)"
        }
    }
}
