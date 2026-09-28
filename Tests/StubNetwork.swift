import Foundation
import Synchronization

// In-process HTTP stub for the API service and store tests: every request made
// through `makeStubSession()` is answered from a route table instead of the
// network, and logged. Routes match a substring of the URL; each route plays
// its responses in order and then repeats the last one. Unmatched URLs get a
// 404. The tests run sequentially, so the table is simply reset per test.
struct StubResponse: Sendable {
    var status = 200
    var body = Data()
    /// Fail with this URLError instead of answering.
    var failure: URLError.Code?
    /// Seconds before answering.
    var delay: Double = 0
    /// Never answer (until the request is cancelled).
    var hangs = false

    static func json(_ text: String, delay: Double = 0) -> StubResponse {
        StubResponse(body: Data(text.utf8), delay: delay)
    }

    static func status(_ status: Int) -> StubResponse {
        StubResponse(status: status, body: Data("error".utf8))
    }

    static func failing(_ code: URLError.Code, delay: Double = 0) -> StubResponse {
        StubResponse(failure: code, delay: delay)
    }

    static let hanging = StubResponse(hangs: true)
}

struct StubRequest: Sendable {
    let url: String
    let userAgent: String?
}

enum StubServer {
    private struct Route {
        let match: String
        var responses: [StubResponse]
    }

    private struct State {
        var routes: [Route] = []
        var log: [StubRequest] = []
    }

    private static let state = Mutex(State())

    static func reset() {
        state.withLock { $0 = State() }
    }

    /// Adds (or replaces) the route for URLs containing `match`.
    static func route(_ match: String, _ responses: StubResponse...) {
        state.withLock { state in
            state.routes.removeAll { $0.match == match }
            state.routes.append(Route(match: match, responses: responses))
        }
    }

    static func requests(matching match: String = "") -> [StubRequest] {
        state.withLock { state in
            state.log.filter { match.isEmpty || $0.url.contains(match) }
        }
    }

    static func requestCount(_ match: String = "") -> Int {
        requests(matching: match).count
    }

    static func clearLog() {
        state.withLock { $0.log.removeAll() }
    }

    fileprivate static func respond(to request: URLRequest) -> StubResponse {
        let url = request.url?.absoluteString ?? ""
        return state.withLock { state in
            state.log.append(StubRequest(url: url, userAgent: request.value(forHTTPHeaderField: "User-Agent")))
            // The longest matching route wins, so "rest/4/cameras" beats "cameras".
            guard let index = state.routes.indices
                .filter({ url.contains(state.routes[$0].match) })
                .max(by: { state.routes[$0].match.count < state.routes[$1].match.count }) else {
                return .status(404)
            }
            let responses = state.routes[index].responses
            guard let first = responses.first else {
                return .status(404)
            }
            if responses.count > 1 {
                state.routes[index].responses.removeFirst()
            }
            return first
        }
    }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private let stopped = Mutex(false)

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = StubServer.respond(to: request)
        guard !response.hangs else {
            return
        }
        if response.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + response.delay) {
                self.deliver(response)
            }
        } else {
            deliver(response)
        }
    }

    override func stopLoading() {
        stopped.withLock { $0 = true }
    }

    private func deliver(_ response: StubResponse) {
        guard !stopped.withLock({ $0 }), let url = request.url else {
            return
        }
        if let failure = response.failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        guard let http = HTTPURLResponse(
            url: url,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

func makeStubSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    configuration.urlCache = nil
    return URLSession(configuration: configuration)
}

/// A service on the stub session that retries without sleeping.
func makeStubService(maxAttempts: Int = 3) -> TrafficAPIService {
    TrafficAPIService(
        session: makeStubSession(),
        userAgent: "NZTraffic-Tests",
        retryPolicy: RetryPolicy(maxAttempts: maxAttempts, baseDelay: .zero)
    )
}

/// A fresh, empty folder under the temporary directory (never the user's
/// Application Support); remove it with `removeTemporaryFolder`.
func makeTemporaryFolder() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("nz-traffic-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func removeTemporaryFolder(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

/// Polls `condition` on the main actor until it holds or `timeout` passes.
@MainActor
func waitUntil(timeout: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            return false
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

// Trimmed real records (2026-09-26 rest/5 snapshots), shaped exactly like the
// live responses. `camerasLive` differs from `cameras` so a test can tell a
// live fetch from a cache replay.
enum StubFixtures {
    static let cameras = #"""
    {"response":{"camera":[
    {"id":653,"name":"SH20 May Rd Overbridge","description":"North along Sth Wstn Mwy from May Rd","direction":"Northbound","highway":"SH20","imageUrl":"/camera/653.jpg","thumbUrl":"/camera/thumb/653.jpg","latitude":-36.90943,"longitude":174.73442,"offline":false,"underMaintenance":false,"sortOrder":20,"region":{"id":2,"name":"Auckland"},"way":{"id":54,"name":"020"}},
    {"id":812,"name":"Otaki Main Highway","description":"Looking south, north of the Mill Road/Main Highway roundabout.","direction":"Southbound","highway":"Old SH1","latitude":-40.75959,"longitude":175.15858,"offline":false,"underMaintenance":false,"sortOrder":0,"region":{"id":9,"name":"Wellington"},"way":{"id":1270,"name":"01P"}},
    {"id":831,"name":"SH1 Tinwald North","description":"North along Hinds Highway from Lagmhor Rd","direction":"Northbound","highway":"SH1","latitude":-43.919508,"longitude":171.721221,"offline":true,"underMaintenance":false,"region":{"id":11,"name":"Canterbury"},"way":{"id":805,"name":"01S"}}
    ]}}
    """#

    static let camerasLive = #"""
    {"response":{"camera":[
    {"id":653,"name":"SH20 May Rd Overbridge","description":"North along Sth Wstn Mwy from May Rd","direction":"Northbound","highway":"SH20","imageUrl":"/camera/653.jpg","thumbUrl":"/camera/thumb/653.jpg","latitude":-36.90943,"longitude":174.73442,"offline":false,"underMaintenance":false,"sortOrder":20,"region":{"id":2,"name":"Auckland"},"way":{"id":54,"name":"020"}},
    {"id":812,"name":"Otaki Main Highway","description":"Looking south, north of the Mill Road/Main Highway roundabout.","direction":"Southbound","highway":"Old SH1","latitude":-40.75959,"longitude":175.15858,"offline":false,"underMaintenance":false,"sortOrder":0,"region":{"id":9,"name":"Wellington"},"way":{"id":1270,"name":"01P"}}
    ]}}
    """#

    static let emptyCameras = #"{"response":{"camera":[]}}"#

    // An active closure (no end date), an active delay ending 1 Oct 2026, and
    // a resolved closure whose end date passed long ago.
    static let events = #"""
    {"response":{"roadevent":[
    {"id":561700,"eventDescription":"Snow","eventType":"Area Warning","impact":"Road Closed","status":"Active","planned":false,"eventIsland":"South Island","direction":"Both Directions","locationArea":"SH 94 Hollyford Road Junction to Donne River Bridge","eventComments":"Road CLOSED due to snow forecast overnight.","expectedResolution":"Until further notice","startDate":"2026-09-26T07:54:00+12:00","eventModified":"2026-09-26T17:14:58.040+12:00","geometry":"MULTILINESTRING ((168.09201 -44.81359, 168.0085 -44.77754, 167.9702 -44.70473))","region":{"id":14,"name":"Southland"},"way":{"id":1150,"name":"094"}},
    {"id":560046,"eventDescription":"Resurfacing","eventType":"Area Warning","impact":"Delays","status":"Active","planned":true,"eventIsland":"South Island","direction":"Both Directions","locationArea":"SH 88 Port Chalmers, between Wickliffe Terrace and Station Road","eventComments":"Temporary traffic signals in place at all times.","expectedResolution":"Until further notice","startDate":"2026-09-14T18:00:00+12:00","endDate":"2099-10-01T00:00:00+13:00","eventModified":"2026-09-25T08:48:55.300+12:00","geometry":"MULTILINESTRING ((170.60882 -45.82017, 170.61807 -45.81806))","region":{"id":13,"name":"Otago"},"way":{"id":1101,"name":"088"}},
    {"id":559001,"eventDescription":"Crash","eventType":"Crash","impact":"Road Closed","status":"Resolved","planned":false,"eventIsland":"North Island","direction":"Both Directions","locationArea":"SH 1 Bombay Hills","eventComments":"Road has reopened.","startDate":"2020-01-01T07:00:00+13:00","endDate":"2020-01-01T09:30:00+13:00","eventModified":"2020-01-01T09:31:00.000+13:00","geometry":"POINT (175.17 -37.18)","region":{"id":2,"name":"Auckland"},"way":{"id":1,"name":"01N"}}
    ]}}
    """#

    // `events` minus the SH94 closure: the active delay only.
    static let eventsWithoutClosure = #"""
    {"response":{"roadevent":[
    {"id":560046,"eventDescription":"Resurfacing","eventType":"Area Warning","impact":"Delays","status":"Active","planned":true,"eventIsland":"South Island","direction":"Both Directions","locationArea":"SH 88 Port Chalmers, between Wickliffe Terrace and Station Road","eventComments":"Temporary traffic signals in place at all times.","expectedResolution":"Until further notice","startDate":"2026-09-14T18:00:00+12:00","endDate":"2099-10-01T00:00:00+13:00","eventModified":"2026-09-25T08:48:55.300+12:00","geometry":"MULTILINESTRING ((170.60882 -45.82017, 170.61807 -45.81806))","region":{"id":13,"name":"Otago"},"way":{"id":1101,"name":"088"}}
    ]}}
    """#

    static let vms = #"""
    {"response":{"vms":[
    {"id":1,"name":"SH59 Acheron T2 - Southbound","description":"SH59 Acheron T2 - Southbound","direction":"Southbound","currentMessage":"CLEARWAY[nl]NOT[nl]OPERATING","lastMessageUpdate":"2026-09-26T14:00:14.720+12:00","lastUpdate":"2026-09-26T17:29:14.757+12:00","latitude":-41.091524,"longitude":174.86814,"region":{"id":9,"name":"Wellington"},"way":{"id":1221,"name":"059"}}
    ]}}
    """#

    static let tim = #"""
    {"response":{"tim":[
    {"id":334,"enabled":1,"latitude":-36.999703891113,"longitude":174.78803381495,"mode":"AUTOMATIC","name":"12 Auckland Airport to Auckland City Centre","virtual":false,"way":{"id":"20A","name":"20A"},"region":{"id":2,"name":"Auckland"},"page":{"line":[{"center":"VIA SH20  R12"},{"left":"SH1 GILLIES","right":27},{"left":"CITY CENTRE","right":32}],"pageTime":5}}
    ]}}
    """#

    static let journeys = #"""
    {"response":{"journey":[
    {"id":87,"name":"SH71","geometry":"MULTILINESTRING ((172.6480065582912 -43.37498338432014, 172.60235348089023 -43.32926975913654), (172.60235348089023 -43.32926975913654, 172.6480065582912 -43.37498338432014))","totalLength":12.727922259582673,"startLatitude":-43.37498338432014,"startLongitude":172.6480065582912,"endLatitude":-43.37498338432014,"endLongitude":172.6480065582912,"time":"00:09:10","ways":{"id":"071","name":"071"},"regions":{"id":11,"name":"Canterbury"},"legs":[
    {"name":"Kaiapoi to Rangiora","geometry":"LINESTRING (172.6480065582912 -43.37498338432014, 172.60235348089023 -43.32926975913654)","totalLength":6.363961129791336,"speed":78,"way":{"id":821,"name":"071"},"sequenceNumber":0,"direction":"I","time":"00:04:50","effectiveSpeedLimit":100,"coverage":90,"flow":80,"freeFlowTime":229},
    {"name":"Rangiora to Kaiapoi","geometry":"LINESTRING (172.60235348089023 -43.32926975913654, 172.6480065582912 -43.37498338432014)","totalLength":6.3639611297913365,"speed":88,"way":{"id":822,"name":"071"},"sequenceNumber":0,"direction":"D","time":"00:04:20","effectiveSpeedLimit":100,"coverage":90,"flow":95,"freeFlowTime":229}
    ]}
    ]}}
    """#

    static let regions = #"""
    {"response":{"region":[{"id":2,"name":"Auckland"},{"id":9,"name":"Wellington"},{"id":11,"name":"Canterbury"},{"id":13,"name":"Otago"},{"id":14,"name":"Southland"}]}}
    """#

    static let evChargers = #"""
    {"type":"FeatureCollection","features":[
    {"type":"Feature","id":712990,"geometry":{"type":"Point","coordinates":[174.912617279991,-36.9648860419307]},"properties":{"OBJECTID":712990,"name":"Ormiston Town Centre","operator":"Todd Property Ormiston Town Centre Limited","address":"240 Ormiston road, Flat Bush, Auckland, 2012, New Zealand","is24Hours":"True","carParkCount":14,"hasCarparkCost":"False","maxTimeLimit":"Unlimited","latitude":-36.9648860428412,"longitude":174.912617279983,"currentType":"AC","numberOfConnectors":14,"connectorsList":"{AC, 32 kW, Type 2 Socketed, Status: Operative, Count:9}","hasChargingCost":"False","GlobalID":"4e79b7b0-9a73-45ca-b183-e0dac0f4f1dd"}}
    ]}
    """#

    static let congestionXML = #"""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?><tns:getTrafficConditionsResponse xmlns:tns="https://infoconnect.highwayinfo.govt.nz/schemas/traffic2"><tns:trafficConditions><tns:lastUpdated>2026-09-26T17:29:19.066+12:00</tns:lastUpdated><tns:motorways><tns:name>Northern Motorway</tns:name><tns:locations><tns:congestion>Free Flow</tns:congestion><tns:direction>Southbound</tns:direction><tns:endLat>-36.7506902724442</tns:endLat><tns:endLon>174.726003398276</tns:endLon><tns:id>2</tns:id><tns:inOut>In</tns:inOut><tns:name>Oteha Valley Rd - Upper Harb Hwy</tns:name><tns:order>1</tns:order><tns:startLat>-36.7183869853163</tns:startLat><tns:startLon>174.712619564421</tns:startLon></tns:locations></tns:motorways></tns:trafficConditions></tns:getTrafficConditionsResponse>
    """#

    /// Routes every endpoint the store calls to a working response.
    static func routeAllEndpoints(delay: Double = 0, journeysDelay: Double? = nil, cameras: String = camerasLive) {
        StubServer.route("/cameras/all", .json(cameras, delay: delay))
        StubServer.route("/events/all/10", .json(events, delay: delay))
        StubServer.route("/signs/vms/all", .json(vms, delay: delay))
        StubServer.route("/signs/tim/all", .json(tim, delay: delay))
        StubServer.route("/journeys/all/10", .json(journeys, delay: journeysDelay ?? delay))
        StubServer.route("/regions/all/10", .json(regions, delay: delay))
        StubServer.route("services.arcgis.com", .json(evChargers, delay: delay))
        StubServer.route("traffic-conditions/rest/2", .json(congestionXML, delay: delay))
    }

    /// Makes every traffic endpoint fail with `code` (EV and regions too).
    static func failAllEndpoints(_ code: URLError.Code) {
        for match in ["/cameras/all", "/events/all/10", "/signs/vms/all", "/signs/tim/all", "/journeys/all/10",
                      "/regions/all/10", "services.arcgis.com", "traffic-conditions/rest/2"] {
            StubServer.route(match, .failing(code))
        }
    }
}
