import Foundation
import SwiftUI

enum DataSection: String, CaseIterable, Identifiable {
    case cameras
    case events
    case vms

    var id: String {
        rawValue
    }
}

@MainActor
final class TrafficStore: ObservableObject {
    @Published private(set) var cameras: [TrafficCamera] = []
    @Published private(set) var events: [RoadEvent] = []
    @Published private(set) var vmsSigns: [VMSSign] = []
    @Published private(set) var loadingSections: Set<DataSection> = []
    @Published private(set) var errors: [DataSection: String] = [:]
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var imageCacheToken: Int = Int(Date().timeIntervalSince1970)
    @Published private(set) var isRefreshing = false

    private let service: TrafficAPIService

    init(service: TrafficAPIService = TrafficAPIService()) {
        self.service = service
    }

    var allRegions: [String] {
        let names = cameras.compactMap(\.regionName)
            + events.compactMap(\.regionName)
            + vmsSigns.compactMap(\.regionName)
        return Array(Set(names)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func isLoading(_ section: DataSection) -> Bool {
        loadingSections.contains(section)
    }

    func loadAllData() async {
        isRefreshing = true
        loadingSections = Set(DataSection.allCases)
        errors = [:]

        async let cameraResult = service.fetchCamerasResult()
        async let eventResult = service.fetchRoadEventsResult()
        async let signResult = service.fetchVMSSignsResult()

        let results = await (cameraResult, eventResult, signResult)

        apply(results.0, to: .cameras)
        apply(results.1, to: .events)
        apply(results.2, to: .vms)

        loadingSections = []
        lastUpdated = Date()
        imageCacheToken = Int(Date().timeIntervalSince1970)
        isRefreshing = false
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

    private func apply(_ result: Result<[TrafficCamera], Error>, to section: DataSection) {
        switch result {
        case .success(let value):
            cameras = value
        case .failure(let error):
            cameras = []
            errors[section] = errorMessage(error)
        }
    }

    private func apply(_ result: Result<[RoadEvent], Error>, to section: DataSection) {
        switch result {
        case .success(let value):
            events = value
        case .failure(let error):
            events = []
            errors[section] = errorMessage(error)
        }
    }

    private func apply(_ result: Result<[VMSSign], Error>, to section: DataSection) {
        switch result {
        case .success(let value):
            vmsSigns = value
        case .failure(let error):
            vmsSigns = []
            errors[section] = errorMessage(error)
        }
    }

    private func errorMessage(_ error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let message = localizedError.errorDescription {
            return message
        }
        return error.localizedDescription
    }
}
