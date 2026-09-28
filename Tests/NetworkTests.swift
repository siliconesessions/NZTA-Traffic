import Foundation

// TrafficAPIService against the in-process stub (StubNetwork.swift): retries,
// fail-fast errors, cancellation, the rest/5 → rest/4 fallback and the
// journeys timeout; and the OfflineCache actor against a temporary folder.
@MainActor
func runNetworkTests(_ t: TestRunner) async {
    testRetryClassification(t)
    await testRetriesTransientFailures(t)
    await testFailsFastWhenUnreachable(t)
    await testCancellationIsNotAFailure(t)
    await testLegacyFallback(t)
    await testRequestDetails(t)
    await testOfflineCacheWrites(t)
}

private func testRetryClassification(_ t: TestRunner) {
    t.group("which failures are retried")
    t.check(TrafficAPIError.httpStatus(503).isRetriable, "a 5xx is retried")
    t.check(!TrafficAPIError.httpStatus(404).isRetriable, "a 4xx is not")
    t.check(!TrafficAPIError.httpStatus(429).isRetriable, "rate limiting is not hammered")
    t.check(TrafficAPIError.transport(.networkConnectionLost, "lost").isRetriable, "a dropped connection is retried")
    t.check(TrafficAPIError.transport(nil, "unknown").isRetriable, "an unknown transport error is retried")
    for code: URLError.Code in [.timedOut, .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .cancelled] {
        t.check(!TrafficAPIError.transport(code, "x").isRetriable, "URLError \(code.rawValue) fails at once")
    }
    t.check(!TrafficAPIError.offline.isRetriable, "offline is not retried")
    t.check(!TrafficAPIError.decoding("bad", "{").isRetriable, "a decoding failure is not retried")
    t.check(TrafficAPIError.offline.errorDescription?.contains("No internet connection") == true, "offline explains itself")

    let policy = RetryPolicy()
    t.equal(policy.maxAttempts, 3, "three attempts")
    t.equal(policy.delay(afterAttempt: 1), .seconds(1), "1 s after the first failure")
    t.equal(policy.delay(afterAttempt: 2), .seconds(2), "2 s after the second")
}

@MainActor
private func testRetriesTransientFailures(_ t: TestRunner) async {
    t.group("transient failures are retried")
    StubServer.reset()
    StubServer.route("/cameras/all", .status(503), .json(StubFixtures.cameras))
    let service = makeStubService()
    let result = await service.fetchCamerasResult()
    t.equal((try? result.get())?.value.count, 3, "a 503 then a 200 succeeds")
    t.equal(StubServer.requestCount("/cameras/all"), 2, "one retry")

    StubServer.reset()
    StubServer.route("/events/all/10", .status(503))
    let exhausted = await service.fetchRoadEventsResult()
    t.check(exhausted.failureError == .httpStatus(503), "three 503s fail with the status")
    t.equal(StubServer.requestCount("/events/all/10"), 3, "no more than three attempts")
}

@MainActor
private func testFailsFastWhenUnreachable(_ t: TestRunner) async {
    t.group("unreachable host fails at once")
    StubServer.reset()
    StubServer.route("/cameras/all", .failing(.cannotFindHost))
    let service = makeStubService()
    let started = Date()
    let result = await service.fetchCamerasResult()
    if case .transport(let code, _)? = result.failureError {
        t.check(code == .cannotFindHost, "the URLError code is kept")
    } else {
        t.check(false, "a DNS failure is a transport error")
    }
    t.equal(StubServer.requestCount("/cameras/all"), 1, "a DNS failure isn't retried")
    t.check(Date().timeIntervalSince(started) < 1, "and returns immediately")

    StubServer.route("/signs/vms/all", .failing(.timedOut))
    _ = await service.fetchVMSSignsResult()
    t.equal(StubServer.requestCount("/signs/vms/all"), 1, "a timeout (already a long wait) isn't retried")
}

@MainActor
private func testCancellationIsNotAFailure(_ t: TestRunner) async {
    t.group("cancellation is not a network error")
    StubServer.reset()
    StubServer.route("/cameras/all", .hanging)
    let service = makeStubService()
    let task = Task { await service.fetchCamerasResult() }
    _ = await waitUntil { StubServer.requestCount("/cameras/all") == 1 }
    task.cancel()
    let result = await task.value
    t.check(result.failureIsCancellation, "a cancelled fetch fails with CancellationError, not 'Unable to reach NZTA API: cancelled'")
    try? await Task.sleep(for: .milliseconds(50))
    t.equal(StubServer.requestCount("/cameras/all"), 1, "and is not retried")

    // Cancelled during the backoff sleep: stops at once too.
    StubServer.reset()
    StubServer.route("/events/all/10", .status(503))
    let slowRetry = TrafficAPIService(
        session: makeStubSession(),
        userAgent: "NZTraffic-Tests",
        retryPolicy: RetryPolicy(maxAttempts: 3, baseDelay: .seconds(5))
    )
    let backingOff = Task { await slowRetry.fetchRoadEventsResult() }
    _ = await waitUntil { StubServer.requestCount("/events/all/10") == 1 }
    let cancelledAt = Date()
    backingOff.cancel()
    let backoffResult = await backingOff.value
    t.check(backoffResult.failureIsCancellation, "cancelling during the backoff reports cancellation")
    t.check(Date().timeIntervalSince(cancelledAt) < 1, "without waiting out the 5 s backoff")
    t.equal(StubServer.requestCount("/events/all/10"), 1, "and without another attempt")
}

@MainActor
private func testLegacyFallback(_ t: TestRunner) async {
    t.group("rest/5 → rest/4 fallback")
    StubServer.reset()
    StubServer.route("rest/5/events/all/10", .status(404))
    StubServer.route("rest/4/events/all/10", .json(StubFixtures.events))
    StubServer.route("rest/5/cameras/all", .status(500))
    StubServer.route("rest/4/cameras/all", .json(StubFixtures.cameras))
    StubServer.route("rest/5/signs/vms/all", .status(410))
    StubServer.route("rest/4/signs/vms/all", .json(StubFixtures.vms))
    let service = makeStubService(maxAttempts: 1)

    let events = await service.fetchRoadEventsResult()
    t.equal((try? events.get())?.value.count, 3, "a 404 from rest/5 is answered by rest/4")
    t.equal(service.versionFallback.legacyEndpoints, ["/events/all/10"], "the fallback is remembered (and reported)")

    StubServer.clearLog()
    _ = await service.fetchRoadEventsResult()
    t.equal(StubServer.requestCount("rest/5/events"), 0, "later requests go straight to rest/4")
    t.equal(StubServer.requestCount("rest/4/events"), 1, "…once")

    let vms = await service.fetchVMSSignsResult()
    t.equal((try? vms.get())?.value.count, 1, "a 410 falls back too")

    let cameras = await service.fetchCamerasResult()
    t.check(cameras.failureError == .httpStatus(500), "a 500 is an outage, not a missing endpoint: no fallback")
    t.equal(StubServer.requestCount("rest/4/cameras"), 0, "rest/4 isn't tried for a 500")
    t.check(APIVersionFallback.shouldFallBack(afterStatus: 404) && APIVersionFallback.shouldFallBack(afterStatus: 410), "404 and 410 fall back")
    t.check(!APIVersionFallback.shouldFallBack(afterStatus: 403), "403 doesn't")

    // Both versions gone: the rest/4 error surfaces and nothing is remembered.
    StubServer.route("rest/5/journeys/all/10", .status(404))
    StubServer.route("rest/4/journeys/all/10", .status(404))
    let journeys = await service.fetchJourneysResult()
    t.check(journeys.failureError == .httpStatus(404), "a 404 from both fails")
    t.check(!service.versionFallback.legacyEndpoints.contains("/journeys/all/10"), "an unsuccessful fallback isn't remembered")
}

@MainActor
private func testRequestDetails(_ t: TestRunner) async {
    t.group("request details")
    StubServer.reset()
    StubFixtures.routeAllEndpoints()
    let service = makeStubService()
    t.equal(TrafficAPIService.requestTimeout(for: TrafficAPIService.Path.journeys), 60, "journeys gets a 60 s timeout")
    t.check(TrafficAPIService.requestTimeout(for: TrafficAPIService.Path.cameras) == nil, "other requests keep the 30 s session timeout")
    t.check(TrafficAPIService.requestTimeout(for: TrafficAPIService.Path.events) == nil, "including events")

    let first = try? await service.fetchCamerasResult().get()
    t.equal(StubServer.requests(matching: "/cameras/all").first?.userAgent, "NZTraffic-Tests", "the User-Agent is sent")
    let second = try? await service.fetchCamerasResult().get()
    t.check(first?.digest == second?.digest, "identical bytes have the same digest")
    StubServer.route("/cameras/all", .json(StubFixtures.cameras))
    let changed = try? await service.fetchCamerasResult().get()
    t.check(changed?.digest != first?.digest, "different bytes don't")

    let tim = try? await service.fetchTIMSignsResult().get()
    t.equal(tim?.value.count, 1, "TIM boards decode through the byte path")
    let congestion = try? await service.fetchCongestionResult().get()
    t.equal(congestion?.value.count, 1, "congestion XML decodes through the byte path")
}

@MainActor
private func testOfflineCacheWrites(_ t: TestRunner) async {
    t.group("offline cache skips unchanged writes")
    let folder = makeTemporaryFolder()
    defer { removeTemporaryFolder(folder) }
    let cache = OfflineCache(directory: folder)
    let bytes = Data(StubFixtures.cameras.utf8)
    let file = folder.appendingPathComponent("cameras.json")

    t.equal(await cache.write(bytes, section: .cameras), .written, "the first write writes")
    let backdated = Date(timeIntervalSinceNow: -3_600)
    try? FileManager.default.setAttributes([.modificationDate: backdated], ofItemAtPath: file.path)
    t.equal(await cache.write(bytes, section: .cameras), .unchanged, "the same bytes again are skipped")
    t.equal(try? Data(contentsOf: file), bytes, "the file still holds them")
    let touched = await cache.savedAt(section: .cameras) ?? .distantPast
    t.check(touched > backdated.addingTimeInterval(60), "…but its date records that they were confirmed now")

    let live = Data(StubFixtures.camerasLive.utf8)
    t.equal(await cache.write(live, section: .cameras), .deferred, "changed bytes soon after a write are held back")
    t.equal(try? Data(contentsOf: file), bytes, "the file keeps the older bytes meanwhile")
    t.equal(await cache.read(section: .cameras)?.data, live, "but reads serve the newest bytes")
    await cache.flush()
    t.equal(try? Data(contentsOf: file), live, "flushing writes them")
    t.equal(await cache.write(live, section: .cameras), .unchanged, "after which they count as saved")

    // A fresh cache instance learns the file's digest when it reads it.
    let reopened = OfflineCache(directory: folder)
    let entry = await reopened.read(section: .cameras)
    t.equal(entry?.data, Data(StubFixtures.camerasLive.utf8), "reads back what was written")
    t.check(entry?.digest == ContentDigest(of: Data(StubFixtures.camerasLive.utf8)), "with its digest")
    t.equal(await reopened.write(Data(StubFixtures.camerasLive.utf8), section: .cameras), .unchanged, "so a matching first refresh isn't rewritten")

    // A deleted file is written again even if the digest matches.
    try? FileManager.default.removeItem(at: file)
    t.equal(await reopened.write(Data(StubFixtures.camerasLive.utf8), section: .cameras), .written, "a missing file is rewritten")

    await reopened.write(Data(StubFixtures.events.utf8), section: .events)
    let info = await reopened.fileInfo()
    t.equal(info.map(\.section), [.cameras, .events], "diagnostics list the cached files in section order")
    t.equal(info.first?.byteCount, StubFixtures.camerasLive.utf8.count, "with their sizes")

    t.check(await reopened.removeAll(), "clearing the cache succeeds")
    t.check(await reopened.fileInfo().isEmpty, "and leaves no files")
    t.check(await reopened.read(section: .cameras) == nil, "nothing to read afterwards")
    t.equal(await reopened.write(Data(StubFixtures.camerasLive.utf8), section: .cameras), .written, "the next write after clearing isn't skipped")

    let disabled = OfflineCache(directory: nil)
    t.equal(await disabled.write(bytes, section: .cameras), .disabled, "a cache without a folder does nothing")

    await testOfflineCacheRewriteInterval(t)
}

@MainActor
private func testOfflineCacheRewriteInterval(_ t: TestRunner) async {
    t.group("offline cache rewrites a changing section at most every 10 minutes")
    let folder = makeTemporaryFolder()
    defer { removeTemporaryFolder(folder) }
    let clock = TestClock(Date(timeIntervalSince1970: 1_790_000_000))
    let cache = OfflineCache(directory: folder, clock: { clock.now })
    let file = folder.appendingPathComponent("journeys.json")
    let first = Data("[1]".utf8)
    let second = Data("[2]".utf8)
    let third = Data("[3]".utf8)

    t.equal(await cache.write(first, section: .journeys), .written, "the first write of a session writes")
    let written = await cache.savedAt(section: .journeys) ?? .distantPast
    t.check(abs(written.timeIntervalSince(clock.now)) < 1, "dated by the injected clock, not the wall clock")
    clock.advance(by: 120)
    t.equal(await cache.write(second, section: .journeys), .deferred, "a change two minutes later waits")
    t.equal(try? Data(contentsOf: file), first, "so the file isn't rewritten")
    let pendingDate = await cache.savedAt(section: .journeys) ?? .distantPast
    t.check(abs(pendingDate.timeIntervalSince(clock.now)) < 1, "the held bytes are dated when they arrived")
    clock.advance(by: 120)
    t.equal(await cache.write(first, section: .journeys), .unchanged, "going back to the saved bytes just confirms the file")
    t.equal(await cache.read(section: .journeys)?.data, first, "and drops the held change")
    clock.advance(by: 600)
    t.equal(await cache.write(third, section: .journeys), .written, "once the interval has passed a change is written")
    t.equal(try? Data(contentsOf: file), third, "straight to disk")
    let immediate = OfflineCache(directory: folder, minimumRewriteInterval: 0, clock: { clock.now })
    await immediate.write(first, section: .journeys)
    t.equal(await immediate.write(second, section: .journeys), .written, "a zero interval writes every change")
}

extension Result where Failure == Error {
    var failureError: TrafficAPIError? {
        guard case .failure(let error) = self else {
            return nil
        }
        return error as? TrafficAPIError
    }

    var failureIsCancellation: Bool {
        guard case .failure(let error) = self else {
            return false
        }
        return error is CancellationError
    }
}
