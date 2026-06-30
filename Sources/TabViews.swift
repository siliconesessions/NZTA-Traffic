import SwiftUI

struct CamerasTabView: View {
    let cameras: [TrafficCamera]
    let isLoading: Bool
    let errorMessage: String?
    let cacheToken: Int
    let hasActiveFilters: Bool
    let onClearFilters: () -> Void
    let onPreview: (TrafficCamera) -> Void
    var onRetry: (() -> Void)?
    @FocusState private var focusedID: String?

    private var onlineCount: Int {
        cameras.filter(\.isOnline).count
    }

    private var cameraIDs: [String] {
        cameras.map(\.id)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let errorMessage {
                        ErrorBanner(message: errorMessage, onRetry: onRetry)
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
                                .keyboardNavigable(id: camera.id, in: cameraIDs, focus: $focusedID) {
                                    onPreview(camera)
                                }
                            }
                        }
                    }
                }
                .padding(24)
            }
            .onChange(of: focusedID) { _, newValue in
                keepFocusVisible(newValue, proxy: proxy)
            }
        }
    }
}

// Scroll a keyboard-focused row/card back into view after an arrow-key move so
// it doesn't drift off-screen. Best-effort: a no-op when the id isn't laid out.
@MainActor
func keepFocusVisible(_ id: String?, proxy: ScrollViewProxy) {
    guard let id else {
        return
    }
    proxy.scrollTo(id, anchor: .center)
}


struct RoadEventsTabView: View {
    let events: [RoadEvent]
    let isLoading: Bool
    let errorMessage: String?
    let hasActiveFilters: Bool
    let onClearFilters: () -> Void
    var onRetry: (() -> Void)?
    @FocusState private var focusedID: String?

    private var closures: Int {
        events.filter(\.isClosure).count
    }

    private var delays: Int {
        events.filter(\.hasDelays).count
    }

    private var eventIDs: [String] {
        events.map(\.id)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let errorMessage {
                        ErrorBanner(message: errorMessage, onRetry: onRetry)
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
                                    .keyboardNavigable(id: event.id, in: eventIDs, focus: $focusedID)
                            }
                        }
                    }
                }
                .padding(24)
            }
            .onChange(of: focusedID) { _, newValue in
                keepFocusVisible(newValue, proxy: proxy)
            }
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
    var onRetry: (() -> Void)?
    @FocusState private var focusedID: String?

    private var signIDs: [String] {
        signs.map(\.id)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let errorMessage {
                        ErrorBanner(message: errorMessage, onRetry: onRetry)
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
                                    .keyboardNavigable(id: sign.id, in: signIDs, focus: $focusedID)
                            }
                        }
                    }
                }
                .padding(24)
            }
            .onChange(of: focusedID) { _, newValue in
                keepFocusVisible(newValue, proxy: proxy)
            }
        }
    }
}

struct TravelTimesTabView: View {
    let journeys: [TrafficJourney]
    let isLoading: Bool
    let errorMessage: String?
    let hasActiveFilters: Bool
    let onClearFilters: () -> Void
    var onRetry: (() -> Void)?
    @FocusState private var focusedID: String?

    private var liveJourneyCount: Int {
        journeys.filter(\.hasLiveData).count
    }

    private var slowJourneyCount: Int {
        journeys.filter { journey in
            journey.overallFlowKind == .slow || journey.overallFlowKind == .congested
        }.count
    }

    private var journeyIDs: [String] {
        journeys.map(\.id)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let errorMessage {
                        ErrorBanner(message: errorMessage, onRetry: onRetry)
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
                                    .keyboardNavigable(id: journey.id, in: journeyIDs, focus: $focusedID)
                            }
                        }
                    }
                }
                .padding(24)
            }
            .onChange(of: focusedID) { _, newValue in
                keepFocusVisible(newValue, proxy: proxy)
            }
        }
    }
}

