import Foundation

// Event lifecycle (status), the whole-highway filter, TIM journey decoding
// and the small model fixes from the 2026-09 review (A1, A6, A7, B12, B13,
// B14, B17, B29). Fixtures are trimmed copies of real records from the
// 2026-09-26 rest/5 snapshots, so they carry the feed's actual shapes.
func runEventFilterTests(_ t: TestRunner) {
    testEventStatusParsing(t)
    testActiveClosures(t)
    testEventSortOrder(t)
    testCanonicalHighwayKey(t)
    testHighwayMentions(t)
    testHighwayFilterCameras(t)
    testHighwayFilterJourneys(t)
    testHighwayFilterEventsAndVMS(t)
    testHighwayFilterTIM(t)
    testHighwayQueryFallback(t)
    testEventDatePhrase(t)
    testDurationFormat(t)
    testEVMixedIsDC(t)
    testEventDecodeGaps(t)
    testTrafficNZURL(t)
}

// MARK: - Fixtures (real records, trimmed)

// 562504: Active closure (SH94 snow).
private let activeClosureJSON = #"""
{"id":562504,"eventDescription":"Snow","eventType":"Area Warning","impact":"Road Closed","status":"Active","planned":false,"locationArea":"SH 94 Te Anau to Milford","locations":"094-0212/15.60-B - 094-0241/09.90-B   NA TO NA to ERP BRIDGE 128 TO NA","startDate":"2026-09-26T07:54:51.163+12:00","alternativeRoute":"Not Applicable","journey":{"id":124,"name":"SH94"},"way":{"id":1165,"name":"094"},"region":{"id":14,"name":"Southland"}}
"""#

// 562315: Scheduled overnight closure starting the next evening.
private let scheduledClosureJSON = #"""
{"id":562315,"eventDescription":"Road Works","eventType":"Area Warning","impact":"Road Closed","status":"Scheduled","planned":true,"locationArea":"SH 3 Ashhurst to Woodville (Manawatu Tararua Highway), eastbound","locations":"03T-0489/03.60-I - 03T-0489/10.65-I   CALIBRATION NODE 2 (RL 283) TO CALIBRATION NODE 3 (RL 287) to CALIBRATION NODE 4 (RL 93) TO RAB 500-W (RL 84)","startDate":"2026-09-27T20:00:00+13:00","endDate":"2026-09-27T22:00:00+13:00","alternativeRoute":"Eastbound traffic, detour via Saddle Road","journey":{"id":65,"name":"SH3"},"way":{"id":611,"name":"003"},"region":{"id":8,"name":"Manawatu-Whanganui"}}
"""#

// 562552: Resolved crash closure that ended earlier the same day.
private let resolvedClosureJSON = #"""
{"id":562552,"eventDescription":"Crash","eventType":"Road Hazard","impact":"Road Closed","status":"Resolved","planned":false,"locationArea":"SH 5 Tirau to Rotorua","locations":"005-0029/13.99   Ngongotaha","startDate":"2026-09-26T03:20:00+12:00","endDate":"2026-09-26T15:51:24.150+12:00","alternativeRoute":"N/A","journey":{"id":22,"name":"SH5"},"way":{"id":195,"name":"005"},"region":{"id":4,"name":"Bay Of Plenty"}}
"""#

// 561377: `locations` sent as an array; journey "SH1N", way "01N".
private let arrayLocationsJSON = #"""
{"id":561377,"eventDescription":"Resurfacing","eventType":"Area Warning","impact":"Caution","status":"Active","planned":true,"locationArea":"SH 1 Cambridge","locations":["01N-0546/23.94-I - 01N-0574/02.91-I   Cambridge","01N-0546/23.96-D - 01N-0574/02.90-D   Cambridge","01N-0574/02.93-D - 01N-0574/04.70   Cambridge"],"startDate":"2026-09-15T15:36:00+12:00","endDate":"2026-11-13T17:00:00+13:00","alternativeRoute":"N/A","journey":{"id":345,"name":"SH1N"},"way":{"id":1265,"name":"01N"},"region":{"id":3,"name":"Waikato"}}
"""#

// 554438: the one event carrying `restrictions`.
private let restrictionsJSON = #"""
{"id":554438,"eventDescription":"Washout","eventType":"Area Warning","impact":"Vehicle Restrictions","status":"Active","planned":false,"locationArea":"SH NA Inland Route 70 - Kaikoura to Greenburn Creek Bridge.","locations":"070-0070/77.50-B - 070-0070/07.60-B   NA TO NA","startDate":"2026-07-08T18:11:34+12:00","alternativeRoute":"Not applicable","restrictions":"Controlled Access Only","journey":{"id":86,"name":"SH1"},"way":{"id":773,"name":"01S"},"region":{"id":11,"name":"Canterbury"}}
"""#

// 560690: Active SH2 closure whose alternative route mentions SH2 again.
private let sh2ClosureJSON = #"""
{"id":560690,"eventDescription":"Road Construction","eventType":"Area Warning","impact":"Road Closed","status":"Active","planned":true,"locationArea":"SH 2 Carterton between Howard Street and Brooklyn Road, northbound","locations":"002-0883/16.88-B - 002-0883/16.47-B   COSTLEY ST TO BROOKLYN RD to HOWARD ST TO COSTLEY ST","startDate":"2026-09-21T06:00:00+12:00","endDate":"2026-10-09T18:00:00+13:00","alternativeRoute":"Northobund traffic, detour via Brooklyn Road to Lincoln Road and then onto Pembroke Street.","journey":{"id":9,"name":"SH2"},"way":{"id":71,"name":"002"},"region":{"id":9,"name":"Wellington"}}
"""#

// 541001: Active SH26 closure whose detour text names SH 1C.
private let detourMentionJSON = #"""
{"id":541001,"eventDescription":"Road Works","eventType":"Area Warning","impact":"Road Closed","status":"Active","planned":false,"locationArea":"SH 26 Hillcrest","locations":"026-0001/00.35 - 026-0001/00.63-D   Newstead to Hillcrest","startDate":"2026-02-20T13:49:00+13:00","alternativeRoute":"Eastbound traffic from SH 1C turn left onto Wairere Dr, right onto Clyde St, and rejoin SH 26.","journey":{"id":29,"name":"SH26"},"way":{"id":266,"name":"026"},"region":{"id":3,"name":"Waikato"}}
"""#

private func event(_ json: String, _ t: TestRunner) -> RoadEvent? {
    decodeModel(RoadEvent.self, json, t)
}

// Swap the status of a fixture without hand-editing the JSON literal.
private func event(_ json: String, status: String?, _ t: TestRunner) -> RoadEvent? {
    let replaced: String
    if let status {
        replaced = json.replacingOccurrences(of: #""status":"Active""#, with: #""status":"\#(status)""#)
    } else {
        replaced = json.replacingOccurrences(of: #""status":"Active","#, with: "")
    }
    return decodeModel(RoadEvent.self, replaced, t)
}

// MARK: - A1 event status

private func testEventStatusParsing(_ t: TestRunner) {
    t.group("event status parsing")
    t.equal(EventStatus(raw: "Active"), .active, "Active")
    t.equal(EventStatus(raw: " active "), .active, "case- and whitespace-insensitive")
    t.equal(EventStatus(raw: "Scheduled"), .scheduled, "Scheduled")
    t.equal(EventStatus(raw: "RESOLVED"), .resolved, "Resolved (upper case)")
    t.equal(EventStatus(raw: nil), .unknown(nil), "missing status is unknown")
    t.equal(EventStatus(raw: "  "), .unknown(nil), "blank status is unknown")
    t.equal(EventStatus(raw: "Cancelled"), .unknown("Cancelled"), "unrecognised status kept raw")

    t.equal(EventStatus.scheduled.label, "Upcoming", "Scheduled is labelled Upcoming")
    t.equal(EventStatus.resolved.label, "Resolved", "Resolved label")
    t.equal(EventStatus.active.label, "Active", "Active label")
    t.equal(EventStatus.unknown("Cancelled").label, "Cancelled", "unknown label is the raw value")
    t.check(EventStatus.unknown(nil).label == nil, "no status -> no label")

    t.check(EventStatus.active.isCurrent, "Active is current")
    t.check(EventStatus.unknown(nil).isCurrent, "missing status fails safe as current")
    t.check(EventStatus.unknown("Cancelled").isCurrent, "unrecognised status fails safe as current")
    t.check(!EventStatus.scheduled.isCurrent, "Scheduled is not current")
    t.check(!EventStatus.resolved.isCurrent, "Resolved is not current")

    guard let scheduled = event(scheduledClosureJSON, t) else { return }
    t.equal(scheduled.status, "Scheduled", "raw status still decoded")
    t.equal(scheduled.statusKind, .scheduled, "statusKind decoded from the record")
    t.check(scheduled.isUpcoming && !scheduled.isActive && !scheduled.isResolved, "scheduled record flags")
}

private func testActiveClosures(_ t: TestRunner) {
    t.group("active closures (Dock badge / menu bar)")
    guard let active = event(activeClosureJSON, t),
          let scheduled = event(scheduledClosureJSON, t),
          let resolved = event(resolvedClosureJSON, t),
          let noStatus = event(activeClosureJSON, status: nil, t),
          let oddStatus = event(activeClosureJSON, status: "Reopening", t) else { return }

    t.check(active.isClosure && active.isActiveClosure, "Active + Road Closed is an active closure")
    t.check(scheduled.isClosure && !scheduled.isActiveClosure, "Scheduled + Road Closed is not counted")
    t.check(resolved.isClosure && !resolved.isActiveClosure, "Resolved + Road Closed is not counted")
    t.check(noStatus.isActiveClosure, "Road Closed with no status is counted (fail safe)")
    t.check(oddStatus.isActiveClosure, "Road Closed with an unrecognised status is counted")

    // The same three-closure mix as the 09-26 feed's Active/Scheduled/Resolved
    // split: the badge must show 1, not 3.
    let events = [active, scheduled, resolved]
    t.equal(events.filter(\.isActiveClosure).count, 1, "only the active closure counts")

    t.check(active.isVisible(showResolved: false), "active events are always listed")
    t.check(scheduled.isVisible(showResolved: false), "upcoming events are listed by default")
    t.check(!resolved.isVisible(showResolved: false), "resolved events are hidden by default")
    t.check(resolved.isVisible(showResolved: true), "Show resolved lists them")
}

private func testEventSortOrder(_ t: TestRunner) {
    t.group("event sort order")
    guard let activeClosure = event(activeClosureJSON, t),
          let scheduledClosure = event(scheduledClosureJSON, t),
          let resolvedClosure = event(resolvedClosureJSON, t),
          let activeCaution = event(arrayLocationsJSON, t),
          let otherActiveClosure = event(sh2ClosureJSON, t) else { return }

    let sorted = [resolvedClosure, activeCaution, scheduledClosure, otherActiveClosure, activeClosure]
        .sorted(by: roadEventSortsBefore)
    t.equal(
        sorted.map { $0.rawId ?? "" },
        ["560690", "562504", "561377", "562315", "562552"],
        "active (closures by title, then caution) → upcoming → resolved"
    )
}

// MARK: - A6 highway keys

private func testCanonicalHighwayKey(_ t: TestRunner) {
    t.group("canonicalHighwayKey")
    let cases: [(String?, String?)] = [
        ("SH1", "1"), ("SH 1", "1"), ("sh-1", "1"), ("State Highway 1", "1"), ("state highway 1", "1"),
        ("1", "1"), ("01", "1"), ("001", "1"), ("01N", "1"), ("01S", "1"), ("SH1N", "1"), ("SH1S", "1"),
        ("Hwy 16", "16"), ("Highway 2", "2"), ("SH16", "16"), ("016", "16"), ("020", "20"), ("SH20", "20"),
        ("20A", "20A"), ("SH20a", "20A"), ("SH 25A", "25A"), ("03A", "3A"), ("1B", "1B"), ("SH1B", "1B"),
        ("SH74M", "74M"), ("2N", "2N"),
        ("ART", nil), ("CNC", nil), ("CNA", nil), ("SH", nil), ("", nil), (nil, nil), ("SH0", nil),
        ("SH1234", nil), ("SH1AB", nil), ("Old SH1", nil), ("SH NA", nil)
    ]
    for (input, expected) in cases {
        t.equal(canonicalHighwayKey(input), expected, "canonicalHighwayKey(\(input.map { "\"\($0)\"" } ?? "nil"))")
    }
}

private func testHighwayMentions(_ t: TestRunner) {
    t.group("highway mentions in text")
    t.equal(highwayMentions(in: "SH 1 Invercargill to Awarua"), ["1"], "event locationArea form")
    t.equal(highwayMentions(in: "SH16/20 Interchange South"), ["16", "20"], "slash-joined short junction form")
    t.equal(highwayMentions(in: "SH1/SH90 INTERSECTION"), ["1", "90"], "slash-joined full junction form")
    t.equal(highwayMentions(in: "SH2/SH50/SH51 Taradale Rd Roundabout"), ["2", "50", "51"], "three-way junction")
    t.equal(highwayMentions(in: "008-0310 TO STATE HIGHWAY 34"), ["34"], "STATE HIGHWAY n")
    t.equal(highwayMentions(in: "SH 25A Kopu"), ["25A"], "spur letter kept")
    t.equal(highwayMentions(in: "Old SH1"), ["1"], "embedded SH token")
    t.equal(highwayMentions(in: "12 Auckland Airport to Auckland City Centre"), [], "bare numbers are not highways")
    t.equal(highwayMentions(in: "SH NA Inland Route 70"), [], "no number after SH")
    t.equal(highwayMentions(in: "SHORE RD SH1234"), [], "over-long number ignored")
    t.equal(highwayMentions(in: nil), [], "nil text")
}

private func cameraFixture(_ json: String, _ t: TestRunner) -> TrafficCamera? {
    decodeModel(TrafficCamera.self, json, t)
}

private func testHighwayFilterCameras(_ t: TestRunner) {
    t.group("highway filter: cameras")
    guard let sh1 = cameraFixture(#"{"id":714,"name":"SH1 Tinwald ","description":"South along Hinds Highway from Lagmhor Rd","highway":"SH1","journey":{"id":86,"name":"SH1"},"way":{"id":805,"name":"01S"},"region":{"id":11,"name":"Canterbury"}}"#, t),
          let sh16 = cameraFixture(#"{"id":654,"name":"SH16 Carrington Rd Overbridge","description":"East along Nth Wstn Mwy from Carrington Rd","highway":"SH16","journey":{"id":1,"name":"SH16"},"way":{"id":11,"name":"016"},"region":{"id":2,"name":"Auckland"}}"#, t),
          let sh18 = cameraFixture(#"{"id":823,"name":"SH18 Unsworth Heights","description":"East along Upper Hbr Mwy from Unsworth Heights","highway":"SH18","journey":{"id":2,"name":"SH18"},"way":{"id":23,"name":"018"},"region":{"id":2,"name":"Auckland"}}"#, t),
          let sh20 = cameraFixture(#"{"id":653,"name":"SH20 May Rd Overbridge","description":"North along Sth Wstn Mwy from May Rd","highway":"SH20","journey":{"id":4,"name":"SH20"},"way":{"id":54,"name":"020"},"region":{"id":2,"name":"Auckland"}}"#, t),
          let sh29 = cameraFixture(#"{"id":603,"name":"SH29 Kaimai Eastern","description":"West along SH29 Kaimai Ranges","highway":"SH29","journey":{"id":44,"name":"SH29"},"way":{"id":391,"name":"029"},"region":{"id":4,"name":"Bay Of Plenty"}}"#, t),
          let junction = cameraFixture(#"{"id":655,"name":"SH16/20 Interchange South","description":"South from Nth Wstn Mwy to Waterview Tunnel\r\n","highway":"SH16","journey":{"id":1,"name":"SH16"},"way":{"id":12,"name":"016"},"region":{"id":2,"name":"Auckland"}}"#, t),
          let art = cameraFixture(#"{"id":310,"name":"Rangiora North","description":"North along Ashley St from High St","highway":"ART","way":{"id":"071","name":"071"},"region":{"id":11,"name":"Canterbury"}}"#, t),
          let arthurs = cameraFixture(#"{"id":665,"name":"SH73 Arthurs Pass","description":"South along SH73 in Arthurs Pass","highway":"SH73","journey":{"id":88,"name":"SH73"},"way":{"id":839,"name":"073"},"region":{"id":11,"name":"Canterbury"}}"#, t) else { return }

    for query in ["SH1", "sh1", "SH 1", "sh-1", "State Highway 1", "1", "01S"] {
        t.check(sh1.matches(region: "", highway: query, search: ""), "\"\(query)\" matches an SH1 camera")
    }
    t.check(!sh16.matches(region: "", highway: "SH1", search: ""), "SH1 does not match SH16")
    t.check(!sh18.matches(region: "", highway: "SH1", search: ""), "SH1 does not match SH18")
    t.check(!sh20.matches(region: "", highway: "SH2", search: ""), "SH2 does not match SH20")
    t.check(!sh29.matches(region: "", highway: "SH2", search: ""), "SH2 does not match SH29")
    t.check(sh16.matches(region: "", highway: "SH16", search: ""), "SH16 matches SH16")
    t.check(sh20.matches(region: "", highway: "020", search: ""), "way code 020 matches SH20")
    t.check(junction.matches(region: "", highway: "SH20", search: ""), "SH16/20 interchange camera matches SH20")
    t.check(junction.matches(region: "", highway: "SH16", search: ""), "…and SH16")
    t.check(!junction.matches(region: "", highway: "SH2", search: ""), "…but not SH2")
    t.check(art.matches(region: "", highway: "art", search: ""), "non-highway route code matches as a whole word")
    t.check(!arthurs.matches(region: "", highway: "art", search: ""), "\"art\" does not match inside \"Arthurs\"")
    t.check(sh1.matches(region: "", highway: "SH", search: ""), "bare SH matches anything on a state highway")
    t.check(art.matches(region: "", highway: "SH71", search: ""), "an ART camera on way 071 is on SH71")
    let local = cameraFixture(#"{"id":2,"name":"Queen St","highway":""}"#, t)
    t.check(local?.matches(region: "", highway: "SH", search: "") == false, "bare SH excludes a camera with no highway")
    // Free-text search stays a plain substring match.
    t.check(sh16.matches(region: "", highway: "", search: "carring"), "search is still a substring match")
}

private func testHighwayFilterJourneys(_ t: TestRunner) {
    t.group("highway filter: journeys")
    func journey(_ name: String, _ way: String) -> TrafficJourney? {
        decodeModel(TrafficJourney.self, #"{"id":"\#(name)","name":"\#(name)","ways":{"id":"\#(way)","name":"\#(way)"},"legs":[]}"#, t)
    }
    let decoys: [(String, String)] = [
        ("SH10", "010"), ("SH11", "011"), ("SH12", "012"), ("SH14", "014"), ("SH15", "015"), ("SH16", "016"),
        ("SH18", "018"), ("SH1B", "01B"), ("SH1C", "01C"), ("SH1J", "01J"), ("SH20", "020")
    ]
    for (name, way) in decoys {
        guard let decoy = journey(name, way) else { continue }
        t.check(!decoy.matches(region: "", highway: "SH1", search: ""), "SH1 does not match the \(name) journey")
    }
    guard let sh1 = journey("SH1", "01N"), let sh1n = journey("SH1N", "01N"), let sh1b = journey("SH1B", "01B"),
          let sh20a = journey("SH20A", "20A"), let sh20 = journey("SH20", "020") else { return }
    t.check(sh1.matches(region: "", highway: "SH1", search: ""), "SH1 matches the SH1 journey")
    t.check(sh1n.matches(region: "", highway: "SH1", search: ""), "SH1 matches the SH1N (North Island) journey")
    t.check(sh1.matches(region: "", highway: "SH 1", search: ""), "NZTA's own \"SH 1\" form matches")
    t.check(sh1b.matches(region: "", highway: "SH1B", search: ""), "a spur is found by its own name")
    t.check(sh20a.matches(region: "", highway: "20a", search: ""), "20a matches SH20A")
    t.check(!sh20a.matches(region: "", highway: "SH20", search: ""), "SH20 does not match the SH20A spur")
    t.check(!sh20.matches(region: "", highway: "SH2", search: ""), "SH2 does not match SH20")

    // Leg names mention the junctions at each end; they aren't the journey's
    // highway, so they don't add keys.
    let withJunctionLegs = #"{"id":"2","name":"SH18","ways":{"id":"018","name":"018"},"legs":[{"name":"SH16 / SH18 to Hobsonville Rd","direction":"I"}]}"#
    guard let sh18 = decodeModel(TrafficJourney.self, withJunctionLegs, t) else { return }
    t.check(sh18.matches(region: "", highway: "SH18", search: ""), "SH18 journey matches SH18")
    t.check(!sh18.matches(region: "", highway: "SH16", search: ""), "a junction leg name doesn't make it an SH16 journey")
    t.check(sh18.matches(region: "", highway: "", search: "hobsonville"), "leg names stay searchable")
}

private func testHighwayFilterEventsAndVMS(_ t: TestRunner) {
    t.group("highway filter: events + VMS")
    guard let sh1n = event(arrayLocationsJSON, t),
          let sh2 = event(sh2ClosureJSON, t),
          let sh26 = event(detourMentionJSON, t) else { return }
    t.check(sh1n.matches(region: "", highway: "SH1", search: ""), "SH1N journey event matches SH1")
    t.check(sh1n.matches(region: "", highway: "sh 1", search: ""), "…and \"sh 1\"")
    t.check(!sh1n.matches(region: "", highway: "SH16", search: ""), "…but not SH16")
    t.check(sh2.matches(region: "", highway: "SH2", search: ""), "SH2 event matches SH2")
    t.check(!sh2.matches(region: "", highway: "SH20", search: ""), "SH2 event does not match SH20")
    t.check(!sh26.matches(region: "", highway: "SH1C", search: ""), "a detour mentioning SH 1C is not an SH1C event")
    t.check(!sh26.matches(region: "", highway: "SH1", search: ""), "…nor an SH1 event")
    t.check(sh26.matches(region: "", highway: "SH26", search: ""), "SH26 event matches SH26")

    let vmsJSON = #"{"id":10,"name":"SH74 Belfast South - Southbound","description":"SH74 Belfast South - Southbound","currentMessage":"","journey":{"id":339,"name":"CNC"},"way":{"id":1206,"name":"CNA"},"region":{"id":11,"name":"Canterbury"}}"#
    guard let vms = decodeModel(VMSSign.self, vmsJSON, t) else { return }
    t.check(vms.matches(region: "", highway: "SH74", search: ""), "a VMS on the CNC corridor matches its named highway")
    t.check(vms.matches(region: "", highway: "cnc", search: ""), "…and the corridor code as a whole word")
    t.check(!vms.matches(region: "", highway: "SH7", search: ""), "…but not SH7")
}

// A7 — TIM boards decode `journey` ("SH1"), so SH1 boards (way "01N") match
// the highway filter; destinations such as "SH1 GILLIES" do not.
private func testHighwayFilterTIM(_ t: TestRunner) {
    t.group("highway filter: TIM boards")
    let sh1Board = #"""
    {"id":336,"latitude":-36.895096810596,"longitude":174.77363571707,"name":"12 Manukau Greenlane Intersection to Auckland City Centre","way":{"id":44,"name":"01N"},"journey":{"id":3,"name":"SH1"},"region":{"id":2,"name":"Auckland"},"page":{"line":[{"left":"SH1 GILLIES","right":9},{"left":"CITY CENTRE","right":15},{"left":"SH1 BRIDGE","right":15}],"pageTime":5}}
    """#
    let spurBoard = #"""
    {"id":334,"latitude":-36.999703891113,"longitude":174.78803381495,"name":"12 Auckland Airport to Auckland City Centre","way":{"id":"20A","name":"20A"},"region":{"id":2,"name":"Auckland"},"page":{"line":[{"center":"VIA SH20  R12"},{"left":"SH1 GILLIES","right":27},{"left":"CITY CENTRE","right":32}],"pageTime":5}}
    """#
    guard let board = decodeModel(TIMSign.self, sh1Board, t),
          let spur = decodeModel(TIMSign.self, spurBoard, t) else { return }
    t.equal(board.journey?.name, "SH1", "TIM journey decodes")
    t.check(board.matches(region: "", highway: "SH1", search: ""), "SH1 board (way 01N) matches SH1")
    t.check(board.matches(region: "", highway: "State Highway 1", search: ""), "…and State Highway 1")
    t.check(!board.matches(region: "", highway: "SH12", search: ""), "board name \"12 Manukau…\" is not SH12")
    t.check(!spur.matches(region: "", highway: "SH1", search: ""), "an SH20A board pointing at \"SH1 GILLIES\" is not an SH1 board")
    t.check(spur.matches(region: "", highway: "SH20A", search: ""), "SH20A board matches SH20A")
    t.check(!spur.matches(region: "", highway: "SH20", search: ""), "…but not SH20")
    t.check(spur.matches(region: "", highway: "", search: "gillies"), "destinations remain searchable")
    t.check(spur.journey == nil, "a board without journey still decodes")
}

private func testHighwayQueryFallback(_ t: TestRunner) {
    t.group("highway query parsing + whole words")
    let empty = HighwayQuery("   ")
    t.check(empty.isEmpty && empty.key == nil, "blank query is empty")
    t.check(empty.matches(keys: [], haystack: ""), "empty query matches everything")
    t.equal(HighwayQuery(" SH 1 ").key, "1", "query is trimmed and normalised")
    t.equal(HighwayQuery("cnc").key, nil, "corridor code has no highway key")
    t.check(HighwayQuery("SH").isHighwayPrefixOnly, "bare SH is a prefix-only query")
    t.check(HighwayQuery("State Highway").isHighwayPrefixOnly, "bare State Highway is a prefix-only query")
    t.check(!HighwayQuery("cnc").isHighwayPrefixOnly, "cnc is a text query")
    for partial in ["s", "Sta", "State", "State H", "state high", "Hw", "High"] {
        t.check(HighwayQuery(partial).isHighwayPrefixOnly, "'\(partial)' is still being typed, so it's prefix-only")
    }
    t.check(!HighwayQuery("Stat Hwy").isHighwayPrefixOnly, "a token that no highway word starts with is text")
    t.check(!HighwayQuery("art").isHighwayPrefixOnly, "art stays a text query")
    t.check(containsWholeWords("cnc", in: "cnc cna sh74 belfast"), "whole word at the start")
    t.check(containsWholeWords("belfast", in: "cnc cna sh74 belfast"), "whole word at the end")
    t.check(containsWholeWords("upper hbr", in: "east along upper hbr mwy"), "multi-word phrase")
    t.check(!containsWholeWords("sh1", in: "sh16 carrington"), "sh1 is not a word inside sh16")
    t.check(!containsWholeWords("art", in: "sh73 arthurs pass"), "art is not a word inside arthurs")
    t.check(containsWholeWords("art", in: "sh73 arthurs pass; art"), "a later whole-word hit is found")
}

// MARK: - B12 event date tense

private func testEventDatePhrase(_ t: TestRunner) {
    t.group("event date phrases")
    // Snapshot time: 2026-09-26 17:30 NZST.
    guard let reference = parseTrafficDate("2026-09-26T17:30:00+12:00") else {
        t.check(false, "reference date parses")
        return
    }
    // 562315 starts at 8 pm on Sun 27 Sep (NZDT begins that morning).
    t.equal(
        eventDatePhrase("2026-09-27T20:00:00+13:00", past: "Started", future: "Starts", relativeTo: reference),
        "Starts in 1 day · Sun 27 Sep, 8:00 pm",
        "future start reads Starts + weekday and NZ time"
    )
    t.equal(
        eventDatePhrase("2026-09-26T08:30:00.000+12:00", past: "Started", future: "Starts", relativeTo: reference),
        "Started 9 hours ago",
        "past start reads Started"
    )
    t.equal(
        eventDatePhrase("2026-09-26T15:30:00+12:00", past: "Ended", future: "Ends", relativeTo: reference),
        "Ended 2 hours ago",
        "past end reads Ended (a Resolved event)"
    )
    t.equal(
        eventDatePhrase("2026-10-02T18:30:00+13:00", past: "Ended", future: "Ends", relativeTo: reference),
        "Ends in 6 days · Fri 2 Oct, 6:30 pm",
        "future end reads Ends + weekday"
    )
    t.equal(eventDatePhrase(nil, past: "Started", future: "Starts", relativeTo: reference), nil, "missing date -> nil")
    t.equal(eventDatePhrase("Until further notice", past: "Ended", future: "Ends", relativeTo: reference), nil, "unparseable -> nil")
    t.equal(formatTrafficDate("2026-10-02T17:30:00+13:00"), "2 Oct, 5:30 pm", "absolute NZ date uses lower-case pm")
}

// MARK: - B13 durations

private func testDurationFormat(_ t: TestRunner) {
    t.group("duration format")
    t.equal(formatTimeInterval(1075), "18m", "17:55 reads 18m")
    t.equal(formatTimeInterval(262), "4m", "4:22 reads 4m")
    t.equal(formatTimeInterval(5640), "1h 34m", "hours and minutes")
    t.equal(formatTimeInterval(7200), "2h", "whole hours drop the minutes")
    t.equal(formatTimeInterval(3580), "1h", "59m 40s rounds up to 1h")
    t.equal(formatTimeInterval(90), "2m", "half a minute rounds up")
    t.equal(formatTimeInterval(20), "<1m", "a few seconds reads <1m")
    t.equal(formatTimeInterval(0), "0m", "zero")
    t.equal(formatTimeInterval(-30), "0m", "negative clamps to zero")
    t.equal(formatTimeInterval(.nan), "0m", "NaN doesn't trap")
    t.equal(formatTimeInterval(.infinity), "0m", "infinity doesn't trap")
    t.check(!formatTimeInterval(1e300).isEmpty, "a huge value doesn't trap")
}

// MARK: - B14 EV Mixed sites

private func testEVMixedIsDC(_ t: TestRunner) {
    t.group("EV Mixed sites are DC")
    let parsed = parseEVConnectors("{DC, 47 kW, Type 2 CCS, Status: Operative, Count:2},{AC, 11 kW, Type 2 Socketed, Status: Operative, Count:2}")
    t.check(parsed.hasDCConnector, "a DC connector group is detected")
    t.check(!parseEVConnectors("{AC, 22 kW, Type 2 Socketed, Count:2}").hasDCConnector, "AC-only groups are not DC")
    t.check(!parseEVConnectors(nil).hasDCConnector, "no connectors -> not DC")

    func charger(_ currentType: String, _ connectors: String) -> EVCharger? {
        let json = #"{"type":"FeatureCollection","features":[{"type":"Feature","geometry":{"type":"Point","coordinates":[172.63,-43.45]},"properties":{"name":"Waiata Shores Woolworths","currentType":"\#(currentType)","connectorsList":"\#(connectors)"}}]}"#
        return decodeModel(EVChargersPayload.self, json, t)?.features.first
    }
    let mixed = charger("Mixed", "{DC, 47 kW, Type 2 CCS, Status: Operative, Count:2},{AC, 11 kW, Type 2 Socketed, Status: Operative, Count:2}")
    t.check(mixed?.isDC == true, "Mixed site with a DC connector is DC")
    t.check(charger("Mixed", "")?.isDC == true, "Mixed site type alone counts as DC")
    t.check(charger("AC", "{DC, 50 kW, CHAdeMO, Status: Operative, Count:1}")?.isDC == true, "a DC connector wins over an AC site type")
    t.check(charger("AC", "{AC, 22 kW, Type 2 Socketed, Count:2}")?.isDC == false, "AC site stays AC")
}

// MARK: - B17 decode gaps

private func testEventDecodeGaps(_ t: TestRunner) {
    t.group("event decode gaps")
    guard let arrayLocations = event(arrayLocationsJSON, t) else { return }
    t.equal(
        arrayLocations.locations,
        "01N-0546/23.94-I - 01N-0574/02.91-I   Cambridge; 01N-0546/23.96-D - 01N-0574/02.90-D   Cambridge; 01N-0574/02.93-D - 01N-0574/04.70   Cambridge",
        "array locations are joined with '; '"
    )
    t.check(arrayLocations.matches(region: "", highway: "", search: "04.70"), "array location text is searchable")
    let mixed = #"{"id":"x","locations":["A", 7, null, {"k":1}, " ", "B"]}"#
    t.equal(decodeModel(RoadEvent.self, mixed, t)?.locations, "A; 7; B", "non-text array entries are skipped")
    t.equal(event(activeClosureJSON, t)?.locations?.hasPrefix("094-0212"), true, "string locations are unchanged")

    guard let restricted = event(restrictionsJSON, t) else { return }
    t.equal(restricted.restrictions, "Controlled Access Only", "restrictions decode")
    t.check(restricted.matches(region: "", highway: "", search: "controlled access"), "restrictions are searchable")
    t.equal(restricted.alternativeRouteText, nil, "\"Not applicable\" is hidden")

    func alternative(_ value: String) -> String? {
        let json = #"{"id":"alt","alternativeRoute":"\#(value)"}"#
        return decodeModel(RoadEvent.self, json, t)?.alternativeRouteText
    }
    for placeholder in ["Not Applicable", "Not applicable.", "Not applicable. ", "N/A", "N/a", "n/a.", "NA", "None", "  not   applicable  "] {
        t.equal(alternative(placeholder), nil, "placeholder \"\(placeholder)\" is hidden")
    }
    t.equal(alternative("Take extra care."), "Take extra care.", "real advice is kept verbatim")
    t.equal(alternative("Eastbound traffic, detour via Saddle Road"), "Eastbound traffic, detour via Saddle Road", "a detour is kept")
}

// MARK: - B29 image URL host allowlist

private func testTrafficNZURL(_ t: TestRunner) {
    t.group("trafficNZURL allowlist")
    func url(_ raw: String?, _ token: Int? = nil) -> String? {
        trafficNZURL(from: raw, cacheToken: token)?.absoluteString
    }
    t.equal(url("/camera/714.jpg"), "https://trafficnz.info/camera/714.jpg", "relative path resolves on trafficnz.info")
    t.equal(url("camera/714.jpg"), "https://trafficnz.info/camera/714.jpg", "relative path without a slash")
    t.equal(url("/camera/714.jpg", 5), "https://trafficnz.info/camera/714.jpg?t=5", "cache token appended")
    t.equal(url("/camera/714.jpg?t=1", 9), "https://trafficnz.info/camera/714.jpg?t=9", "existing token replaced")
    t.equal(url("http://trafficnz.info/camera/714.jpg"), "https://trafficnz.info/camera/714.jpg", "http upgraded")
    t.equal(url("https://www.trafficnz.info/camera/714.jpg"), "https://www.trafficnz.info/camera/714.jpg", "trafficnz.info subdomain allowed")
    t.equal(url("https://www.journeys.nzta.govt.nz/img/1.jpg"), "https://www.journeys.nzta.govt.nz/img/1.jpg", "nzta.govt.nz subdomain allowed")
    t.equal(url("//www.trafficnz.info/camera/1.jpg"), "https://www.trafficnz.info/camera/1.jpg", "protocol-relative allowed host gets https")

    t.equal(url("https://trafficnz.info.evil.example/x.jpg"), nil, "lookalike host rejected")
    t.equal(url("https://evil.example/x.jpg"), nil, "foreign https host rejected")
    t.equal(url("http://evil.example/a"), nil, "foreign http host rejected after upgrade")
    t.equal(url("https://notrafficnz.info/x.jpg"), nil, "suffix without a dot rejected")
    t.equal(url("https://trafficnz.info@evil.example/x.jpg"), nil, "userinfo trick pointing elsewhere rejected")
    t.equal(url("https://user@trafficnz.info/x.jpg"), nil, "userinfo rejected")
    t.equal(url("//evil.example/x.jpg"), nil, "protocol-relative foreign host rejected")
    t.equal(url("javascript:alert(1)"), nil, "javascript: scheme rejected")
    t.equal(url("file:///etc/passwd"), nil, "file: scheme rejected")
    t.equal(url("data:image/png;base64,AAAA"), nil, "data: scheme rejected")
    t.equal(url("ftp://trafficnz.info/x.jpg"), nil, "non-https scheme rejected")
    t.equal(url(nil), nil, "nil path")
    t.equal(url("  "), nil, "blank path")

    let cameraJSON = #"{"id":714,"name":"SH1 Tinwald ","highway":"SH1","imageUrl":"/camera/714.jpg","thumbUrl":"/camera/thumb/714.jpg"}"#
    let camera = decodeModel(TrafficCamera.self, cameraJSON, t)
    t.equal(camera?.imageURL(cacheToken: 3)?.absoluteString, "https://trafficnz.info/camera/714.jpg?t=3", "camera image URL")
    let hostile = #"{"id":1,"imageUrl":"https://evil.example/a.jpg","thumbUrl":"https://evil.example/b.jpg"}"#
    t.check(decodeModel(TrafficCamera.self, hostile, t)?.imageURL(cacheToken: 1) == nil, "camera with a foreign image host gets no URL")
}
