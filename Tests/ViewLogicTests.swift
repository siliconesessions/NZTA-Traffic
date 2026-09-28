import CoreLocation
import Foundation

// The views' Foundation-only logic from the 2026-09 review (ViewLogic.swift
// and the filter additions in Models/TrafficStore): the live camera image
// (A2), Flow and congestion draw order and per-leg filtering (A5, A16), the
// side-by-side offset for opposite directions, the EV and congestion layers
// honouring Region / Highway / Search (B15), cluster emphasis (B7), blank TIM
// boards (B18), grid arrow keys (B27), the region picker's restored selection
// (B24), the Travel Times caption (B6), framing a region's results on the
// map (C5) and the sidebar badges (C6). Region outlines, congestion and
// journey records are trimmed from the 2026-09-26 snapshots.
@MainActor
func runViewLogicTests(_ t: TestRunner) async {
    testLiveCameraImage(t)
    testFlowSegmentsPerLeg(t)
    testCongestionDrawOrder(t)
    testCongestionFilter(t)
    testOffsetPolyline(t)
    testRegionPlacement(t)
    testDiacriticSearch(t)
    testEVChargerFilter(t)
    testClusterEmphasis(t)
    testGridFocus(t)
    testRegionSelection(t)
    testJourneyCaption(t)
    testMapFrame(t)
    testSectionBadge(t)
    await testStoreLayerFilters(t)
}

// MARK: - Fixtures

// Three real regions' outlines from /regions/all/10.
private let regionsJSON = #"""
{"response":{"region":[
{"id":1,"name":"Northland","geometry":"POLYGON ((174.48847454570907 -36.22293279673548, 174.02376850464358 -36.136347409620804, 173.98468776550257 -36.117706938688734, 173.38849978920126 -35.547524590007974, 172.68292489697913 -34.43130883566011, 172.8403779094454 -34.51585923303987, 173.8706740966519 -35.12190961304251, 174.09670720726837 -35.28519324901362, 174.4863755526178 -35.838851347318375, 174.5760345027645 -36.072893223118356, 174.48847454570907 -36.22293279673548))"},
{"id":2,"name":"Auckland","geometry":"POLYGON ((175.01968027370535 -37.2337476404605, 174.8998271955347 -37.18471165889149, 174.43745134960736 -36.74590370342549, 174.42892336262094 -36.694119058791905, 174.43194643782135 -36.4395870037119, 174.48847454570907 -36.22293279673548, 174.5090968082559 -36.2320003306375, 174.6606738342904 -36.39713605922942, 175.0207185969952 -37.22873488307567, 175.01968027370535 -37.2337476404605))"},
{"id":9,"name":"Wellington","geometry":"POLYGON ((174.80988370635936 -41.32586716988049, 174.77164627817106 -41.29593585128134, 174.77258126954771 -41.276098398575456, 174.8776545073193 -41.048837334374966, 175.03233143454244 -40.86994132853283, 175.17001319809944 -40.7437700837228, 175.20082410657048 -40.73309694375239, 175.60916552019697 -40.74416077937096, 175.66279696269763 -40.895973567918006, 175.67230662794896 -40.92913160474758, 175.66930812617693 -40.945001870192016, 175.45912584657816 -41.21812777261162, 174.80988370635936 -41.32586716988049))"}
]}}
"""#

// SH20B Puhinui Rd, both directions of Campana Rd – SH20 (the same two end
// points, reversed) with the Free Flow twin listed last, so drawing in feed
// order would hide the Heavy one; plus an Unknown North-Western segment.
private let sh20bCongestionXML = #"""
<?xml version="1.0" encoding="UTF-8" standalone="yes"?><tns:getTrafficConditionsResponse xmlns:tns="https://infoconnect.highwayinfo.govt.nz/schemas/traffic2"><tns:trafficConditions><tns:lastUpdated>2026-09-27T21:45:21.787+13:00</tns:lastUpdated><tns:motorways><tns:name>SH20B Puhinui Rd</tns:name><tns:locations><tns:congestion>Heavy</tns:congestion><tns:direction>Eastbound</tns:direction><tns:endLat>-36.99354</tns:endLat><tns:endLon>174.84286</tns:endLon><tns:id>70</tns:id><tns:inOut>In</tns:inOut><tns:name>Campana Rd - SH20</tns:name><tns:order>0</tns:order><tns:startLat>-36.99939</tns:startLat><tns:startLon>174.82603</tns:startLon></tns:locations><tns:locations><tns:congestion>Free Flow</tns:congestion><tns:direction>Westbound</tns:direction><tns:endLat>-36.99939</tns:endLat><tns:endLon>174.82603</tns:endLon><tns:id>67</tns:id><tns:inOut>Out</tns:inOut><tns:name>SH20 - Campana Rd</tns:name><tns:order>0</tns:order><tns:startLat>-36.99354</tns:startLat><tns:startLon>174.84286</tns:startLon></tns:locations></tns:motorways><tns:motorways><tns:name>North-Western Motorway</tns:name><tns:locations><tns:congestion>Unknown</tns:congestion><tns:direction>Westbound</tns:direction><tns:endLat>-36.8627</tns:endLat><tns:endLon>174.7004</tns:endLon><tns:id>90</tns:id><tns:inOut>Out</tns:inOut><tns:name>Great North Rd - Pt Chevalier Rd</tns:name><tns:order>1</tns:order><tns:startLat>-36.8645</tns:startLat><tns:startLon>174.7240</tns:startLon></tns:locations></tns:motorways></tns:trafficConditions></tns:getTrafficConditionsResponse>
"""#

// A leg with a straight two-point geometry (north for I, south for D) and
// the flow ratio NZTA reports for `flowKind`; No Data is a leg with no
// coverage.
private func flowLeg(_ name: String, direction: String, sequence: Int, flowKind: FlowKind) -> String {
    let geometry = direction == "I"
        ? "LINESTRING (174.80 -41.20, 174.80 -41.10)"
        : "LINESTRING (174.80 -41.10, 174.80 -41.20)"
    let flow: Double
    switch flowKind {
    case .freeFlow:
        flow = 0.95
    case .moderate:
        flow = 0.7
    case .slow:
        flow = 0.5
    case .congested:
        flow = 0.2
    case .noData:
        flow = 0
    }
    let coverage = flowKind == .noData ? 0 : 1
    return #"{"name":"\#(name)","geometry":"\#(geometry)","totalLength":11.1,"time":"00:07:00","freeFlowTime":400,"way":{"id":\#(sequence * 2 + (direction == "I" ? 0 : 1)),"name":"001"},"sequenceNumber":\#(sequence),"direction":"\#(direction)","effectiveSpeedLimit":100,"coverage":\#(coverage),"flow":\#(flow)}"#
}

private func journey(_ id: String, _ legs: [String], _ t: TestRunner) -> TrafficJourney? {
    decodeModel(TrafficJourney.self, #"{"id":"\#(id)","name":"SH1","regions":{"id":9,"name":"Wellington"},"legs":["# + legs.joined(separator: ",") + "]}", t)
}

private func coordinate(_ latitude: Double, _ longitude: Double) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
}

// MARK: - A2

private func testLiveCameraImage(_ t: TestRunner) {
    t.group("camera grid shows the live frame")
    guard let camera = decodeModel(
        TrafficCamera.self,
        #"{"id":714,"name":"SH1 Johnsonville","imageUrl":"/camera/714.jpg","thumbUrl":"/camera/thumb/714.jpg","latitude":-41.22,"longitude":174.8}"#,
        t
    ) else { return }
    t.equal(camera.liveImageURL(cacheToken: 0)?.path, "/camera/714.jpg", "the card loads the live frame, not the thumbnail")
    t.equal(camera.liveImageURL(cacheToken: 3)?.query, "t=3", "with the refresh token")
    t.equal(camera.stillThumbnailURL?.path, "/camera/thumb/714.jpg", "the static thumb is only the fallback")
    t.check(camera.stillThumbnailURL?.query == nil, "the never-changing thumb has no cache token")

    guard let thumbOnly = decodeModel(
        TrafficCamera.self,
        #"{"id":9,"name":"Thumb only","thumbUrl":"/camera/thumb/9.jpg"}"#,
        t
    ) else { return }
    t.check(thumbOnly.liveImageURL(cacheToken: 0) == nil, "no live path → no live URL (the card falls back to the still, marked not live)")
    t.equal(thumbOnly.imageURL(cacheToken: 0)?.path, "/camera/thumb/9.jpg", "the preview sheet still falls back to the thumb")
}

// MARK: - A5 / A16

private func testFlowSegmentsPerLeg(_ t: TestRunner) {
    t.group("flow map: per-leg filter and draw order")
    // Feed order: a grey No Data increasing leg first, then its moderate
    // decreasing twin; then a congested leg inside a mostly free-flowing
    // journey.
    guard let tawa = journey("10", [
        flowLeg("Tawa to Ngauranga", direction: "I", sequence: 0, flowKind: .noData),
        flowLeg("Ngauranga to Tawa", direction: "D", sequence: 0, flowKind: .moderate)
    ], t), let tunnel = journey("11", [
        flowLeg("Terrace Tunnel to Basin", direction: "I", sequence: 0, flowKind: .congested),
        flowLeg("Basin to Terrace Tunnel", direction: "D", sequence: 0, flowKind: .freeFlow),
        flowLeg("Basin to Airport", direction: "I", sequence: 1, flowKind: .freeFlow),
        flowLeg("Airport to Basin", direction: "D", sequence: 1, flowKind: .freeFlow)
    ], t) else { return }
    t.equal(tawa.legs.map(\.flowKind), [.noData, .moderate], "fixture flows (Tawa)")
    t.equal(tunnel.legs.map(\.flowKind), [.congested, .freeFlow, .freeFlow, .freeFlow], "fixture flows (tunnel)")

    let everything = Set(FlowKind.allCases)
    let all = flowMapSegments(for: [tawa, tunnel], allowedKinds: everything)
    t.equal(all.count, 6, "one segment per drawable leg part")
    t.equal(all.first?.flowKind, .noData, "No Data draws first, underneath")
    t.equal(all.last?.flowKind, .congested, "Congested draws last, on top")
    let ranks = all.map(\.flowKind.drawRank)
    t.equal(ranks, ranks.sorted(), "ordered by draw rank")
    t.equal(Set(all.map(\.id)).count, all.count, "segment ids are unique")
    t.equal(
        all.filter { $0.flowKind == .freeFlow }.map(\.id),
        ["11|\(tunnel.legs[1].id)|0", "11|\(tunnel.legs[2].id)|0", "11|\(tunnel.legs[3].id)|0"],
        "feed order kept within a rank, so every render draws the same"
    )

    let defaults: Set<FlowKind> = [.freeFlow, .moderate, .slow, .congested]
    let byDefault = flowMapSegments(for: [tawa, tunnel], allowedKinds: defaults)
    t.check(!byDefault.contains { $0.flowKind == .noData }, "No Data off → no grey legs drawn")
    t.equal(byDefault.count, 5, "every live leg drawn")

    let congestedOnly = flowMapSegments(for: [tawa, tunnel], allowedKinds: [.congested])
    t.equal(congestedOnly.map(\.flowKind), [.congested], "the Congested chip alone finds a congested leg in a free-flowing journey")
    t.check(tunnel.overallFlowKind != .congested, "(which the journey's average doesn't show)")

    let counts = flowMapLegCounts(for: [tawa, tunnel], allowedKinds: defaults)
    t.equal(counts.total, 5, "counts use the same per-leg filter")
    t.equal(counts.mapped, 5, "all of them drawable")

    t.equal(
        FlowKind.allCases.sorted { $0.drawRank < $1.drawRank },
        [.noData, .freeFlow, .moderate, .slow, .congested],
        "draw ranks, bottom to top"
    )
}

private func testCongestionDrawOrder(_ t: TestRunner) {
    t.group("congestion: worst on top")
    guard let segments = CongestionXMLParser.parse(Data(sh20bCongestionXML.utf8)) else {
        t.check(false, "congestion fixture parses")
        return
    }
    t.equal(segments.map(\.level), [.heavy, .freeFlow, .unknown], "fixture levels in feed order")
    let ordered = congestionDrawOrder(segments)
    t.equal(ordered.map(\.level), [.unknown, .freeFlow, .heavy], "Unknown first, Heavy last — never under its Free Flow twin")
}

// MARK: - B15 congestion and EV filters

private func testCongestionFilter(_ t: TestRunner) {
    t.group("congestion: region, highway and search")
    guard let segments = CongestionXMLParser.parse(Data(sh20bCongestionXML.utf8)) else { return }
    let puhinui = segments[0]
    let northwestern = segments[2]
    t.check(puhinui.matches(region: "Auckland", highway: "", search: ""), "every segment is in Auckland")
    t.check(!puhinui.matches(region: "Wellington", highway: "", search: ""), "and in no other region")
    t.check(puhinui.matches(region: "", highway: "SH20B", search: ""), "a motorway named by its highway")
    t.check(!puhinui.matches(region: "", highway: "SH20", search: ""), "a spur isn't its parent highway")
    t.check(northwestern.matches(region: "", highway: "SH16", search: ""), "the North-Western Motorway is SH16")
    t.check(!northwestern.matches(region: "", highway: "SH1", search: ""), "and not SH1")
    t.check(puhinui.matches(region: "", highway: "", search: "campana"), "search finds the segment name")
    t.check(puhinui.matches(region: "", highway: "", search: "heavy"), "and the level")

    t.equal(aucklandMotorwayHighway("Northern Motorway"), "SH1", "Northern Motorway")
    t.equal(aucklandMotorwayHighway("South-Western Motorway"), "SH20", "South-Western Motorway")
    t.equal(aucklandMotorwayHighway("Upper Harbour Motorway"), "SH18", "Upper Harbour Motorway")
    t.check(aucklandMotorwayHighway("Route 12") == nil, "Route 12 isn't a state highway")
}

private func testRegionPlacement(_ t: TestRunner) {
    t.group("EV chargers: placing a point in a region")
    guard let payload = decodeModel(RegionsPayload.self, regionsJSON, t) else { return }
    let outlines = payload.response.region.compactMap { region -> RegionOutline? in
        guard let name = region.name, !region.boundary.isEmpty else { return nil }
        return RegionOutline(name: name, rings: region.boundary)
    }
    t.equal(outlines.count, 3, "each region's POLYGON decodes to an outline")
    t.equal(outlines.first?.rings.first?.count, 11, "with all its points")

    t.equal(regionName(containing: coordinate(-36.96489, 174.91262), in: outlines), "Auckland", "Ormiston, inside Auckland")
    t.equal(regionName(containing: coordinate(-35.7251, 174.3237), in: outlines), "Northland", "Whangārei, inside Northland")
    // Central Wellington lies just outside the coarse outline.
    t.equal(regionName(containing: coordinate(-41.2924, 174.7787), in: outlines), "Wellington", "central Wellington, by the nearest outline")
    t.check(regionName(containing: coordinate(-45.8788, 170.5028), in: outlines) == nil, "Dunedin, far from all three → no region")
}

private func testDiacriticSearch(_ t: TestRunner) {
    t.group("search ignores macrons")
    t.equal(foldedForSearch("Ōtaki Whangārei"), "otaki whangarei", "folded and lowercased")
    t.check(matchesNeedle("otaki", in: searchableHaystack(["Ōtaki Gorge Rd"])), "otaki finds Ōtaki")
    t.check(matchesNeedle("Ōtaki", in: searchableHaystack(["Otaki Main Highway"])), "Ōtaki finds Otaki")
    t.check(!matchesNeedle("tauranga", in: searchableHaystack(["Ōtaki"])), "no false match")
}

private func testEVChargerFilter(_ t: TestRunner) {
    t.group("EV chargers: highway and search")
    let json = #"""
    {"type":"Feature","id":1,"geometry":{"type":"Point","coordinates":[174.3237,-35.7251]},"properties":{"name":"Whangārei Town Basin","operator":"ChargeNet","address":"85379 State Highway 2, Whangārei 0110","latitude":-35.7251,"longitude":174.3237,"currentType":"DC","connectorsList":"{DC, 50 kW, CHAdeMO, Status: Operative, Count:1}"}}
    """#
    guard let charger = decodeModel(EVCharger.self, json, t) else { return }
    t.check(charger.matches(highway: HighwayQuery("SH2"), search: ""), "an address on State Highway 2 matches SH2")
    t.check(!charger.matches(highway: HighwayQuery("SH1"), search: ""), "but not SH1")
    t.check(charger.matches(highway: HighwayQuery(""), search: "whangarei"), "search without the macron")
    t.check(charger.matches(highway: HighwayQuery(""), search: "chargenet"), "search by operator")
    t.check(!charger.matches(highway: HighwayQuery(""), search: "tesla"), "no false match")
}

// MARK: - A5 offset

private func testOffsetPolyline(_ t: TestRunner) {
    t.group("opposite directions drawn side by side")
    let north = [coordinate(-41.2, 174.8), coordinate(-41.1, 174.8)]
    let south = Array(north.reversed())
    let degreesPerPoint = 0.0005
    let offsetNorth = offsetPolyline(north, points: 3, degreesLongitudePerPoint: degreesPerPoint)
    let offsetSouth = offsetPolyline(south, points: 3, degreesLongitudePerPoint: degreesPerPoint)
    t.nearlyEqual(offsetNorth[0].longitude, 174.8 - 3 * degreesPerPoint, tolerance: 1e-9, "northbound moves west (left of travel)")
    t.nearlyEqual(offsetSouth[1].longitude, 174.8 + 3 * degreesPerPoint, tolerance: 1e-9, "southbound moves east")
    t.nearlyEqual(
        (offsetSouth[1].longitude - offsetNorth[0].longitude) / degreesPerPoint,
        6,
        tolerance: 1e-6,
        "twins end up two offsets (a line's width) apart"
    )
    t.nearlyEqual(offsetNorth[0].latitude, -41.2, tolerance: 1e-9, "a north–south line keeps its latitudes")

    // East-bound: moved north by the same screen distance (Mercator), which
    // is fewer degrees of latitude than of longitude away from the equator.
    let east = [coordinate(-41.2, 174.8), coordinate(-41.2, 174.9)]
    let offsetEast = offsetPolyline(east, points: 3, degreesLongitudePerPoint: degreesPerPoint)
    t.check(offsetEast[0].latitude > -41.2, "eastbound moves north (left of travel)")
    let latitudeShift = offsetEast[0].latitude + 41.2
    t.nearlyEqual(latitudeShift / (3 * degreesPerPoint), cos(41.2 * .pi / 180), tolerance: 1e-3, "by the same on-screen distance")

    // A right-angle bend keeps the offset at both legs (a mitred corner).
    let bend = [coordinate(-41.2, 174.8), coordinate(-41.1, 174.8), coordinate(-41.1, 174.9)]
    let offsetBend = offsetPolyline(bend, points: 2, degreesLongitudePerPoint: degreesPerPoint)
    t.nearlyEqual(offsetBend[1].longitude, 174.8 - 2 * degreesPerPoint, tolerance: 1e-9, "the corner stays two points off the first leg")
    t.check(offsetBend[1].latitude > -41.1, "and off the second")

    t.equal(offsetPolyline([north[0]], points: 3, degreesLongitudePerPoint: degreesPerPoint).count, 1, "a single point is returned as is")
    let unchanged = offsetPolyline(north, points: 3, degreesLongitudePerPoint: 0)
    t.nearlyEqual(unchanged[0].longitude, 174.8, tolerance: 0, "no map width yet → unchanged")
    let repeated = [coordinate(-41.2, 174.8), coordinate(-41.2, 174.8), coordinate(-41.1, 174.8)]
    let offsetRepeated = offsetPolyline(repeated, points: 3, degreesLongitudePerPoint: degreesPerPoint)
    t.check(offsetRepeated.allSatisfy { $0.longitude.isFinite && $0.latitude.isFinite }, "a repeated point doesn't produce NaN")
    t.nearlyEqual(offsetRepeated[0].longitude, 174.8 - 3 * degreesPerPoint, tolerance: 1e-9, "and is offset like its neighbours")
}

// MARK: - B7 / B18

private func testClusterEmphasis(_ t: TestRunner) {
    t.group("map cluster emphasis and blank TIM boards")
    let base = #"{"id":1,"eventType":"Area Warning","impact":"IMPACT","status":"STATUS","planned":false,"locationArea":"SH 1","region":{"id":9,"name":"Wellington"}}"#
    func event(_ impact: String, _ status: String) -> RoadEvent? {
        decodeModel(
            RoadEvent.self,
            base.replacingOccurrences(of: "IMPACT", with: impact).replacingOccurrences(of: "STATUS", with: status),
            t
        )
    }
    guard let closure = event("Road Closed", "Active"),
          let caution = event("Caution", "Active"),
          let upcoming = event("Road Closed", "Scheduled"),
          let resolved = event("Road Closed", "Resolved") else { return }
    t.check(closure.mapEmphasis > caution.mapEmphasis, "an active closure outranks caution")
    t.check(caution.mapEmphasis > upcoming.mapEmphasis, "anything current outranks an upcoming closure")
    t.check(upcoming.mapEmphasis > resolved.mapEmphasis, "resolved is lowest")

    guard let online = decodeModel(TrafficCamera.self, #"{"id":1,"name":"A","offline":false}"#, t),
          let offline = decodeModel(TrafficCamera.self, #"{"id":2,"name":"B","offline":true}"#, t) else { return }
    t.check(offline.mapEmphasis > online.mapEmphasis, "an offline camera stands out in a cluster")

    let blank = #"{"id":1,"name":"Blank board","latitude":-36.9,"longitude":174.7,"page":{"line":[],"pageTime":5}}"#
    let showing = #"{"id":2,"name":"Live board","latitude":-36.9,"longitude":174.7,"page":{"line":[{"left":"CITY CENTRE","right":32}],"pageTime":5}}"#
    guard let blankBoard = decodeModel(TIMSign.self, blank, t),
          let liveBoard = decodeModel(TIMSign.self, showing, t) else { return }
    t.check(blankBoard.isBlank, "a board with no lines is blank")
    t.check(!liveBoard.isBlank, "a board with a time isn't")
}

// MARK: - B27

private func testGridFocus(_ t: TestRunner) {
    t.group("arrow keys in lists and grids")
    t.equal(adaptiveGridColumnCount(width: 1132, minimum: 280, spacing: 16), 3, "1,132 pt of 280 pt cards → 3 columns")
    t.equal(adaptiveGridColumnCount(width: 1180, minimum: 280, spacing: 16), 4, "1,180 pt → 4")
    t.equal(adaptiveGridColumnCount(width: 200, minimum: 280, spacing: 16), 1, "narrower than a card → 1")
    t.equal(adaptiveGridColumnCount(width: .infinity, minimum: 280, spacing: 16), 1, "unmeasured → 1")

    t.equal(gridFocusTarget(from: nil, count: 10, columns: 3, move: .down), 0, "nothing focused: an arrow enters at the first item")
    t.equal(gridFocusTarget(from: nil, count: 10, columns: 3, move: .up), 0, "whichever arrow it is")
    t.check(gridFocusTarget(from: nil, count: 0, columns: 3, move: .down) == nil, "an empty list has nowhere to go")
    t.equal(gridFocusTarget(from: 1, count: 10, columns: 3, move: .down), 4, "↓ moves a row, not one item")
    t.equal(gridFocusTarget(from: 4, count: 10, columns: 3, move: .up), 1, "↑ moves a row back")
    t.check(gridFocusTarget(from: 1, count: 10, columns: 3, move: .up) == nil, "↑ from the top row leaves the grid")
    t.equal(gridFocusTarget(from: 4, count: 10, columns: 3, move: .right), 5, "→ one item")
    t.equal(gridFocusTarget(from: 3, count: 10, columns: 3, move: .left), 2, "← one item, wrapping to the row above")
    t.equal(gridFocusTarget(from: 8, count: 10, columns: 3, move: .down), 9, "↓ into a short last row lands on its last item")
    t.check(gridFocusTarget(from: 9, count: 10, columns: 3, move: .down) == nil, "↓ from the last row leaves the grid")
    t.equal(gridFocusTarget(from: 2, count: 5, columns: 1, move: .down), 3, "a list is one column")
    t.equal(gridFocusTarget(from: 99, count: 5, columns: 1, move: .down), 0, "a stale focus restarts at the top")
}

// MARK: - B24

private func testRegionSelection(_ t: TestRunner) {
    t.group("region picker selection")
    let regions = ["Auckland", "Manawatu-Whanganui", "Wellington"]
    t.equal(normalizedRegionSelection("", available: regions, listIsComplete: true), "", "All Regions stays")
    t.equal(normalizedRegionSelection("Wellington", available: regions, listIsComplete: true), "Wellington", "a listed region stays")
    t.equal(normalizedRegionSelection("wellington", available: regions, listIsComplete: true), "Wellington", "restored casing is corrected")
    t.equal(normalizedRegionSelection("Hawkes Bay", available: regions, listIsComplete: false), "Hawkes Bay", "kept while the list is still loading")
    t.equal(normalizedRegionSelection("Hawke's Bay (old)", available: regions, listIsComplete: true), "", "an unknown region falls back to All Regions")
}

// MARK: - B6

private func testJourneyCaption(_ t: TestRunner) {
    t.group("Travel Times explains hidden journeys")
    t.equal(
        journeyVisibilityCaption(shown: 9, total: 131, hiddenWithoutLiveData: 122),
        "Showing 9 of 131 journeys · 122 with no live data are hidden",
        "the default: No Data hidden"
    )
    t.equal(
        journeyVisibilityCaption(shown: 5, total: 131, hiddenWithoutLiveData: 122),
        "Showing 5 of 131 journeys · 122 with no live data and 4 more by the flow filters are hidden",
        "No Data and a chip"
    )
    t.equal(
        journeyVisibilityCaption(shown: 128, total: 131, hiddenWithoutLiveData: 0),
        "Showing 128 of 131 journeys · 3 hidden by the flow filters",
        "a chip only"
    )
    t.equal(
        journeyVisibilityCaption(shown: 130, total: 131, hiddenWithoutLiveData: 1),
        "Showing 130 of 131 journeys · 1 with no live data is hidden",
        "singular"
    )
    t.check(journeyVisibilityCaption(shown: 131, total: 131, hiddenWithoutLiveData: 0) == nil, "nothing hidden → no caption")
}

// MARK: - The store's layer filters

@MainActor
private func testStoreLayerFilters(_ t: TestRunner) async {
    t.group("store: EV, congestion and flow layer filters")
    StubServer.reset()
    StubFixtures.routeAllEndpoints()
    let folder = makeTemporaryFolder()
    defer { removeTemporaryFolder(folder) }
    let store = TrafficStore(
        service: makeStubService(),
        cache: OfflineCache(directory: folder),
        imageCache: nil,
        monitorsNetwork: false,
        reconnectDelay: .zero
    )
    await store.start().value
    let idle = await waitUntil {
        store.loadingSections.isEmpty && !store.isRefreshing && !store.isLoadingEVChargers && !store.allRegions.isEmpty
    }
    t.check(idle, "everything loads")

    // The stub regions have no outlines, so chargers are placed by address.
    t.equal(store.filteredEVChargers(region: "", highway: "", search: "").count, 1, "unfiltered: every charger")
    t.equal(store.filteredEVChargers(region: "Auckland", highway: "", search: "").count, 1, "Flat Bush, Auckland → Auckland")
    t.equal(store.filteredEVChargers(region: "Wellington", highway: "", search: "").count, 0, "not Wellington")
    t.equal(store.filteredEVChargers(region: "", highway: "", search: "ormiston").count, 1, "search")
    t.equal(store.filteredEVChargers(region: "", highway: "SH1", search: "").count, 0, "highway: not on one")

    t.equal(store.filteredCongestion(region: "Auckland", highway: "SH1", search: "").count, 1, "the Northern Motorway is SH1 in Auckland")
    t.equal(store.filteredCongestion(region: "Canterbury", highway: "", search: "").count, 0, "no congestion outside Auckland")

    let everything = Set(FlowKind.allCases)
    let segments = store.mapFlowSegments(region: "", highway: "", search: "", flows: everything)
    t.equal(segments.count, flowMapSegments(for: store.journeys, allowedKinds: everything).count, "the Flow map draws every leg")
    t.check(
        store.mapFlowSegments(region: "Auckland", highway: "", search: "", flows: everything).isEmpty,
        "and the region filter applies (the stub journey is in Canterbury)"
    )
    StubServer.reset()
}

// MARK: - Map framing (C5)

private func testMapFrame(_ t: TestRunner) {
    t.group("map framing and NZ bounds")

    // Three Auckland cameras from the 2026-09-26 /cameras snapshot.
    let auckland = [
        CLLocationCoordinate2D(latitude: -36.90943, longitude: 174.73442),
        CLLocationCoordinate2D(latitude: -36.87173, longitude: 174.71018),
        CLLocationCoordinate2D(latitude: -36.871997, longitude: 174.704836)
    ]
    let frame = mapFrame(fitting: auckland)
    t.check(frame != nil, "Auckland cameras produce a frame")
    if let frame {
        t.check(abs(frame.centerLatitude - -36.89058) < 1e-6, "frame is centred on the cameras' latitude")
        t.check(abs(frame.centerLongitude - 174.719628) < 1e-6, "frame is centred on the cameras' longitude")
        t.equal(frame.latitudeDelta, 0.08, "a tight cluster gets the minimum span")
    }

    // One point anywhere still frames at the minimum span.
    let single = mapFrame(fitting: [auckland[0]])
    t.equal(single?.latitudeDelta, 0.08, "a single point gets the minimum latitude span")
    t.equal(single?.longitudeDelta, 0.08, "a single point gets the minimum longitude span")

    // Far North to Bluff: the span covers both, padded 30%.
    let country = mapFrame(fitting: [
        CLLocationCoordinate2D(latitude: -34.43, longitude: 172.68),
        CLLocationCoordinate2D(latitude: -46.60, longitude: 168.36)
    ])
    if let country {
        t.check(abs(country.latitudeDelta - 12.17 * 1.3) < 1e-9, "north-south span is padded")
        t.check(abs(country.longitudeDelta - 4.32 * 1.3) < 1e-9, "east-west span is padded")
    } else {
        t.check(false, "Far North to Bluff produces a frame")
    }

    // The Chathams (Waitangi, 176.56°W) frame with Christchurch across the
    // antimeridian: a ~13° box centred east of the mainland, not a 350° one.
    let chathams = CLLocationCoordinate2D(latitude: -43.95, longitude: -176.56)
    let christchurch = CLLocationCoordinate2D(latitude: -43.53, longitude: 172.64)
    if let across = mapFrame(fitting: [christchurch, chathams], padding: 1) {
        t.check(abs(across.longitudeDelta - 10.8) < 1e-9, "the Chathams join the mainland across 180°")
        t.check(abs(across.centerLongitude - 178.04) < 1e-9, "centre falls between Christchurch and the Chathams")
    } else {
        t.check(false, "Christchurch and the Chathams produce a frame")
    }
    if let east = mapFrame(fitting: [chathams]) {
        t.check(abs(east.centerLongitude - -176.56) < 1e-9, "a Chathams-only frame keeps its western longitude")
    } else {
        t.check(false, "the Chathams alone produce a frame")
    }

    // A stray coordinate outside New Zealand (Sydney) doesn't widen the frame.
    let withStray = mapFrame(fitting: auckland + [CLLocationCoordinate2D(latitude: -33.87, longitude: 151.21)])
    t.equal(withStray, frame, "points outside NZ are ignored")
    t.check(mapFrame(fitting: []) == nil, "no coordinates, no frame")
    t.check(
        mapFrame(fitting: [CLLocationCoordinate2D(latitude: .nan, longitude: 174.7)]) == nil,
        "non-finite coordinates are ignored"
    )

    // The camera-centre bounds keep all of NZ, the Chathams included, in reach.
    let bounds = NZMapArea.cameraCenterBounds
    let west = bounds.centerLongitude - bounds.longitudeDelta / 2
    let eastEdge = bounds.centerLongitude + bounds.longitudeDelta / 2
    t.check(west <= 166.4 && eastEdge >= 360 - 176.56, "bounds span Fiordland to the Chathams")
    let south = bounds.centerLatitude - bounds.latitudeDelta / 2
    let north = bounds.centerLatitude + bounds.latitudeDelta / 2
    t.check(south <= -47.3 && north >= -34.4, "bounds span Stewart Island to Cape Reinga")
}

private func testSectionBadge(_ t: TestRunner) {
    t.group("sidebar section badges")
    t.equal(sectionBadgeText(count: 313, isLoading: false, hasError: false), "313", "count when loaded")
    t.equal(sectionBadgeText(count: 313, isLoading: true, hasError: true), "313", "last-good count stays, unmarked, while a retry loads")
    t.equal(sectionBadgeText(count: 313, isLoading: false, hasError: true), "313 !", "stale count is marked after a failure")
    t.equal(sectionBadgeText(count: 0, isLoading: false, hasError: true), "!", "failure with nothing to show")
    t.equal(sectionBadgeText(count: 0, isLoading: true, hasError: true), nil, "no badge while a retry loads")
    t.equal(sectionBadgeText(count: 0, isLoading: false, hasError: false), nil, "empty section has no badge")
    t.equal(sectionBadgeAccessibilityLabel(count: 313, isLoading: false, hasError: true), "313, last update failed", "VoiceOver hears what the mark means")
    t.equal(sectionBadgeAccessibilityLabel(count: 0, isLoading: false, hasError: true), "Last update failed", "as does a lone mark")
    t.equal(sectionBadgeAccessibilityLabel(count: 313, isLoading: false, hasError: false), "313", "a plain count reads as itself")
}
