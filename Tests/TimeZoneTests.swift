import Foundation

// B10 — NZTA timestamps are NZ time and the app shows NZ time whatever zone
// the Mac is in. On a Mac set to Pacific/Auckland a regression that drops the
// formatters' NZ pinning still passes, so run_tests.sh runs the whole suite
// again under TZ=UTC and TZ=America/Los_Angeles (and says which zone each run
// expects, checked below, so a TZ that silently didn't apply can't pass).
// Every string here is the full expected output, not a `contains`.
func runTimeZoneTests(_ t: TestRunner) {
    testExpectedZone(t)
    testMainDateFormats(t)
    testDaylightSaving(t)
    testRelativeDates(t)
}

private func testExpectedZone(_ t: TestRunner) {
    let zone = TimeZone.current.identifier
    t.group("dates: running in \(zone)")
    // Compared by UTC offset in January and July, since TZ=UTC reports its
    // identifier as "GMT".
    if let expected = ProcessInfo.processInfo.environment["NZ_TRAFFIC_EXPECT_TZ"], !expected.isEmpty {
        let instants = [Date(timeIntervalSince1970: 1_767_225_600), Date(timeIntervalSince1970: 1_782_864_000)]
        let offsets = instants.map { TimeZone.current.secondsFromGMT(for: $0) }
        let expectedOffsets = instants.map { TimeZone(identifier: expected)?.secondsFromGMT(for: $0) ?? .min }
        t.equal(offsets, expectedOffsets, "the run's time zone (\(expected)) took effect")
    }
}

private func testMainDateFormats(_ t: TestRunner) {
    t.group("dates: the feeds' formats show NZ time")
    // Whole-second ISO (startDate / endDate on most events).
    t.equal(formatTrafficDate("2026-06-15T00:00:00+12:00"), "15 Jun, 12:00 am", "whole-second ISO, NZST midnight")
    // Fractional ISO (every eventCreated / eventModified, half the startDates).
    t.equal(formatTrafficDate("2026-09-25T22:02:18.991+12:00"), "25 Sep, 10:02 pm", "fractional-second ISO")
    // UTC input still shows NZ wall-clock time.
    t.equal(formatTrafficDate("2026-06-15T00:00:00Z"), "15 Jun, 12:00 pm", "a UTC instant shows as NZ time")
    // NZ-local "dd/MM/yyyy HH:mm" (expectedResolution on about a third of events).
    t.equal(formatTrafficDate("25/09/2026 22:00"), "25 Sep, 10:00 pm", "dd/MM/yyyy HH:mm is NZ time")
    t.equal(parseTrafficDate("25/09/2026 22:00"), parseTrafficDate("2026-09-25T22:00:00+12:00"), "and parses to the NZ instant")
    // Free text is passed through untouched.
    t.equal(formatTrafficDate("Until further notice"), "Until further notice", "free text is unchanged")
    t.equal(formatTrafficDate("  "), nil, "blank → nil")
}

// NZ daylight time began at 2:00 am NZST on Sunday 27 September 2026.
private func testDaylightSaving(_ t: TestRunner) {
    t.group("dates: across the NZ daylight-saving change")
    t.equal(formatTrafficDate("2026-09-26T13:30:00Z"), "27 Sep, 1:30 am", "30 minutes before the change is NZST")
    t.equal(formatTrafficDate("2026-09-26T14:30:00Z"), "27 Sep, 3:30 am", "30 minutes after, clocks read NZDT")
    t.equal(
        parseTrafficDate("27/09/2026 20:00"),
        parseTrafficDate("2026-09-27T20:00:00+13:00"),
        "a dd/MM time after the change is read as NZDT"
    )
    t.equal(
        parseTrafficDate("26/09/2026 20:00"),
        parseTrafficDate("2026-09-26T20:00:00+12:00"),
        "and one before it as NZST"
    )
}

private func testRelativeDates(_ t: TestRunner) {
    t.group("dates: relative phrasing against a fixed now")
    guard let now = parseTrafficDate("2026-09-26T00:02:18.991+12:00") else {
        t.check(false, "reference date parses")
        return
    }
    t.equal(formatRelativeTrafficDate("2026-09-25T22:02:18.991+12:00", relativeTo: now), "2 hours ago", "fractional ISO, two hours earlier")
    t.equal(formatRelativeTrafficDate("25/09/2026 22:02", relativeTo: now), "2 hours ago", "dd/MM, two hours earlier")
    t.equal(formatRelativeTrafficDate("2026-09-27T01:02:18.991+13:00", relativeTo: now), "in 1 day", "24 hours on, across the change to NZDT")
    t.equal(formatRelativeTrafficDate("Until further notice", relativeTo: now), nil, "free text → nil (callers fall back)")
    t.equal(
        eventDatePhrase("2026-09-27T20:00:00+13:00", past: "Started", future: "Starts", relativeTo: now.addingTimeInterval(17.5 * 3600)),
        "Starts in 1 day · Sun 27 Sep, 8:00 pm",
        "the weekday and time are NZ's, not the Mac's"
    )
}
