import Foundation
import SwiftUI

enum DataSection: String, CaseIterable, Identifiable {
    case cameras
    case events
    case vms
    case journeys

    var id: String {
        rawValue
    }
}

@MainActor
final class TrafficStore: ObservableObject {
    @Published private(set) var cameras: [TrafficCamera] = []
    @Published private(set) var events: [RoadEvent] = []
    @Published private(set) var vmsSigns: [VMSSign] = []
    @Published private(set) var journeys: [TrafficJourney] = []
    @Published private(set) var allRegions: [String] = []
    @Published private(set) var loadingSections: Set<DataSection> = []
    @Published private(set) var errors: [DataSection: String] = [:]
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var imageCacheToken: Int = Int(Date().timeIntervalSince1970)
    @Published private(set) var isRefreshing = false

    private let service: TrafficAPIService

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
        _ = await (camerasTask, eventsTask, signsTask, journeysTask)

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

    func filteredCameras(region: String, highway: String, search: String) -> [TrafficCamera] {
        cameras
            .filter { $0.matches(region: region, highway: highway, search: search) }
            .sorted { lhs, rhs in
                if let lhsSort = lhs.sortOrder, let rhsSort = rhs.sortOrder, lhsSort != rhsSort {
                    return lhsSort < rhsSort
                }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    func filteredEvents(region: String, highway: String, search: String) -> [RoadEvent] {
        events
            .filter { $0.matches(region: region, highway: highway, search: search) }
            .sorted { lhs, rhs in
                if lhs.severityRank != rhs.severityRank {
                    return lhs.severityRank < rhs.severityRank
                }
                return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
            }
    }

    func filteredVMSSigns(region: String, highway: String, search: String) -> [VMSSign] {
        vmsSigns
            .filter { $0.matches(region: region, highway: highway, search: search) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func filteredJourneys(region: String, highway: String, search: String) -> [TrafficJourney] {
        journeys
            .filter { $0.matches(region: region, highway: highway, search: search) }
            .sorted { lhs, rhs in
                let lhsDelay = lhs.congestionDelay ?? -1
                let rhsDelay = rhs.congestionDelay ?? -1
                if lhsDelay != rhsDelay {
                    return lhsDelay > rhsDelay
                }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    private func apply<T>(
        _ result: Result<[T], Error>,
        to section: DataSection,
        keyPath: ReferenceWritableKeyPath<TrafficStore, [T]>
    ) {
        switch result {
        case .success(let value):
            self[keyPath: keyPath] = value
        case .failure(let error):
            // Keep the previously loaded data on a transient failure instead of
            // wiping it — the error banner surfaces the problem while the user
            // keeps the last-known-good data for this section.
            errors[section] = errorMessage(error)
        }
    }

    private func computeAllRegions() -> [String] {
        let names = cameras.compactMap(\.regionName)
            + events.compactMap(\.regionName)
            + vmsSigns.compactMap(\.regionName)
            + journeys.compactMap(\.regionName)
        return Array(Set(names)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func errorMessage(_ error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let message = localizedError.errorDescription {
            return message
        }
        return error.localizedDescription
    }
}
