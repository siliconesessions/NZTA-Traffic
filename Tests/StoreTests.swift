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
    await testAutoRefreshCadence(t)
    await testStoreDiagnostics(t)
}

private struct StoreFixture {
    let store: TrafficStore
    let cache: OfflineCache
    let folder: URL
}

// A store on the stub network with an empty temporary cache, optionally
// seeded with saved (cached) copies of the four cacheable sections.
@MainActor
private func makeStore(seedCache: Bool = false) async -> StoreFixture {
    let folder = makeTemporaryFolder()
    let cache = OfflineCache(directory: folder)
    if seedCache {
        await cache.write(Data(StubFixtures.cameras.utf8), section: .cameras)
        await cache.write(Data(StubFixtures.events.utf8), section: .events)
        await cache.write(Data(StubFixtures.vms.utf8), section: .vms)
        await cache.write(Data(StubFixtures.journeys.utf8), section: .journeys)
    }
    let store = TrafficStore(
        service: makeStubService(),
        cache: OfflineCache(directory: folder),
        imageCache: nil,
        monitorsNetwork: false,
        reconnectDelay: .zero
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
    let saved = await fixture.cache.read(section: .cameras)
    t.equal(saved?.data, Data(StubFixtures.cameras.utf8), "and written to the cache")
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
private func testLaunchAfterUnfinishedLaunch(_ t: TestRunner) async {
    t.group("store: launch after a launch that never finished")
    t.check(LaunchGuard.shouldDiscardSavedData(previousLaunchUnfinished: true), "an unfinished previous launch discards the saved copy")
    t.check(!LaunchGuard.shouldDiscardSavedData(previousLaunchUnfinished: false), "a normal previous launch keeps it")
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
