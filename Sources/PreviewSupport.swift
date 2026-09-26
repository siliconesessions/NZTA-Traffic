#if DEBUG
import Foundation

// SwiftUI preview support. A preview must never hit the live NZTA/ArcGIS
// endpoints or touch the user's real offline cache, so `TrafficStore.preview()`
// builds a store whose URLSession is answered in-process by
// `PreviewURLProtocol` (a small canned snapshot per endpoint, trimmed from real
// 2026 responses) and whose OfflineCache is disabled. Sample cameras carry no
// image URLs, so AsyncImage never fetches a JPEG either.
//
// Compiled only into Debug builds (Xcode previews); build_app.sh and the Xcode
// Release configuration leave the whole file out.

extension TrafficStore {
    static func preview() -> TrafficStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PreviewURLProtocol.self]
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        return TrafficStore(
            service: TrafficAPIService(session: session),
            cache: OfflineCache(directory: nil)
        )
    }
}

// Answers every request from `PreviewFixtures` without touching the network.
// Unknown paths get a 404 (non-retriable, so no backoff delay in the canvas).
final class PreviewURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let fixture = PreviewFixtures.fixture(for: url)
        let status = fixture == nil ? 404 : 200
        let body = fixture?.body ?? Data()
        let contentType = fixture?.contentType ?? "text/plain"
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

enum PreviewFixtures {
    static func fixture(for url: URL) -> (body: Data, contentType: String)? {
        let path = url.path
        let json: String
        if url.host == "services.arcgis.com" {
            json = evChargers
        } else if path.contains("traffic-conditions") {
            return (Data(congestionXML.utf8), "application/xml")
        } else if path.hasSuffix("/cameras/all") {
            json = cameras
        } else if path.contains("/events/all") {
            json = events
        } else if path.hasSuffix("/signs/vms/all") {
            json = vmsSigns
        } else if path.hasSuffix("/signs/tim/all") {
            json = timSigns
        } else if path.contains("/journeys/all") {
            json = journeys
        } else if path.contains("/regions/all") {
            json = regions
        } else {
            return nil
        }
        return (Data(json.utf8), "application/json")
    }

    static let cameras = #"""
    {"response":{"camera":[
    {"id":653,"name":"SH20 May Rd Overbridge","description":"North along Sth Wstn Mwy from May Rd","direction":"Northbound","highway":"SH20","latitude":-36.90943,"longitude":174.73442,"offline":false,"underMaintenance":false,"sortOrder":20,"region":{"id":2,"name":"Auckland"},"way":{"id":54,"name":"020"}},
    {"id":812,"name":"Otaki Main Highway","description":"Looking south, north of the Mill Road/Main Highway roundabout.","direction":"Southbound","highway":"Old SH1","latitude":-40.75959,"longitude":175.15858,"offline":false,"underMaintenance":false,"sortOrder":0,"region":{"id":9,"name":"Wellington"},"way":{"id":1270,"name":"01P"}},
    {"id":831,"name":"SH1 Tinwald North","description":"North along Hinds Highway from Lagmhor Rd","direction":"Northbound","highway":"SH1","latitude":-43.919508,"longitude":171.721221,"offline":true,"underMaintenance":false,"region":{"id":11,"name":"Canterbury"},"way":{"id":805,"name":"01S"}}
    ]}}
    """#

    static let events = #"""
    {"response":{"roadevent":[
    {"id":561700,"eventDescription":"Snow","eventType":"Area Warning","impact":"Road Closed","status":"Active","planned":false,"eventIsland":"South Island","direction":"Both Directions","locationArea":"SH 94 Hollyford Road Junction to Donne River Bridge","eventComments":"Road CLOSED due to snow forecast overnight. Anticipate re-opening by 10am Sunday once snow cleared.","expectedResolution":"Until further notice","startDate":"2026-09-26T07:54:00+12:00","eventModified":"2026-09-26T17:14:58.040+12:00","geometry":"MULTILINESTRING ((168.09201 -44.81359, 168.0085 -44.77754, 167.9702 -44.70473))","region":{"id":14,"name":"Southland"},"way":{"id":1150,"name":"094"}},
    {"id":560046,"eventDescription":"Resurfacing","eventType":"Area Warning","impact":"Delays","status":"Active","planned":true,"eventIsland":"South Island","direction":"Both Directions","locationArea":"SH 88 Port Chalmers, between Wickliffe Terrace and Station Road","eventComments":"Temporary traffic signals in place at all times. Expect up to 10 minute delays.","expectedResolution":"Until further notice","startDate":"2026-09-14T18:00:00+12:00","endDate":"2026-10-01T00:00:00+13:00","eventModified":"2026-09-25T08:48:55.300+12:00","geometry":"MULTILINESTRING ((170.60882 -45.82017, 170.61807 -45.81806))","region":{"id":13,"name":"Otago"},"way":{"id":1101,"name":"088"}},
    {"id":561526,"eventDescription":"Pavement Repairs","eventType":"Area Warning","impact":"Caution","status":"Active","planned":true,"eventIsland":"South Island","direction":"Both Directions","locationArea":"SH 1 Invercargill to Awarua","eventComments":"Stop/Go traffic management in place between 7am and 5:30pm. Expect up to 5 minute delays.","expectedResolution":"02/10/2026 17:30","startDate":"2026-09-21T07:00:00+12:00","endDate":"2026-10-02T17:30:00+13:00","eventModified":"2026-09-24T10:54:22.233+12:00","geometry":"MULTILINESTRING ((168.36636 -46.4572, 168.38775 -46.47681))","region":{"id":14,"name":"Southland"},"way":{"id":1143,"name":"01S"}}
    ]}}
    """#

    static let vmsSigns = #"""
    {"response":{"vms":[
    {"id":1,"name":"SH59 Acheron T2 - Southbound","description":"SH59 Acheron T2 - Southbound","direction":"Southbound","currentMessage":"CLEARWAY[nl]NOT[nl]OPERATING[np]ALL[nl]VEHICLES[nl]KEEP RIGHT","lastMessageUpdate":"2026-09-26T14:00:14.720+12:00","lastUpdate":"2026-09-26T17:29:14.757+12:00","latitude":-41.091524,"longitude":174.86814,"region":{"id":9,"name":"Wellington"},"way":{"id":1221,"name":"059"}},
    {"id":11,"name":"SH2 Belmont - Southbound","description":"SH2 Belmont - Southbound","direction":"Southbound","currentMessage":"WGTN CBD [jl4]23[nl]AIRPORT [jl4]32","lastMessageUpdate":"2026-09-26T17:25:44.677+12:00","lastUpdate":"2026-09-26T17:29:14.757+12:00","latitude":-41.182949,"longitude":174.94194,"region":{"id":9,"name":"Wellington"},"way":{"id":79,"name":"002"}}
    ]}}
    """#

    static let timSigns = #"""
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
    {"response":{"region":[
    {"id":2,"name":"Auckland"},{"id":9,"name":"Wellington"},{"id":11,"name":"Canterbury"},{"id":13,"name":"Otago"},{"id":14,"name":"Southland"}
    ]}}
    """#

    static let evChargers = #"""
    {"type":"FeatureCollection","features":[
    {"type":"Feature","id":712990,"geometry":{"type":"Point","coordinates":[174.912617279991,-36.9648860419307]},"properties":{"OBJECTID":712990,"name":"Ormiston Town Centre","operator":"Todd Property Ormiston Town Centre Limited","address":"240 Ormiston road, Flat Bush, Auckland, 2012, New Zealand","is24Hours":"True","carParkCount":14,"hasCarparkCost":"False","maxTimeLimit":"Unlimited","latitude":-36.9648860428412,"longitude":174.912617279983,"currentType":"AC","numberOfConnectors":14,"connectorsList":"{AC, 32 kW, Type 2 Socketed, Status: Operative, Count:9},{AC, 32 kW, Type 1 Tethered, Status: Operative, Count:4}","hasChargingCost":"False","GlobalID":"4e79b7b0-9a73-45ca-b183-e0dac0f4f1dd"}}
    ]}
    """#

    static let congestionXML = #"""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?><tns:getTrafficConditionsResponse xmlns:tns="https://infoconnect.highwayinfo.govt.nz/schemas/traffic2"><tns:trafficConditions><tns:lastUpdated>2026-09-26T17:29:19.066+12:00</tns:lastUpdated><tns:motorways><tns:name>Northern Motorway</tns:name><tns:locations><tns:congestion>Free Flow</tns:congestion><tns:direction>Southbound</tns:direction><tns:endLat>-36.7506902724442</tns:endLat><tns:endLon>174.726003398276</tns:endLon><tns:id>2</tns:id><tns:inOut>In</tns:inOut><tns:name>Oteha Valley Rd - Upper Harb Hwy</tns:name><tns:order>1</tns:order><tns:startLat>-36.7183869853163</tns:startLat><tns:startLon>174.712619564421</tns:startLon></tns:locations></tns:motorways></tns:trafficConditions></tns:getTrafficConditionsResponse>
    """#
}
#endif
