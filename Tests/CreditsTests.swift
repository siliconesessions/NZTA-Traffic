import Foundation

// The data-source list, credits and notices shown in About, Help and the
// About panel (TrafficAPIService.dataSources, AppCredits), and the NZ display
// names for NZTA's region tags.
func runCreditsTests(_ t: TestRunner) {
    testDataSources(t)
    testCredits(t)
    testRegionDisplayNames(t)
    testRegionSearchFolding(t)
}

private func testDataSources(_ t: TestRunner) {
    t.group("credits: data sources")

    let urls = TrafficAPIService.dataSources.map(\.url)
    let paths = [
        TrafficAPIService.Path.cameras,
        TrafficAPIService.Path.events,
        TrafficAPIService.Path.vms,
        TrafficAPIService.Path.journeys,
        TrafficAPIService.Path.tim,
        TrafficAPIService.Path.regions
    ]
    for path in paths {
        t.check(urls.contains(TrafficAPIService.baseURL + path), "lists the rest/5 feed \(path)")
    }
    t.check(urls.contains(TrafficAPIService.congestionURL), "lists the congestion XML feed")
    t.check(urls.contains(TrafficAPIService.evChargersURL), "lists the EV Roam feed")
    t.equal(urls.count, 8, "one entry per fetch")
    t.equal(Set(urls).count, urls.count, "no duplicates")

    t.equal(TrafficAPIService.dataHosts, ["trafficnz.info", "services.arcgis.com"], "both hosts, in list order")

    let ev = TrafficAPIService.dataSources.first { $0.url == TrafficAPIService.evChargersURL }
    t.equal(ev?.host, "services.arcgis.com", "EV host")
    t.equal(ev?.format, "GeoJSON", "EV format")
    t.check(ev?.displayURL.contains("?") == false, "display URL drops the query string")
    t.check(ev?.displayURL.hasPrefix("services.arcgis.com/") == true, "display URL drops the scheme")

    let cameras = TrafficAPIService.dataSources.first { $0.url.hasSuffix(TrafficAPIService.Path.cameras) }
    t.equal(cameras?.displayURL, "trafficnz.info/service/traffic/rest/5/cameras/all", "rest/5 camera display URL")
    let congestion = TrafficAPIService.dataSources.first { $0.url == TrafficAPIService.congestionURL }
    t.equal(congestion?.format, "XML", "congestion format")
}

private func testCredits(_ t: TestRunner) {
    t.group("credits: attribution and notices")

    t.check(AppCredits.attribution.contains("NZ Transport Agency Waka Kotahi (NZTA)"), "credits the agency by its current name")
    t.check(AppCredits.attribution.contains("CC BY 4.0"), "names the licence")
    t.check(AppCredits.evAttribution.contains("EV Roam") && AppCredits.evAttribution.contains("CC BY 4.0"), "EV Roam credit and licence")
    t.check(AppCredits.evAttribution.contains("reformatted"), "EV credit notes the modification (CC BY 4.0 s3(a)(1)(B))")
    t.check(AppCredits.notAffiliated.contains("not affiliated with or endorsed by NZTA"), "independence notice")
    // NZTA terms of use, clause 3(c).
    t.check(AppCredits.notableEventsNotice.contains("notable"), "notable-events notice says notable")
    t.check(AppCredits.notableEventsNotice.contains("verified"), "notable-events notice says verified")

    t.equal(
        AppCredits.offlineCachePath,
        "~/Library/Application Support/\(AppIdentity.supportFolderName)/OfflineCache",
        "cache path matches OfflineCache.defaultDirectory's folders"
    )
    t.check(AppCredits.offlineCacheNote.contains(AppCredits.offlineCachePath), "privacy note names the cache path")

    let steps = AppCredits.gatekeeperSteps.joined(separator: " ")
    t.check(steps.contains("Privacy & Security") && steps.contains("Open Anyway"), "Gatekeeper steps use the macOS 15+ flow")
    t.check(!steps.contains("Control-click"), "no removed Control-click override")
    t.check(AppCredits.quarantineCommand.contains("/Applications/\(AppIdentity.productName).app"), "xattr command names the installed app")
    t.check(AppCredits.releasesURL.hasPrefix(AppIdentity.projectURL), "releases live on the project")
}

private func testRegionDisplayNames(_ t: TestRunner) {
    t.group("region display names")

    t.equal(regionDisplayName("Manawatu-Whanganui"), "Manawatū-Whanganui", "macron")
    t.equal(regionDisplayName("Hawkes Bay"), "Hawke\u{2019}s Bay", "apostrophe")
    t.equal(regionDisplayName("Bay Of Plenty"), "Bay of Plenty", "lower-case of")
    t.equal(regionDisplayName(" bay of plenty "), "Bay of Plenty", "case and whitespace")
    t.equal(regionDisplayName("Northland"), "Northland", "others unchanged")
    t.equal(regionDisplayName("Nelson/Marlborough"), "Nelson/Marlborough", "others unchanged (slash)")

    // Every tag /regions/all sends has a display form; the raw tags still
    // filter (display names are never used as the filter key).
    if let regions = try? JSONDecoder().decode(RegionsPayload.self, from: Fixture.data("regions.json") ?? Data()).response.region {
        let shown = regions.compactMap(\.name).map(regionDisplayName)
        t.check(shown.contains("Manawatū-Whanganui"), "fixture Manawatū-Whanganui")
        t.check(shown.contains("Hawke\u{2019}s Bay"), "fixture Hawke’s Bay")
        t.check(shown.contains("Bay of Plenty"), "fixture Bay of Plenty")
        t.check(!shown.contains { $0.contains("Of Plenty") || $0 == "Hawkes Bay" }, "no raw spellings left")
        t.check(matchesRegion("Hawkes Bay", selectedRegion: "Hawkes Bay"), "raw tag still filters")
    } else {
        t.check(false, "regions fixture decodes")
    }
}

private func testRegionSearchFolding(_ t: TestRunner) {
    t.group("search folds apostrophes")

    t.equal(foldedForSearch("Hawke\u{2019}s Bay"), "hawkes bay", "curly apostrophe dropped")
    t.equal(foldedForSearch("Hawke's Bay"), "hawkes bay", "straight apostrophe dropped")
    let haystack = searchableHaystack(["Hawkes Bay", "SH2 Napier"])
    t.check(matchesNeedle("hawke's bay", in: haystack), "the label's spelling finds the feed's")
    t.check(matchesNeedle("Hawke\u{2019}s", in: haystack), "curly query finds it too")
    t.check(matchesNeedle("hawkes", in: haystack), "plain query still matches")
    t.check(matchesNeedle("manawatū", in: searchableHaystack(["Manawatu-Whanganui"])), "macron query finds plain feed text")
}
