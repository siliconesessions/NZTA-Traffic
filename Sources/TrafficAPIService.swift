import Foundation

struct TrafficAPIService {
    private let baseURL = "https://trafficnz.info/service/traffic/rest/4"
    private let session: URLSession
    private let decoder: JSONDecoder

    init(session: URLSession = .shared) {
        self.session = session
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

    func fetchCamerasResult() async -> Result<[TrafficCamera], Error> {
        await result { try await fetchCameras() }
    }

    func fetchRoadEventsResult() async -> Result<[RoadEvent], Error> {
        await result { try await fetchRoadEvents() }
    }

    func fetchVMSSignsResult() async -> Result<[VMSSign], Error> {
        await result { try await fetchVMSSigns() }
    }

    private func request<T: Decodable>(_ path: String) async throws -> T {
        guard let url = URL(string: baseURL + path) else {
            throw TrafficAPIError.invalidURL(baseURL + path)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("NZTA Traffic macOS", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
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
