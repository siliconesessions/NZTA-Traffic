import Foundation
import Network
import Observation
import SwiftUI

enum DataSection: String, CaseIterable, Identifiable {
    case cameras
    case events
    case vms
    case journeys
    case timSigns
    case congestion

    var id: String {
        rawValue
    }
}

@Observable
@MainActor
final class TrafficStore {
    private(set) var cameras: [TrafficCamera] = []
    private(set) var events: [RoadEvent] = []
    private(set) var vmsSigns: [VMSSign] = []
    private(set) var journeys: [TrafficJourney] = []
    // TIM roadside travel-time boards (/signs/tim/all). Refreshed each cycle
    // like the other live sections and surfaced as a map layer.
    private(set) var timSigns: [TIMSign] = []
    // Auckland motorway congestion segments (traffic-conditions/rest/2, XML).
    // Live data refreshed each cycle and rendered as a colour-coded map layer.
    private(set) var congestion: [CongestionSegment] = []
    // EV Roam public charging stations. Static reference data fetched once (like
    // the canonical regions) rather than on every refresh, so it has its own
    // loading/error state instead of being a per-refresh DataSection.
    private(set) var evChargers: [EVCharger] = []
    private(set) var isLoadingEVChargers = false
    private(set) var evChargersError: String?
    // The 14 canonical region names from /regions/all — fetched once and merged
    // into `allRegions` so the region Picker is stable and consistently cased
    // even before (or independently of) the feature data finishing loading.
    private(set) var canonicalRegions: [String] = []
    private(set) var allRegions: [String] = []
    private(set) var loadingSections: Set<DataSection> = []
    private(set) var errors: [DataSection: String] = [:]
    private(set) var lastUpdated: Date?
    private(set) var imageCacheToken: Int = Int(Date().timeIntervalSince1970)
    private(set) var isRefreshing = false

    // Reachability + offline-cache state. `isOnline` is driven by NWPathMonitor;
    // `isServingCachedData` / `cacheTimestamp` reflect whether the data currently
    // in memory came from the on-disk offline cache (a failed or offline fetch
    // fell back to it) and how old that snapshot is. These drive the offline
    // banner. See the offline-cache exception documented in CLAUDE.md.
    private(set) var isOnline = true
    private(set) var isServingCachedData = false
    private(set) var cacheTimestamp: Date?

    @ObservationIgnored private let service: TrafficAPIService
    @ObservationIgnored private let cache = OfflineCache()
    // Sections currently served from the on-disk cache because their live fetch
    // failed (or has not completed yet). Drives `isServingCachedData`.
    @ObservationIgnored private var servedSections: Set<DataSection> = []
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private let monitorQueue = DispatchQueue(label: "nzta.reachability.monitor")

    // Memoized filter+sort results, keyed on the active filter inputs and
    // cleared whenever the underlying data changes. Marked @ObservationIgnored
    // so populating the cache during a view's `body` does not itself trigger a
    // re-render (which would loop).
    private struct FilterKey: Hashable {
        let region: String
        let highway: String
        let search: String
    }
    @ObservationIgnored private var cameraCache: [FilterKey: [TrafficCamera]] = [:]
    @ObservationIgnored private var eventCache: [FilterKey: [RoadEvent]] = [:]
    @ObservationIgnored private var vmsCache: [FilterKey: [VMSSign]] = [:]
    @ObservationIgnored private var journeyCache: [FilterKey: [TrafficJourney]] = [:]
    @ObservationIgnored private var timCache: [FilterKey: [TIMSign]] = [:]

    init(service: TrafficAPIService = TrafficAPIService()) {
        self.service = service
        startNetworkMonitoring()
    }

    deinit {
        pathMonitor.cancel()
    }

    func isLoading(_ section: DataSection) -> Bool {
        loadingSections.contains(section)
    }

    /// Show the offline / cached-data banner when the network is unreachable or
    /// any section is currently being served from the on-disk cache.
    var shouldShowOfflineBanner: Bool {
        !isOnline || isServingCachedData
    }

    // NWPathMonitor reports reachability changes on a background queue; hop back
    // to the main actor to update the observed `isOnline` flag.
    private func startNetworkMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                self?.isOnline = online
            }
        }
        pathMonitor.start(queue: monitorQueue)
    }

    var loadProgress: Double {
        let total = Double(DataSection.allCases.count)
        guard total > 0 else {
            return 1
        }
        let remaining = Double(loadingSections.count)
        return max(0, min(1, (total - remaining) / total))
    }

    /// Count of high-priority events (road closures) — surfaced as a Dock badge.
    var criticalAlertCount: Int {
        events.filter(\.isClosure).count
    }

    /// Loads all sections concurrently.
    /// - Parameter bustImageCache: when `true` (an explicit user refresh) the
    ///   image cache token is bumped so camera image URLs change and bypass the
    ///   URL cache. Background/auto refreshes leave the token stable and rely on
    ///   the shared `URLCache` + HTTP revalidation instead of re-downloading
    ///   every image each tick.
    func loadAllData(bustImageCache: Bool = false) async {
        loadingSections = Set(DataSection.allCases)
        errors = [:]
        isRefreshing = true

        async let camerasTask: () = loadCameras()
        async let eventsTask: () = loadEvents()
        async let signsTask: () = loadVMS()
        async let journeysTask: () = loadJourneys()
        async let timTask: () = loadTIMSigns()
        async let congestionTask: () = loadCongestion()
        async let regionsTask: () = loadRegions()
        async let evChargersTask: () = loadEVChargers()
        _ = await (camerasTask, eventsTask, signsTask, journeysTask, timTask, congestionTask, regionsTask, evChargersTask)

        allRegions = computeAllRegions()
        lastUpdated = Date()
        if bustImageCache {
            imageCacheToken = Int(Date().timeIntervalSince1970)
        }
        await refreshCacheBannerState()
        isRefreshing = false
    }

    /// Reloads a single section, used by the per-section "Retry" button on an
    /// error banner. Mirrors the per-section work `loadAllData` does but scoped
    /// to one section, so an isolated failure can be retried without re-fetching
    /// everything. The matching `loadX` clears the section's loading flag and
    /// (on failure) repopulates `errors`.
    func reload(_ section: DataSection) async {
        loadingSections.insert(section)
        errors[section] = nil
        switch section {
        case .cameras:
            await loadCameras()
        case .events:
            await loadEvents()
        case .vms:
            await loadVMS()
        case .journeys:
            await loadJourneys()
        case .timSigns:
            await loadTIMSigns()
        case .congestion:
            await loadCongestion()
        }
        allRegions = computeAllRegions()
        await refreshCacheBannerState()
    }

    /// Force a re-fetch of the otherwise fetch-once EV charger layer, used by the
    /// map's per-layer Retry after a failed initial load. Clearing the array lets
    /// `loadEVChargers`' "already loaded" guard fall through and re-fetch.
    func reloadEVChargers() async {
        evChargers = []
        evChargersError = nil
        await loadEVChargers()
    }

    /// Snapshot of current section counts, recent per-section errors, app version
    /// and preferences for Help → Export Diagnostics. Assembled on the main actor
    /// (it reads observed state); the command writes the rendered text to disk.
    func diagnosticsReport() -> DiagnosticsReport {
        let sections: [DiagnosticsReport.SectionStat] = [
            .init(name: "Cameras", count: cameras.count, error: errors[.cameras]),
            .init(name: "Cameras Online", count: cameras.filter(\.isOnline).count, error: nil),
            .init(name: "Road Events", count: events.count, error: errors[.events]),
            .init(name: "Active Closures", count: criticalAlertCount, error: nil),
            .init(name: "VMS Signs", count: vmsSigns.count, error: errors[.vms]),
            .init(name: "Travel Times", count: journeys.count, error: errors[.journeys]),
            .init(name: "TIM Signs", count: timSigns.count, error: errors[.timSigns]),
            .init(name: "Congestion Segments", count: congestion.count, error: errors[.congestion]),
            .init(name: "EV Chargers", count: evChargers.count, error: evChargersError)
        ]
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return DiagnosticsReport(
            appVersion: version,
            appBuild: build,
            generatedAt: Date(),
            lastUpdated: lastUpdated,
            isOnline: isOnline,
            sections: sections,
            preferences: DiagnosticsReport.collectPreferences()
        )
    }

    /// Populates empty sections from the on-disk cache so the UI has content to
    /// show immediately on launch, ahead of (or in place of) the first live
    /// fetch. Decoding runs off the main actor. Only fills sections that are
    /// still empty, so it never clobbers fresher live data already in memory.
    func primeFromCache() async {
        var served: Set<DataSection> = []
        if await primeSection(.cameras, keyPath: \.cameras, decode: { await self.service.decodeCachedCameras($0) }) {
            served.insert(.cameras)
        }
        if await primeSection(.events, keyPath: \.events, decode: { await self.service.decodeCachedRoadEvents($0) }) {
            served.insert(.events)
        }
        if await primeSection(.vms, keyPath: \.vmsSigns, decode: { await self.service.decodeCachedVMSSigns($0) }) {
            served.insert(.vms)
        }
        if await primeSection(.journeys, keyPath: \.journeys, decode: { await self.service.decodeCachedJourneys($0) }) {
            served.insert(.journeys)
        }
        guard !served.isEmpty else {
            return
        }
        servedSections.formUnion(served)
        invalidateFilterCaches()
        allRegions = computeAllRegions()
        isServingCachedData = true
        cacheTimestamp = await cache.newestModificationDate(among: servedSections)
    }

    private func primeSection<T>(
        _ section: DataSection,
        keyPath: ReferenceWritableKeyPath<TrafficStore, [T]>,
        decode: (Data) async -> [T]?
    ) async -> Bool {
        guard self[keyPath: keyPath].isEmpty,
              let data = await cache.read(section: section),
              let value = await decode(data) else {
            return false
        }
        self[keyPath: keyPath] = value
        return true
    }

    private func loadCameras() async {
        await loadCached(
            section: .cameras,
            keyPath: \.cameras,
            fetch: { await self.service.fetchCamerasResult() },
            decodeCache: { await self.service.decodeCachedCameras($0) }
        )
    }

    private func loadEvents() async {
        await loadCached(
            section: .events,
            keyPath: \.events,
            fetch: { await self.service.fetchRoadEventsResult() },
            decodeCache: { await self.service.decodeCachedRoadEvents($0) }
        )
    }

    private func loadVMS() async {
        await loadCached(
            section: .vms,
            keyPath: \.vmsSigns,
            fetch: { await self.service.fetchVMSSignsResult() },
            decodeCache: { await self.service.decodeCachedVMSSigns($0) }
        )
    }

    private func loadJourneys() async {
        await loadCached(
            section: .journeys,
            keyPath: \.journeys,
            fetch: { await self.service.fetchJourneysResult() },
            decodeCache: { await self.service.decodeCachedJourneys($0) }
        )
    }

    // Shared load path for the four offline-cacheable sections. On success it
    // updates the in-memory slice and persists the raw bytes; on failure it
    // surfaces the error and falls back to the cached copy (if any), marking the
    // section cache-served so the offline banner appears. Disk IO runs on the
    // OfflineCache actor (off the main actor).
    private func loadCached<T>(
        section: DataSection,
        keyPath: ReferenceWritableKeyPath<TrafficStore, [T]>,
        fetch: () async -> Result<(value: [T], data: Data), Error>,
        decodeCache: (Data) async -> [T]?
    ) async {
        switch await fetch() {
        case .success(let fetched):
            self[keyPath: keyPath] = fetched.value
            invalidateFilterCaches()
            servedSections.remove(section)
            await cache.write(fetched.data, section: section)
        case .failure(let error):
            errors[section] = errorMessage(error)
            if let data = await cache.read(section: section),
               let restored = await decodeCache(data) {
                self[keyPath: keyPath] = restored
                invalidateFilterCaches()
                servedSections.insert(section)
            }
        }
        loadingSections.remove(section)
    }

    // Recompute the offline-banner state from which sections (if any) are still
    // being served from cache after a load attempt.
    private func refreshCacheBannerState() async {
        isServingCachedData = !servedSections.isEmpty
        cacheTimestamp = isServingCachedData
            ? await cache.newestModificationDate(among: servedSections)
            : nil
    }

    private func loadTIMSigns() async {
        let result = await service.fetchTIMSignsResult()
        apply(result, to: .timSigns, keyPath: \.timSigns)
        loadingSections.remove(.timSigns)
    }

    private func loadCongestion() async {
        let result = await service.fetchCongestionResult()
        apply(result, to: .congestion, keyPath: \.congestion)
        loadingSections.remove(.congestion)
    }

    // EV charger locations are static, so fetch them only once (and retry on a
    // later refresh only if the first attempt failed and left the list empty).
    // A failure surfaces via `evChargersError` on the map's EV layer rather than
    // wiping any previously loaded markers.
    private func loadEVChargers() async {
        guard evChargers.isEmpty else {
            return
        }
        isLoadingEVChargers = true
        defer { isLoadingEVChargers = false }
        switch await service.fetchEVChargersResult() {
        case .success(let chargers):
            evChargers = chargers
            evChargersError = nil
        case .failure(let error):
            evChargersError = errorMessage(error)
        }
    }

    // The canonical region list is static reference data, so fetch it only once
    // (the first time it is needed). It is intentionally not a `DataSection`: a
    // failure leaves the picker to fall back to data-derived names rather than
    // surfacing an error banner. Updating `allRegions` here lets the picker
    // populate as soon as regions arrive, ahead of the heavier feature loads.
    private func loadRegions() async {
        guard canonicalRegions.isEmpty else {
            return
        }
        guard case .success(let regions) = await service.fetchRegionsResult() else {
            return
        }
        let names = regions.compactMap { cleanText($0.name) }.filter { !$0.isEmpty }
        guard !names.isEmpty else {
            return
        }
        canonicalRegions = names
        allRegions = computeAllRegions()
    }

    func filteredCameras(region: String, highway: String, search: String) -> [TrafficCamera] {
        let key = FilterKey(region: region, highway: highway, search: search)
        if let cached = cameraCache[key] {
            return cached
        }
        let result = cameras
            .filter { $0.matches(region: region, highway: highway, search: search) }
            .sorted { lhs, rhs in
                if let lhsSort = lhs.sortOrder, let rhsSort = rhs.sortOrder, lhsSort != rhsSort {
                    return lhsSort < rhsSort
                }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
        cameraCache[key] = result
        return result
    }

    func filteredEvents(region: String, highway: String, search: String) -> [RoadEvent] {
        let key = FilterKey(region: region, highway: highway, search: search)
        if let cached = eventCache[key] {
            return cached
        }
        let result = events
            .filter { $0.matches(region: region, highway: highway, search: search) }
            .sorted { lhs, rhs in
                if lhs.severityRank != rhs.severityRank {
                    return lhs.severityRank < rhs.severityRank
                }
                return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
            }
        eventCache[key] = result
        return result
    }

    func filteredVMSSigns(region: String, highway: String, search: String) -> [VMSSign] {
        let key = FilterKey(region: region, highway: highway, search: search)
        if let cached = vmsCache[key] {
            return cached
        }
        let result = vmsSigns
            .filter { $0.matches(region: region, highway: highway, search: search) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        vmsCache[key] = result
        return result
    }

    func filteredJourneys(region: String, highway: String, search: String) -> [TrafficJourney] {
        let key = FilterKey(region: region, highway: highway, search: search)
        if let cached = journeyCache[key] {
            return cached
        }
        let result = journeys
            .filter { $0.matches(region: region, highway: highway, search: search) }
            .sorted { lhs, rhs in
                let lhsDelay = lhs.congestionDelay ?? -1
                let rhsDelay = rhs.congestionDelay ?? -1
                if lhsDelay != rhsDelay {
                    return lhsDelay > rhsDelay
                }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
        journeyCache[key] = result
        return result
    }

    func filteredTIMSigns(region: String, highway: String, search: String) -> [TIMSign] {
        let key = FilterKey(region: region, highway: highway, search: search)
        if let cached = timCache[key] {
            return cached
        }
        let result = timSigns
            .filter { $0.matches(region: region, highway: highway, search: search) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        timCache[key] = result
        return result
    }

    // Fully-scoped slices: region/highway/search filtering (memoized above)
    // plus the per-section visibility flags the UI toggles. Keeping the whole
    // filter pipeline here matches "filtering lives in the store".
    func scopedCameras(region: String, highway: String, search: String, statuses: Set<CameraStatusKind>) -> [TrafficCamera] {
        filteredCameras(region: region, highway: highway, search: search)
            .filter { statuses.contains($0.statusKind) }
    }

    func scopedEvents(
        region: String,
        highway: String,
        search: String,
        impacts: Set<EventImpactKind>,
        showPlanned: Bool,
        showUnplanned: Bool,
        island: EventIslandFilter
    ) -> [RoadEvent] {
        filteredEvents(region: region, highway: highway, search: search)
            .filter { impacts.contains($0.impactKind) }
            .filter { $0.isPlanned ? showPlanned : showUnplanned }
            .filter { island.matches($0.eventIsland) }
    }

    func scopedVMSSigns(region: String, highway: String, search: String, hideEmpty: Bool) -> [VMSSign] {
        let base = filteredVMSSigns(region: region, highway: highway, search: search)
        return hideEmpty ? base.filter(\.hasDisplayMessage) : base
    }

    func scopedJourneys(region: String, highway: String, search: String, flows: Set<FlowKind>) -> [TrafficJourney] {
        filteredJourneys(region: region, highway: highway, search: search)
            .filter { flows.contains($0.overallFlowKind) }
    }

    private func apply<T>(
        _ result: Result<[T], Error>,
        to section: DataSection,
        keyPath: ReferenceWritableKeyPath<TrafficStore, [T]>
    ) {
        switch result {
        case .success(let value):
            self[keyPath: keyPath] = value
            invalidateFilterCaches()
        case .failure(let error):
            // Keep the previously loaded data on a transient failure instead of
            // wiping it — the error banner surfaces the problem while the user
            // keeps the last-known-good data for this section.
            errors[section] = errorMessage(error)
        }
    }

    private func invalidateFilterCaches() {
        cameraCache.removeAll(keepingCapacity: true)
        eventCache.removeAll(keepingCapacity: true)
        vmsCache.removeAll(keepingCapacity: true)
        journeyCache.removeAll(keepingCapacity: true)
        timCache.removeAll(keepingCapacity: true)
    }

    private func computeAllRegions() -> [String] {
        // Gather every feature's region name in a single pass into one
        // pre-sized buffer rather than building (and then concatenating) five
        // separate compactMap arrays.
        var derived: [String] = []
        derived.reserveCapacity(
            cameras.count + events.count + vmsSigns.count + journeys.count + timSigns.count
        )
        for camera in cameras {
            if let region = camera.regionName { derived.append(region) }
        }
        for event in events {
            if let region = event.regionName { derived.append(region) }
        }
        for sign in vmsSigns {
            if let region = sign.regionName { derived.append(region) }
        }
        for journey in journeys {
            if let region = journey.regionName { derived.append(region) }
        }
        for sign in timSigns {
            if let region = sign.regionName { derived.append(region) }
        }
        return mergedRegionNames(canonical: canonicalRegions, derived: derived)
    }

    private func errorMessage(_ error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let message = localizedError.errorDescription {
            return message
        }
        return error.localizedDescription
    }
}

// Persists raw section JSON to Application Support so the app can show the last
// known data while offline or when a fetch fails. This is the one place the app
// keeps API data on disk (see the offline-cache exception in CLAUDE.md). All IO
// is actor-isolated to keep it off the main actor, and every operation is
// best-effort: failures silently no-op rather than disrupting live data.
actor OfflineCache {
    private let directory: URL

    init() {
        let fileManager = FileManager.default
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        directory = base
            .appendingPathComponent("NZTATraffic", isDirectory: true)
            .appendingPathComponent("OfflineCache", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func write(_ data: Data, section: DataSection) {
        try? data.write(to: fileURL(for: section), options: .atomic)
    }

    func read(section: DataSection) -> Data? {
        try? Data(contentsOf: fileURL(for: section))
    }

    // Most recent on-disk modification time among the given cached sections —
    // i.e. how old the snapshot currently being shown is.
    func newestModificationDate(among sections: Set<DataSection>) -> Date? {
        var newest: Date?
        for section in sections {
            guard
                let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL(for: section).path),
                let modified = attributes[.modificationDate] as? Date
            else {
                continue
            }
            if newest == nil || modified > newest! {
                newest = modified
            }
        }
        return newest
    }

    private func fileURL(for section: DataSection) -> URL {
        directory.appendingPathComponent("\(section.rawValue).json", isDirectory: false)
    }
}
