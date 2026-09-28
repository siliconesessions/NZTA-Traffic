import Foundation
import Observation

// TrafficStore end to end against the stub network and a temporary offline
// cache (no reachability monitor, no shared URL cache): the launch prime, the
// single-flight refresh, journeys loading on its own, failures and offline
// fallback, reconnect reload, unchanged-feed skipping and diagnostics.
@MainActor
func runStoreTests(_ t: TestRunner) async {
    await testLaunchPrimesWithNeutralBanner(t)
    await testRefreshIsSingleFlight(t)
    await testJourneysLoadOnTheirOwn(t)
    await testFailureKeepsSavedData(t)
    await testOfflineAndReconnect(t)
    await testUnchangedFeedIsNotRepublished(t)
    await testEmptyFeedIsNotAFailure(t)
    await testClearOfflineCache(t)
    await testLaunchAfterUnfinishedLaunch(t)
    await testLiveOnlySuccessDoesNotStampUpdated(t)
    await testAutoRefreshCadence(t)
    await testStoreDiagnostics(t)
    await testWatchedClosureNotifications(t)
    await testWatchingFilter(t)
    await testServerErrorFallsBackToSavedData(t)
    await testPoisonedResponseKeepsData(t)
    await testPrimeFillsOnlyEmptySections(t)
    await testReloadClearsOnlyItsOwnError(t)
    await testFilterMemoFollowsNewData(t)
    await testCancelledRequestIsNotAnError(t)
    await testInjectedClock(t)
}

private struct StoreFixture {
    let store: TrafficStore
    let cache: OfflineCache
    let folder: URL
}

// A store on the stub network with an empty temporary cache, optionally
// seeded with saved (cached) copies of the four cacheable sections, and
// optionally on a test clock instead of the real time.
@MainActor
private func makeStore(seedCache: Bool = false, clock: TestClock? = nil) async -> StoreFixture {
    let folder = makeTemporaryFolder()
    let cache = OfflineCache(directory: folder)
    if seedCache {
        await cache.write(Data(StubFixtures.cameras.utf8), section: .cameras)
        await cache.write(Data(StubFixtures.events.utf8), section: .events)
        await cache.write(Data(StubFixtures.vms.utf8), section: .vms)
        await cache.write(Data(StubFixtures.journeys.utf8), section: .journeys)
    }
    let now: @Sendable () -> Date
    if let clock {
        now = { clock.now }
    } else {
        now = { Date() }
    }
    let store = TrafficStore(
        service: makeStubService(),
        cache: OfflineCache(directory: folder),
        imageCache: nil,
        monitorsNetwork: false,
        reconnectDelay: .zero,
        clock: now
    )
    return StoreFixture(store: store, cache: cache, folder: folder)
}

// Every load, including the journeys tail and the fetch-once layers, is done.
@MainActor
private func waitForIdle(_ store: TrafficStore) async -> Bool {
    await waitUntil {
        store.loadingSections.isEmpty && !store.isRefreshing && !store.isLoadingEVChargers
    }
}

@MainActor
private func testLaunchPrimesWithNeutralBanner(_ t: TestRunner) async {
    t.group("store: warm launch")
    StubServer.reset()
    StubFixtures.routeAllEndpoints(delay: 0.3)
    let fixture = await makeStore(seedCache: true)
    defer { removeTemporaryFolder(fixture.folder) }
    let store = fixture.store

    t.check(store.loadingSections.isEmpty, "nothing is loading before launch")
    let launch = store.start()
    t.equal(store.loadingSections, Set(DataSection.allCases), "launch marks every section loading before reading the cache")
    t.check(store.isRefreshing, "and shows it is refreshing")

    t.check(await waitUntil { store.cameras.count == 3 }, "cached cameras appear before the live load answers")
    t.check(store.freshnessBanner?.isUpdating == true, "the banner says saved data is updating")
    t.check(store.freshnessBanner?.isWarning == false, "not the 'couldn't reach NZTA' warning")
    t.check(store.errors.isEmpty, "no errors while priming")
    t.check(store.lastUpdated == nil, "nothing is 'updated' until a live fetch succeeds")
    t.equal(store.events.count, 2, "the resolved event that ended long ago isn't replayed")
    t.equal(store.dockBadgeLabel, "1?", "the Dock badge flags a closure count from saved data")
    t.check(store.eventsAreProvisional, "events are provisional while saved")

    await launch.value
    t.equal(store.cameras.count, 2, "the live cameras replace the saved ones")
    t.check(store.lastUpdated != nil, "a live success stamps lastUpdated")
    t.equal(store.dockBadgeLabel, "1", "a live count loses the caveat")
    t.check(await waitForIdle(store), "journeys and the reference data finish")
    t.check(store.freshnessBanner == nil, "no banner once everything is live")
    t.check(store.savedSections.isEmpty, "nothing is served from the cache any more")
    t.equal(store.journeys.count, 1, "journeys loaded")
    t.check(!store.allRegions.isEmpty, "regions loaded")
    t.equal(store.evChargers.count, 1, "EV chargers loaded once")
    t.equal(StubServer.requestCount("/cameras/all"), 1, "one cameras request for the whole launch")
}

@MainActor
private func testRefreshIsSingleFlight(_ t: TestRunner) async {
    t.group("store: refresh is single-flight")
    StubServer.reset()
    StubFixtures.routeAllEndpoints(delay: 0.3)
    let fixture = await makeStore()
    defer { removeTemporaryFolder(fixture.folder) }
    let store = fixture.store
    let tokenBefore = store.imageCacheToken

    let automatic = Task { await store.loadAllData() }
    t.check(await waitUntil { store.isRefreshing }, "an automatic refresh starts")
    let manual = Task { await store.loadAllData(bustImageCache: true) }
    let retry = Task { await store.reload(.cameras) }
    await automatic.value
    t.check(!store.isRefreshing, "isRefreshing clears only when the shared refresh is done")
    await manual.value
    await retry.value
    t.check(await waitForIdle(store), "everything settles")

    t.equal(StubServer.requestCount("/cameras/all"), 1, "overlapping refresh and Retry share one cameras request")
    t.equal(StubServer.requestCount("/events/all/10"), 1, "one events request")
    t.equal(StubServer.requestCount("/journeys/all/10"), 1, "one journeys request")
    t.check(store.imageCacheToken != tokenBefore, "the manual refresh upgraded the running one to fresh images")
    let bumped = store.imageCacheToken
    t.check(store.errors.isEmpty, "no errors")

    // A later refresh is a fresh one.
    await store.loadAllData()
    t.equal(StubServer.requestCount("/cameras/all"), 2, "the next refresh fetches again")
    t.equal(store.imageCacheToken, bumped, "an automatic refresh leaves the image URLs alone")
}

@MainActor
private func testJourneysLoadOnTheirOwn(_ t: TestRunner) async {
    t.group("store: journeys don't hold the refresh")
    StubServer.reset()
    StubFixtures.routeAllEndpoints(delay: 0.05, journeysDelay: 1.0)
    let fixture = await makeStore()
    defer { removeTemporaryFolder(fixture.folder) }
    let store = fixture.store

    let started = Date()
    await store.loadAllData()
    t.check(Date().timeIntervalSince(started) < 0.8, "the refresh returns before the slow journeys request")
    t.check(!store.isRefreshing, "Refresh is available again")
    t.equal(store.cameras.count, 2, "cameras applied as soon as they arrived")
    t.check(store.isLoading(.journeys), "journeys is still loading, with its own flag")
    t.equal(store.loadProgress, 1, "the progress bar covers the shared sections")

    // A second refresh while journeys is still running joins it.
    await store.loadAllData()
    t.equal(StubServer.requestCount("/journeys/all/10"), 1, "a refresh during the journeys load doesn't request it again")
    t.check(await waitUntil { !store.isLoading(.journeys) }, "journeys finishes")
    t.equal(store.journeys.count, 1, "and is applied")
}

@MainActor
private func testFailureKeepsSavedData(_ t: TestRunner) async {
    t.group("store: failures fall back to saved data")
    StubServer.reset()
    StubFixtures.failAllEndpoints(.cannotConnectToHost)
    let fixture = await makeStore(seedCache: true)
    defer { removeTemporaryFolder(fixture.folder) }
    let store = fixture.store

    let started = Date()
    await store.loadAllData()
    t.check(Date().timeIntervalSince(started) < 1, "an unreachable host fails fast")
    t.check(await waitForIdle(store), "every section settles")
    t.equal(StubServer.requestCount("/cameras/all"), 1, "and isn't retried")
    t.equal(store.cameras.count, 3, "the saved cameras are shown")
    t.check(store.savedSections.contains(.cameras), "marked as saved")
    t.check(store.failedSections.isSuperset(of: Set(DataSection.allCases)), "every section records the failure")
    t.check(store.errors[.cameras]?.contains("Unable to reach NZTA API") == true, "with an error message")
    t.check(store.lastUpdated == nil, "a refresh where everything failed doesn't stamp 'Updated'")
    if case .unreachable(let since)? = store.freshnessBanner {
        t.check(since != nil, "the couldn't-reach banner dates the saved copy")
    } else {
        t.check(false, "a real failure shows the couldn't-reach banner")
    }
    t.equal(store.dockBadgeLabel, "1?", "the badge is qualified")

    // Recovering: live data replaces the saved copy and clears the state.
    StubFixtures.routeAllEndpoints()
    await store.loadAllData()
    t.check(await waitForIdle(store), "the retry settles")
    t.equal(store.cameras.count, 2, "live data replaces the saved copy")
    t.check(store.failedSections.isEmpty && store.savedSections.isEmpty && store.errors.isEmpty, "failure state clears")
    t.check(store.freshnessBanner == nil, "and the banner goes")

    // A failure over live data keeps the live data (no cache re-read).
    StubFixtures.failAllEndpoints(.networkConnectionLost)
    await store.loadAllData()
    t.equal(store.cameras.count, 2, "a later failure keeps the live data on screen")
    t.check(!store.savedSections.contains(.cameras), "rather than swapping in the older saved copy")
    t.check(store.freshnessBanner?.isWarning == true, "and warns that it couldn't refresh")
    t.equal(StubServer.requestCount("/cameras/all"), 1 + 1 + 3, "a dropped connection is retried (3 attempts)")
}

@MainActor
private func testOfflineAndReconnect(_ t: TestRunner) async {
    t.group("store: offline, then back online")
    StubServer.reset()
    StubFixtures.routeAllEndpoints()
    let fixture = await makeStore(seedCache: true)
    defer { removeTemporaryFolder(fixture.folder) }
    let store = fixture.store

    store.networkStatusChanged(isOnline: false)
    await store.loadAllData()
    t.check(await waitForIdle(store), "an offline refresh settles at once")
    t.equal(StubServer.requestCount(), 0, "offline, no request is even attempted")
    t.equal(store.cameras.count, 3, "saved data is shown")
    t.check(store.errors[.cameras]?.contains("No internet connection") == true, "each section says it's offline")
    t.check(store.evChargersError?.contains("No internet connection") == true, "so does the EV layer")
    t.check(store.freshnessBanner == .offline(since: store.savedDates.values.min()), "the offline banner dates the oldest saved copy")
    t.equal(store.displayedError(for: .cameras), nil, "a tab with data leaves the offline notice to the banner")
    t.check(store.displayedError(for: .timSigns)?.contains("No internet connection") == true, "an empty one still says it's offline")

    store.networkStatusChanged(isOnline: true)
    t.check(await waitUntil { StubServer.requestCount("/cameras/all") == 1 }, "coming back online reloads by itself")
    t.check(await waitForIdle(store), "the reload settles")
    t.equal(store.cameras.count, 2, "with live data")
    t.check(store.freshnessBanner == nil, "and the banner clears")
    t.equal(store.evChargers.count, 1, "the EV layer loads too")

    store.networkStatusChanged(isOnline: false)
    store.networkStatusChanged(isOnline: true)
    try? await Task.sleep(for: .milliseconds(100))
    t.equal(StubServer.requestCount("/cameras/all"), 1, "a reconnect with nothing unconfirmed doesn't reload")
}

private final class ChangeFlag: @unchecked Sendable {
    var fired = false
}

@MainActor
private func testUnchangedFeedIsNotRepublished(_ t: TestRunner) async {
    t.group("store: unchanged feeds are skipped")
    StubServer.reset()
    StubFixtures.routeAllEndpoints()
    let fixture = await makeStore()
    defer { removeTemporaryFolder(fixture.folder) }
    let store = fixture.store
    await store.loadAllData()
    _ = await waitForIdle(store)
    let firstFetch = store.lastLiveSuccess[.cameras]

    let unchanged = ChangeFlag()
    withObservationTracking {
        _ = store.cameras
    } onChange: {
        unchanged.fired = true
    }
    try? await Task.sleep(for: .milliseconds(5))
    await store.loadAllData()
    t.check(!unchanged.fired, "byte-identical cameras aren't reassigned (no re-render, memo kept)")
    t.check(store.lastLiveSuccess[.cameras] != firstFetch, "the section still counts as freshly confirmed")
    t.equal(await fixture.cache.fileInfo().first?.byteCount, StubFixtures.camerasLive.utf8.count, "the cached copy is intact")

    let changed = ChangeFlag()
    withObservationTracking {
        _ = store.cameras
    } onChange: {
        changed.fired = true
    }
    StubServer.route("/cameras/all", .json(StubFixtures.cameras))
    await store.loadAllData()
    t.check(changed.fired, "new bytes are applied")
    t.equal(store.cameras.count, 3, "with the new data")
    // A change this soon after the last write is held back until a flush.
    t.equal(await fixture.cache.read(section: .cameras)?.data, Data(StubFixtures.camerasLive.utf8), "the file isn't rewritten straight away")
    await store.flushOfflineCache()
    let saved = await fixture.cache.read(section: .cameras)
    t.equal(saved?.data, Data(StubFixtures.cameras.utf8), "but is written to the cache on a flush")
}

@MainActor
private func testEmptyFeedIsNotAFailure(_ t: TestRunner) async {
    t.group("store: an empty feed keeps the data")
    StubServer.reset()
    StubFixtures.routeAllEndpoints()
    let fixture = await makeStore()
    defer { removeTemporaryFolder(fixture.folder) }
    let store = fixture.store
    await store.loadAllData()
    _ = await waitForIdle(store)

    StubServer.route("/cameras/all", .json(StubFixtures.emptyCameras))
    await store.loadAllData()
    t.equal(store.cameras.count, 2, "an empty list over loaded cameras keeps them")
    t.check(store.errors[.cameras]?.contains("empty list") == true, "and says why")
    t.check(!store.failedSections.contains(.cameras), "NZTA answered, so it isn't a connectivity failure")
    t.check(store.freshnessBanner == nil, "no couldn't-reach banner")
}

@MainActor
private func testClearOfflineCache(_ t: TestRunner) async {
    t.group("store: clear offline cache")
    StubServer.reset()
    StubFixtures.failAllEndpoints(.cannotConnectToHost)
    let fixture = await makeStore(seedCache: true)
    defer { removeTemporaryFolder(fixture.folder) }
    let store = fixture.store
    let token = store.imageCacheToken

    await store.clearOfflineCache()
    t.check(await fixture.cache.fileInfo().isEmpty, "the saved section files are deleted")
    t.check(store.imageCacheToken != token, "camera images reload from new URLs")
    t.check(store.cameras.isEmpty, "with the cache gone and NZTA unreachable there is nothing to replay")

    StubFixtures.routeAllEndpoints()
    await store.clearOfflineCache()
    _ = await waitForIdle(store)
    t.equal(store.cameras.count, 2, "clearing reloads live data")
    t.equal(await fixture.cache.fileInfo().count, 4, "which is saved again")
}

@MainActor
private func testLiveOnlySuccessDoesNotStampUpdated(_ t: TestRunner) async {
    t.group("store: \"Updated\" follows the sections the banner covers")
    StubServer.reset()
    StubFixtures.failAllEndpoints(.cannotConnectToHost)
    StubServer.route("/signs/tim/all", .json(StubFixtures.tim))
    let fixture = await makeStore()
    defer { removeTemporaryFolder(fixture.folder) }
    let store = fixture.store
    await store.loadAllData()
    _ = await waitForIdle(store)
    t.check(!store.timSigns.isEmpty, "the TIM boards loaded")
    t.equal(store.lastUpdated, nil, "but a live-only section alone doesn't count as an update")
    t.equal(store.failedSections.contains(.cameras), true, "while the cacheable sections failed")
    StubFixtures.routeAllEndpoints()
    await store.loadAllData()
    _ = await waitForIdle(store)
    t.check(store.lastUpdated != nil, "a cacheable section's success does")
}

@MainActor
private func testLaunchAfterUnfinishedLaunch(_ t: TestRunner) async {
    t.group("store: launch after a launch that never finished")
    t.check(LaunchGuard.unfinishedLaunchKey.hasPrefix("nzta."), "the flag lives with the app's other preferences")

    StubServer.reset()
    StubFixtures.failAllEndpoints(.cannotConnectToHost)
    let fixture = await makeStore(seedCache: true)
    defer { removeTemporaryFolder(fixture.folder) }
    let store = fixture.store
    await store.start(discardingSavedData: true).value
    _ = await waitForIdle(store)
    t.check(store.cameras.isEmpty, "the suspect saved data is neither primed nor replayed after a failure")
    t.check(await fixture.cache.fileInfo().isEmpty, "and is deleted")
    t.check(store.errors[.cameras] != nil, "the live failure is still reported")
}

@MainActor
private func testAutoRefreshCadence(_ t: TestRunner) async {
    t.group("store: auto-refresh cadence")
    StubServer.reset()
    let fixture = await makeStore()
    defer { removeTemporaryFolder(fixture.folder) }
    let store = fixture.store

    t.check(store.effectiveAutoRefreshInterval == nil, "off by default")
    store.configureAutoRefresh(AutoRefreshSettings(isEnabled: true, storedInterval: 30))
    t.equal(store.effectiveAutoRefreshInterval, 60, "a stored 30 s runs at the 60 s floor")
    store.configureAutoRefresh(AutoRefreshSettings(isEnabled: true, storedInterval: 120))
    t.equal(store.effectiveAutoRefreshInterval, 120, "settings changes apply")
    store.updateAppActivity(isAppActive: false, hasVisibleWindow: true)
    t.equal(store.effectiveAutoRefreshInterval, 120, "a visible window keeps the pace")
    store.updateAppActivity(isAppActive: false, hasVisibleWindow: false)
    t.equal(store.effectiveAutoRefreshInterval, 360, "in the background with no window it backs off")
    store.updateAppActivity(isAppActive: true, hasVisibleWindow: false)
    t.equal(store.effectiveAutoRefreshInterval, 120, "activating the app restores it")
    store.configureAutoRefresh(AutoRefreshSettings(isEnabled: false, storedInterval: 120))
    t.check(store.effectiveAutoRefreshInterval == nil, "and it can be turned off")
}

@MainActor
private func testStoreDiagnostics(_ t: TestRunner) async {
    t.group("store: diagnostics report")
    StubServer.reset()
    StubFixtures.routeAllEndpoints()
    StubServer.route("rest/5/signs/tim/all", .status(404))
    StubServer.route("rest/4/signs/tim/all", .json(StubFixtures.tim))
    let fixture = await makeStore()
    defer { removeTemporaryFolder(fixture.folder) }
    let store = fixture.store
    await store.loadAllData()
    _ = await waitForIdle(store)

    let text = await store.diagnosticsReport(preferences: ["nzta.autoRefreshEnabled": "1"]).formattedText()
    t.check(text.contains("System:       macOS "), "includes the macOS version")
    t.check(text.contains("Cameras: 2\n    live; last live fetch: 20"), "per-section status with its last live fetch")
    t.check(text.contains("cameras.json: \(StubFixtures.camerasLive.utf8.count) bytes, saved "), "offline cache files with sizes and dates")
    t.check(text.contains("falling back to rest/4 for /signs/tim/all"), "the rest/4 fallback is reported")
    t.check(text.contains("Auto-refresh: off"), "the refresh state")
    t.check(text.contains("nzta.autoRefreshEnabled = 1"), "the injected preferences")
}

// D4: the store reports closures new on watched roads after live events
// fetches only — never the launch's first live fetch (the baseline) and never
// saved data.
@MainActor
private func testWatchedClosureNotifications(_ t: TestRunner) async {
    t.group("store: closures on watched roads")
    StubServer.reset()
    StubFixtures.routeAllEndpoints()
    // First live fetch: only the delay. Then the SH94 closure appears.
    StubServer.route(
        "/events/all/10",
        .json(StubFixtures.eventsWithoutClosure),
        .json(StubFixtures.events)
    )
    let fixture = await makeStore(seedCache: true)
    defer { removeTemporaryFolder(fixture.folder) }
    let store = fixture.store
    var watchlist = Watchlist()
    watchlist.watchHighway("SH94")
    store.setWatchlist(watchlist)
    var reported: [[String]] = []
    store.onNewWatchedClosures = { closures, _ in
        reported.append(closures.map(\.id))
    }

    await store.start().value
    t.check(store.events.contains { $0.id == "560046" }, "the first live events fetch landed")
    t.check(reported.isEmpty, "neither the saved closure nor the first live fetch notifies")
    await store.loadAllData()
    t.equal(reported, [["561700"]], "the SH94 closure that appeared since is reported")
    t.equal(store.watchedActiveClosureCount, 1, "and counted as on a watched road")
    await store.loadAllData()
    t.equal(reported.count, 1, "an unchanged feed reports nothing more")
    t.check(await waitForIdle(store), "settles")
}

@MainActor
private func testWatchingFilter(_ t: TestRunner) async {
    t.group("store: watching filter")
    StubServer.reset()
    StubFixtures.routeAllEndpoints()
    let fixture = await makeStore()
    defer { removeTemporaryFolder(fixture.folder) }
    let store = fixture.store
    await store.loadAllData()
    t.check(await waitForIdle(store), "loaded")
    let allStatuses = Set(CameraStatusKind.allCases)
    t.equal(store.scopedCameras(region: "", highway: "", search: "", statuses: allStatuses, watchingOnly: true).count, 0, "nothing watched, nothing shown")
    store.updateWatchlist { $0.setWatching(cameraID: "812", true) }
    t.equal(
        store.scopedCameras(region: "", highway: "", search: "", statuses: allStatuses, watchingOnly: true).map(\.id),
        ["812"],
        "a watched camera"
    )
    store.updateWatchlist { $0.watchHighway("SH20") }
    t.equal(
        store.scopedCameras(region: "", highway: "", search: "", statuses: allStatuses, watchingOnly: true).count,
        2,
        "plus the cameras on a watched highway"
    )
    let impacts = Set(EventImpactKind.allCases)
    let watchedEvents = store.scopedEvents(
        region: "", highway: "", search: "", impacts: impacts, showPlanned: true, showUnplanned: true,
        showResolved: false, island: .all, watchingOnly: true
    )
    t.check(watchedEvents.isEmpty, "no events on SH20")
    store.updateWatchlist { $0.setWatching(journeyID: "87", true) }
    t.equal(
        store.scopedJourneys(region: "", highway: "", search: "", flows: Set(FlowKind.allCases), watchingOnly: true).map(\.id),
        ["87"],
        "a watched journey"
    )
    t.equal(store.scopedCameras(region: "", highway: "", search: "", statuses: allStatuses).count, 2, "the filter off shows everything")
}

// MARK: - E4 seams: server errors, poisoned responses, priming, the memo, time

@MainActor
private func testServerErrorFallsBackToSavedData(_ t: TestRunner) async {
    t.group("store: a 503 is retried, then served from the saved copy")
    StubServer.reset()
    StubFixtures.routeAllEndpoints()
    StubServer.route("/cameras/all", .status(503))
    let fixture = await makeStore(seedCache: true)
    defer { removeTemporaryFolder(fixture.folder) }
    let store = fixture.store

    await store.loadAllData()
    t.check(await waitForIdle(store), "the refresh settles")
    t.equal(StubServer.requestCount("/cameras/all"), 3, "a 5xx is tried three times (no real backoff sleeps)")
    t.equal(store.cameras.count, 3, "the empty section falls back to the saved cameras")
    t.check(store.savedSections.contains(.cameras), "marked as saved")
    t.check(store.failedSections.contains(.cameras), "and as failed")
    t.equal(store.errors[.cameras], "NZTA API returned HTTP 503.", "the error names the status")
    t.check(store.errors[.events] == nil && store.events.count == 3, "the other sections load normally")
    t.check(!store.savedSections.contains(.events), "from live data")
}

@MainActor
private func testPoisonedResponseKeepsData(_ t: TestRunner) async {
    t.group("store: a poisoned 200 keeps the data and the saved copy")
    StubServer.reset()
    StubFixtures.routeAllEndpoints()
    let fixture = await makeStore()
    defer { removeTemporaryFolder(fixture.folder) }
    let store = fixture.store

    await store.loadAllData()
    t.check(await waitForIdle(store), "the first refresh settles")
    t.equal(store.cameras.count, 2, "live cameras shown")
    let savedBytes = await fixture.cache.read(section: .cameras)?.data
    t.equal(savedBytes, Data(StubFixtures.camerasLive.utf8), "and saved verbatim")

    let poisoned: [(String, String)] = [
        ("an HTML error page", "<html><body>Service Unavailable</body></html>"),
        ("a renamed list key", #"{"response":{"cams":[{"id":1}]}}"#),
        ("a list of unreadable entries", #"{"response":{"camera":[null,"x",7]}}"#),
    ]
    for (label, body) in poisoned {
        StubServer.route("/cameras/all", .json(body))
        await store.reload(.cameras)
        t.equal(store.cameras.map(\.id), ["653", "812"], "\(label): the cameras on screen stay")
        t.check(store.errors[.cameras]?.hasPrefix("Unable to read NZTA API JSON") == true, "\(label): reported as unreadable (got \(store.errors[.cameras] ?? "nil"))")
        t.check(store.failedSections.contains(.cameras), "\(label): recorded as a failure")
        t.check(!store.savedSections.contains(.cameras), "\(label): live data isn't swapped for the saved copy")
        let afterBytes = await fixture.cache.read(section: .cameras)?.data
        t.equal(afterBytes, savedBytes, "\(label): the saved copy isn't overwritten")
    }
    t.equal(StubServer.requestCount("/cameras/all"), 1 + poisoned.count, "an unreadable 200 isn't retried")
}

@MainActor
private func testPrimeFillsOnlyEmptySections(_ t: TestRunner) async {
    t.group("store: the launch prime fills only empty sections")
    StubServer.reset()
    StubFixtures.routeAllEndpoints()
    let fixture = await makeStore()
    defer { removeTemporaryFolder(fixture.folder) }
    let store = fixture.store

    // Live cameras arrive before the launch (e.g. a Retry), then the disk
    // holds an older, different copy of cameras and events.
    await store.reload(.cameras)
    t.equal(store.cameras.count, 2, "live cameras loaded")
    await fixture.cache.write(Data(StubFixtures.cameras.utf8), section: .cameras)
    await fixture.cache.write(Data(StubFixtures.events.utf8), section: .events)
    StubFixtures.failAllEndpoints(.cannotConnectToHost)

    await store.start().value
    t.check(await waitForIdle(store), "the launch settles")
    t.equal(store.cameras.count, 2, "cameras already on screen aren't replaced by the saved copy")
    t.check(!store.savedSections.contains(.cameras), "and aren't marked saved")
    t.check(store.savedSections.contains(.events), "the empty events section is primed from disk")
    t.equal(Set(store.events.map(\.id)), ["561700", "560046"], "without the event that already ended")
}

@MainActor
private func testReloadClearsOnlyItsOwnError(_ t: TestRunner) async {
    t.group("store: Retry clears only its own section's error")
    StubServer.reset()
    StubFixtures.failAllEndpoints(.cannotConnectToHost)
    let fixture = await makeStore()
    defer { removeTemporaryFolder(fixture.folder) }
    let store = fixture.store

    await store.loadAllData()
    t.check(await waitForIdle(store), "the failed refresh settles")
    t.check(store.errors[.cameras] != nil && store.errors[.events] != nil && store.errors[.vms] != nil, "every section has an error")

    StubServer.route("/cameras/all", .json(StubFixtures.camerasLive))
    await store.reload(.cameras)
    t.equal(store.errors[.cameras], nil, "the retried section's error clears")
    t.equal(store.cameras.count, 2, "and its data arrives")
    t.check(store.errors[.events] != nil && store.errors[.vms] != nil, "the other sections keep their errors")
    t.check(store.failedSections == Set(DataSection.allCases).subtracting([.cameras]), "and stay failed")
}

@MainActor
private func testFilterMemoFollowsNewData(_ t: TestRunner) async {
    t.group("store: memoized filters follow new data")
    StubServer.reset()
    StubFixtures.routeAllEndpoints()
    let fixture = await makeStore()
    defer { removeTemporaryFolder(fixture.folder) }
    let store = fixture.store

    await store.reload(.cameras)
    t.equal(store.filteredCameras(region: "Canterbury", highway: "", search: "").count, 0, "no Canterbury camera live yet")
    t.equal(store.filteredCameras(region: "", highway: "SH1", search: "").map(\.id), ["812"], "SH1 finds the Old SH1 camera")

    // Same filter inputs, new data: the memo must not serve the old answer.
    StubServer.route("/cameras/all", .json(StubFixtures.cameras))
    await store.reload(.cameras)
    t.equal(store.filteredCameras(region: "Canterbury", highway: "", search: "").map(\.id), ["831"], "the new Canterbury camera appears")
    t.equal(store.filteredCameras(region: "", highway: "SH1", search: "").map(\.id), ["812", "831"], "and joins it under SH1")

    // Unrelated sections loading don't disturb it.
    await store.reload(.events)
    t.equal(store.filteredCameras(region: "Canterbury", highway: "", search: "").map(\.id), ["831"], "an events load leaves the camera memo right")
}

@MainActor
private func testCancelledRequestIsNotAnError(_ t: TestRunner) async {
    t.group("store: a cancelled request is not an error")
    StubServer.reset()
    StubFixtures.routeAllEndpoints()
    StubServer.route("/cameras/all", .failing(.cancelled))
    let fixture = await makeStore(seedCache: true)
    defer { removeTemporaryFolder(fixture.folder) }
    let store = fixture.store

    await store.reload(.cameras)
    t.equal(store.errors[.cameras], nil, "no error banner")
    t.check(!store.failedSections.contains(.cameras), "not recorded as a failure")
    t.check(store.cameras.isEmpty && !store.savedSections.contains(.cameras), "and no fallback to the saved copy")
    t.equal(StubServer.requestCount("/cameras/all"), 1, "and not retried")
    t.check(!store.isLoading(.cameras), "the loading flag clears")
}

@MainActor
private func testInjectedClock(_ t: TestRunner) async {
    t.group("store: time comes from the injected clock")
    StubServer.reset()
    StubFixtures.routeAllEndpoints()
    guard let start = parseTrafficDate("2026-09-26T17:30:00+12:00") else {
        t.check(false, "start date parses")
        return
    }
    let clock = TestClock(start)
    let fixture = await makeStore(clock: clock)
    defer { removeTemporaryFolder(fixture.folder) }
    let store = fixture.store

    await store.loadAllData()
    t.check(await waitForIdle(store), "the refresh settles")
    t.equal(store.lastUpdated, start, "'Updated' is stamped from the clock")
    t.equal(store.lastLiveSuccess[.cameras], start, "and so is each section's last success")

    clock.advance(by: 60)
    await store.refreshIfStale(maxAge: 120)
    t.equal(StubServer.requestCount("/cameras/all"), 1, "a window reopened a minute later doesn't refresh")
    clock.advance(by: 90)
    await store.refreshIfStale(maxAge: 120)
    t.equal(StubServer.requestCount("/cameras/all"), 2, "two and a half minutes later it does")

    // Replaying saved events drops the ones that ended before "now": the
    // delay ends 1 Oct 2099, so a clock in 2100 leaves only the open closure.
    let later = await makeStore(seedCache: true, clock: TestClock(Date(timeIntervalSince1970: 4_102_444_800 + 86_400 * 30)))
    defer { removeTemporaryFolder(later.folder) }
    StubFixtures.failAllEndpoints(.cannotConnectToHost)
    await later.store.start().value
    t.check(await waitForIdle(later.store), "the later launch settles")
    t.equal(later.store.events.map(\.id), ["561700"], "events that ended before the clock's now aren't replayed")
}
