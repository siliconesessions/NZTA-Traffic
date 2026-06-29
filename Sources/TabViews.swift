import SwiftUI

struct CamerasTabView: View {
    let cameras: [TrafficCamera]
    let isLoading: Bool
    let errorMessage: String?
    let cacheToken: Int
    let hasActiveFilters: Bool
    let onClearFilters: () -> Void
    let onPreview: (TrafficCamera) -> Void

    private var onlineCount: Int {
        cameras.filter(\.isOnline).count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let errorMessage {
                    ErrorBanner(message: errorMessage)
                }

                if isLoading && cameras.isEmpty {
                    LoadingView(title: "Loading traffic cameras...")
                } else if cameras.isEmpty {
                    FilterableEmptyState(
                        systemImage: "video.slash",
                        title: "No cameras to show",
                        hasActiveFilters: hasActiveFilters,
                        onClearFilters: onClearFilters
                    )
                } else {
                    StatsRow(stats: [
                        StatItem(title: "Total Cameras", value: "\(cameras.count)", tint: .black),
                        StatItem(title: "Online", value: "\(onlineCount)", tint: .green)
                    ])

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)], spacing: 16) {
                        ForEach(cameras) { camera in
                            CameraCard(camera: camera, cacheToken: cacheToken) {
                                onPreview(camera)
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}


struct RoadEventsTabView: View {
    let events: [RoadEvent]
    let isLoading: Bool
    let errorMessage: String?
    let hasActiveFilters: Bool
    let onClearFilters: () -> Void

    private var closures: Int {
        events.filter(\.isClosure).count
    }

    private var delays: Int {
        events.filter(\.hasDelays).count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let errorMessage {
                    ErrorBanner(message: errorMessage)
                }

                if isLoading && events.isEmpty {
                    LoadingView(title: "Loading road events...")
                } else if events.isEmpty {
                    FilterableEmptyState(
                        systemImage: "exclamationmark.triangle",
                        title: "No road events to show",
                        hasActiveFilters: hasActiveFilters,
                        onClearFilters: onClearFilters
                    )
                } else {
                    StatsRow(stats: [
                        StatItem(title: "Total Events", value: "\(events.count)", tint: .black),
                        StatItem(title: "Road Closures", value: "\(closures)", tint: .red),
                        StatItem(title: "Delays", value: "\(delays)", tint: .orange)
                    ])

                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(events) { event in
                            RoadEventCard(event: event)
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}

struct VMSTabView: View {
    let signs: [VMSSign]
    let isLoading: Bool
    let errorMessage: String?
    let hideEmpty: Bool
    let hasActiveFilters: Bool
    let onClearFilters: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let errorMessage {
                    ErrorBanner(message: errorMessage)
                }

                if isLoading && signs.isEmpty {
                    LoadingView(title: "Loading VMS signs...")
                } else if signs.isEmpty {
                    FilterableEmptyState(
                        systemImage: "signpost.right",
                        title: "No VMS signs to show",
                        hasActiveFilters: hasActiveFilters,
                        onClearFilters: onClearFilters
                    )
                } else {
                    StatsRow(stats: [
                        StatItem(title: hideEmpty ? "Signs With Message" : "Active VMS Signs", value: "\(signs.count)", tint: .orange)
                    ])

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], spacing: 16) {
                        ForEach(signs) { sign in
                            VMSCard(sign: sign)
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}

struct TravelTimesTabView: View {
    let journeys: [TrafficJourney]
    let isLoading: Bool
    let errorMessage: String?
    let hasActiveFilters: Bool
    let onClearFilters: () -> Void

    private var liveJourneyCount: Int {
        journeys.filter(\.hasLiveData).count
    }

    private var slowJourneyCount: Int {
        journeys.filter { journey in
            journey.overallFlowKind == .slow || journey.overallFlowKind == .congested
        }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let errorMessage {
                    ErrorBanner(message: errorMessage)
                }

                if isLoading && journeys.isEmpty {
                    LoadingView(title: "Loading travel times...")
                } else if journeys.isEmpty {
                    FilterableEmptyState(
                        systemImage: "speedometer",
                        title: "No journeys to show",
                        hasActiveFilters: hasActiveFilters,
                        onClearFilters: onClearFilters
                    )
                } else {
                    StatsRow(stats: [
                        StatItem(title: "Total Journeys", value: "\(journeys.count)", tint: .black),
                        StatItem(title: "With Live Data", value: "\(liveJourneyCount)", tint: .blue),
                        StatItem(title: "Slow / Congested", value: "\(slowJourneyCount)", tint: .orange)
                    ])

                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(journeys) { journey in
                            JourneyCard(journey: journey)
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}

