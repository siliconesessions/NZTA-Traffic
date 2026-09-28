import Foundation

// The watchlist (D4) — highway normalisation, matching, persistence — the
// new-closure tracker and notification text, the Travel Times board list
// (D1) and the EV layer's re-fetch rule (B4). Pure logic; the store's
// closure hook is covered in StoreTests.
func runWatchlistTests(_ t: TestRunner) {
    testWatchlistEditing(t)
    testWatchlistMatching(t)
    testWatchlistPersistence(t)
    testClosureTracker(t)
    testClosureNotifications(t)
    testTIMBoardListing(t)
    testEVChargerRefetch(t)
}

// Real-shaped records (rest/5, 2026-09-26).
private func closureEvent(
    id: Int,
    location: String,
    status: String = "Active",
    impact: String = "Road Closed",
    way: String = "001",
    journey: (id: Int, name: String)? = nil,
    _ t: TestRunner
) -> RoadEvent? {
    let journeyJSON = journey.map { #","journey":{"id":\#($0.id),"name":"\#($0.name)"}"# } ?? ""
    return decodeModel(
        RoadEvent.self,
        #"{"id":\#(id),"eventDescription":"Crash","eventType":"Crash","impact":"\#(impact)","status":"\#(status)","planned":false,"direction":"Both Directions","locationArea":"\#(location)","region":{"id":2,"name":"Auckland"},"way":{"id":1,"name":"\#(way)"}\#(journeyJSON)}"#,
        t
    )
}

private func testWatchlistEditing(_ t: TestRunner) {
    t.group("watchlist editing")
    var watchlist = Watchlist()
    t.check(watchlist.isEmpty, "starts empty")
    t.equal(watchlist.watchHighway("State Highway 1"), "1", "a highway is stored by its key")
    t.check(watchlist.isWatching(highway: "SH1N"), "every spelling of SH1 is watched")
    t.check(watchlist.isWatching(highway: "01S"), "including way codes")
    t.check(!watchlist.isWatching(highway: "SH1B"), "not the SH1B spur")
    t.check(!watchlist.isWatching(highway: "SH10"), "nor SH10")
    t.equal(watchlist.watchHighway("Arthurs Pass"), nil, "something that isn't a highway isn't added")
    watchlist.watchHighway("sh 20a")
    watchlist.watchHighway("SH2")
    watchlist.watchHighway("1B")
    t.equal(watchlist.sortedHighways, ["1", "1B", "2", "20A"], "highways sort in road order")
    t.equal(watchlist.sortedHighways.map(highwayLabel), ["SH1", "SH1B", "SH2", "SH20A"], "and read as SH labels")
    watchlist.unwatchHighway("SH 2")
    t.check(!watchlist.isWatching(highway: "2"), "unwatching removes it")

    watchlist.setWatching(cameraID: "653", true)
    watchlist.setWatching(journeyID: "87", true)
    t.check(watchlist.isWatching(cameraID: "653"), "camera watched by id")
    t.check(watchlist.isWatching(journeyID: "87"), "journey watched by id")
    watchlist.setWatching(cameraID: "653", false)
    t.check(!watchlist.isWatching(cameraID: "653"), "and unwatched")
}

private func testWatchlistMatching(_ t: TestRunner) {
    t.group("watchlist matching")
    var watchlist = Watchlist()
    watchlist.watchHighway("SH1")

    guard let onSH1 = closureEvent(id: 1, location: "SH 1 Bombay Hills", way: "01N", t),
          let onSH16 = closureEvent(id: 2, location: "SH 16 Kumeu", way: "016", t),
          let onJourney = closureEvent(id: 3, location: "Kaiapoi", way: "071", journey: (87, "SH71"), t) else { return }
    t.check(watchlist.watches(onSH1), "an event on a watched highway")
    t.check(!watchlist.watches(onSH16), "not one on SH16")
    t.check(!watchlist.watches(onJourney), "nor an unwatched journey")
    watchlist.setWatching(journeyID: "87", true)
    t.check(watchlist.watches(onJourney), "an event on a watched journey (events carry the /journeys id)")
    t.equal(watchlist.watchedHighways(of: onSH1), ["1"], "the watched highways it's on")

    guard let camera = decodeModel(TrafficCamera.self, #"{"id":653,"name":"SH20 May Rd Overbridge","highway":"SH20","way":{"id":54,"name":"020"}}"#, t),
          let journey = decodeModel(TrafficJourney.self, #"{"id":87,"name":"SH71","ways":{"id":"071","name":"071"}}"#, t) else { return }
    t.check(!watchlist.watches(camera), "a camera on an unwatched highway")
    watchlist.setWatching(cameraID: "653", true)
    t.check(watchlist.watches(camera), "a watched camera")
    t.check(watchlist.watches(journey), "a watched journey")
    var byHighway = Watchlist()
    byHighway.watchHighway("20")
    t.check(byHighway.watches(camera), "a camera on a watched highway")
}

private func testWatchlistPersistence(_ t: TestRunner) {
    t.group("watchlist persistence")
    var watchlist = Watchlist()
    watchlist.watchHighway("SH20")
    watchlist.watchHighway("SH1")
    watchlist.setWatching(cameraID: "812", true)
    watchlist.setWatching(cameraID: "653", true)
    watchlist.setWatching(journeyID: "87", true)
    let data = watchlist.encodedData()
    t.equal(
        data.flatMap { String(data: $0, encoding: .utf8) },
        #"{"cameras":["653","812"],"highways":["1","20"],"journeys":["87"]}"#,
        "stable JSON: sorted keys and lists"
    )
    t.equal(Watchlist.decoded(from: data), watchlist, "round-trips")
    t.check(Watchlist.decoded(from: nil).isEmpty, "nothing stored is an empty watchlist")
    t.check(Watchlist.decoded(from: Data("not json".utf8)).isEmpty, "unreadable data is an empty watchlist")
    let lenient = Watchlist.decoded(from: Data(#"{"highways":["State Highway 1","Arthurs Pass","01N"]}"#.utf8))
    t.equal(lenient.sortedHighways, ["1"], "stored highways are re-normalised, junk dropped")
    t.check(lenient.cameraIDs.isEmpty, "missing lists are empty")

    let preferences = DiagnosticsReport.collectPreferences(from: [Watchlist.defaultsKey: data ?? Data()])
    t.equal(
        preferences[Watchlist.defaultsKey],
        "highways: 2, cameras: 2, journeys: 1",
        "diagnostics report how much is watched, not what"
    )
}

private func testClosureTracker(_ t: TestRunner) {
    t.group("new closures on watched roads")
    var watchlist = Watchlist()
    watchlist.watchHighway("SH1")
    guard let existing = closureEvent(id: 10, location: "SH 1 Bombay Hills", way: "01N", t),
          let fresh = closureEvent(id: 11, location: "SH 1 Brynderwyn Hills", way: "01N", t),
          let elsewhere = closureEvent(id: 12, location: "SH 16 Kumeu", way: "016", t),
          let delay = closureEvent(id: 13, location: "SH 1 Silverdale", impact: "Delays", way: "01N", t),
          let upcoming = closureEvent(id: 14, location: "SH 1 Puhoi", status: "Scheduled", way: "01N", t),
          let laterSH16 = closureEvent(id: 15, location: "SH 16 Helensville", way: "016", t) else { return }

    var tracker = WatchedClosureTracker()
    t.check(!tracker.hasBaseline, "no baseline before the first live fetch")
    t.check(tracker.newWatchedClosures(in: [existing], watchlist: watchlist).isEmpty, "the first live fetch only records a baseline")
    t.check(tracker.hasBaseline, "baseline recorded")
    t.check(tracker.newWatchedClosures(in: [existing], watchlist: watchlist).isEmpty, "an unchanged feed reports nothing")

    let found = tracker.newWatchedClosures(in: [existing, fresh, elsewhere, delay, upcoming], watchlist: watchlist)
    t.equal(found.map(\.id), ["11"], "only the new active closure on a watched road")
    t.check(tracker.newWatchedClosures(in: [existing, fresh], watchlist: watchlist).isEmpty, "reported once")
    // It clears, then comes back: still not reported again this session.
    _ = tracker.newWatchedClosures(in: [existing], watchlist: watchlist)
    t.check(tracker.newWatchedClosures(in: [existing, fresh], watchlist: watchlist).isEmpty, "never twice for one closure")

    // Watching SH16 now doesn't announce the SH16 closure already in force.
    _ = tracker.newWatchedClosures(in: [existing, elsewhere], watchlist: watchlist)
    watchlist.watchHighway("SH16")
    t.check(tracker.newWatchedClosures(in: [existing, elsewhere], watchlist: watchlist).isEmpty, "a new watch doesn't announce closures already in force")
    t.equal(tracker.newWatchedClosures(in: [existing, elsewhere, laterSH16], watchlist: watchlist).map(\.id), ["15"], "but does a new one")

    // An empty watchlist still keeps the baseline current.
    var quiet = WatchedClosureTracker()
    _ = quiet.newWatchedClosures(in: [], watchlist: Watchlist())
    t.check(quiet.newWatchedClosures(in: [fresh], watchlist: Watchlist()).isEmpty, "nothing watched, nothing reported")
    t.check(quiet.newWatchedClosures(in: [fresh], watchlist: watchlist).isEmpty, "and what arrived meanwhile is baseline")
}

private func testClosureNotifications(_ t: TestRunner) {
    t.group("closure notification text")
    var watchlist = Watchlist()
    watchlist.watchHighway("SH1")
    watchlist.setWatching(journeyID: "87", true)
    guard let onSH1 = closureEvent(id: 21, location: "SH 1 Brynderwyn Hills", way: "01N", t),
          let onJourney = closureEvent(id: 22, location: "Kaiapoi to Rangiora", way: "071", journey: (87, "SH71"), t) else { return }

    let single = closureNotificationContents(for: [onSH1], watchlist: watchlist)
    t.equal(single.count, 1, "one notification per closure")
    t.equal(single.first?.identifier, "closure-21", "identified by the event")
    t.equal(single.first?.title, "Road closed on SH1", "titled with the watched highway")
    t.equal(single.first?.body, "SH 1 Brynderwyn Hills · Crash · Both Directions", "where, what and which way")
    t.equal(
        closureNotificationContents(for: [onJourney], watchlist: watchlist).first?.title,
        "Road closed on SH71",
        "a watched journey's closure names the journey"
    )

    let three = closureNotificationContents(for: [onSH1, onJourney, onSH1], watchlist: watchlist)
    t.equal(three.count, 3, "up to three are posted one by one")

    var many: [RoadEvent] = []
    for id in 30..<35 {
        if let event = closureEvent(id: id, location: "SH 1 Site \(id)", way: "01N", t) {
            many.append(event)
        }
    }
    let summary = closureNotificationContents(for: many, watchlist: watchlist)
    t.equal(summary.count, 1, "more than three become one summary")
    t.equal(summary.first?.title, "5 new closures on roads you watch", "summary title")
    t.equal(
        summary.first?.body,
        "SH1: SH 1 Site 30\nSH1: SH 1 Site 31\nSH1: SH 1 Site 32\nand 2 more",
        "the first three, then a count"
    )
    t.check(closureNotificationContents(for: [], watchlist: watchlist).isEmpty, "nothing new, nothing posted")
}

private func testTIMBoardListing(_ t: TestRunner) {
    t.group("travel-time board list")
    func board(_ id: Int, _ name: String, region: String?, lines: String) -> TIMSign? {
        let regionJSON = region.map { #","region":{"id":1,"name":"\#($0)"}"# } ?? ""
        return decodeModel(
            TIMSign.self,
            #"{"id":\#(id),"name":"\#(name)","latitude":-36.9,"longitude":174.7\#(regionJSON),"page":{"line":[\#(lines)]}}"#,
            t
        )
    }
    let times = #"{"left":"CITY CENTRE","right":12}"#
    guard let canterbury = board(1, "CHC - KBR01 Kaiapoi Bridge", region: "Canterbury", lines: times),
          let auckland2 = board(2, "12 Gillies Avenue to Auckland Airport", region: "Auckland", lines: times),
          let auckland1 = board(3, "2 Queenstown Road", region: "Auckland", lines: times),
          let blank = board(4, "AHB - Orams Rd - NB", region: "Auckland", lines: #"{"center":""}"#),
          let noRegion = board(5, "Mystery board", region: nil, lines: times),
          let wellington = board(6, "Willis / Karo (V)", region: "Wellington", lines: #"{"center":"CITY CENTRE"},{"center":"16 MINUTES"}"#)
    else { return }

    let listing = timBoardListing(
        [auckland1, auckland2, blank, canterbury, noRegion, wellington],
        regionOrder: ["Northland", "Auckland", "Wellington", "Canterbury"]
    )
    t.equal(listing.groups.map(\.region), ["Auckland", "Wellington", "Canterbury", "Other"], "regions north to south, no region last")
    t.equal(listing.groups.first?.boards.map(\.id), ["3", "2"], "the store's order within a region")
    t.equal(listing.blank.map(\.id), ["4"], "blank boards are set apart")
    t.equal(listing.showingCount, 5, "text-only boards count as showing")

    let unordered = timBoardListing([canterbury, auckland1], regionOrder: [])
    t.equal(unordered.groups.map(\.region), ["Auckland", "Canterbury"], "alphabetical without a canonical order")
}

private func testEVChargerRefetch(_ t: TestRunner) {
    t.group("EV layer re-fetch")
    let now = Date(timeIntervalSince1970: 1_000_000)
    t.check(AutoRefreshPolicy.shouldRefetchEVChargers(hasData: false, loadedAt: nil, now: now), "never loaded")
    t.check(AutoRefreshPolicy.shouldRefetchEVChargers(hasData: false, loadedAt: now, now: now), "loaded but empty (a failed or empty load)")
    t.check(!AutoRefreshPolicy.shouldRefetchEVChargers(hasData: true, loadedAt: now.addingTimeInterval(-600), now: now), "fresh data isn't re-fetched")
    t.check(AutoRefreshPolicy.shouldRefetchEVChargers(hasData: true, loadedAt: now.addingTimeInterval(-3600), now: now), "an hour old is re-fetched")
}
