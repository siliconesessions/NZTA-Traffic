import Foundation

struct TrafficAPIService {
    // rest/5 is a drop-in superset of rest/4 (cameras/VMS/journeys identical
    // wrappers); road events additionally carry `direction`/`travelDirection`.
    private let baseURL = "https://trafficnz.info/service/traffic/rest/5"
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

    func fetchCameras() async throws -> [TrafficCamera] {
        let payload: CamerasPayload = try await request("/cameras/all")
        return payload.response.camera
    }

    func fetchRoadEvents() async throws -> [RoadEvent] {
        let payload: RoadEventsPayload = try await request("/events/all/10")
        return payload.response.roadevent
    }

    func fetchVMSSigns() async throws -> [VMSSign] {
        let payload: VMSPayload = try await request("/signs/vms/all")
        return payload.response.vms
    }

    func fetchJourneys() async throws -> [TrafficJourney] {
        let payload: JourneysPayload = try await request("/journeys/all/10")
        return payload.response.journey
    }

    func fetchRegions() async throws -> [Region] {
        let payload: RegionsPayload = try await request("/regions/all/10")
        return payload.response.region
    }

    // These entry points are `nonisolated` so that, when called from the
    // @MainActor `TrafficStore`, the network fetch and (notably) the JSON
    // decode of large payloads run on the cooperative thread pool rather than
    // blocking the main thread.
    nonisolated func fetchCamerasResult() async -> Result<[TrafficCamera], Error> {
        await result { try await fetchCameras() }
    }

    nonisolated func fetchRoadEventsResult() async -> Result<[RoadEvent], Error> {
        await result { try await fetchRoadEvents() }
    }

    nonisolated func fetchVMSSignsResult() async -> Result<[VMSSign], Error> {
        await result { try await fetchVMSSigns() }
    }

    nonisolated func fetchJourneysResult() async -> Result<[TrafficJourney], Error> {
        await result { try await fetchJourneys() }
    }

    nonisolated func fetchRegionsResult() async -> Result<[Region], Error> {
        await result { try await fetchRegions() }
    }

    nonisolated private func request<T: Decodable>(_ path: String) async throws -> T {
        guard let url = URL(string: baseURL + path) else {
            throw TrafficAPIError.invalidURL(baseURL + path)
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
