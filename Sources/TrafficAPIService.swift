import Foundation
import Synchronization

/// One section's fetch: the decoded entries, the raw response bytes (the
/// offline cache persists these for the four cacheable sections), their
/// digest (so the store can spot an unchanged feed), and how many unreadable
/// entries the lenient decode skipped.
struct SectionFetch<Element> {
    let value: [Element]
    let data: Data
    let digest: ContentDigest
    let dropped: Int

    init(value: [Element], data: Data, dropped: Int) {
        self.value = value
        self.data = data
        digest = ContentDigest(of: data)
        self.dropped = dropped
    }
}

extension SectionFetch: Sendable where Element: Sendable {}

// Decoded entries plus skipped-entry count, for the fetch-once EV layer.
typealias LenientFetch<Element> = (value: [Element], dropped: Int)

/// Retry schedule for transient failures (see `TrafficAPIError.isRetriable`):
/// up to three attempts, waiting 1 s then 2 s. Injectable so tests don't sleep.
struct RetryPolicy: Sendable {
    var maxAttempts = 3
    var baseDelay: Duration = .seconds(1)

    static let standard = RetryPolicy()

    /// The wait after failed attempt `attempt` (1-based): base, 2×base, …
    func delay(afterAttempt attempt: Int) -> Duration {
        baseDelay * (1 << max(0, attempt - 1))
    }
}

/// The traffic endpoints that fell back from the undocumented rest/5 to the
/// documented rest/4 this session. Shared by every copy of the service (it is
/// a struct), and remembered so later requests go straight to rest/4.
final class APIVersionFallback: Sendable {
    private let legacyPaths = Mutex<Set<String>>([])

    /// rest/5 is undocumented; if it disappears (404/410) the same path is
    /// tried once on rest/4, which NZTA documents. Other failures don't count.
    static func shouldFallBack(afterStatus status: Int) -> Bool {
        status == 404 || status == 410
    }

    func usesLegacy(_ path: String) -> Bool {
        legacyPaths.withLock { $0.contains(path) }
    }

    func markLegacy(_ path: String) {
        legacyPaths.withLock { _ = $0.insert(path) }
    }

    /// The endpoint paths now served from rest/4, sorted (Export Diagnostics).
    var legacyEndpoints: [String] {
        legacyPaths.withLock { $0.sorted() }
    }
}

// A DecodingError's own explanation ("Expected "camera" but the response has
// "cameras"") says far more than its generic localizedDescription ("The data
// couldn't be read because it is missing.").
private func decodingFailureDescription(_ error: Error) -> String {
    guard let decodingError = error as? DecodingError else {
        return error.localizedDescription
    }
    switch decodingError {
    case .dataCorrupted(let context),
         .keyNotFound(_, let context),
         .typeMismatch(_, let context),
         .valueNotFound(_, let context):
        return context.debugDescription
    @unknown default:
        return error.localizedDescription
    }
}

struct TrafficAPIService {
    // rest/5 is a drop-in superset of rest/4 (cameras/VMS/journeys identical
    // wrappers); road events additionally carry `direction`/`travelDirection`.
    // NZTA only documents rest/4, so a 404/410 from rest/5 falls back to it
    // (see APIVersionFallback); the v5-only fields are optional in the models.
    static let baseURL = "https://trafficnz.info/service/traffic/rest/5"
    static let legacyBaseURL = "https://trafficnz.info/service/traffic/rest/4"
    // EV Roam public charging stations (external NZTA ArcGIS host, GeoJSON).
    // Static reference data on a different host than the traffic API, so it is
    // fetched as an absolute URL with no cache-busting token. resultRecordCount
    // covers the full ~636-feature dataset in a single page.
    static let evChargersURL = "https://services.arcgis.com/CXBb7LAjgIIdcsPt/arcgis/rest/services/EV_Roam_charging_stations/FeatureServer/0/query?where=1=1&outFields=*&outSR=4326&f=geojson&resultRecordCount=2000"
    // Auckland motorway congestion conditions. This is the one NZTA endpoint
    // that serves application/xml rather than JSON, so it is fetched as raw Data
    // and decoded with an XMLParser (CongestionXMLParser) instead of JSONDecoder.
    // No rest/4 fallback: it is a separate service and already fails soft.
    static let congestionURL = "https://trafficnz.info/service/traffic-conditions/rest/2"

    enum Path {
        static let cameras = "/cameras/all"
        static let events = "/events/all/10"
        static let vms = "/signs/vms/all"
        static let journeys = "/journeys/all/10"
        static let tim = "/signs/tim/all"
        static let regions = "/regions/all/10"
    }

    /// One feed the app reads, as listed in About and Help: what it is, the
    /// host it comes from, the URL (without query) and its format.
    struct DataSource: Sendable, Hashable {
        let title: String
        let url: String
        let format: String

        /// The host the request goes to, e.g. "trafficnz.info".
        var host: String {
            URL(string: url)?.host() ?? url
        }

        /// The URL without scheme or query, for display.
        var displayURL: String {
            let noScheme = url.replacingOccurrences(of: "https://", with: "")
            return noScheme.split(separator: "?", maxSplits: 1).first.map(String.init) ?? noScheme
        }
    }

    /// Every feed the app fetches, built from the same constants the requests
    /// use so the About and Help lists can't drift from the code.
    static let dataSources: [DataSource] = [
        DataSource(title: "Traffic cameras", url: baseURL + Path.cameras, format: "JSON"),
        DataSource(title: "Road events", url: baseURL + Path.events, format: "JSON"),
        DataSource(title: "Variable message signs", url: baseURL + Path.vms, format: "JSON"),
        DataSource(title: "Travel times (journeys)", url: baseURL + Path.journeys, format: "JSON"),
        DataSource(title: "Travel time signs (TIM)", url: baseURL + Path.tim, format: "JSON"),
        DataSource(title: "Regions", url: baseURL + Path.regions, format: "JSON"),
        DataSource(title: "Auckland motorway congestion", url: congestionURL, format: "XML"),
        DataSource(title: "EV charging stations (EV Roam, hosted on ArcGIS Online)", url: evChargersURL, format: "GeoJSON")
    ]

    /// The distinct hosts the app contacts for traffic data, in list order.
    static var dataHosts: [String] {
        var seen: Set<String> = []
        return dataSources.map(\.host).filter { seen.insert($0).inserted }
    }

    // The journeys endpoint computes for 14–17 s before its first byte, over
    // half the 30 s idle timeout the other requests use, so it gets longer.
    // (An explicit URLRequest timeout overrides the session's, even at 60.)
    static let journeysTimeout: TimeInterval = 60

    /// A per-request idle timeout for `path`, or nil for the session default.
    static func requestTimeout(for path: String) -> TimeInterval? {
        path == Path.journeys ? journeysTimeout : nil
    }

    private let session: URLSession
    private let decoder: JSONDecoder
    private let retryPolicy: RetryPolicy
    // Sent on every API request so the operator can attribute load to an app
    // version and find the project (see AppIdentity.userAgent). Set per request
    // rather than on the session so an injected (preview/test) session gets it
    // too.
    private let userAgent: String
    let versionFallback = APIVersionFallback()

    init(
        session: URLSession? = nil,
        userAgent: String = AppIdentity.userAgent(),
        retryPolicy: RetryPolicy = .standard
    ) {
        self.userAgent = userAgent
        self.retryPolicy = retryPolicy
        self.session = session ?? Self.makeSession()
        decoder = JSONDecoder()
    }

    // Fail fast rather than wait: with waitsForConnectivity a request to an
    // unreachable host (offline, DNS failure, captive portal) waited out the
    // whole resource timeout, three times over — about six minutes of a stuck
    // "Refreshing…". Offline is now handled up front (the store serves saved
    // data and reloads when NWPathMonitor reports the network back).
    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }

    // Every fetch returns the raw response bytes alongside the decoded value,
    // so the store can persist the exact JSON of the four cacheable sections
    // (see OfflineCache) and skip re-applying a feed whose bytes haven't
    // changed. Persisted bytes are later re-decoded via the `decodeCached…`
    // helpers through these identical payload wrappers. `dropped` counts
    // unreadable entries the lenient decode skipped (Export Diagnostics); a
    // structurally broken response throws instead (see decodeSectionList).
    // Every async entry point in this type is `@concurrent` so decoding never
    // runs on the caller's (main) actor — see the note above `fetchCamerasResult()`.
    @concurrent nonisolated func fetchCameras() async throws -> SectionFetch<TrafficCamera> {
        let data = try await requestTrafficData(Path.cameras)
        let response = try decodePayload(CamerasPayload.self, from: data).response
        return SectionFetch(value: response.camera, data: data, dropped: response.droppedCount)
    }

    @concurrent nonisolated func fetchRoadEvents() async throws -> SectionFetch<RoadEvent> {
        let data = try await requestTrafficData(Path.events)
        let response = try decodePayload(RoadEventsPayload.self, from: data).response
        return SectionFetch(value: response.roadevent, data: data, dropped: response.droppedCount)
    }

    @concurrent nonisolated func fetchVMSSigns() async throws -> SectionFetch<VMSSign> {
        let data = try await requestTrafficData(Path.vms)
        let response = try decodePayload(VMSPayload.self, from: data).response
        return SectionFetch(value: response.vms, data: data, dropped: response.droppedCount)
    }

    @concurrent nonisolated func fetchJourneys() async throws -> SectionFetch<TrafficJourney> {
        let data = try await requestTrafficData(Path.journeys)
        let response = try decodePayload(JourneysPayload.self, from: data).response
        return SectionFetch(value: response.journey, data: data, dropped: response.droppedCount)
    }

    // Re-decode persisted section bytes for offline replay, off the main actor
    // (`@concurrent`, see the note on the `…Result()` entry points below).
    // Returns nil when the cached JSON no longer parses (e.g. the API shape
    // changed since it was written) so the caller can quietly skip that section.
    @concurrent nonisolated func decodeCachedCameras(_ data: Data) async -> [TrafficCamera]? {
        try? decoder.decode(CamerasPayload.self, from: data).response.camera
    }

    @concurrent nonisolated func decodeCachedRoadEvents(_ data: Data) async -> [RoadEvent]? {
        try? decoder.decode(RoadEventsPayload.self, from: data).response.roadevent
    }

    @concurrent nonisolated func decodeCachedVMSSigns(_ data: Data) async -> [VMSSign]? {
        try? decoder.decode(VMSPayload.self, from: data).response.vms
    }

    @concurrent nonisolated func decodeCachedJourneys(_ data: Data) async -> [TrafficJourney]? {
        try? decoder.decode(JourneysPayload.self, from: data).response.journey
    }

    @concurrent nonisolated func fetchTIMSigns() async throws -> SectionFetch<TIMSign> {
        let data = try await requestTrafficData(Path.tim)
        let response = try decodePayload(TIMSignsPayload.self, from: data).response
        return SectionFetch(value: response.tim, data: data, dropped: response.droppedCount)
    }

    @concurrent nonisolated func fetchRegions() async throws -> [Region] {
        let data = try await requestTrafficData(Path.regions)
        return try decodePayload(RegionsPayload.self, from: data).response.region
    }

    @concurrent nonisolated func fetchEVChargers() async throws -> LenientFetch<EVCharger> {
        let data = try await requestData(Self.evChargersURL, accept: "application/json")
        let payload = try decodePayload(EVChargersPayload.self, from: data)
        return (payload.features, payload.droppedCount)
    }

    @concurrent nonisolated func fetchCongestion() async throws -> SectionFetch<CongestionSegment> {
        let data = try await requestData(Self.congestionURL, accept: "application/xml")
        guard let segments = CongestionXMLParser.parse(data) else {
            let prefix = String(data: Data(data.prefix(180)), encoding: .utf8) ?? "unreadable response"
            throw TrafficAPIError.decoding("Unable to parse congestion XML", prefix)
        }
        // The XML parser has no per-entry leniency to report.
        return SectionFetch(value: segments, data: data, dropped: 0)
    }

    // These entry points are `@concurrent` so that, when called from the
    // @MainActor `TrafficStore`, the network fetch and (notably) the decode of
    // multi-megabyte payloads always run on the cooperative thread pool rather
    // than blocking the main thread. Plain `nonisolated async` is not enough:
    // under NonisolatedNonsendingByDefault (part of Xcode's "Approachable
    // Concurrency") it would run on the caller's actor — i.e. the main actor.
    // A cancelled fetch comes back as `.failure(CancellationError())`, never
    // as a transport error (see performDataRequest).
    @concurrent nonisolated func fetchCamerasResult() async -> Result<SectionFetch<TrafficCamera>, Error> {
        await result { try await fetchCameras() }
    }

    @concurrent nonisolated func fetchRoadEventsResult() async -> Result<SectionFetch<RoadEvent>, Error> {
        await result { try await fetchRoadEvents() }
    }

    @concurrent nonisolated func fetchVMSSignsResult() async -> Result<SectionFetch<VMSSign>, Error> {
        await result { try await fetchVMSSigns() }
    }

    @concurrent nonisolated func fetchJourneysResult() async -> Result<SectionFetch<TrafficJourney>, Error> {
        await result { try await fetchJourneys() }
    }

    @concurrent nonisolated func fetchTIMSignsResult() async -> Result<SectionFetch<TIMSign>, Error> {
        await result { try await fetchTIMSigns() }
    }

    @concurrent nonisolated func fetchRegionsResult() async -> Result<[Region], Error> {
        await result { try await fetchRegions() }
    }

    @concurrent nonisolated func fetchEVChargersResult() async -> Result<LenientFetch<EVCharger>, Error> {
        await result { try await fetchEVChargers() }
    }

    @concurrent nonisolated func fetchCongestionResult() async -> Result<SectionFetch<CongestionSegment>, Error> {
        await result { try await fetchCongestion() }
    }

    // A traffic API path on rest/5, or on rest/4 once rest/5 has answered 404
    // or 410 for it this session (tried once per failure, then remembered).
    @concurrent nonisolated private func requestTrafficData(_ path: String) async throws -> Data {
        let timeout = Self.requestTimeout(for: path)
        if versionFallback.usesLegacy(path) {
            return try await requestData(Self.legacyBaseURL + path, accept: "application/json", timeout: timeout)
        }
        do {
            return try await requestData(Self.baseURL + path, accept: "application/json", timeout: timeout)
        } catch TrafficAPIError.httpStatus(let status) where APIVersionFallback.shouldFallBack(afterStatus: status) {
            let data = try await requestData(Self.legacyBaseURL + path, accept: "application/json", timeout: timeout)
            versionFallback.markLegacy(path)
            return data
        }
    }

    // GET with retry: transient failures (see `isRetriable`) are retried with
    // the policy's exponential backoff; anything else fails at once. The
    // caller parses the returned bytes.
    @concurrent nonisolated private func requestData(
        _ urlString: String,
        accept: String,
        timeout: TimeInterval? = nil
    ) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw TrafficAPIError.invalidURL(urlString)
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue(accept, forHTTPHeaderField: "Accept")
        urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let timeout {
            // Overrides the session's idle timeout for this request only.
            urlRequest.timeoutInterval = timeout
        }

        let maxAttempts = max(1, retryPolicy.maxAttempts)
        for attempt in 1...maxAttempts {
            try Task.checkCancellation()
            do {
                return try await performDataRequest(urlRequest)
            } catch let error as TrafficAPIError where error.isRetriable && attempt < maxAttempts {
                // A throwing sleep, so cancellation ends the retries at once.
                try await Task.sleep(for: retryPolicy.delay(afterAttempt: attempt))
            }
        }
        throw TrafficAPIError.transport(nil, "Exhausted \(maxAttempts) attempts")
    }

    @concurrent nonisolated private func performDataRequest(_ urlRequest: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError where error.code == .cancelled {
            // URLSession reports task cancellation as URLError.cancelled; it is
            // not a network failure and must not be retried or shown.
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            throw TrafficAPIError.transport(error.code, error.localizedDescription)
        } catch {
            throw TrafficAPIError.transport(nil, error.localizedDescription)
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

    // Decode raw bytes, wrapping decode failures with the DecodingError's own
    // explanation and the start of the response.
    nonisolated private func decodePayload<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            let prefix = String(data: Data(data.prefix(180)), encoding: .utf8) ?? "unreadable response"
            throw TrafficAPIError.decoding(decodingFailureDescription(error), prefix)
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

enum TrafficAPIError: LocalizedError, Equatable {
    case invalidURL(String)
    case invalidResponse
    case httpStatus(Int)
    case emptyResponse
    /// A URLSession failure, with its URLError code when there was one.
    case transport(URLError.Code?, String)
    case decoding(String, String)
    /// NWPathMonitor reports no network, so no request was sent.
    case offline

    // Failures a retry seconds later won't fix, or that already took a full
    // timeout: retrying them only kept Refresh disabled for minutes.
    private static let nonRetriableTransportCodes: Set<URLError.Code> = [
        .timedOut,
        .notConnectedToInternet,
        .cannotFindHost,
        .cannotConnectToHost,
        .dnsLookupFailed,
        .internationalRoamingOff,
        .dataNotAllowed,
        .callIsActive,
        .cancelled,
        .badURL,
        .unsupportedURL,
        .appTransportSecurityRequiresSecureConnection,
        .secureConnectionFailed,
        .serverCertificateUntrusted,
        .serverCertificateHasBadDate,
        .serverCertificateHasUnknownRoot,
        .serverCertificateNotYetValid,
        .clientCertificateRejected,
        .clientCertificateRequired,
        .userAuthenticationRequired
    ]

    /// Transient failures worth retrying: dropped connections and other
    /// transport hiccups, and server-side 5xx responses. Unreachable hosts,
    /// timeouts, being offline, client errors and decoding failures are not.
    var isRetriable: Bool {
        switch self {
        case .transport(let code, _):
            guard let code else {
                return true
            }
            return !Self.nonRetriableTransportCodes.contains(code)
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
        case .transport(_, let message):
            return "Unable to reach NZTA API: \(message)"
        case .decoding(let message, let prefix):
            return "Unable to read NZTA API JSON: \(message). Response began with: \(prefix)"
        case .offline:
            return "No internet connection. Showing the last data received; NZ Traffic reloads when you’re back online."
        }
    }
}
