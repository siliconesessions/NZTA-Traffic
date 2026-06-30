import Foundation
import Observation
import SwiftUI

enum DataSection: String, CaseIterable, Identifiable {
    case cameras
    case events
    case vms
    case journeys
    case timSigns

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

    @ObservationIgnored private let service: TrafficAPIService

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
    }

    func isLoading(_ section: DataSection) -> Bool {
        loadingSections.contains(section)
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
        async let regionsTask: () = loadRegions()
        async let evChargersTask: () = loadEVChargers()
        _ = await (camerasTask, eventsTask, signsTask, journeysTask, timTask, regionsTask, evChargersTask)

        allRegions = computeAllRegions()
        lastUpdated = Date()
        if bustImageCache {
            imageCacheToken = Int(Date().timeIntervalSince1970)
        }
        isRefreshing = false
    }

    private func loadCameras() async {
        let result = await service.fetchCamerasResult()
        apply(result, to: .cameras, keyPath: \.cameras)
        loadingSections.remove(.cameras)
    }

    private func loadEvents() async {
        let result = await service.fetchRoadEventsResult()
        apply(result, to: .events, keyPath: \.events)
        loadingSections.remove(.events)
    }

    private func loadVMS() async {
        let result = await service.fetchVMSSignsResult()
        apply(result, to: .vms, keyPath: \.vmsSigns)
        loadingSections.remove(.vms)
    }

    private func loadJourneys() async {
        let result = await service.fetchJourneysResult()
        apply(result, to: .journeys, keyPath: \.journeys)
        loadingSections.remove(.journeys)
    }

    private func loadTIMSigns() async {
        let result = await service.fetchTIMSignsResult()
        apply(result, to: .timSigns, keyPath: \.timSigns)
        loadingSections.remove(.timSigns)
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
        let derived = cameras.compactMap(\.regionName)
            + events.compactMap(\.regionName)
            + vmsSigns.compactMap(\.regionName)
            + journeys.compactMap(\.regionName)
            + timSigns.compactMap(\.regionName)
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
