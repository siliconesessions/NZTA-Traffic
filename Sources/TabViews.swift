import SwiftUI

struct CamerasTabView: View {
    let cameras: [TrafficCamera]
    let isLoading: Bool
    let errorMessage: String?
    let cacheToken: Int
    let imageGeneration: Int
    let hasActiveFilters: Bool
    let onClearFilters: () -> Void
    let onPreview: (TrafficCamera) -> Void
    var onRetry: (() -> Void)?
    @FocusState private var focusedID: String?
    // The grid's current column count, for ↑/↓ to move a row.
    @State private var columns = 1
    @Namespace private var rotorNamespace

    private nonisolated static let minimumCardWidth: CGFloat = 280
    private nonisolated static let gridSpacing: CGFloat = 16

    private var onlineCount: Int {
        cameras.filter(\.isOnline).count
    }

    var body: some View {
        let cameraIDs = cameras.map(\.id)
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
                            StatItem(title: "Total Cameras", value: "\(cameras.count)", tint: .gray),
                            StatItem(title: "Online", value: "\(onlineCount)", tint: .green)
                        ])

                        cameraGrid(ids: cameraIDs)
                    }
                }
                .padding(24)
            }
            .onChange(of: focusedID) { _, newValue in
                keepFocusVisible(newValue, proxy: proxy)
            }
        }
    }

    // The cards, one VoiceOver rotor stop per camera that isn't live.
    private func cameraGrid(ids cameraIDs: [String]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: Self.minimumCardWidth), spacing: Self.gridSpacing)],
            spacing: Self.gridSpacing
        ) {
            ForEach(cameras) { camera in
                CameraCard(camera: camera, cacheToken: cacheToken, imageGeneration: imageGeneration) {
                    onPreview(camera)
                }
                .keyboardFocusable(id: camera.id, focus: $focusedID) {
                    onPreview(camera)
                }
                .accessibilityRotorEntry(id: camera.id, in: rotorNamespace)
            }
        }
        // VoiceOver: jump between cameras that aren't live.
        .accessibilityRotor("Offline Cameras") {
            ForEach(cameras.filter { !$0.isOnline }) { camera in
                AccessibilityRotorEntry(Text(camera.displayName), id: camera.id, in: rotorNamespace)
            }
        }
        .onGeometryChange(for: Int.self) { geometry in
            adaptiveGridColumnCount(
                width: geometry.size.width,
                minimum: Self.minimumCardWidth,
                spacing: Self.gridSpacing
            )
        } action: { count in
            columns = count
        }
        .keyboardNavigation(over: cameraIDs, columns: columns, focus: $focusedID)
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
    @Namespace private var rotorNamespace

    // Closures and delays in force now; upcoming and resolved events are
    // counted separately (resolved ones only appear when "Show resolved" is on).
    private var activeClosures: Int {
        events.filter(\.isActiveClosure).count
    }

    private var activeDelays: Int {
        events.filter { $0.isActive && $0.hasDelays }.count
    }

    private var upcoming: Int {
        events.filter(\.isUpcoming).count
    }

    var body: some View {
        let eventIDs = events.map(\.id)
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
                            StatItem(title: "Total Events", value: "\(events.count)", tint: .gray),
                            StatItem(title: "Active Closures", value: "\(activeClosures)", tint: .red),
                            StatItem(title: "Active Delays", value: "\(activeDelays)", tint: .orange),
                            StatItem(title: "Upcoming", value: "\(upcoming)", tint: .eventUpcoming)
                        ])

                        // NZTA terms of use 3(c): say the feed is notable,
                        // verified events only.
                        Text(AppCredits.notableEventsNotice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        eventList(ids: eventIDs)
                    }
                }
                .padding(24)
            }
            .onChange(of: focusedID) { _, newValue in
                keepFocusVisible(newValue, proxy: proxy)
            }
        }
    }

    private func eventList(ids eventIDs: [String]) -> some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(events) { event in
                RoadEventCard(event: event)
                    .keyboardFocusable(id: event.id, focus: $focusedID)
                    .accessibilityRotorEntry(id: event.id, in: rotorNamespace)
            }
        }
        .keyboardNavigation(over: eventIDs, focus: $focusedID)
        // VoiceOver: jump straight to the closures (and the delays) in
        // force now among hundreds of events.
        .accessibilityRotor("Closures") {
            ForEach(events.filter(\.isActiveClosure)) { event in
                AccessibilityRotorEntry(Text(event.displayTitle), id: event.id, in: rotorNamespace)
            }
        }
        .accessibilityRotor("Delays") {
            ForEach(events.filter { $0.isActive && $0.hasDelays }) { event in
                AccessibilityRotorEntry(Text(event.displayTitle), id: event.id, in: rotorNamespace)
            }
        }
    }
}

struct VMSTabView: View {
    let signs: [VMSSign]
    let isLoading: Bool
    let errorMessage: String?
    let hideEmpty: Bool
    // Signs matching the shared filters that "Hide signs with no active
    // message" is hiding.
    var hiddenBlankCount = 0
    let hasActiveFilters: Bool
    let onClearFilters: () -> Void
    var onShowBlank: (() -> Void)?
    var onRetry: (() -> Void)?
    @FocusState private var focusedID: String?
    @State private var columns = 1

    private nonisolated static let minimumCardWidth: CGFloat = 300
    private nonisolated static let gridSpacing: CGFloat = 16

    // Everything left is blank and the toggle is hiding it: say so, rather
    // than suggesting a refresh.
    private var blankSignsHint: HiddenItemsHint? {
        guard hiddenBlankCount > 0, let onShowBlank else {
            return nil
        }
        let noun = hiddenBlankCount == 1 ? "sign has" : "signs have"
        return HiddenItemsHint(
            message: "\(hiddenBlankCount) \(noun) no message right now.",
            actionTitle: "Show Blank Signs",
            action: onShowBlank
        )
    }

    var body: some View {
        let signIDs = signs.map(\.id)
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
                            onClearFilters: onClearFilters,
                            hiddenByDefault: blankSignsHint
                        )
                    } else {
                        StatsRow(stats: [
                            StatItem(title: hideEmpty ? "Signs With Message" : "Active VMS Signs", value: "\(signs.count)", tint: .orange)
                        ])

                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: Self.minimumCardWidth), spacing: Self.gridSpacing)],
                            spacing: Self.gridSpacing
                        ) {
                            ForEach(signs) { sign in
                                VMSCard(sign: sign)
                                    .keyboardFocusable(id: sign.id, focus: $focusedID)
                            }
                        }
                        .onGeometryChange(for: Int.self) { geometry in
                            adaptiveGridColumnCount(
                                width: geometry.size.width,
                                minimum: Self.minimumCardWidth,
                                spacing: Self.gridSpacing
                            )
                        } action: { count in
                            columns = count
                        }
                        .keyboardNavigation(over: signIDs, columns: columns, focus: $focusedID)
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
    // Journeys matching the shared filters, before the flow chips — the
    // "of 131" in "Showing 9 of 131 journeys".
    var totalCount = 0
    // How many of those the chips hide for having no live data (No Data is
    // off by default).
    var hiddenWithoutLiveData = 0
    let isLoading: Bool
    let errorMessage: String?
    let hasActiveFilters: Bool
    let onClearFilters: () -> Void
    // Turns every flow chip on, No Data included.
    var onShowAll: (() -> Void)?
    var onRetry: (() -> Void)?
    // Auckland motorway congestion as text (see AucklandMotorwaysSection),
    // under the shared filters; empty hides the section.
    var motorways: [CongestionListGroup] = []
    @FocusState private var focusedID: String?

    private var liveJourneyCount: Int {
        journeys.filter(\.hasLiveData).count
    }

    private var slowJourneyCount: Int {
        journeys.filter { journey in
            journey.overallFlowKind == .slow || journey.overallFlowKind == .congested
        }.count
    }

    private var noLiveDataHint: HiddenItemsHint? {
        guard hiddenWithoutLiveData > 0, let onShowAll else {
            return nil
        }
        let subject = hiddenWithoutLiveData == 1 ? "The 1 journey" : "All \(hiddenWithoutLiveData) journeys"
        return HiddenItemsHint(
            message: "\(subject) here \(hiddenWithoutLiveData == 1 ? "has" : "have") no live data right now, and No Data is hidden.",
            actionTitle: "Show All Journeys",
            action: onShowAll
        )
    }

    var body: some View {
        let journeyIDs = journeys.map(\.id)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let errorMessage {
                        ErrorBanner(message: errorMessage, onRetry: onRetry)
                    }

                    if !motorways.isEmpty {
                        AucklandMotorwaysSection(groups: motorways)
                    }

                    if isLoading && journeys.isEmpty {
                        LoadingView(title: "Loading travel times...")
                    } else if journeys.isEmpty {
                        FilterableEmptyState(
                            systemImage: "speedometer",
                            title: "No journeys to show",
                            hasActiveFilters: hasActiveFilters,
                            onClearFilters: onClearFilters,
                            hiddenByDefault: noLiveDataHint
                        )
                    } else {
                        StatsRow(stats: [
                            StatItem(title: "Journeys Shown", value: "\(journeys.count)", tint: .gray),
                            StatItem(title: "With Live Data", value: "\(liveJourneyCount)", tint: .blue),
                            StatItem(title: "Slow / Congested", value: "\(slowJourneyCount)", tint: .orange)
                        ])

                        hiddenJourneysCaption

                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(journeys) { journey in
                                JourneyCard(journey: journey)
                                    .keyboardFocusable(id: journey.id, focus: $focusedID)
                            }
                        }
                        .keyboardNavigation(over: journeyIDs, focus: $focusedID)
                    }
                }
                .padding(24)
            }
            .onChange(of: focusedID) { _, newValue in
                keepFocusVisible(newValue, proxy: proxy)
            }
        }
    }

    // "Showing 9 of 131 journeys · 122 with no live data are hidden [Show
    // All]" whenever the flow chips hide journeys, so the list never quietly
    // shows a fraction of what the sidebar badge counts.
    @ViewBuilder
    private var hiddenJourneysCaption: some View {
        if let caption = journeyVisibilityCaption(
            shown: journeys.count,
            total: totalCount,
            hiddenWithoutLiveData: hiddenWithoutLiveData
        ) {
            HStack(spacing: 8) {
                Image(systemName: "eye.slash")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(caption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let onShowAll {
                    Button("Show All", action: onShowAll)
                        .controlSize(.small)
                        .help("Show every journey, including those with no live data")
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// The Auckland congestion map layer as text: each motorway direction with its
// segments in travel order and their level in words, so the data isn't only
// coloured lines on the map — for VoiceOver, and for anyone who can't tell
// the colours apart. Collapsed by default under a one-line summary.
struct AucklandMotorwaysSection: View {
    let groups: [CongestionListGroup]
    @AppStorage("nzta.travelTimes.showMotorways") private var isExpanded = false

    private var summary: String {
        congestionSummary(groups.flatMap(\.segments))
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(groups) { group in
                    CongestionGroupView(group: group)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                Text("Auckland Motorways")
                    .font(.headline)
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
        .padding(14)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: Radii.card))
        .overlay { CardBorder() }
    }
}

private struct CongestionGroupView: View {
    let group: CongestionListGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(group.title)
                    .font(.subheadline.weight(.semibold))
                Text(group.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 4)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            ForEach(group.segments) { segment in
                HStack(spacing: 10) {
                    Image(systemName: segment.level.symbol)
                        .font(.caption)
                        .foregroundStyle(segment.level.color)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    Text(segment.name ?? segment.displayName)
                        .font(.callout)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(segment.level.label)
                        .font(.callout.weight(segment.level.severityRank >= 2 ? .semibold : .regular))
                        .foregroundStyle(segment.level.severityRank >= 2 ? .primary : .secondary)
                }
                .padding(.vertical, 3)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

// Travel Times › Boards: NZTA's roadside travel-time (TIM) boards as they
// read now, grouped by region north to south. Boards showing nothing are set
// apart in a collapsed list rather than filling the grid with empty cards.
struct TravelTimeBoardsView: View {
    let listing: TIMBoardListing
    // Blank boards matching the shared filters that "Hide blank boards" hides.
    var hiddenBlankCount = 0
    let isLoading: Bool
    let errorMessage: String?
    let hasActiveFilters: Bool
    let onClearFilters: () -> Void
    var onShowBlank: (() -> Void)?
    var onRetry: (() -> Void)?
    @AppStorage("nzta.travelTimes.showBlankBoards") private var showsBlankBoards = false
    @FocusState private var focusedID: String?
    @State private var columns = 1

    private nonisolated static let minimumCardWidth: CGFloat = 300
    private nonisolated static let gridSpacing: CGFloat = 16

    private var isEmpty: Bool {
        listing.groups.isEmpty && listing.blank.isEmpty
    }

    private var blankBoardsHint: HiddenItemsHint? {
        guard hiddenBlankCount > 0, let onShowBlank else {
            return nil
        }
        let noun = hiddenBlankCount == 1 ? "board is" : "boards are"
        return HiddenItemsHint(
            message: "\(hiddenBlankCount) \(noun) blank right now.",
            actionTitle: "Show Blank Boards",
            action: onShowBlank
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let errorMessage {
                        ErrorBanner(message: errorMessage, onRetry: onRetry)
                    }

                    if isLoading && isEmpty {
                        LoadingView(title: "Loading travel-time boards...")
                    } else if isEmpty {
                        FilterableEmptyState(
                            systemImage: "clock",
                            title: "No travel-time boards to show",
                            hasActiveFilters: hasActiveFilters,
                            onClearFilters: onClearFilters,
                            hiddenByDefault: blankBoardsHint
                        )
                    } else {
                        StatsRow(stats: [
                            StatItem(title: "Boards Showing Times", value: "\(listing.showingCount)", tint: .cyan),
                            StatItem(title: "Blank Right Now", value: "\(listing.blank.count + hiddenBlankCount)", tint: .gray)
                        ])

                        ForEach(listing.groups) { group in
                            regionSection(group)
                        }

                        if !listing.blank.isEmpty {
                            blankBoards
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

    private func regionSection(_ group: TIMBoardGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(regionDisplayName(group.region))
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: Self.minimumCardWidth), spacing: Self.gridSpacing, alignment: .top)],
                spacing: Self.gridSpacing
            ) {
                ForEach(group.boards) { sign in
                    TIMCard(sign: sign)
                        .keyboardFocusable(id: sign.id, focus: $focusedID)
                }
            }
            .onGeometryChange(for: Int.self) { geometry in
                adaptiveGridColumnCount(
                    width: geometry.size.width,
                    minimum: Self.minimumCardWidth,
                    spacing: Self.gridSpacing
                )
            } action: { count in
                columns = count
            }
            .keyboardNavigation(over: group.boards.map(\.id), columns: columns, focus: $focusedID)
        }
    }

    // Names only: there's nothing on them to read.
    private var blankBoards: some View {
        DisclosureGroup(isExpanded: $showsBlankBoards) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(listing.blank) { sign in
                    HStack(spacing: 8) {
                        Text(sign.displayName)
                            .font(.callout)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if let region = sign.regionName {
                            Text(regionDisplayName(region))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, 8)
        } label: {
            Text("\(listing.blank.count) blank \(listing.blank.count == 1 ? "board" : "boards")")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: Radii.card))
        .overlay { CardBorder() }
    }
}
