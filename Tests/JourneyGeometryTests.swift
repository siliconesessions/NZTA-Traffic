import CoreLocation
import Foundation

// Journey maths, WKT geometry and decode robustness from the 2026-09 review
// (A3, A4, B11, A15, B9, B21, A10, A18). Journey and event fixtures are
// trimmed copies of real records from the 2026-09-26 rest/5 snapshots (only
// the per-link `lengths` detail, which the app doesn't decode, is left out).
func runJourneyGeometryTests(_ t: TestRunner) {
    testJourneyDirections(t)
    testJourneyDirectionLabels(t)
    testLegDataIssues(t)
    testRealJourneyWithBadLegs(t)
    testLegIDs(t)
    testWKTParts(t)
    testEventPins(t)
    testWKTLinearTime(t)
    testLenientSectionDecoding(t)
    testSectionRefreshDecision(t)
    testOverflowSafeNumbers(t)
}

// MARK: - Fixtures

// SH20B Auckland (journey 7): two I legs with sound times and their two D
// twins, whose times (28:51 and 30:44 for 1.8 km and 0.5 km at ~36 km/h)
// contradict their own length and speed. Before A3/A4 this journey topped the
// Travel Times list with "Delay +31:39".
private let sh20bJourneyJSON = #"""
{"id":7,"name":"SH20B","geometry":"MULTILINESTRING ((174.8450111275632 -36.992804931970234, 174.82606333871155 -36.99936714886306), (174.82606333871155 -36.99936714886306, 174.8450111275632 -36.992804931970234), (174.82606333871155 -36.99936714886306, 174.8204918527637 -37.00129770136158), (174.8204918527637 -37.00129770136158, 174.82606333871155 -36.99936714886306))","totalLength":4.7637415667818575,"time":"00:00:00","ways":{"id":"20B","name":"20B"},"regions":{"id":2,"name":"Auckland"},"legs":[
{"name":"Puhinui to Campana Rd","geometry":"LINESTRING (174.8450111275632 -36.992804931970234, 174.82606333871155 -36.99936714886306)","totalLength":1.841594424970985,"speed":40.0000365027479,"way":{"id":61,"name":"20B"},"sequenceNumber":0,"direction":"I","time":"00:02:40","effectiveSpeedLimit":80,"coverage":1,"flow":0.5000004562843487,"freeFlowTime":80.05687510927953},
{"name":"Campana Rd to Puhinui","geometry":"LINESTRING (174.82606333871155 -36.99936714886306, 174.8450111275632 -36.992804931970234)","totalLength":1.841594424970985,"speed":36.20334838400049,"way":{"id":62,"name":"20B"},"sequenceNumber":0,"direction":"D","time":"00:28:51","effectiveSpeedLimit":72.79115724954634,"coverage":1,"flow":0.49735915394072294,"freeFlowTime":860.9426248907207},
{"name":"Campana Rd to Orrs Road","geometry":"LINESTRING (174.82606333871155 -36.99936714886306, 174.8204918527637 -37.00129770136158)","totalLength":0.5402763584199437,"speed":40.00179476721203,"way":{"id":63,"name":"20B"},"sequenceNumber":1,"direction":"I","time":"00:00:46","effectiveSpeedLimit":80,"coverage":1,"flow":0.5000224345901504,"freeFlowTime":23.443124890720476},
{"name":"Orrs Road to Campana Rd","geometry":"LINESTRING (174.8204918527637 -37.00129770136158, 174.82606333871155 -36.99936714886306)","totalLength":0.5402763584199437,"speed":36.43640396939379,"way":{"id":64,"name":"20B"},"sequenceNumber":1,"direction":"D","time":"00:30:44","effectiveSpeedLimit":73.23594694738965,"coverage":1,"flow":0.49752075979257193,"freeFlowTime":917.5563751092798}
]}
"""#

// SH1 Auckland (journey 3) seq 9: the I leg and its D twin, which NZTA gives
// the same name and sequence number. The D leg's 53:15 comes from a duplicated
// 68-link list (68 km of links for a 10 km leg).
private let redoubtIncreasingLegJSON = #"""
{"name":"Redoubt Rd to Papakura","geometry":"LINESTRING (174.88783259437892 -36.991956216098494, 174.90950344115558 -37.019643085953916, 174.91044628086613 -37.04046530505996, 174.9290652484604 -37.07358015061338)","totalLength":10.043383431618658,"speed":67.33869573784378,"way":{"id":1272,"name":"01N"},"sequenceNumber":9,"direction":"I","time":"00:08:58","effectiveSpeedLimit":100.00000000000001,"coverage":1,"flow":0.6733869573784377,"freeFlowTime":362.5153365642154}
"""#

private let redoubtDecreasingLegJSON = #"""
{"name":"Redoubt Rd to Papakura","geometry":"LINESTRING (174.88768732478053 -36.9919857947068, 174.90939653108586 -37.019843266887776, 174.91033711604103 -37.04058440575264, 174.92891722080915 -37.073619776679536)","totalLength":10.050635603566644,"speed":76.93775588906551,"way":{"id":1274,"name":"01N"},"sequenceNumber":9,"direction":"D","time":"00:53:15","effectiveSpeedLimit":94.44781638792934,"coverage":1,"flow":0.814605978533754,"freeFlowTime":2603.33573417421}
"""#

// SH1 Auckland seq 5 I: a single-link (dict-shaped `lengths`) record whose
// 00:00:11 for 9.02 km implies about 2,950 km/h.
private let otehaLegJSON = #"""
{"name":"Oteha to SH18 Interchange","geometry":"LINESTRING (174.72600325854552 -36.75069291323165, 174.73780479357478 -36.761695647129756, 174.76129318421232 -36.79904890601829, 174.75019796258815 -36.82120473079403, 174.72842045433015 -36.75240232103937)","totalLength":9.02,"speed":85.99999999999999,"way":{"id":37,"name":"01N"},"sequenceNumber":5,"direction":"I","time":"00:00:11","effectiveSpeedLimit":100.00000000000001,"coverage":1,"flow":0.8599999999999998,"freeFlowTime":10.146806715306209}
"""#

// Event 561536 "SH 6 Paringa to Haast Pass": a winding line whose
// bounding-box centre lies 8.8 km from the road.
private let haastGeometry = "MULTILINESTRING ((169.3711500000637 -43.765210086994635, 169.36032000006364 -43.771650086992516, 169.34082000006393 -43.770040086993504, 169.3288000000643 -43.76431008699582, 169.31624000006508 -43.74650008700246, 169.3008600000658 -43.73187008700799, 169.26803000006674 -43.717280087013776, 169.24644000006657 -43.72979008700985, 169.23205000006706 -43.72080008701328, 169.2289100000674 -43.713180087016006, 169.21795000006728 -43.72065008701365, 169.2176500000671 -43.72482008701218, 169.20962000006736 -43.721600087013464, 169.20680000006712 -43.7274800870115, 169.20287000006712 -43.728210087011306, 169.20395000006704 -43.732510087009764, 169.19250000006713 -43.73247008701003, 169.16734000006676 -43.750730087004065, 169.15333000006675 -43.755310087002705, 169.12562000006605 -43.78341008699307, 169.12420000006577 -43.78972008699079, 169.11591000006584 -43.79140008699035, 169.06598000006525 -43.82170008698009, 169.05856000006472 -43.83808008697403, 169.05850000006419 -43.85179008696876, 169.04538000006414 -43.85735008696692, 169.0473500000638 -43.86525008696382, 169.04163000006355 -43.873130086960856, 169.0486000000628 -43.891460086953494, 169.0690700000618 -43.91066008694541, 169.0882300000611 -43.9250300869392, 169.10205000006084 -43.92650008693834, 169.11110000006053 -43.93234008693578, 169.14876000005967 -43.94344008693046, 169.14613000005946 -43.95028008692769, 169.1505700000592 -43.956730086924935, 169.1670800000586 -43.96743008692015, 169.22002000005781 -43.972290086917035, 169.24144000005805 -43.96018008692163, 169.2517000000584 -43.94902008692603, 169.28011000005841 -43.938890086929575, 169.29619000005817 -43.94151008692821, 169.3162800000574 -43.95591008692186, 169.35049000005714 -43.953360086922245))"

private func journeyFixture(legs: [String], _ t: TestRunner) -> TrafficJourney? {
    decodeModel(TrafficJourney.self, #"{"id":"j","name":"SH99","legs":["# + legs.joined(separator: ",") + "]}", t)
}

// A synthetic leg: `time` is H:MM:SS, the rest plain numbers. Speeds match
// length/time so the leg passes the plausibility checks.
private func legJSON(
    _ name: String,
    direction: String,
    sequence: Int,
    length: Double,
    time: String,
    freeFlow: Double,
    speed: Double = -1,
    way: Int = 1
) -> String {
    #"{"name":"\#(name)","direction":"\#(direction)","sequenceNumber":\#(sequence),"totalLength":\#(length),"time":"\#(time)","freeFlowTime":\#(freeFlow),"speed":\#(speed),"coverage":1,"flow":0.8,"way":{"id":\#(way),"name":"099"}}"#
}

// Metres from `point` to the nearest point on `parts`, measured in the same
// local equirectangular frame the pin placement uses.
private func metresToLine(_ point: CLLocationCoordinate2D, _ parts: [GeoPolyline]) -> Double {
    let metresPerDegree = 111_195.0
    let xScale = cos(point.latitude * .pi / 180)
    var best = Double.greatestFiniteMagnitude
    for part in parts {
        for index in 0..<part.count {
            let ax = (part.longitudes[index] - point.longitude) * xScale
            let ay = part.latitudes[index] - point.latitude
            guard index > 0 else {
                best = min(best, (ax * ax + ay * ay).squareRoot())
                continue
            }
            let bx = (part.longitudes[index - 1] - point.longitude) * xScale
            let by = part.latitudes[index - 1] - point.latitude
            let dx = ax - bx
            let dy = ay - by
            let lengthSquared = dx * dx + dy * dy
            let fraction = lengthSquared > 0 ? min(1, max(0, -(bx * dx + by * dy) / lengthSquared)) : 0
            let qx = bx + fraction * dx
            let qy = by + fraction * dy
            best = min(best, (qx * qx + qy * qy).squareRoot())
        }
    }
    return best * metresPerDegree
}

// MARK: - A3 per-direction totals

private func testJourneyDirections(_ t: TestRunner) {
    t.group("journey totals per direction")
    // Two I legs, both live; two D legs, one live. The API interleaves them.
    guard let journey = journeyFixture(legs: [
        legJSON("Alpha to Bravo", direction: "I", sequence: 0, length: 10, time: "00:10:00", freeFlow: 500, speed: 60),
        legJSON("Bravo to Alpha", direction: "D", sequence: 0, length: 10, time: "00:11:40", freeFlow: 500, speed: 51.43),
        legJSON("Bravo to Charlie", direction: "I", sequence: 1, length: 5, time: "00:05:00", freeFlow: 300, speed: 60),
        legJSON("Charlie to Bravo", direction: "D", sequence: 1, length: 5, time: "00:00:00", freeFlow: 0)
    ], t) else { return }

    t.equal(journey.directions.count, 2, "one summary per direction")
    guard journey.directions.count == 2 else { return }
    let increasing = journey.directions[0]
    let decreasing = journey.directions[1]
    t.check(increasing.direction == .increasing, "increasing direction listed first")
    t.check(decreasing.direction == .decreasing, "decreasing direction second")

    t.nearlyEqual(increasing.currentTime, 900, "I now = its own two legs only (600 + 300 s)")
    t.nearlyEqual(increasing.freeFlowTime, 800, "I free flow over the same legs")
    t.nearlyEqual(increasing.delay, 100, "I delay")
    t.nearlyEqual(increasing.length, 15, "I length is one direction, not both")
    t.equal(increasing.timedLegCount, 2, "both I legs timed")
    t.check(!increasing.isPartial, "I fully covered")
    t.check(!increasing.detailText.contains("live on"), "full coverage isn't called out")

    t.nearlyEqual(decreasing.currentTime, 700, "D now from its one live leg")
    t.nearlyEqual(decreasing.freeFlowTime, 500, "D free flow from that same leg")
    t.nearlyEqual(decreasing.delay, 200, "D delay")
    t.equal(decreasing.timedLegCount, 1, "one D leg timed")
    t.check(decreasing.isPartial, "D is partial")
    t.check(decreasing.detailText.contains("live on 1 of 2 legs"), "partial coverage is stated (got \(decreasing.detailText))")
    t.equal(decreasing.legs.map(\.name), ["Charlie to Bravo", "Bravo to Alpha"], "D legs in travel order (descending sequence)")
    t.equal(increasing.legs.map(\.name), ["Alpha to Bravo", "Bravo to Charlie"], "I legs in travel order")

    t.nearlyEqual(journey.worstDelay, 200, "sort key is the worse direction's delay, not a two-way sum")
    t.equal(
        increasing.detailText,
        "Now 15m · free flow 13m · delay +2m · avg 60 km/h · 15.0 km",
        "I card line"
    )

    // The delay is the difference of the times as shown: 48m 20s (48m)
    // against 40m 45s (41m) is +7m, not the raw 7m 35s rounded to +8m.
    guard let rounding = journeyFixture(legs: [
        legJSON("A to B", direction: "I", sequence: 0, length: 40, time: "00:48:20", freeFlow: 2445, speed: 50)
    ], t) else { return }
    let roundingLine = rounding.directions.first?.detailText ?? ""
    t.check(roundingLine.hasPrefix("Now 48m · free flow 41m · delay +7m"), "the direction line adds up (got \(roundingLine))")

    // A leg with a current time but no free-flow time can't be compared, so it
    // stays out of BOTH sums rather than inflating "now" alone.
    guard let mixed = journeyFixture(legs: [
        legJSON("A to B", direction: "I", sequence: 0, length: 10, time: "00:10:00", freeFlow: 500, speed: 60),
        legJSON("B to C", direction: "I", sequence: 1, length: 10, time: "00:10:00", freeFlow: 0, speed: 60)
    ], t) else { return }
    t.nearlyEqual(mixed.directions.first?.currentTime, 600, "now excludes a leg without free-flow time")
    t.nearlyEqual(mixed.directions.first?.freeFlowTime, 500, "free flow over the same single leg")

    // Nothing live: no times, no delay, still a per-direction length.
    guard let quiet = journeyFixture(legs: [
        legJSON("A to B", direction: "I", sequence: 0, length: 4, time: "00:00:00", freeFlow: 0),
        legJSON("B to A", direction: "D", sequence: 0, length: 4, time: "00:00:00", freeFlow: 0)
    ], t) else { return }
    t.check(quiet.worstDelay == nil, "no live legs -> no delay to sort by")
    t.equal(quiet.directions.first?.detailText, "No live times · 4.0 km", "quiet direction line")
}

// MARK: - A3 direction labels

private func testJourneyDirectionLabels(_ t: TestRunner) {
    t.group("journey direction labels")
    t.check(journeyLegEndpoints("SH16 / SH18 Interchange to Greenhithe").map { [$0.from, $0.to] } == ["SH16 / SH18 Interchange", "Greenhithe"], "splits at ' to '")
    t.check(journeyLegEndpoints("Waipahihi - Waiouru to Taihape")?.from == "Waipahihi - Waiouru", "keeps a hyphenated start")
    t.check(journeyLegEndpoints("Motorway") == nil, "no ' to ' -> nil")
    t.check(journeyLegEndpoints(nil) == nil, "nil name -> nil")

    // The D legs reuse the I legs' names, as NZTA does on SH1 Wellington, so the
    // D label comes from the I end points reversed, not from its own names.
    guard let journey = journeyFixture(legs: [
        legJSON("Manawatu Boundary to Otaki", direction: "I", sequence: 0, length: 4, time: "00:00:00", freeFlow: 0),
        legJSON("Manawatu Boundary to Otaki", direction: "D", sequence: 0, length: 4, time: "00:00:00", freeFlow: 0),
        legJSON("Evans Bay to Wellington Airport", direction: "I", sequence: 1, length: 3, time: "00:00:00", freeFlow: 0),
        legJSON("Evans Bay to Wellington Airport", direction: "D", sequence: 1, length: 3, time: "00:00:00", freeFlow: 0)
    ], t) else { return }
    t.equal(journey.directions.map(\.label), [
        "Manawatu Boundary → Wellington Airport",
        "Wellington Airport → Manawatu Boundary"
    ], "labels come from the increasing end points")

    // Only D legs: read them in travel order (highest sequence first).
    guard let decreasingOnly = journeyFixture(legs: [
        legJSON("Bravo to Alpha", direction: "D", sequence: 0, length: 1, time: "00:00:00", freeFlow: 0),
        legJSON("Charlie to Bravo", direction: "D", sequence: 1, length: 1, time: "00:00:00", freeFlow: 0)
    ], t) else { return }
    t.equal(decreasingOnly.directions.first?.label, "Charlie → Alpha", "D-only journey labelled from its own legs")

    // A loop (same start and end) or unreadable names fall back to NZTA's terms.
    guard let loop = journeyFixture(legs: [
        legJSON("Hangatiki to Waitomo", direction: "I", sequence: 0, length: 1, time: "00:00:00", freeFlow: 0),
        legJSON("Waitomo to Hangatiki", direction: "I", sequence: 1, length: 1, time: "00:00:00", freeFlow: 0),
        legJSON("Link road", direction: "D", sequence: 0, length: 1, time: "00:00:00", freeFlow: 0)
    ], t) else { return }
    t.equal(loop.directions.first?.label, "Increasing direction", "loop falls back to the direction name")
    t.equal(loop.directions.last?.label, "Decreasing direction", "reversed loop falls back too")

    guard let noDirection = journeyFixture(legs: [
        #"{"name":"A to B","sequenceNumber":0,"totalLength":2}"#
    ], t) else { return }
    t.check(noDirection.directions.first?.direction == .unspecified, "a leg without a direction is grouped separately")
    t.equal(noDirection.directions.first?.label, "A → B", "and still labelled by its end points")
}

// MARK: - A4 plausibility

private func testLegDataIssues(_ t: TestRunner) {
    t.group("journey leg plausibility")
    guard let redoubtIncreasing = decodeModel(TrafficJourneyLeg.self, redoubtIncreasingLegJSON, t),
          let redoubtDecreasing = decodeModel(TrafficJourneyLeg.self, redoubtDecreasingLegJSON, t),
          let oteha = decodeModel(TrafficJourneyLeg.self, otehaLegJSON, t) else { return }
    t.check(redoubtIncreasing.dataIssue == nil, "Redoubt Rd → Papakura I (10 km, 8:58 at 67 km/h) is plausible")
    t.check(redoubtDecreasing.dataIssue == .timeContradictsSpeed, "the D twin's 53:15 for 10 km at 77 km/h is flagged")
    t.check(oteha.dataIssue == .impossibleSpeed, "Oteha → SH18: 9.02 km in 11 s is flagged")
    t.nearlyEqual(redoubtDecreasing.currentTimeSeconds, 3195, "the flagged leg keeps its reported time for the tooltip")

    // The pure check on its own.
    t.check(
        journeyLegDataIssue(length: 3.41, speed: 86.9, speedLimit: 100, currentTime: 88, freeFlowTime: 77) == nil,
        "Keneperu → Tawa (0.6× its measured speed) stays within tolerance"
    )
    t.check(
        journeyLegDataIssue(length: 5, speed: 60, speedLimit: 100, currentTime: 300, freeFlowTime: 1800) == .freeFlowContradictsLimit,
        "a free-flow time far off length/limit is flagged"
    )
    t.check(
        journeyLegDataIssue(length: nil, speed: nil, speedLimit: nil, currentTime: 100, freeFlowTime: 500) == .freeFlowExceedsCurrent,
        "free flow over twice the current time is flagged"
    )
    t.check(
        journeyLegDataIssue(length: nil, speed: 60, speedLimit: 100, currentTime: 3000, freeFlowTime: 200) == nil,
        "nothing to check without a length (a slow leg is not an error)"
    )
    t.check(
        journeyLegDataIssue(length: 10, speed: -1, speedLimit: 0, currentTime: 0, freeFlowTime: 0) == nil,
        "a leg with no live times has no data issue"
    )
}

private func testRealJourneyWithBadLegs(_ t: TestRunner) {
    t.group("SH20B: bad legs left out of the totals")
    guard let journey = decodeModel(TrafficJourney.self, sh20bJourneyJSON, t),
          journey.directions.count == 2 else {
        t.check(false, "SH20B fixture decodes into two directions")
        return
    }
    let increasing = journey.directions[0]
    let decreasing = journey.directions[1]
    t.equal(increasing.label, "Puhinui → Orrs Road", "I label from its end legs")
    t.equal(decreasing.label, "Orrs Road → Puhinui", "D label reversed")
    t.nearlyEqual(increasing.currentTime, 206, "I now = 2:40 + 0:46")
    t.nearlyEqual(increasing.freeFlowTime, 103.5, tolerance: 0.01, "I free flow = 80.06 + 23.44 s")
    t.nearlyEqual(increasing.delay, 102.5, tolerance: 0.01, "I delay about 1:42")
    t.equal(decreasing.dataIssueLegCount, 2, "both D legs flagged")
    t.check(decreasing.currentTime == nil, "D has no reliable time left")
    t.check(decreasing.detailText.hasPrefix("No reliable live times"), "D line says so (got \(decreasing.detailText))")
    t.check(decreasing.detailText.contains("2 legs left out (data issue)"), "and surfaces the excluded legs")
    t.nearlyEqual(journey.worstDelay, 102.5, tolerance: 0.01, "sort key ~102 s, not the 1,899 s the bad legs produced")
    t.equal(journey.dataIssueLegCount, 2, "journey-level data-issue count")
}

// MARK: - B11 leg ids

private func testLegIDs(_ t: TestRunner) {
    t.group("journey leg ids")
    guard let journey = decodeModel(
        TrafficJourney.self,
        #"{"id":3,"name":"SH1","legs":["# + redoubtIncreasingLegJSON + "," + redoubtDecreasingLegJSON + "]}",
        t
    ) else { return }
    let ids = journey.legs.map(\.id)
    t.equal(Set(ids).count, 2, "I/D twins sharing name and sequence get distinct ids")
    t.check(ids.first?.contains("|I|") == true, "the id carries the direction")
    t.check(ids.first?.contains("1272") == true, "and the way id")

    // Fully identical records (same direction, way, name and sequence) still
    // get unique ids within their journey.
    let twin = legJSON("A to B", direction: "I", sequence: 0, length: 1, time: "00:00:00", freeFlow: 0)
    guard let duplicated = journeyFixture(legs: [twin, twin, twin], t) else { return }
    t.equal(Set(duplicated.legs.map(\.id)).count, 3, "exact duplicates are suffixed to stay unique")
}

// MARK: - A15 WKT parts

private func testWKTParts(_ t: TestRunner) {
    t.group("WKT parts stay separate")
    // SH20B's journey geometry: four parts, alternating I and D.
    let route = parseWKTParts(
        "MULTILINESTRING ((174.8450111275632 -36.992804931970234, 174.82606333871155 -36.99936714886306), "
            + "(174.82606333871155 -36.99936714886306, 174.8450111275632 -36.992804931970234), "
            + "(174.82606333871155 -36.99936714886306, 174.8204918527637 -37.00129770136158), "
            + "(174.8204918527637 -37.00129770136158, 174.82606333871155 -36.99936714886306))"
    )
    t.equal(route.count, 4, "a four-part MULTILINESTRING yields four runs")
    t.equal(route.map(\.count), [2, 2, 2, 2], "each run keeps only its own vertices")
    // Flattened, part 2 (ending at Puhinui) would join part 3 (starting at
    // Campana Rd) with a chord; kept apart, no run contains that jump.
    t.nearlyEqual(route[1].longitudes.last, 174.8450111275632, "part 2 ends at Puhinui")
    t.nearlyEqual(route[2].longitudes.first, 174.82606333871155, "part 3 starts at Campana Rd on its own")

    let twoPartLeg = decodeModel(
        TrafficJourneyLeg.self,
        #"{"name":"A to B","geometry":"MULTILINESTRING ((174 -41, 174.1 -41.1), (175 -42, 175.1 -42.1))"}"#,
        t
    )
    t.equal(twoPartLeg?.polylineParts.count, 2, "a multi-part leg keeps two drawable parts")
    t.check(twoPartLeg?.hasMapGeometry == true, "and has map geometry")

    let point = parseWKTParts("POINT (172.5 -43.5)")
    t.equal(point.count, 1, "POINT is one run")
    t.check(point.first?.isDrawable == false, "a lone point isn't drawable as a line")

    let withZ = parseWKTParts("LINESTRING Z (174 -41 12.5, 175 -42 13)")
    t.equal(withZ.first?.latitudes ?? [], [-41, -42], "a Z value after the pair is ignored")

    let withInvalid = parseWKTParts("LINESTRING (0 0, 174 -41, 200 -41, 174.5 -95, 175 -42)")
    t.equal(withInvalid.first?.count, 2, "0,0 and out-of-range pairs are skipped")

    t.equal(parseWKTParts("LINESTRING (1.2.3 -41, 174 -41)").first?.count, 1, "a malformed number drops its pair")
    t.equal(parseWKTParts("LINESTRING (174e0 -4.1e1)").first?.latitudes ?? [], [-41], "exponent notation parses")
    t.check(parseWKTParts("LINESTRING EMPTY").isEmpty, "EMPTY -> no parts")
    t.check(parseWKTParts("   ").isEmpty, "blank -> no parts")
}

// MARK: - B9 event pins

private func testEventPins(_ t: TestRunner) {
    t.group("event pins sit on the line")
    let pointEvent = decodeModel(RoadEvent.self, #"{"id":"e","geometry":"POINT (172.5 -43.5)"}"#, t)
    t.nearlyEqual(pointEvent?.mapCoordinate?.latitude, -43.5, "POINT event maps to its point (latitude)")
    t.nearlyEqual(pointEvent?.mapCoordinate?.longitude, 172.5, "POINT event maps to its point (longitude)")

    // L-shaped line: the bounding-box centre (170.5, -43.5) is off the line.
    let lShape = "MULTILINESTRING ((170 -44, 170 -43), (170 -43, 171 -43))"
    guard let lPin = coordinateFromWKTGeometry(lShape) else {
        t.check(false, "L-shaped line yields a pin")
        return
    }
    t.check(metresToLine(lPin, parseWKTParts(lShape)) < 1, "L-shaped line: pin lies on the line")
    let bboxCentre = CLLocationCoordinate2D(latitude: -43.5, longitude: 170.5)
    t.check(metresToLine(bboxCentre, parseWKTParts(lShape)) > 30_000, "(the old bbox-centre pin was ~40 km off)")

    guard let haast = decodeModel(RoadEvent.self, #"{"id":561536,"geometry":"\#(haastGeometry)"}"#, t),
          let haastPin = haast.mapCoordinate else {
        t.check(false, "SH6 Paringa–Haast event maps")
        return
    }
    let haastParts = parseWKTParts(haastGeometry)
    t.check(metresToLine(haastPin, haastParts) < 1, "SH6 Paringa–Haast pin is on the road")
    let lats = haastParts.flatMap(\.latitudes)
    let lons = haastParts.flatMap(\.longitudes)
    let oldPin = CLLocationCoordinate2D(
        latitude: ((lats.min() ?? 0) + (lats.max() ?? 0)) / 2,
        longitude: ((lons.min() ?? 0) + (lons.max() ?? 0)) / 2
    )
    t.check(metresToLine(oldPin, haastParts) > 8_000, "(its bbox centre was 8.8 km off the road)")
}

// MARK: - B21 linear-time parsing

private func testWKTLinearTime(_ t: TestRunner) {
    t.group("WKT parsing is linear")
    // The old backtracking regex took ~5 s on 10,000 digits and ~86 s on 40,000.
    let digits = String(repeating: "1", count: 200_000)
    let start = Date()
    let pin = coordinateFromWKTGeometry("POINT (" + digits + ")")
    let parts = parseWKTParts("LINESTRING (" + digits + " " + digits + ", 174 -41)")
    let elapsed = Date().timeIntervalSince(start)
    t.check(pin == nil, "a 200,000-digit number is not a coordinate")
    t.equal(parts.first?.count, 1, "the valid pair after it still parses")
    t.check(elapsed < 1, "200,000 digits parse in well under a second (took \(elapsed) s)")
}

// MARK: - A10 lenient section decoding

private func testLenientSectionDecoding(_ t: TestRunner) {
    t.group("lenient section decoding")
    func cameras(_ json: String) -> CameraResponse? {
        try? JSONDecoder().decode(CamerasPayload.self, from: Data(json.utf8)).response
    }
    func throwsDecoding<T: Decodable>(_ type: T.Type, _ json: String) -> Bool {
        (try? JSONDecoder().decode(T.self, from: Data(json.utf8))) == nil
    }

    let withNull = cameras(#"{"response":{"camera":[{"id":1,"name":"a"},null,{"id":2,"name":"b"}]}}"#)
    t.equal(withNull?.camera.count, 2, "a null element is skipped, not the whole list")
    t.equal(withNull?.droppedCount, 1, "and counted")
    let withString = cameras(#"{"response":{"camera":[{"id":1,"name":"a"},"oops"]}}"#)
    t.equal(withString?.camera.count, 1, "a string element is skipped")
    t.equal(withString?.droppedCount, 1, "and counted")

    t.check(throwsDecoding(CamerasPayload.self, #"{"response":{"camera":[null,"x",3]}}"#), "a list with no readable entry is a failure")
    t.check(throwsDecoding(CamerasPayload.self, #"{"response":{"cameras":[{"id":1}]}}"#), "a renamed list key is a failure")
    t.check(throwsDecoding(CamerasPayload.self, #"{"response":{"error":"maintenance"}}"#), "an error body is a failure")
    t.check(throwsDecoding(CamerasPayload.self, #"{"response":{"camera":"none"}}"#), "a list that is a string is a failure")
    t.check(throwsDecoding(CamerasPayload.self, #"{"error":"maintenance"}"#), "a missing response is a failure")

    t.equal(cameras(#"{"response":{}}"#)?.camera.count, 0, "an empty response is an empty list, not an error")
    t.equal(cameras(#"{"response":{"camera":[]}}"#)?.camera.count, 0, "an empty list decodes")
    t.equal(cameras(#"{"response":{"camera":null}}"#)?.camera.count, 0, "a null list decodes as empty")
    t.equal(cameras(#"{"response":{"camera":{"id":1,"name":"solo"}}}"#)?.camera.count, 1, "a lone object is a one-element list")

    let camelEvents = try? JSONDecoder().decode(
        RoadEventsPayload.self,
        from: Data(#"{"response":{"roadEvent":[{"id":"e1","eventDescription":"Slip"}]}}"#.utf8)
    )
    t.equal(camelEvents?.response.roadevent.count, 1, "the roadEvent spelling still decodes")

    // ArcGIS answers some failures with HTTP 200 and an error body.
    t.check(
        throwsDecoding(EVChargersPayload.self, #"{"error":{"code":400,"message":"Invalid query","details":[]}}"#),
        "an ArcGIS error body is a failure, not zero chargers"
    )
    t.equal(
        (try? JSONDecoder().decode(EVChargersPayload.self, from: Data(#"{"type":"FeatureCollection","features":[]}"#.utf8)))?.features.count,
        0,
        "an empty FeatureCollection decodes"
    )

    // Nested lists are lenient too: one bad leg or TIM line is skipped.
    let journey = decodeModel(
        TrafficJourney.self,
        #"{"id":1,"name":"SH1","legs":[{"name":"A to B","direction":"I"},null,"junk"]}"#,
        t
    )
    t.equal(journey?.legs.count, 1, "a bad leg is skipped, the journey keeps the rest")
    let tim = try? JSONDecoder().decode(
        TIMSignsPayload.self,
        from: Data(#"{"response":{"tim":[{"id":1,"name":"Board","page":{"line":[{"left":"CBD","right":12},7]}}]}}"#.utf8)
    )
    t.equal(tim?.response.tim.first?.lines.count, 1, "a bad TIM line is skipped")

    // Export Diagnostics reports what was skipped.
    let report = DiagnosticsReport(
        appVersion: "1",
        appBuild: "1",
        generatedAt: Date(timeIntervalSince1970: 0),
        lastUpdated: nil,
        isOnline: true,
        sections: [
            .init(name: "Cameras", count: 312, error: nil, droppedCount: 1),
            .init(name: "VMS Signs", count: 390, error: "boom", droppedCount: 4)
        ],
        preferences: [:]
    ).formattedText()
    t.check(report.contains("Cameras: 312 (1 unreadable entry skipped)"), "diagnostics list a skipped entry")
    t.check(report.contains("VMS Signs: 390 (4 unreadable entries skipped) — ERROR: boom"), "alongside any error")
}

private func testSectionRefreshDecision(_ t: TestRunner) {
    t.group("empty refresh keeps last good data")
    t.check(sectionRefreshDecision(fetchedCount: 0, currentCount: 313) == .keepPrevious, "empty list over loaded data is suspect")
    t.check(sectionRefreshDecision(fetchedCount: 0, currentCount: 0) == .replace(persist: false), "empty over empty is accepted but not cached")
    t.check(sectionRefreshDecision(fetchedCount: 312, currentCount: 313) == .replace(persist: true), "a normal refresh replaces and caches")
    t.check(sectionRefreshDecision(fetchedCount: 5, currentCount: 0) == .replace(persist: true), "a first load replaces and caches")
}

// MARK: - A18 overflow-safe numbers

private func testOverflowSafeNumbers(_ t: TestRunner) {
    t.group("overflow-safe numeric conversions")
    // decodeLossyString used to trap on whole numbers beyond Int.
    t.equal(decodeModel(TrafficCamera.self, #"{"id":1e20,"name":"x"}"#, t)?.rawId, "1e+20", "id 1e20 keeps its Double spelling")
    t.check(decodeModel(TrafficCamera.self, #"{"id":12345678901234567890,"name":"x"}"#, t)?.rawId != nil, "id beyond Int.max decodes")
    t.equal(decodeModel(TrafficCamera.self, #"{"id":"a","name":-1e19}"#, t)?.name, "-1e+19", "name -1e19 decodes")
    t.equal(decodeModel(TrafficCamera.self, #"{"id":42.0,"name":"x"}"#, t)?.rawId, "42", "a whole Double still reads without .0")
    t.equal(decodeModel(TrafficCamera.self, #"{"id":4.5,"name":"x"}"#, t)?.rawId, "4.5", "a fraction keeps its decimals")
    let timLine = try? JSONDecoder().decode(
        TIMSignsPayload.self,
        from: Data(#"{"response":{"tim":[{"id":1,"page":{"line":[{"left":"CBD","right":1e20}]}}]}}"#.utf8)
    )
    t.equal(timLine?.response.tim.first?.lines.first?.timeText, "1e+20", "TIM right 1e20 falls through safely")

    // parseTimeIntervalString did Int arithmetic that overflowed during decode.
    t.nearlyEqual(parseTimeIntervalString("01:06:41"), 4001, "normal H:MM:SS")
    t.nearlyEqual(parseTimeIntervalString("3000000000000000:00:00"), 1.08e19, tolerance: 1e5, "absurd hours don't overflow")
    t.check(parseTimeIntervalString("99999999999999999999:00:00") == nil, "hours beyond Int -> nil")
    t.check(parseTimeIntervalString("-1:00:00") == nil, "negative -> nil")
    t.check(parseTimeIntervalString("00:75:00") == nil, "minutes over 59 -> nil")
    t.check(parseTimeIntervalString("00:00:60") == nil, "seconds over 59 -> nil")
    t.check(parseTimeIntervalString("1:2") == nil, "two fields -> nil")
    let absurdLeg = decodeModel(
        TrafficJourneyLeg.self,
        #"{"name":"A to B","time":"3000000000000000:00:00","totalLength":5,"speed":60,"freeFlowTime":200}"#,
        t
    )
    t.check(absurdLeg?.dataIssue == .timeContradictsSpeed, "an absurd leg time decodes and is flagged, not trapped")

    t.equal(formatWholeNumber(82.4), "82", "rounds to a whole number")
    t.equal(formatWholeNumber(-0.4), "0", "negative zero reads 0")
    t.equal(formatWholeNumber(9.2e18), "9200000000000000000", "just inside Int range")
    t.check(formatWholeNumber(1e19) == nil, "1e19 -> nil, no trap")
    t.check(formatWholeNumber(-1e19) == nil, "-1e19 -> nil, no trap")
    t.check(formatWholeNumber(.nan) == nil, "NaN -> nil, no trap")
    t.check(formatWholeNumber(.infinity) == nil, "infinity -> nil, no trap")
    t.equal(formatTimeInterval(1e19), "16666h 40m", "a 1e19 s duration is clamped, not trapped")

    // EV power strings are parsed into a Double and shown as a whole number.
    func charger(_ connectors: String) -> EVCharger? {
        decodeModel(
            EVCharger.self,
            #"{"type":"Feature","geometry":{"type":"Point","coordinates":[174.76,-36.85]},"properties":{"name":"X","currentType":"DC","connectorsList":"\#(connectors)"}}"#,
            t
        )
    }
    t.equal(charger("{DC, 1e19 kW, Type 2 CCS, Status: Operative, Count:1}")?.powerSummary, "DC", "1e19 kW is dropped, not trapped")
    t.equal(charger("{DC, 99999999999999999999 kW, CHAdeMO, Status: Operative, Count:1}")?.powerSummary, "DC", "a 20-digit kW is dropped")
    t.equal(charger("{DC, 50 kW, CHAdeMO, Status: Operative, Count:1}")?.powerSummary, "DC · 50 kW", "normal power still shows")

    // Sums of huge lengths overflow to infinity (inf/inf = NaN average speed).
    guard let huge = journeyFixture(legs: [
        #"{"name":"A to B","direction":"I","sequenceNumber":0,"totalLength":1e308,"speed":50,"coverage":1,"flow":0.5}"#,
        #"{"name":"B to C","direction":"I","sequenceNumber":1,"totalLength":1e308,"speed":50,"coverage":1,"flow":0.5}"#
    ], t) else { return }
    t.check(huge.directions.first?.averageSpeed == nil, "a NaN average speed is dropped")
    t.equal(huge.directions.first?.detailText, "No live times", "and the line renders without it or the infinite length")
    guard let fast = journeyFixture(legs: [
        #"{"name":"A to B","direction":"I","sequenceNumber":0,"totalLength":1,"speed":1e19,"coverage":1,"flow":0.5}"#
    ], t) else { return }
    t.equal(fast.directions.first?.detailText, "No live times · 1.0 km", "a 1e19 km/h speed isn't shown")
}
