import Foundation

// The refresh lifecycle's pure policy (Sources/RefreshPolicy.swift): the
// auto-refresh cadence and its 60 s floor, the freshness banner, the Dock
// badge, and the single-flight helper the store coalesces loads with.
@MainActor
func runRefreshPolicyTests(_ t: TestRunner) async {
    testIntervalClampAndMigration(t)
    testBackgroundCadence(t)
    testNextRefreshDelay(t)
    testCameraImageReloadSpacing(t)
    testReconnectReload(t)
    testStaleData(t)
    testIntervalLabels(t)
    testFreshnessBanner(t)
    testFreshnessMessages(t)
    testDockBadge(t)
    testDataSections(t)
    testEndedEvents(t)
    testDiagnosticsReportExtras(t)
    await testSingleFlight(t)
}

private func testIntervalClampAndMigration(_ t: TestRunner) {
    t.group("auto-refresh interval: 60–600 s")
    t.equal(AutoRefreshPolicy.clamp(30), 60, "the old 30 s option clamps up to the 60 s floor")
    t.equal(AutoRefreshPolicy.clamp(59), 60, "anything under a minute clamps to 60 s")
    t.equal(AutoRefreshPolicy.clamp(120), 120, "in-range values are kept")
    t.equal(AutoRefreshPolicy.clamp(3600), 600, "the ceiling is 10 minutes")
    t.equal(AutoRefreshPolicy.intervalOptions, [60, 120, 300, 600], "the pickers no longer offer 30 s")
    t.check(AutoRefreshPolicy.intervalOptions.allSatisfy { AutoRefreshPolicy.clamp($0) == $0 }, "every option is in range")

    t.equal(AutoRefreshPolicy.migratedStoredInterval(30), 60, "a stored 30 s is migrated to 60 s")
    t.equal(AutoRefreshPolicy.migratedStoredInterval(45), 60, "a stored 45 s is migrated to 60 s")
    t.equal(AutoRefreshPolicy.migratedStoredInterval(900), 600, "a stored value over 600 s is migrated down")
    t.check(AutoRefreshPolicy.migratedStoredInterval(120) == nil, "an in-range value is left alone")
    t.check(AutoRefreshPolicy.migratedStoredInterval(nil) == nil, "an unset value is left unset")

    let settings = AutoRefreshSettings(isEnabled: true, storedInterval: 30)
    t.equal(settings.interval, 60, "settings built from a stale stored value are clamped")
    t.check(settings == AutoRefreshSettings(isEnabled: true, storedInterval: 60), "equal once clamped, so re-applying is a no-op")
    t.equal(AutoRefreshPolicy.enabledKey, "nzta.autoRefreshEnabled", "the enabled key is unchanged")
    t.equal(AutoRefreshPolicy.intervalKey, "nzta.refreshIntervalSeconds", "the interval key is unchanged")
}

private func testBackgroundCadence(_ t: TestRunner) {
    t.group("auto-refresh backs off in the background")
    t.equal(AutoRefreshPolicy.effectiveInterval(base: 120, isAppActive: true, hasVisibleWindow: true), 120, "frontmost: the chosen interval")
    t.equal(AutoRefreshPolicy.effectiveInterval(base: 120, isAppActive: false, hasVisibleWindow: true), 120, "a window on screen keeps the chosen interval")
    t.equal(AutoRefreshPolicy.effectiveInterval(base: 120, isAppActive: true, hasVisibleWindow: false), 120, "an active app keeps the chosen interval")
    t.equal(AutoRefreshPolicy.effectiveInterval(base: 120, isAppActive: false, hasVisibleWindow: false), 360, "inactive with no window: three times slower")
    t.equal(AutoRefreshPolicy.backgroundInterval(for: 60), 180, "1 minute backs off to 3 minutes")
    t.equal(AutoRefreshPolicy.backgroundInterval(for: 300), 900, "5 minutes backs off to the 15-minute ceiling")
    t.equal(AutoRefreshPolicy.backgroundInterval(for: 600), 900, "10 minutes also backs off only to 15 minutes")
    t.equal(AutoRefreshPolicy.backgroundInterval(for: 30), 180, "a stale 30 s is clamped before backing off")
    for base in AutoRefreshPolicy.intervalOptions {
        t.check(AutoRefreshPolicy.backgroundInterval(for: base) >= base, "background is never faster than \(base) s")
    }
}

private func testNextRefreshDelay(_ t: TestRunner) {
    t.group("auto-refresh counts from the last refresh")
    let now = Date(timeIntervalSince1970: 1_000_000)
    t.equal(AutoRefreshPolicy.delayUntilNextRefresh(lastAttempt: nil, now: now, interval: 120), 0, "no refresh yet: due now")
    t.equal(
        AutoRefreshPolicy.delayUntilNextRefresh(lastAttempt: now.addingTimeInterval(-30), now: now, interval: 120),
        90,
        "30 s after a refresh, the next is 90 s away"
    )
    t.equal(
        AutoRefreshPolicy.delayUntilNextRefresh(lastAttempt: now.addingTimeInterval(-500), now: now, interval: 120),
        0,
        "an overdue refresh (after the background back-off) runs at once"
    )
    // Switching apps changes only the interval, never the anchor, so it can't
    // keep postponing a refresh.
    let anchor = now.addingTimeInterval(-100)
    t.equal(
        AutoRefreshPolicy.delayUntilNextRefresh(lastAttempt: anchor, now: now, interval: 360),
        260,
        "backing off extends the wait from the same anchor"
    )
    t.equal(
        AutoRefreshPolicy.delayUntilNextRefresh(lastAttempt: anchor, now: now, interval: 120),
        20,
        "coming back to the foreground shortens it again"
    )
}

private func testCameraImageReloadSpacing(_ t: TestRunner) {
    t.group("camera image reload spacing")
    let now = Date(timeIntervalSince1970: 2_000_000)
    t.check(AutoRefreshPolicy.shouldReloadCameraImages(lastReload: nil, now: now), "first cameras refresh reloads images")
    t.check(!AutoRefreshPolicy.shouldReloadCameraImages(lastReload: now.addingTimeInterval(-10), now: now), "a burst within 30 s doesn't reload again")
    t.check(
        AutoRefreshPolicy.shouldReloadCameraImages(lastReload: now.addingTimeInterval(-57), now: now),
        "a 60 s tick that landed a few seconds early still reloads"
    )
}

private func testReconnectReload(_ t: TestRunner) {
    t.group("reload once back online")
    t.check(AutoRefreshPolicy.shouldReloadOnReconnect(wasOnline: false, isOnline: true, hasUnconfirmedData: true), "offline → online with failures reloads")
    t.check(!AutoRefreshPolicy.shouldReloadOnReconnect(wasOnline: false, isOnline: true, hasUnconfirmedData: false), "nothing to confirm: no reload")
    t.check(!AutoRefreshPolicy.shouldReloadOnReconnect(wasOnline: true, isOnline: true, hasUnconfirmedData: true), "no transition: no reload")
    t.check(!AutoRefreshPolicy.shouldReloadOnReconnect(wasOnline: true, isOnline: false, hasUnconfirmedData: true), "going offline never reloads")
}

private func testStaleData(_ t: TestRunner) {
    t.group("stale data warning")
    let now = Date(timeIntervalSince1970: 3_000_000)
    t.check(!AutoRefreshPolicy.isDataStale(lastUpdated: nil, now: now), "never updated isn't 'stale'")
    t.check(!AutoRefreshPolicy.isDataStale(lastUpdated: now.addingTimeInterval(-599), now: now), "under 10 minutes is fresh")
    t.check(AutoRefreshPolicy.isDataStale(lastUpdated: now.addingTimeInterval(-601), now: now), "over 10 minutes is stale")
}

private func testIntervalLabels(_ t: TestRunner) {
    t.group("interval labels")
    t.equal(AutoRefreshPolicy.intervalLabel(60), "1 minute", "singular minute")
    t.equal(AutoRefreshPolicy.intervalLabel(300), "5 minutes", "plural minutes")
    t.equal(AutoRefreshPolicy.shortIntervalLabel(120), "2m", "compact minutes")
    t.equal(AutoRefreshPolicy.shortIntervalLabel(90), "90s", "compact seconds")
}

private func section(
    hasData: Bool = true,
    saved: Bool = false,
    failed: Bool = false,
    loading: Bool = false,
    date: Date? = nil
) -> SectionFreshness {
    SectionFreshness(hasData: hasData, isSaved: saved, lastFetchFailed: failed, isLoading: loading, dataDate: date)
}

private func testFreshnessBanner(_ t: TestRunner) {
    t.group("freshness banner")
    let old = Date(timeIntervalSince1970: 1_000)
    let older = Date(timeIntervalSince1970: 500)
    let recent = Date(timeIntervalSince1970: 9_000)

    t.check(FreshnessBanner.make(isOnline: true, sections: [section(date: recent), section(date: recent)]) == nil, "all live: no banner")

    // A warm launch: every section primed from disk while the live load runs.
    let primed = FreshnessBanner.make(isOnline: true, sections: [
        section(saved: true, loading: true, date: old),
        section(saved: true, loading: true, date: older)
    ])
    t.check(primed == .updating(since: older), "primed data while loading is 'updating', not an error")
    t.check(primed?.isWarning == false, "the priming banner is not a warning")

    let failed = FreshnessBanner.make(isOnline: true, sections: [
        section(saved: true, failed: true, date: old),
        section(date: recent)
    ])
    t.check(failed == .unreachable(since: old), "a failed live fetch with saved data shows 'couldn't reach'")
    t.check(failed?.isWarning == true, "couldn't reach is a warning")

    let liveButFailing = FreshnessBanner.make(isOnline: true, sections: [section(failed: true, date: recent)])
    t.check(liveButFailing == .unreachable(since: recent), "a failed refresh over live data dates the data it kept")

    t.check(
        FreshnessBanner.make(isOnline: true, sections: [section(hasData: false, failed: true)]) == nil,
        "a failed section with nothing on screen leaves it to the tab's error banner"
    )
    t.check(
        FreshnessBanner.make(isOnline: true, sections: [section(saved: true, date: old)]) == .saved(since: old),
        "saved data with no load and no failure is plain 'saved'"
    )

    let offline = FreshnessBanner.make(isOnline: false, sections: [
        section(date: recent),
        section(saved: true, date: older),
        section(hasData: false)
    ])
    t.check(offline == .offline(since: older), "offline reports the oldest data on screen")
    t.check(FreshnessBanner.make(isOnline: false, sections: []) == .offline(since: nil), "offline with nothing loaded")

    // B19: the worst case, not the best.
    let mixed = FreshnessBanner.make(isOnline: true, sections: [
        section(saved: true, failed: true, date: recent),
        section(saved: true, failed: true, date: older)
    ])
    t.check(mixed == .unreachable(since: older), "the banner shows the oldest saved copy, not the newest")
}

private func testFreshnessMessages(_ t: TestRunner) {
    t.group("freshness banner wording")
    let now = Date(timeIntervalSince1970: 100_000)
    let twoHoursAgo = now.addingTimeInterval(-7_200)
    t.equal(
        FreshnessBanner.updating(since: twoHoursAgo).message(relativeTo: now),
        "Showing saved data from 2 hours ago — updating…",
        "priming says 'saved data … updating'"
    )
    t.equal(
        FreshnessBanner.unreachable(since: twoHoursAgo).message(relativeTo: now),
        "Couldn’t reach NZTA — showing data from 2 hours ago.",
        "a real failure says couldn't reach"
    )
    t.equal(
        FreshnessBanner.offline(since: twoHoursAgo).message(relativeTo: now),
        "Offline — showing data from 2 hours ago.",
        "offline with data"
    )
    t.equal(FreshnessBanner.offline(since: nil).message(relativeTo: now), "Offline — no internet connection.", "offline without data")
    t.equal(
        FreshnessBanner.saved(since: now.addingTimeInterval(-20)).message(relativeTo: now),
        "Showing saved data from less than a minute ago.",
        "under a minute reads naturally"
    )
    t.check(
        !FreshnessBanner.updating(since: twoHoursAgo).message(relativeTo: now).contains("couldn"),
        "the launch banner never claims NZTA was unreachable"
    )
    // The same banner ages as time passes (the view re-renders on a timer).
    t.equal(
        FreshnessBanner.offline(since: twoHoursAgo).message(relativeTo: now.addingTimeInterval(3_600)),
        "Offline — showing data from 3 hours ago.",
        "the age moves with the clock"
    )
    t.equal(describeDataAge(now.addingTimeInterval(-86_400 * 3), relativeTo: now), "3 days ago", "days")
    t.equal(FreshnessBanner.unreachable(since: nil).shortMessage, "Couldn’t reach NZTA — showing saved data", "timeless menu wording")
}

private func testDockBadge(_ t: TestRunner) {
    t.group("dock badge")
    t.check(DockBadge.label(activeClosures: 0, isProvisional: false) == nil, "no closures: no badge")
    t.check(DockBadge.label(activeClosures: 0, isProvisional: true) == nil, "no closures from saved data: still no badge")
    t.equal(DockBadge.label(activeClosures: 5, isProvisional: false), "5", "live count")
    t.equal(DockBadge.label(activeClosures: 5, isProvisional: true), "5?", "a count from saved data is qualified")
}

private func testDataSections(_ t: TestRunner) {
    t.group("data sections")
    t.equal(DataSection.cacheable, [.cameras, .events, .vms, .journeys], "the four offline-cacheable sections")
    t.check(!DataSection.refreshedTogether.contains(.journeys), "journeys doesn't hold a refresh back")
    t.equal(
        Set(DataSection.refreshedTogether + [.journeys]),
        Set(DataSection.allCases),
        "every section is loaded by a refresh"
    )
}

private func testEndedEvents(_ t: TestRunner) {
    t.group("ended events left out of a cache replay")
    guard let payload = decodeModel(RoadEventsPayload.self, StubFixtures.events, t) else {
        return
    }
    let events = payload.response.roadevent
    let now = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21
    t.equal(events.count, 3, "fixture decodes")
    t.check(!events[0].hasEnded(before: now), "no end date: not ended")
    t.check(!events[1].hasEnded(before: now), "a future end date: not ended")
    t.check(events[2].hasEnded(before: now), "an end date in the past: ended")
    t.equal(events.filter { !$0.hasEnded(before: now) }.map(\.id).count, 2, "the replay keeps the current events")
}

private func testDiagnosticsReportExtras(_ t: TestRunner) {
    t.group("diagnostics: cache, system, API, per-section status")
    let saved = Date(timeIntervalSince1970: 1_790_000_000)
    let report = DiagnosticsReport(
        appVersion: "3.0.0",
        appBuild: "15",
        generatedAt: Date(timeIntervalSince1970: 0),
        lastUpdated: nil,
        isOnline: true,
        sections: [
            .init(name: "Cameras", count: 313, error: nil, status: "live", lastSuccess: saved),
            .init(name: "Road Events", count: 0, error: "boom", status: "no live data yet, last fetch failed")
        ],
        preferences: [:],
        system: DiagnosticsReport.systemDescription(operatingSystem: "Version 27.0 (Build 27A266a)"),
        freshness: "Couldn’t reach NZTA — showing data from 2 hours ago.",
        refresh: ["Auto-refresh: every 120 s (foreground; chosen 120 s)"],
        cacheFiles: [.init(name: "cameras.json", byteCount: 237_140, savedAt: saved)],
        apiFallbacks: ["/events/all/10"]
    )
    let text = report.formattedText()
    t.check(text.contains("System:       macOS Version 27.0 (Build 27A266a), arm64"), "OS version and architecture")
    t.check(text.contains("Banner:       Couldn’t reach NZTA"), "the freshness banner")
    t.check(text.contains("Auto-refresh: every 120 s"), "refresh state")
    t.check(text.contains("    live; last live fetch: 2026-09-21T"), "per-section status with its last live fetch")
    t.check(text.contains("    no live data yet, last fetch failed; last live fetch: never"), "a section that never loaded")
    t.check(text.contains("Road Events: 0 — ERROR: boom"), "errors still render on the section line")
    t.check(text.contains("cameras.json: 237140 bytes, saved 2026-09-21T"), "offline cache files with size and age")
    t.check(text.contains("Traffic API: rest/5, falling back to rest/4 for /events/all/10"), "the rest/4 fallback is noted")

    let plain = DiagnosticsReport(
        appVersion: "1",
        appBuild: "1",
        generatedAt: Date(timeIntervalSince1970: 0),
        lastUpdated: nil,
        isOnline: true,
        sections: [],
        preferences: [:]
    ).formattedText()
    t.check(plain.contains("Offline Cache\n-------------\n(empty)"), "an empty cache says so")
    t.check(plain.contains("Traffic API: rest/5\n"), "no fallback: plain rest/5")
    t.check(!plain.contains("System:"), "no system line unless supplied")
}

private final class Counter {
    var value = 0
}

@MainActor
private func testSingleFlight(_ t: TestRunner) async {
    t.group("single flight")
    let flight = SingleFlight<String, Int>()
    let runs = Counter()
    let operation: @MainActor () async -> Int = {
        runs.value += 1
        try? await Task.sleep(for: .milliseconds(50))
        return runs.value
    }

    async let first = flight.run("cameras", operation)
    async let second = flight.run("cameras", operation)
    async let other = flight.run("events", operation)
    let results = await (first, second, other)
    t.equal(runs.value, 2, "concurrent callers for one key share a single run")
    t.equal(results.0, results.1, "both callers get the shared result")
    t.check(!flight.isRunning("cameras"), "the key is free once the run finishes")

    let later = await flight.run("cameras", operation)
    t.equal(runs.value, 3, "a caller after the run finished starts a fresh one")
    t.equal(later, 3, "…and gets the fresh result")

    // Cancelling one waiting caller doesn't cancel the shared work.
    let slow: @MainActor () async -> Int = {
        try? await Task.sleep(for: .milliseconds(100))
        return Task.isCancelled ? -1 : 42
    }
    let cancelled = Task { await flight.run("slow", slow) }
    let waiter = Task { await flight.run("slow", slow) }
    try? await Task.sleep(for: .milliseconds(20))
    cancelled.cancel()
    t.equal(await waiter.value, 42, "the shared job isn't cancelled by one caller")
    t.equal(await cancelled.value, 42, "the cancelled caller still receives the result")
}
