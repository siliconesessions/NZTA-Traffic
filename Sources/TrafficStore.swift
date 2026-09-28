import Foundation
import Network
import Observation

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
    // EV Roam public charging stations. Reference data that changes about
    // daily (connector status), so it is fetched on the first refresh and
    // again once it is over an hour old (AutoRefreshPolicy.evChargerMaxAge)
    // rather than every refresh. Not a per-refresh DataSection: it has its own
    // loading/error state.
    private(set) var evChargers: [EVCharger] = []
    private(set) var isLoadingEVChargers = false
    private(set) var evChargersError: String?
    // The 14 canonical region names from /regions/all — fetched once and merged
    // into `allRegions` so the region Picker is stable and consistently cased
    // even before (or independently of) the feature data finishing loading.
    private(set) var canonicalRegions: [String] = []
    // The canonical regions' outlines, from the same fetch. EV chargers carry
    // no region, so the EV layer's region filter places them by location.
    private(set) var regionOutlines: [RegionOutline] = []
    private(set) var allRegions: [String] = []
    private(set) var loadingSections: Set<DataSection> = []
    // The latest problem per section. Kept until that section's next result,
    // so a refresh in progress doesn't hide it.
    private(set) var errors: [DataSection: String] = [:]
    // When any section last fetched live data. Never stamped by a refresh in
    // which everything failed, so "Updated …" and the stale warning stay true
    // during an outage.
    private(set) var lastUpdated: Date?
    // Changes only on an explicit refresh (⌘R, the menu bar, Clear Offline
    // Cache) and is appended to camera image URLs as `?t=`, so those loads
    // bypass the URL cache. It starts at 0, so the same URLs — and the images
    // cached for them — carry over between launches.
    private(set) var imageCacheToken = 0
    // Bumped when the cameras section refreshes (no more than every 30 s).
    // Camera images then re-request their unchanged URL with a revalidating
    // load (ETag/304), keeping the old frame up until the new one arrives —
    // see CameraImage. This is what keeps on-screen images live on auto-refresh.
    private(set) var cameraImageGeneration = 0
    // A refresh's shared sections are loading (journeys finishes on its own —
    // see `DataSection.refreshedTogether`), or the launch is priming from disk.
    private(set) var isRefreshing = false

    // Reachability (NWPathMonitor) and where the data on screen came from.
    // These drive the freshness banner, the Dock badge caveat and the menu bar
    // hints (see `freshnessBanner`). See the offline-cache exception in CLAUDE.md.
    private(set) var isOnline = true
    // Sections showing data replayed from the offline cache (primed at launch
    // or restored after a failed fetch) that no live fetch has replaced yet.
    private(set) var savedSections: Set<DataSection> = []
    // Sections whose latest live fetch failed (network, HTTP, decode, offline).
    private(set) var failedSections: Set<DataSection> = []
    // When each saved section's cache file was written (or last confirmed).
    private(set) var savedDates: [DataSection: Date] = [:]
    // When each section last fetched live data.
    private(set) var lastLiveSuccess: [DataSection: Date] = [:]

    // The highways, cameras and journeys the user watches. The App loads it
    // from and saves it to UserDefaults (`Watchlist.defaultsKey`); the cards'
    // watch buttons and Settings edit it here.
    private(set) var watchlist = Watchlist()
    // Called on the main actor with the active closures on watched roads that
    // are new since the previous successful live events fetch (see
    // WatchedClosureTracker); the App posts the notifications.
    @ObservationIgnored var onNewWatchedClosures: (@MainActor (_ closures: [RoadEvent], _ watchlist: Watchlist) -> Void)?
    @ObservationIgnored private var closureTracker = WatchedClosureTracker()

    @ObservationIgnored private let service: TrafficAPIService
    @ObservationIgnored private let cache: OfflineCache
    // The URL cache camera images load through (Clear Offline Cache empties it).
    @ObservationIgnored private let imageCache: URLCache?
    // Unreadable entries the lenient decode skipped in each section's latest
    // fetch — only reported by Export Diagnostics, so not observed.
    @ObservationIgnored private var droppedCounts: [DataSection: Int] = [:]
    @ObservationIgnored private var droppedEVChargerCount = 0
    @ObservationIgnored private let pathMonitor: NWPathMonitor?
    @ObservationIgnored private let monitorQueue = DispatchQueue(label: "nzta.reachability.monitor")
    @ObservationIgnored private let reconnectDelay: Duration
    // "Now" for every time-dependent decision (ages, ended events, EV
    // re-fetch, auto-refresh ticks); a fixed or stepped clock in tests.
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?

    // Single-flight loading: one in-flight load per section, and one refresh
    // at a time. Overlapping callers (a manual refresh during an auto tick, a
    // Retry, a reconnect, the window reappearing) join the running work
    // instead of starting a second fetch that would race it.
    private enum RefreshJob: Hashable {
        case sharedSections
    }

    private enum SectionLoadOutcome {
        case updated
        case emptyFeed
        case failed
        case cancelled
    }

    @ObservationIgnored private let sectionLoads = SingleFlight<DataSection, SectionLoadOutcome>()
    @ObservationIgnored private let refreshFlight = SingleFlight<RefreshJob, Void>()
    // Digest of the bytes behind each section's data on screen. A refresh
    // whose bytes match skips reassigning the array, the filter-cache reset and
    // the re-render (feeds often come back byte-identical between ticks).
    @ObservationIgnored private var appliedDigests: [DataSection: ContentDigest] = [:]
    // An explicit refresh asked for fresh camera images; applied when the
    // cameras section lands (or when the refresh ends, if it failed).
    @ObservationIgnored private var pendingImageBust = false
    @ObservationIgnored private var lastCameraImageReload: Date?
    // Start of the latest refresh of any kind — the auto-refresh cadence and
    // `refreshIfStale` count from it.
    @ObservationIgnored private(set) var lastRefreshAttempt: Date?
    @ObservationIgnored private var launchTask: Task<Void, Never>?
    // When the EV layer last loaded; it is re-fetched once this is over an hour old.
    @ObservationIgnored private var evChargersLoadedAt: Date?
    @ObservationIgnored private var primeTask: Task<Void, Never>?
    @ObservationIgnored private var isLoadingRegions = false

    // Auto-refresh, owned here rather than by a window so it keeps running
    // (and the Dock badge / menu bar keep updating) with the window closed.
    // The App feeds in the `nzta.*` settings and the app's activity.
    @ObservationIgnored private var autoRefresh = AutoRefreshSettings(
        isEnabled: false,
        storedInterval: AutoRefreshPolicy.defaultInterval
    )
    @ObservationIgnored private var isAppActive = true
    @ObservationIgnored private var hasVisibleWindow = true
    @ObservationIgnored private var autoRefreshTask: Task<Void, Never>?

    // Memoized filter+sort results, keyed on the active filter inputs and
    // cleared when that section's data changes. Marked @ObservationIgnored
    // so populating the cache during a view's `body` does not itself trigger a
    // re-render (which would loop).
    private struct FilterKey: Hashable {
        let region: String
        let highway: String
        let search: String
        // Only the events slice varies on "Show resolved"; the other
        // sections leave it false.
        var showResolved = false
    }
    @ObservationIgnored private var cameraCache: [FilterKey: [TrafficCamera]] = [:]
    @ObservationIgnored private var eventCache: [FilterKey: [RoadEvent]] = [:]
    @ObservationIgnored private var vmsCache: [FilterKey: [VMSSign]] = [:]
    @ObservationIgnored private var journeyCache: [FilterKey: [TrafficJourney]] = [:]
    @ObservationIgnored private var timCache: [FilterKey: [TIMSign]] = [:]
    @ObservationIgnored private var congestionCache: [FilterKey: [CongestionSegment]] = [:]
    @ObservationIgnored private var congestionMatchCounts: [FilterKey: Int] = [:]
    @ObservationIgnored private var evChargerCache: [FilterKey: [EVCharger]] = [:]
    // The Flow map's per-leg selection also depends on the flow chips.
    private struct FlowSegmentKey: Hashable {
        let filter: FilterKey
        let flows: Set<FlowKind>
    }
    @ObservationIgnored private var flowSegmentCache: [FlowSegmentKey: [FlowMapSegment]] = [:]
    // Each EV charger's region (by id), worked out once per charger list and
    // set of region outlines; nil until needed.
    @ObservationIgnored private var evChargerRegions: [String: String]?

    // Every dependency is injectable so SwiftUI previews and the tests run
    // against a stubbed URLSession, a disabled or temporary cache, no image
    // cache and no reachability monitor, instead of the live API and the
    // user's real Application Support folder; `clock` pins "now".
    init(
        service: TrafficAPIService = TrafficAPIService(),
        cache: OfflineCache = OfflineCache(),
        imageCache: URLCache? = .shared,
        monitorsNetwork: Bool = true,
        reconnectDelay: Duration = .seconds(2),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.service = service
        self.clock = clock
        self.cache = cache
        self.imageCache = imageCache
        self.reconnectDelay = reconnectDelay
        pathMonitor = monitorsNetwork ? NWPathMonitor() : nil
        // Images loaded at launch are already fresh; the first reload is due
        // on a later cameras refresh.
        lastCameraImageReload = clock()
        startNetworkMonitoring()
    }

    deinit {
        pathMonitor?.cancel()
    }

    func isLoading(_ section: DataSection) -> Bool {
        loadingSections.contains(section)
    }

    /// The banner above each tab's content: offline, couldn't reach NZTA, or saved
    /// data on screen while the live load runs. nil when everything shown is
    /// live.
    var freshnessBanner: FreshnessBanner? {
        FreshnessBanner.make(isOnline: isOnline, sections: DataSection.cacheable.map(freshness(of:)))
    }

    func freshness(of section: DataSection) -> SectionFreshness {
        let isSaved = savedSections.contains(section)
        return SectionFreshness(
            hasData: hasData(section),
            isSaved: isSaved,
            lastFetchFailed: failedSections.contains(section),
            isLoading: loadingSections.contains(section),
            dataDate: isSaved ? savedDates[section] : lastLiveSuccess[section]
        )
    }

    /// The error a section's tab shows. Offline, a section that still has
    /// data shows none: the offline banner already says so, and Retry can't
    /// work until the connection is back.
    func displayedError(for section: DataSection) -> String? {
        if !isOnline, hasData(section) {
            return nil
        }
        return errors[section]
    }

    private func hasData(_ section: DataSection) -> Bool {
        switch section {
        case .cameras:
            return !cameras.isEmpty
        case .events:
            return !events.isEmpty
        case .vms:
            return !vmsSigns.isEmpty
        case .journeys:
            return !journeys.isEmpty
        case .timSigns:
            return !timSigns.isEmpty
        case .congestion:
            return !congestion.isEmpty
        }
    }

    // NWPathMonitor reports reachability changes on a background queue; hop back
    // to the main actor to update the observed `isOnline` flag.
    private func startNetworkMonitoring() {
        guard let pathMonitor else {
            return
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            // `.requiresConnection` (e.g. VPN on demand) still lets a request
            // through, so only a definite "no route" counts as offline.
            let online = path.status != .unsatisfied
            Task { @MainActor in
                self?.networkStatusChanged(isOnline: online)
            }
        }
        pathMonitor.start(queue: monitorQueue)
    }

    /// Reachability changes (from NWPathMonitor; internal so tests can
    /// simulate them). Coming back online after a failure — or with saved data
    /// on screen — triggers one debounced reload.
    func networkStatusChanged(isOnline online: Bool) {
        let wasOnline = isOnline
        guard online != wasOnline else {
            return
        }
        isOnline = online
        reconnectTask?.cancel()
        reconnectTask = nil
        let hasUnconfirmedData = !failedSections.isEmpty || !savedSections.isEmpty
        guard AutoRefreshPolicy.shouldReloadOnReconnect(
            wasOnline: wasOnline,
            isOnline: online,
            hasUnconfirmedData: hasUnconfirmedData
        ) else {
            return
        }
        let delay = reconnectDelay
        reconnectTask = Task {
            // Let the new path settle (DNS, captive portals) before reloading.
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard self.isOnline else {
                return
            }
            await self.loadAllData()
        }
    }

    // Progress of the shared part of a refresh (the toolbar status's progress).
    var loadProgress: Double {
        let sections = DataSection.refreshedTogether
        let remaining = sections.filter(loadingSections.contains).count
        return Double(sections.count - remaining) / Double(sections.count)
    }

    /// Road closures in force now (status Active, or no recognised status) —
    /// the Dock badge and the menu bar "Active closures" line. Upcoming
    /// (Scheduled) and Resolved closures are not counted.
    var criticalAlertCount: Int {
        events.filter(\.isActiveClosure).count
    }

    /// The events on screen weren't confirmed by the latest fetch: they were
    /// replayed from the offline cache, or the events fetch failed.
    var eventsAreProvisional: Bool {
        savedSections.contains(.events) || failedSections.contains(.events)
    }

    /// The Dock badge text (nil clears it); "3?" when the count comes from
    /// saved data.
    var dockBadgeLabel: String? {
        DockBadge.label(activeClosures: criticalAlertCount, isProvisional: eventsAreProvisional)
    }

    /// Active closures on watched highways or journeys (the menu bar's
    /// "On roads you watch" line).
    var watchedActiveClosureCount: Int {
        guard !watchlist.isEmpty else {
            return 0
        }
        return events.filter { $0.isActiveClosure && watchlist.watches($0) }.count
    }

    // MARK: - Watchlist

    func setWatchlist(_ newValue: Watchlist) {
        if newValue != watchlist {
            watchlist = newValue
        }
    }

    func updateWatchlist(_ change: (inout Watchlist) -> Void) {
        var copy = watchlist
        change(&copy)
        setWatchlist(copy)
    }

    // After a successful live events fetch (never saved data): the first
    // records a baseline; later ones report closures new on watched roads.
    private func liveEventsArrived() {
        let fresh = closureTracker.newWatchedClosures(in: events, watchlist: watchlist)
        if !fresh.isEmpty {
            onNewWatchedClosures?(fresh, watchlist)
        }
    }

    /// Number of road events the user sees: Resolved events are left out
    /// unless "Show resolved" is on (sidebar badge, menu bar).
    func visibleEventCount(showResolved: Bool) -> Int {
        showResolved ? events.count : events.filter { !$0.isResolved }.count
    }

    // MARK: - Loading

    /// Launch: show the offline cache's data at once, then load live. Called
    /// once by the App (not a window), so it happens whether or not a window
    /// opens. Every section is marked loading first, so the tabs show a
    /// loading state rather than an empty one while the cache is read.
    /// - Parameter discardingSavedData: the previous launch never finished its
    ///   first refresh (see LaunchGuard), so the saved copy is deleted rather
    ///   than shown — if it was what brought the app down, showing it again
    ///   would repeat the crash on every launch.
    @discardableResult
    func start(discardingSavedData: Bool = false) -> Task<Void, Never> {
        if let launchTask {
            return launchTask
        }
        loadingSections = Set(DataSection.allCases)
        isRefreshing = true
        let task = Task {
            let prime = Task {
                if discardingSavedData {
                    await self.cache.removeAll()
                } else {
                    await self.primeFromCache()
                }
            }
            self.primeTask = prime
            await prime.value
            self.primeTask = nil
            await self.loadAllData()
        }
        launchTask = task
        return task
    }

    /// Refreshes when the last refresh started more than `maxAge` ago — used
    /// when the main window (re)appears. Waits for the launch load rather than
    /// starting a second one.
    func refreshIfStale(maxAge: TimeInterval) async {
        if let launchTask {
            await launchTask.value
        }
        if let lastRefreshAttempt, clock().timeIntervalSince(lastRefreshAttempt) <= maxAge {
            return
        }
        await loadAllData()
    }

    /// Refreshes every live section, single-flight: while a refresh is
    /// running, callers join it rather than starting another. Each section is
    /// applied the moment its own fetch completes; the call returns once the
    /// shared sections are done, while journeys (14–17 s server-side) finishes
    /// on its own with its own loading flag.
    /// - Parameter bustImageCache: an explicit user refresh (⌘R, the menu
    ///   bar). Camera images then load from new `?t=` URLs, bypassing the URL
    ///   cache. A refresh already running is "upgraded" rather than repeated.
    ///   Automatic refreshes instead re-request the same image URLs with a
    ///   revalidating load (see `cameraImageGeneration`); the JSON itself is
    ///   sent no-store, so every refresh downloads it in full.
    func loadAllData(bustImageCache: Bool = false) async {
        if bustImageCache {
            pendingImageBust = true
        }
        // Never race the launch's cache priming: start after it.
        if let primeTask {
            await primeTask.value
        }
        await refreshFlight.run(.sharedSections) {
            await self.runRefresh()
        }
        // A joining explicit refresh whose image bust the running refresh
        // didn't get to apply.
        applyPendingImageBust()
    }

    private func runRefresh() async {
        isRefreshing = true
        lastRefreshAttempt = clock()
        loadingSections.formUnion(DataSection.refreshedTogether)
        startIndependentLoads()

        async let camerasLoad = loadSection(.cameras)
        async let eventsLoad = loadSection(.events)
        async let vmsLoad = loadSection(.vms)
        async let timLoad = loadSection(.timSigns)
        async let congestionLoad = loadSection(.congestion)
        _ = await (camerasLoad, eventsLoad, vmsLoad, timLoad, congestionLoad)

        applyPendingImageBust()
        isRefreshing = false
    }

    // Loads that don't hold a refresh up: journeys (slow server-side) and the
    // fetch-once reference data. Each is single-flight/guarded, so starting
    // one that is already running just joins it.
    private func startIndependentLoads() {
        Task {
            await self.loadSection(.journeys)
        }
        if canonicalRegions.isEmpty, !isLoadingRegions, isOnline {
            Task {
                await self.loadRegions()
            }
        }
        if evChargersAreDue, !isLoadingEVChargers {
            Task {
                await self.loadEVChargers()
            }
        }
    }

    /// Reloads a single section, used by the per-section "Retry" button on an
    /// error banner. Joins a load of that section already in flight.
    func reload(_ section: DataSection) async {
        errors[section] = nil
        await loadSection(section)
    }

    /// Re-fetches the EV charger layer now, whatever its age — the map's
    /// per-layer Retry. The markers already shown stay until it lands.
    func reloadEVChargers() async {
        guard !isLoadingEVChargers else {
            return
        }
        evChargersError = nil
        await loadEVChargers(force: true)
    }

    // Never loaded, or loaded over an hour ago (connector status changes
    // about daily upstream).
    private var evChargersAreDue: Bool {
        AutoRefreshPolicy.shouldRefetchEVChargers(
            hasData: !evChargers.isEmpty,
            loadedAt: evChargersLoadedAt,
            now: clock()
        )
    }

    /// Settings › Clear Offline Cache: deletes the saved section files and the
    /// cached camera images, then reloads everything (an escape hatch should a
    /// bad cached copy ever cause trouble). Data already on screen stays until
    /// the reload replaces it.
    /// Writes saved-data updates the offline cache is holding back (it
    /// rewrites a changing section at most every 10 minutes).
    func flushOfflineCache() async {
        await cache.flush()
    }

    func clearOfflineCache() async {
        await cache.removeAll()
        imageCache?.removeAllCachedResponses()
        await loadAllData(bustImageCache: true)
    }

    // Per-section single flight: the loading flag is owned by the one job, so
    // overlapping refreshes can't clear each other's flags early.
    @discardableResult
    private func loadSection(_ section: DataSection) async -> SectionLoadOutcome {
        await sectionLoads.run(section) {
            self.loadingSections.insert(section)
            let outcome = await self.performLoad(section)
            self.loadingSections.remove(section)
            return outcome
        }
    }

    private func performLoad(_ section: DataSection) async -> SectionLoadOutcome {
        switch section {
        case .cameras:
            return await loadCacheable(
                .cameras,
                keyPath: \.cameras,
                fetch: { await self.service.fetchCamerasResult() },
                decodeCached: { await self.service.decodeCachedCameras($0) }
            )
        case .events:
            let outcome = await loadCacheable(
                .events,
                keyPath: \.events,
                fetch: { await self.service.fetchRoadEventsResult() },
                decodeCached: { data in
                    // Don't replay events that have already ended as current.
                    await self.service.decodeCachedRoadEvents(data)?.filter { !$0.hasEnded(before: self.clock()) }
                }
            )
            if case .updated = outcome {
                liveEventsArrived()
            }
            return outcome
        case .vms:
            return await loadCacheable(
                .vms,
                keyPath: \.vmsSigns,
                fetch: { await self.service.fetchVMSSignsResult() },
                decodeCached: { await self.service.decodeCachedVMSSigns($0) }
            )
        case .journeys:
            return await loadCacheable(
                .journeys,
                keyPath: \.journeys,
                fetch: { await self.service.fetchJourneysResult() },
                decodeCached: { await self.service.decodeCachedJourneys($0) }
            )
        case .timSigns:
            return await loadLive(.timSigns, keyPath: \.timSigns) {
                await self.service.fetchTIMSignsResult()
            }
        case .congestion:
            return await loadLive(.congestion, keyPath: \.congestion) {
                await self.service.fetchCongestionResult()
            }
        }
    }

    // Shared load path for the four offline-cacheable sections. On success it
    // updates the in-memory slice and persists the raw bytes — unless the list
    // came back empty while data is already loaded, which keeps the last good
    // data and cache and reports it (sectionRefreshDecision). On failure (which
    // includes a structurally broken response, see decodeSectionList) it
    // records the error and keeps whatever is on screen, restoring the cached
    // copy only when the section has nothing to show. Offline, it doesn't try
    // the network at all. Disk IO runs on the OfflineCache actor.
    private func loadCacheable<T>(
        _ section: DataSection,
        keyPath: ReferenceWritableKeyPath<TrafficStore, [T]>,
        fetch: () async -> Result<SectionFetch<T>, Error>,
        decodeCached: (Data) async -> [T]?
    ) async -> SectionLoadOutcome {
        let result = isOnline ? await fetch() : .failure(TrafficAPIError.offline)
        switch result {
        case .success(let fetched):
            droppedCounts[section] = fetched.dropped
            switch sectionRefreshDecision(fetchedCount: fetched.value.count, currentCount: self[keyPath: keyPath].count) {
            case .replace(let persist):
                applyLive(fetched, to: section, keyPath: keyPath)
                if persist {
                    await cache.write(fetched.data, digest: fetched.digest, section: section)
                }
                return .updated
            case .keepPrevious:
                recordEmptyFeed(section)
                return .emptyFeed
            }
        case .failure(let error):
            // A cancelled load is not a failure: no error, no cache fallback.
            guard !(error is CancellationError) else {
                return .cancelled
            }
            recordFailure(error, for: section)
            if self[keyPath: keyPath].isEmpty {
                await restoreFromCache(section, keyPath: keyPath, decode: decodeCached)
            }
            return .failed
        }
    }

    // Load path for the live-only sections (TIM boards, congestion): same
    // rules, minus the disk cache.
    private func loadLive<T>(
        _ section: DataSection,
        keyPath: ReferenceWritableKeyPath<TrafficStore, [T]>,
        fetch: () async -> Result<SectionFetch<T>, Error>
    ) async -> SectionLoadOutcome {
        let result = isOnline ? await fetch() : .failure(TrafficAPIError.offline)
        switch result {
        case .success(let fetched):
            droppedCounts[section] = fetched.dropped
            switch sectionRefreshDecision(fetchedCount: fetched.value.count, currentCount: self[keyPath: keyPath].count) {
            case .replace:
                applyLive(fetched, to: section, keyPath: keyPath)
                return .updated
            case .keepPrevious:
                recordEmptyFeed(section)
                return .emptyFeed
            }
        case .failure(let error):
            guard !(error is CancellationError) else {
                return .cancelled
            }
            // Keep the previously loaded data on a failure instead of wiping
            // it — the error banner surfaces the problem while the user keeps
            // the last-known-good data for this section.
            recordFailure(error, for: section)
            return .failed
        }
    }

    private func applyLive<T>(
        _ fetched: SectionFetch<T>,
        to section: DataSection,
        keyPath: ReferenceWritableKeyPath<TrafficStore, [T]>
    ) {
        // Byte-identical to what's on screen (the usual case between ticks):
        // skip the reassignment, the filter-cache reset and the re-render.
        if appliedDigests[section] != fetched.digest {
            self[keyPath: keyPath] = fetched.value
            appliedDigests[section] = fetched.digest
            invalidateFilterCache(for: section)
            refreshRegions()
        }
        if errors[section] != nil {
            errors[section] = nil
        }
        if failedSections.contains(section) {
            failedSections.remove(section)
        }
        if savedSections.contains(section) {
            savedSections.remove(section)
            savedDates[section] = nil
        }
        let now = clock()
        lastLiveSuccess[section] = now
        // "Updated …" speaks for the sections the freshness banner covers, so
        // a live-only section (TIM, congestion) succeeding alone can't claim
        // an update while the banner says NZTA couldn't be reached.
        if section.isCacheable {
            lastUpdated = now
        }
        if section == .cameras {
            camerasRefreshed(at: now)
        }
    }

    // NZTA answered, but with an empty list over data we already have: keep
    // the data (and the cache) and say so. Not a connectivity failure.
    private func recordEmptyFeed(_ section: DataSection) {
        errors[section] = Self.emptyFeedMessage
        if failedSections.contains(section) {
            failedSections.remove(section)
        }
    }

    private func recordFailure(_ error: Error, for section: DataSection) {
        errors[section] = errorMessage(error)
        if !failedSections.contains(section) {
            failedSections.insert(section)
        }
    }

    // Replays a section's cached bytes into an empty section and marks it
    // saved. Used by the launch prime and as the fallback after a failure.
    @discardableResult
    private func restoreFromCache<T>(
        _ section: DataSection,
        keyPath: ReferenceWritableKeyPath<TrafficStore, [T]>,
        decode: (Data) async -> [T]?
    ) async -> Bool {
        guard self[keyPath: keyPath].isEmpty,
              let entry = await cache.read(section: section),
              let restored = await decode(entry.data),
              !restored.isEmpty,
              // Re-check after the suspensions: never clobber data that
              // arrived meanwhile.
              self[keyPath: keyPath].isEmpty else {
            return false
        }
        self[keyPath: keyPath] = restored
        // The replay may be filtered (ended events), so it isn't the bytes'
        // exact decode: the next live fetch always applies.
        appliedDigests[section] = nil
        invalidateFilterCache(for: section)
        savedSections.insert(section)
        savedDates[section] = entry.savedAt
        refreshRegions()
        return true
    }

    // Populates empty sections from the on-disk cache so the UI has content to
    // show immediately on launch, ahead of (or in place of) the first live
    // fetch. Decoding runs off the main actor. Only fills sections that are
    // still empty, so it never clobbers fresher live data already in memory.
    // Saved data shows the neutral "Showing saved data … updating…" banner,
    // not an error: nothing has failed yet.
    private func primeFromCache() async {
        await restoreFromCache(.cameras, keyPath: \.cameras) { await self.service.decodeCachedCameras($0) }
        await restoreFromCache(.events, keyPath: \.events) { data in
            await self.service.decodeCachedRoadEvents(data)?.filter { !$0.hasEnded(before: self.clock()) }
        }
        await restoreFromCache(.vms, keyPath: \.vmsSigns) { await self.service.decodeCachedVMSSigns($0) }
        await restoreFromCache(.journeys, keyPath: \.journeys) { await self.service.decodeCachedJourneys($0) }
    }

    // Camera images follow the cameras section: an explicit refresh's pending
    // bust gives them new URLs; otherwise they revalidate their current ones.
    private func camerasRefreshed(at now: Date) {
        if pendingImageBust {
            applyPendingImageBust()
            return
        }
        guard AutoRefreshPolicy.shouldReloadCameraImages(lastReload: lastCameraImageReload, now: now) else {
            return
        }
        cameraImageGeneration &+= 1
        lastCameraImageReload = now
    }

    private func applyPendingImageBust() {
        guard pendingImageBust else {
            return
        }
        pendingImageBust = false
        imageCacheToken = max(imageCacheToken + 1, Int(clock().timeIntervalSince1970))
        lastCameraImageReload = clock()
    }

    // EV chargers change slowly (locations rarely, connector status about
    // daily), so they load on the first refresh and again on a refresh once
    // they're over an hour old — or at once after a failed load left the list
    // empty. A failure surfaces via `evChargersError` on the map's EV layer
    // rather than wiping any previously loaded markers.
    private func loadEVChargers(force: Bool = false) async {
        guard force || evChargersAreDue, !isLoadingEVChargers else {
            return
        }
        guard isOnline else {
            evChargersError = errorMessage(TrafficAPIError.offline)
            return
        }
        isLoadingEVChargers = true
        defer { isLoadingEVChargers = false }
        switch await service.fetchEVChargersResult() {
        case .success(let fetched):
            evChargersLoadedAt = self.clock()
            // An empty list over markers already shown keeps them (as the
            // live sections do).
            if !fetched.value.isEmpty || evChargers.isEmpty, fetched.value != evChargers {
                evChargers = fetched.value
                evChargersChanged()
            }
            droppedEVChargerCount = fetched.dropped
            evChargersError = nil
        case .failure(let error):
            guard !(error is CancellationError) else {
                return
            }
            evChargersError = errorMessage(error)
        }
    }

    // The canonical region list is static reference data, so fetch it only once
    // (the first time it is needed). It is intentionally not a `DataSection`: a
    // failure leaves the picker to fall back to data-derived names rather than
    // surfacing an error banner. Updating `allRegions` here lets the picker
    // populate as soon as regions arrive, ahead of the heavier feature loads.
    private func loadRegions() async {
        guard canonicalRegions.isEmpty, !isLoadingRegions else {
            return
        }
        isLoadingRegions = true
        defer { isLoadingRegions = false }
        guard case .success(let regions) = await service.fetchRegionsResult() else {
            return
        }
        let names = regions.compactMap { cleanText($0.name) }.filter { !$0.isEmpty }
        guard !names.isEmpty else {
            return
        }
        canonicalRegions = names
        regionOutlines = regions.compactMap { region in
            guard let name = cleanText(region.name), !region.boundary.isEmpty else {
                return nil
            }
            return RegionOutline(name: name, rings: region.boundary)
        }
        evChargersChanged()
        refreshRegions()
    }

    // The EV memo and region placements are stale once the charger list or
    // the region outlines change.
    private func evChargersChanged() {
        evChargerCache.removeAll(keepingCapacity: true)
        evChargerRegions = nil
    }

    // MARK: - Auto-refresh

    /// Applies the auto-refresh settings (the App passes the `nzta.*`
    /// values whenever they change). Idempotent: unchanged settings leave the
    /// running schedule alone.
    func configureAutoRefresh(_ settings: AutoRefreshSettings) {
        guard settings != autoRefresh || (settings.isEnabled && autoRefreshTask == nil) else {
            return
        }
        autoRefresh = settings
        rescheduleAutoRefresh()
    }

    /// The app's activity, from the App. Auto-refresh slows down while the app
    /// is in the background with no window on screen, and catches up at once
    /// if a refresh fell due in the meantime.
    func updateAppActivity(isAppActive: Bool, hasVisibleWindow: Bool) {
        guard isAppActive != self.isAppActive || hasVisibleWindow != self.hasVisibleWindow else {
            return
        }
        self.isAppActive = isAppActive
        self.hasVisibleWindow = hasVisibleWindow
        if autoRefresh.isEnabled {
            rescheduleAutoRefresh()
        }
    }

    /// The auto-refresh interval in force now, or nil when it's off.
    var effectiveAutoRefreshInterval: Int? {
        guard autoRefresh.isEnabled else {
            return nil
        }
        return AutoRefreshPolicy.effectiveInterval(
            base: autoRefresh.interval,
            isAppActive: isAppActive,
            hasVisibleWindow: hasVisibleWindow
        )
    }

    private func rescheduleAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
        guard autoRefresh.isEnabled else {
            return
        }
        autoRefreshTask = Task { [weak self] in
            await Self.runAutoRefreshLoop { [weak self] in self }
        }
    }

    // Rescheduling only changes when the next tick falls — it is always
    // counted from the start of the last refresh, so switching apps or
    // changing a setting never postpones a refresh indefinitely, and a manual
    // refresh pushes the next tick back. Cancelling the loop never cancels a
    // refresh in progress (loads run in their own tasks). The loop re-acquires
    // the store on each tick rather than holding it, so it never keeps a
    // discarded store (and its NWPathMonitor) alive; the App's store lives as
    // long as the app anyway.
    private static func runAutoRefreshLoop(_ store: @MainActor () -> TrafficStore?) async {
        if let launchTask = store()?.launchTask {
            await launchTask.value
        }
        while !Task.isCancelled {
            guard let (delay, interval) = store()?.nextAutoRefreshDelay() else {
                return
            }
            if delay > 0 {
                do {
                    // A little tolerance lets the system coalesce the wakeup
                    // with other timers; the loop re-checks after waking.
                    try await Task.sleep(
                        for: .seconds(delay),
                        tolerance: .seconds(AutoRefreshPolicy.sleepTolerance(forInterval: interval))
                    )
                } catch {
                    return
                }
                // Re-check: a manual refresh may have moved the next tick.
                continue
            }
            guard let current = store() else {
                return
            }
            await current.loadAllData()
        }
    }

    // The wait before the next automatic refresh and the interval in force,
    // or nil when auto-refresh is off.
    private func nextAutoRefreshDelay() -> (TimeInterval, Int)? {
        guard let interval = effectiveAutoRefreshInterval else {
            return nil
        }
        let delay = AutoRefreshPolicy.delayUntilNextRefresh(
            lastAttempt: lastRefreshAttempt,
            now: clock(),
            interval: interval
        )
        return (delay, interval)
    }

    // MARK: - Diagnostics

    /// Snapshot for Help → Export Diagnostics: counts, per-section status and
    /// errors, the offline cache's files, refresh and API state, system and app
    /// version, and preferences (injectable so tests never read real defaults).
    func diagnosticsReport(
        preferences: [String: String] = DiagnosticsReport.collectPreferences()
    ) async -> DiagnosticsReport {
        let sections: [DiagnosticsReport.SectionStat] = [
            sectionStat("Cameras", .cameras, count: cameras.count),
            .init(name: "Cameras Online", count: cameras.filter(\.isOnline).count, error: nil),
            sectionStat("Road Events", .events, count: events.count),
            .init(name: "Upcoming Events", count: events.filter(\.isUpcoming).count, error: nil),
            .init(name: "Resolved Events", count: events.filter(\.isResolved).count, error: nil),
            .init(name: "Active Closures", count: criticalAlertCount, error: nil),
            sectionStat("VMS Signs", .vms, count: vmsSigns.count),
            sectionStat("Travel Times", .journeys, count: journeys.count),
            .init(
                name: "Journey Legs With Data Issues",
                count: journeys.reduce(0) { $0 + $1.dataIssueLegCount },
                error: nil
            ),
            sectionStat("TIM Signs", .timSigns, count: timSigns.count),
            sectionStat("Congestion Segments", .congestion, count: congestion.count),
            .init(name: "EV Chargers", count: evChargers.count, error: evChargersError, droppedCount: droppedEVChargerCount)
        ]
        let cacheFiles = await cache.fileInfo().map { file in
            DiagnosticsReport.CacheFile(
                name: "\(file.section.rawValue).json",
                byteCount: file.byteCount,
                savedAt: file.savedAt
            )
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return DiagnosticsReport(
            appVersion: version,
            appBuild: build,
            generatedAt: clock(),
            lastUpdated: lastUpdated,
            isOnline: isOnline,
            sections: sections,
            preferences: preferences,
            system: DiagnosticsReport.systemDescription(),
            freshness: freshnessBanner?.message(relativeTo: clock()),
            refresh: refreshDiagnostics(),
            cacheFiles: cacheFiles,
            apiFallbacks: service.versionFallback.legacyEndpoints
        )
    }

    private func sectionStat(_ name: String, _ section: DataSection, count: Int) -> DiagnosticsReport.SectionStat {
        DiagnosticsReport.SectionStat(
            name: name,
            count: count,
            error: errors[section],
            droppedCount: droppedCounts[section] ?? 0,
            status: sectionStatus(section),
            lastSuccess: lastLiveSuccess[section]
        )
    }

    private func sectionStatus(_ section: DataSection) -> String {
        var parts: [String] = []
        if loadingSections.contains(section) {
            parts.append("loading")
        }
        if savedSections.contains(section) {
            parts.append("saved data (offline cache)")
        } else if lastLiveSuccess[section] != nil {
            parts.append("live")
        } else {
            parts.append("no live data yet")
        }
        if failedSections.contains(section) {
            parts.append("last fetch failed")
        }
        return parts.joined(separator: ", ")
    }

    private func refreshDiagnostics() -> [String] {
        let iso = ISO8601DateFormatter()
        var lines: [String] = []
        if let interval = effectiveAutoRefreshInterval {
            let mode = isAppActive || hasVisibleWindow ? "foreground" : "background"
            lines.append("Auto-refresh: every \(interval) s (\(mode); chosen \(autoRefresh.interval) s)")
        } else {
            lines.append("Auto-refresh: off")
        }
        lines.append("Refreshing: \(isRefreshing ? "yes" : "no")")
        lines.append("Last refresh started: \(lastRefreshAttempt.map(iso.string(from:)) ?? "never")")
        return lines
    }

    // MARK: - Filtering

    func filteredCameras(region: String, highway: String, search: String) -> [TrafficCamera] {
        let key = FilterKey(region: region, highway: highway, search: search)
        if let cached = cameraCache[key] {
            return cached
        }
        let highwayQuery = HighwayQuery(highway)
        let result = cameras
            .filter { $0.matches(region: region, highway: highwayQuery, search: search) }
            .sorted { lhs, rhs in
                if let lhsSort = lhs.sortOrder, let rhsSort = rhs.sortOrder, lhsSort != rhsSort {
                    return lhsSort < rhsSort
                }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
        Self.memoize(result, for: key, in: &cameraCache)
        return result
    }

    // Resolved events are dropped unless `showResolved`; the rest sort
    // current → upcoming → resolved, then by severity (roadEventSortsBefore).
    func filteredEvents(region: String, highway: String, search: String, showResolved: Bool) -> [RoadEvent] {
        let key = FilterKey(region: region, highway: highway, search: search, showResolved: showResolved)
        if let cached = eventCache[key] {
            return cached
        }
        let highwayQuery = HighwayQuery(highway)
        let result = events
            .filter { event in
                event.isVisible(showResolved: showResolved)
                    && event.matches(region: region, highway: highwayQuery, search: search)
            }
            .sorted(by: roadEventSortsBefore)
        Self.memoize(result, for: key, in: &eventCache)
        return result
    }

    func filteredVMSSigns(region: String, highway: String, search: String) -> [VMSSign] {
        let key = FilterKey(region: region, highway: highway, search: search)
        if let cached = vmsCache[key] {
            return cached
        }
        let highwayQuery = HighwayQuery(highway)
        let result = vmsSigns
            .filter { $0.matches(region: region, highway: highwayQuery, search: search) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        Self.memoize(result, for: key, in: &vmsCache)
        return result
    }

    func filteredJourneys(region: String, highway: String, search: String) -> [TrafficJourney] {
        let key = FilterKey(region: region, highway: highway, search: search)
        if let cached = journeyCache[key] {
            return cached
        }
        let highwayQuery = HighwayQuery(highway)
        // Most delayed first, by the worse of each journey's two directions.
        let result = journeys
            .filter { $0.matches(region: region, highway: highwayQuery, search: search) }
            .sorted { lhs, rhs in
                let lhsDelay = lhs.worstDelay ?? -1
                let rhsDelay = rhs.worstDelay ?? -1
                if lhsDelay != rhsDelay {
                    return lhsDelay > rhsDelay
                }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
        Self.memoize(result, for: key, in: &journeyCache)
        return result
    }

    // By name in natural order ("2 …" before "12 …").
    func filteredTIMSigns(region: String, highway: String, search: String) -> [TIMSign] {
        let key = FilterKey(region: region, highway: highway, search: search)
        if let cached = timCache[key] {
            return cached
        }
        let highwayQuery = HighwayQuery(highway)
        let result = timSigns
            .filter { $0.matches(region: region, highway: highwayQuery, search: search) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        Self.memoize(result, for: key, in: &timCache)
        return result
    }

    // Fully-scoped slices: region/highway/search filtering (memoized above)
    // plus the per-section visibility flags the UI toggles. Keeping the whole
    // filter pipeline here matches "filtering lives in the store".
    // `watchingOnly` (the "Watching" chip) keeps what the watchlist covers;
    // it is applied after the memoized slice, like the chips.
    func scopedCameras(
        region: String,
        highway: String,
        search: String,
        statuses: Set<CameraStatusKind>,
        watchingOnly: Bool = false
    ) -> [TrafficCamera] {
        filteredCameras(region: region, highway: highway, search: search)
            .filter { statuses.contains($0.statusKind) && (!watchingOnly || watchlist.watches($0)) }
    }

    func scopedEvents(
        region: String,
        highway: String,
        search: String,
        impacts: Set<EventImpactKind>,
        showPlanned: Bool,
        showUnplanned: Bool,
        showResolved: Bool,
        island: EventIslandFilter,
        watchingOnly: Bool = false
    ) -> [RoadEvent] {
        filteredEvents(region: region, highway: highway, search: search, showResolved: showResolved)
            .filter { impacts.contains($0.impactKind) }
            .filter { $0.isPlanned ? showPlanned : showUnplanned }
            .filter { island.matches($0.eventIsland) }
            .filter { !watchingOnly || watchlist.watches($0) }
    }

    func scopedVMSSigns(region: String, highway: String, search: String, hideEmpty: Bool) -> [VMSSign] {
        let base = filteredVMSSigns(region: region, highway: highway, search: search)
        return hideEmpty ? base.filter(\.hasDisplayMessage) : base
    }

    func scopedJourneys(
        region: String,
        highway: String,
        search: String,
        flows: Set<FlowKind>,
        watchingOnly: Bool = false
    ) -> [TrafficJourney] {
        filteredJourneys(region: region, highway: highway, search: search)
            .filter { flows.contains($0.overallFlowKind) && (!watchingOnly || watchlist.watches($0)) }
    }

    // The Flow map filters per leg rather than per journey (see
    // flowMapSegments), so it starts from the unscoped journey slice.
    func mapFlowSegments(region: String, highway: String, search: String, flows: Set<FlowKind>) -> [FlowMapSegment] {
        let key = FlowSegmentKey(filter: FilterKey(region: region, highway: highway, search: search), flows: flows)
        if let cached = flowSegmentCache[key] {
            return cached
        }
        let result = flowMapSegments(
            for: filteredJourneys(region: region, highway: highway, search: search),
            allowedKinds: flows
        )
        Self.memoize(result, for: key, in: &flowSegmentCache)
        return result
    }

    func scopedTIMSigns(region: String, highway: String, search: String, hideBlank: Bool) -> [TIMSign] {
        let base = filteredTIMSigns(region: region, highway: highway, search: search)
        return hideBlank ? base.filter { !$0.isBlank } : base
    }

    // Auckland congestion: Auckland only, the highway its motorway carries,
    // and search over the motorway, segment, direction and level. Ordered
    // for drawing, worst level on top (see congestionDrawOrder).
    func filteredCongestion(region: String, highway: String, search: String) -> [CongestionSegment] {
        let key = FilterKey(region: region, highway: highway, search: search)
        if let cached = congestionCache[key] {
            return cached
        }
        let highwayQuery = HighwayQuery(highway)
        let result = congestionDrawOrder(
            congestion.filter { $0.matches(region: region, highway: highwayQuery, search: search) }
        )
        Self.memoize(result, for: key, in: &congestionCache)
        return result
    }

    /// Segments passing the filters, drawable or not (the map's "n of m").
    func congestionMatchCount(region: String, highway: String, search: String) -> Int {
        let key = FilterKey(region: region, highway: highway, search: search)
        if let cached = congestionMatchCounts[key] {
            return cached
        }
        let highwayQuery = HighwayQuery(highway)
        let count = congestion.count { $0.matches(region: region, highway: highwayQuery, search: search) }
        Self.memoize(count, for: key, in: &congestionMatchCounts)
        return count
    }

    // EV chargers by region (placed by location, see evChargerRegion),
    // highway (an address on one) and search, sorted by name.
    func filteredEVChargers(region: String, highway: String, search: String) -> [EVCharger] {
        let key = FilterKey(region: region, highway: highway, search: search)
        if let cached = evChargerCache[key] {
            return cached
        }
        let highwayQuery = HighwayQuery(highway)
        let regions = region.isEmpty ? [:] : placedEVChargerRegions()
        let result = evChargers
            .filter { charger in
                (region.isEmpty || matchesRegion(regions[charger.id], selectedRegion: region))
                    && charger.matches(highway: highwayQuery, search: search)
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        Self.memoize(result, for: key, in: &evChargerCache)
        return result
    }

    private func placedEVChargerRegions() -> [String: String] {
        if let evChargerRegions {
            return evChargerRegions
        }
        var placed: [String: String] = [:]
        for charger in evChargers {
            if let name = evChargerRegion(charger) {
                placed[charger.id] = name
            }
        }
        evChargerRegions = placed
        return placed
    }

    // From the region outlines when they've loaded. Without them (the
    // regions fetch failed), fall back to a region named in the address —
    // "…, Flat Bush, Auckland, 2012" — which covers the main centres.
    private func evChargerRegion(_ charger: EVCharger) -> String? {
        if !regionOutlines.isEmpty {
            guard let coordinate = charger.mapCoordinate else {
                return nil
            }
            return regionName(containing: coordinate, in: regionOutlines)
        }
        let address = foldedForSearch(charger.address ?? "")
        return allRegions.first { containsWholeWords(foldedForSearch($0), in: address) }
    }

    // Only the changed section's memo is stale.
    // Each distinct (debounced) filter adds a memo entry holding a whole
    // filtered array, and sections whose feed rarely changes keep theirs for
    // hours; start over past a few dozen entries so memory stays bounded.
    private static let memoLimit = 24

    private static func memoize<Key: Hashable, Value>(_ value: Value, for key: Key, in memo: inout [Key: Value]) {
        if memo.count >= memoLimit {
            memo.removeAll(keepingCapacity: true)
        }
        memo[key] = value
    }

    private func invalidateFilterCache(for section: DataSection) {
        switch section {
        case .cameras:
            cameraCache.removeAll(keepingCapacity: true)
        case .events:
            eventCache.removeAll(keepingCapacity: true)
        case .vms:
            vmsCache.removeAll(keepingCapacity: true)
        case .journeys:
            journeyCache.removeAll(keepingCapacity: true)
            flowSegmentCache.removeAll(keepingCapacity: true)
        case .timSigns:
            timCache.removeAll(keepingCapacity: true)
        case .congestion:
            congestionCache.removeAll(keepingCapacity: true)
            congestionMatchCounts.removeAll(keepingCapacity: true)
        }
    }

    private func refreshRegions() {
        let regions = computeAllRegions()
        if regions != allRegions {
            allRegions = regions
        }
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

    // Shown (and exported in diagnostics) when a feed that had data returns
    // an empty list; see sectionRefreshDecision.
    private static let emptyFeedMessage =
        "NZTA sent an empty list, so the last data received is still shown."

    private func errorMessage(_ error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let message = localizedError.errorDescription {
            return message
        }
        return error.localizedDescription
    }
}
