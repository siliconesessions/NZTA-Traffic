import AppKit
import MapKit
import SwiftUI

enum TrafficTab: String, CaseIterable, Identifiable {
    case cameras = "Traffic Cameras"
    case events = "Road Events"
    case vms = "VMS Signs"
    case travelTimes = "Travel Times"
    case trafficMap = "Map"
    case about = "About"

    var id: String {
        rawValue
    }

    var icon: String {
        switch self {
        case .cameras:
            return "video"
        case .events:
            return "exclamationmark.triangle"
        case .vms:
            return "signpost.right"
        case .travelTimes:
            return "speedometer"
        case .trafficMap:
            return "map"
        case .about:
            return "info.circle"
        }
    }
}

struct ContentView: View {
    @State private var store: TrafficStore
    @AppStorage("nzta.autoRefreshEnabled") private var autoRefreshEnabled = false
    @AppStorage("nzta.refreshIntervalSeconds") private var refreshIntervalSeconds = 120
    @AppStorage("nzta.hideEmptyVMS") private var hideEmptyVMS = true
    @AppStorage("nzta.event.showClosures") private var showEventClosures = true
    @AppStorage("nzta.event.showDelays") private var showEventDelays = true
    @AppStorage("nzta.event.showCaution") private var showEventCaution = true
    @AppStorage("nzta.event.showOther") private var showEventOther = true
    @AppStorage("nzta.event.showPlanned") private var showEventPlanned = true
    @AppStorage("nzta.event.showUnplanned") private var showEventUnplanned = true
    @AppStorage("nzta.event.island") private var eventIslandFilter: EventIslandFilter = .all
    @AppStorage("nzta.camera.showOnline") private var showCameraOnline = true
    @AppStorage("nzta.camera.showOffline") private var showCameraOffline = true
    @AppStorage("nzta.camera.showMaintenance") private var showCameraMaintenance = true
    @AppStorage("nzta.flow.showFreeFlow") private var showFlowFreeFlow = true
    @AppStorage("nzta.flow.showModerate") private var showFlowModerate = true
    @AppStorage("nzta.flow.showSlow") private var showFlowSlow = true
    @AppStorage("nzta.flow.showCongested") private var showFlowCongested = true
    @AppStorage("nzta.flow.showNoData") private var showFlowNoData = false
    @SceneStorage("nzta.scene.selectedTab") private var selectedTab: TrafficTab = .cameras
    @SceneStorage("nzta.scene.region") private var selectedRegion = ""
    @SceneStorage("nzta.scene.highway") private var highwayFilter = ""
    @SceneStorage("nzta.scene.search") private var searchFilter = ""
    @State private var selectedCamera: TrafficCamera?
    @State private var autoRefreshTask: Task<Void, Never>?
    @State private var mapPosition = MapCameraPosition.region(trafficMapInitialRegion)
    @State private var mapVisibleSpan: MKCoordinateSpan = trafficMapInitialRegion.span
    @SceneStorage("nzta.scene.mapLayer") private var mapSelectedLayer: TrafficMapLayer = .cameras
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var debouncedHighway = ""
    @State private var debouncedSearch = ""
    @State private var filterDebounceTask: Task<Void, Never>?
    @AppStorage("nzta.hasSeenWelcome") private var hasSeenWelcome = false
    @FocusState private var searchFocused: Bool
    @State private var showWelcome = false

    // Injectable store so previews/tests can supply one backed by a stubbed
    // API service; defaults to a live store for the app. @MainActor because
    // TrafficStore is main-actor-isolated; the default is built in-body (not as
    // a default argument) to keep that call on the main actor.
    @MainActor init(store: TrafficStore? = nil) {
        _store = State(initialValue: store ?? TrafficStore())
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filters
            Divider()
            sectionTabs
        }
        .frame(minWidth: 980, minHeight: 680)
        .background(Color.primary.opacity(0.025))
        .background(tabShortcuts)
        .background(searchFocusShortcut)
        .task {
            await store.loadAllData()
        }
        .onAppear {
            refreshIntervalSeconds = clampedRefreshInterval
            // Seed the debounced filters from any @SceneStorage-restored values.
            debouncedHighway = highwayFilter
            debouncedSearch = searchFilter
            configureAutoRefresh()
            if !hasSeenWelcome {
                showWelcome = true
            }
        }
        .onDisappear {
            autoRefreshTask?.cancel()
            filterDebounceTask?.cancel()
        }
        .onChange(of: autoRefreshEnabled) {
            configureAutoRefresh()
        }
        .onChange(of: refreshIntervalSeconds) {
            refreshIntervalSeconds = clampedRefreshInterval
            configureAutoRefresh()
        }
        .onChange(of: highwayFilter) {
            scheduleFilterDebounce()
        }
        .onChange(of: searchFilter) {
            scheduleFilterDebounce()
        }
        .onChange(of: store.criticalAlertCount, initial: true) { _, count in
            updateDockBadge(count)
        }
        .sheet(item: $selectedCamera) { camera in
            CameraPreviewView(camera: camera, cacheToken: store.imageCacheToken)
        }
        .sheet(isPresented: $showWelcome) {
            WelcomeView(onFinish: finishWelcome)
        }
    }

    // Show a Dock badge with the active-closure count (or clear it).
    private func updateDockBadge(_ count: Int) {
        NSApplication.shared.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    private func finishWelcome(enableAutoRefresh: Bool) {
        if enableAutoRefresh {
            autoRefreshEnabled = true
            configureAutoRefresh()
        }
        hasSeenWelcome = true
    }

    // Hidden control: ⌘F moves focus to the search field.
    private var searchFocusShortcut: some View {
        Button("") { searchFocused = true }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    private var clampedRefreshInterval: Int {
        min(600, max(30, refreshIntervalSeconds))
    }

    // Hidden buttons that bind ⌘1…⌘6 to each tab. They stay in the hierarchy so
    // their keyboard shortcuts are active, but are not visible or focusable.
    private var tabShortcuts: some View {
        ForEach(Array(TrafficTab.allCases.enumerated()), id: \.element) { index, tab in
            Button("") { selectedTab = tab }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    private var hasActiveFilters: Bool {
        !selectedRegion.isEmpty || !highwayFilter.isEmpty || !searchFilter.isEmpty
    }

    private var activeFilterSummary: String {
        var parts: [String] = []
        if !selectedRegion.isEmpty { parts.append("Region: \(selectedRegion)") }
        if !highwayFilter.isEmpty { parts.append("Highway: \(highwayFilter)") }
        if !searchFilter.isEmpty { parts.append("Search: \(searchFilter)") }
        return parts.isEmpty ? "No active filters" : parts.joined(separator: " · ")
    }

    private func clearAllFilters() {
        selectedRegion = ""
        highwayFilter = ""
        searchFilter = ""
        // Clear the debounced copies immediately so results update at once.
        filterDebounceTask?.cancel()
        debouncedHighway = ""
        debouncedSearch = ""
    }

    // Coalesce rapid keystrokes in the highway/search fields so filtering and
    // sorting run at most once per 300 ms of typing rather than per keystroke.
    private func scheduleFilterDebounce() {
        filterDebounceTask?.cancel()
        filterDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else {
                return
            }
            debouncedHighway = highwayFilter
            debouncedSearch = searchFilter
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    DataSectionPill(
                        icon: "video.fill",
                        label: "Cameras",
                        count: store.cameras.count,
                        isLoading: store.isLoading(.cameras),
                        hasError: store.errors[.cameras] != nil
                    )
                    DataSectionPill(
                        icon: "exclamationmark.triangle.fill",
                        label: "Events",
                        count: store.events.count,
                        isLoading: store.isLoading(.events),
                        hasError: store.errors[.events] != nil
                    )
                    DataSectionPill(
                        icon: "signpost.right.fill",
                        label: "VMS",
                        count: store.vmsSigns.count,
                        isLoading: store.isLoading(.vms),
                        hasError: store.errors[.vms] != nil
                    )
                    DataSectionPill(
                        icon: "speedometer",
                        label: "Travel",
                        count: store.journeys.count,
                        isLoading: store.isLoading(.journeys),
                        hasError: store.errors[.journeys] != nil
                    )
                }

                Spacer()

                HStack(spacing: 4) {
                    if store.isRefreshing {
                        Text("Refreshing…")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.blue)
                    } else {
                        if isDataStale {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .help("Data may be stale — refresh to update")
                        }
                        Text("Updated")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(lastUpdatedText)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(isDataStale ? .orange : .primary)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)

            ProgressView(value: store.loadProgress)
                .progressViewStyle(.linear)
                .tint(.blue)
                .opacity(store.isRefreshing ? 1 : 0)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: store.isRefreshing)
                .padding(.horizontal, 20)
                .padding(.bottom, 4)
        }
        .background(.background)
    }

    private var lastUpdatedText: String {
        guard let lastUpdated = store.lastUpdated else {
            return "Not yet"
        }
        return lastUpdated.formatted(.relative(presentation: .named))
    }

    // Considered stale after 10 minutes without a completed refresh. Recomputed
    // on each render (e.g. when auto-refresh ticks or the user interacts).
    private var isDataStale: Bool {
        guard let lastUpdated = store.lastUpdated, !store.isRefreshing else {
            return false
        }
        return Date().timeIntervalSince(lastUpdated) > 600
    }

    private var filters: some View {
        HStack(spacing: 10) {
            Picker("Region", selection: $selectedRegion) {
                Text("All Regions").tag("")
                ForEach(store.allRegions, id: \.self) { region in
                    Text(region).tag(region)
                }
            }
            .labelsHidden()
            .frame(width: 180)

            TextField("Highway (e.g. SH1)", text: $highwayFilter)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 120, maxWidth: 200)

            TextField("Search locations", text: $searchFilter)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 180, maxWidth: 360)
                .focused($searchFocused)

            if hasActiveFilters {
                Label("Filtered", systemImage: "line.3.horizontal.decrease.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .help(activeFilterSummary)
            }

            Button {
                clearAllFilters()
            } label: {
                Image(systemName: "xmark.circle")
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(!hasActiveFilters)
            .help("Clear all filters (⌘E)")

            Button {
                Task {
                    await store.loadAllData(bustImageCache: true)
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(store.isRefreshing)
            .help(store.isRefreshing ? "Refreshing…" : "Refresh now (⌘R)")

            Spacer(minLength: 8)

            autoRefreshMenu
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.background)
    }

    private var autoRefreshMenu: some View {
        Menu {
            Toggle("Enable Auto-refresh", isOn: $autoRefreshEnabled)
            Divider()
            Picker("Interval", selection: $refreshIntervalSeconds) {
                Text("30 seconds").tag(30)
                Text("1 minute").tag(60)
                Text("2 minutes").tag(120)
                Text("5 minutes").tag(300)
                Text("10 minutes").tag(600)
            }
            .disabled(!autoRefreshEnabled)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: autoRefreshEnabled
                      ? "arrow.triangle.2.circlepath.circle.fill"
                      : "arrow.triangle.2.circlepath.circle")
                    .foregroundStyle(autoRefreshEnabled ? Color.blue : .secondary)
                if autoRefreshEnabled {
                    Text(autoRefreshIntervalLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(autoRefreshEnabled
              ? "Auto-refresh every \(autoRefreshIntervalLabel)"
              : "Auto-refresh off")
    }

    private var autoRefreshIntervalLabel: String {
        let seconds = clampedRefreshInterval
        if seconds < 60 {
            return "\(seconds)s"
        }
        if seconds % 60 == 0 {
            return "\(seconds / 60)m"
        }
        return "\(seconds)s"
    }

    // Chrome for a tab's scoped (per-section) filter row.
    private func scopedBar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack {
            content()
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(minHeight: 48)
        .padding(.vertical, 4)
        .background(.background)
    }

    // One TabView page: its scoped filter bar above the section content.
    @ViewBuilder
    private func tabContainer<Filters: View, Content: View>(
        _ tab: TrafficTab,
        @ViewBuilder filters: () -> Filters,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            scopedBar { filters() }
            Divider()
            content()
        }
        .tabItem { Label(tab.rawValue, systemImage: tab.icon) }
        .tag(tab)
    }

    // Section navigation. Each tab is its own computed property to keep the
    // body expression small enough for the type-checker.
    private var sectionTabs: some View {
        TabView(selection: $selectedTab) {
            camerasTab
            eventsTab
            vmsTab
            travelTimesTab
            mapTab
            AboutView()
                .tabItem { Label(TrafficTab.about.rawValue, systemImage: TrafficTab.about.icon) }
                .tag(TrafficTab.about)
        }
    }

    private var camerasTab: some View {
        tabContainer(.cameras) {
            cameraStatusFilters
        } content: {
            CamerasTabView(
                cameras: scopedCameras(),
                isLoading: store.isLoading(.cameras),
                errorMessage: store.errors[.cameras],
                cacheToken: store.imageCacheToken,
                hasActiveFilters: hasActiveFilters,
                onClearFilters: clearAllFilters,
                onPreview: { selectedCamera = $0 }
            )
        }
    }

    private var eventsTab: some View {
        tabContainer(.events) {
            eventImpactFilters
        } content: {
            RoadEventsTabView(
                events: scopedEvents(),
                isLoading: store.isLoading(.events),
                errorMessage: store.errors[.events],
                hasActiveFilters: hasActiveFilters,
                onClearFilters: clearAllFilters
            )
        }
    }

    private var vmsTab: some View {
        tabContainer(.vms) {
            EmptyVMSToggleRow(hideEmpty: $hideEmptyVMS)
        } content: {
            VMSTabView(
                signs: scopedVMSSigns(),
                isLoading: store.isLoading(.vms),
                errorMessage: store.errors[.vms],
                hideEmpty: hideEmptyVMS,
                hasActiveFilters: hasActiveFilters,
                onClearFilters: clearAllFilters
            )
        }
    }

    private var travelTimesTab: some View {
        tabContainer(.travelTimes) {
            flowFilters
        } content: {
            TravelTimesTabView(
                journeys: scopedJourneys(),
                isLoading: store.isLoading(.journeys),
                errorMessage: store.errors[.journeys],
                hasActiveFilters: hasActiveFilters,
                onClearFilters: clearAllFilters
            )
        }
    }

    private var mapTab: some View {
        tabContainer(.trafficMap) {
            mapTabFilterBar
        } content: {
            TrafficMapTabView(
                cameras: scopedCameras(),
                events: scopedEvents(),
                vmsSigns: scopedVMSSigns(),
                journeys: scopedJourneys(),
                camerasLoading: store.isLoading(.cameras),
                eventsLoading: store.isLoading(.events),
                vmsLoading: store.isLoading(.vms),
                journeysLoading: store.isLoading(.journeys),
                cameraErrorMessage: store.errors[.cameras],
                eventErrorMessage: store.errors[.events],
                vmsErrorMessage: store.errors[.vms],
                journeyErrorMessage: store.errors[.journeys],
                position: $mapPosition,
                visibleSpan: $mapVisibleSpan,
                selectedLayer: $mapSelectedLayer,
                onCameraPreview: { selectedCamera = $0 }
            )
        }
    }

    private var mapTabFilterBar: some View {
        let counts = mapCounts
        return HStack(spacing: 12) {
            Picker("Layer", selection: $mapSelectedLayer) {
                Text("Cameras").tag(TrafficMapLayer.cameras)
                Text("Events").tag(TrafficMapLayer.events)
                Text("VMS").tag(TrafficMapLayer.vms)
                Text("Flow").tag(TrafficMapLayer.flow)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 280)

            mapLayerFilters

            Spacer()

            Label("\(counts.mapped) mapped", systemImage: "mappin.and.ellipse")
                .font(.caption)
                .foregroundStyle(.secondary)

            if counts.unmapped > 0 {
                Label("\(counts.unmapped) off-map", systemImage: "location.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Button {
                mapPosition = .region(trafficMapInitialRegion)
            } label: {
                Image(systemName: "scope")
            }
            .help("Reset map view")
        }
    }

    @ViewBuilder
    private var mapLayerFilters: some View {
        switch mapSelectedLayer {
        case .cameras:
            cameraStatusFilters
        case .events:
            eventImpactFilters
        case .vms:
            EmptyVMSToggleRow(hideEmpty: $hideEmptyVMS)
        case .flow:
            flowFilters
        }
    }

    private var flowFilters: some View {
        FlowFilterRow(
            showFreeFlow: $showFlowFreeFlow,
            showModerate: $showFlowModerate,
            showSlow: $showFlowSlow,
            showCongested: $showFlowCongested,
            showNoData: $showFlowNoData
        )
    }

    private struct MapCounts {
        let mapped: Int
        let total: Int
        var unmapped: Int { total - mapped }
    }

    private var mapCounts: MapCounts {
        switch mapSelectedLayer {
        case .cameras:
            let items = scopedCameras()
            let mapped = items.filter { $0.mapCoordinate != nil }.count
            return MapCounts(mapped: mapped, total: items.count)
        case .events:
            let items = scopedEvents()
            let mapped = items.filter { $0.mapCoordinate != nil }.count
            return MapCounts(mapped: mapped, total: items.count)
        case .vms:
            let items = scopedVMSSigns()
            let mapped = items.filter { $0.mapCoordinate != nil }.count
            return MapCounts(mapped: mapped, total: items.count)
        case .flow:
            let allLegs = scopedJourneys().flatMap(\.legs)
            let mapped = allLegs.filter { !$0.polylineLatitudes.isEmpty }.count
            return MapCounts(mapped: mapped, total: allLegs.count)
        }
    }

    private var cameraStatusFilters: some View {
        CameraStatusFilterRow(
            showOnline: $showCameraOnline,
            showOffline: $showCameraOffline,
            showMaintenance: $showCameraMaintenance
        )
    }

    private var eventImpactFilters: some View {
        EventImpactFilterRow(
            showClosures: $showEventClosures,
            showDelays: $showEventDelays,
            showCaution: $showEventCaution,
            showOther: $showEventOther,
            showPlanned: $showEventPlanned,
            showUnplanned: $showEventUnplanned,
            island: $eventIslandFilter
        )
    }

    private var allowedEventImpacts: Set<EventImpactKind> {
        var set = Set<EventImpactKind>()
        if showEventClosures { set.insert(.closure) }
        if showEventDelays { set.insert(.delays) }
        if showEventCaution { set.insert(.caution) }
        if showEventOther { set.insert(.other) }
        return set
    }

    private var allowedCameraStatuses: Set<CameraStatusKind> {
        var set = Set<CameraStatusKind>()
        if showCameraOnline { set.insert(.online) }
        if showCameraOffline { set.insert(.offline) }
        if showCameraMaintenance { set.insert(.maintenance) }
        return set
    }

    private func scopedCameras() -> [TrafficCamera] {
        store.scopedCameras(region: selectedRegion, highway: debouncedHighway, search: debouncedSearch, statuses: allowedCameraStatuses)
    }

    private func scopedEvents() -> [RoadEvent] {
        store.scopedEvents(
            region: selectedRegion,
            highway: debouncedHighway,
            search: debouncedSearch,
            impacts: allowedEventImpacts,
            showPlanned: showEventPlanned,
            showUnplanned: showEventUnplanned,
            island: eventIslandFilter
        )
    }

    private func scopedVMSSigns() -> [VMSSign] {
        store.scopedVMSSigns(region: selectedRegion, highway: debouncedHighway, search: debouncedSearch, hideEmpty: hideEmptyVMS)
    }

    private var allowedFlowKinds: Set<FlowKind> {
        var set = Set<FlowKind>()
        if showFlowFreeFlow { set.insert(.freeFlow) }
        if showFlowModerate { set.insert(.moderate) }
        if showFlowSlow { set.insert(.slow) }
        if showFlowCongested { set.insert(.congested) }
        if showFlowNoData { set.insert(.noData) }
        return set
    }

    private func scopedJourneys() -> [TrafficJourney] {
        store.scopedJourneys(region: selectedRegion, highway: debouncedHighway, search: debouncedSearch, flows: allowedFlowKinds)
    }

    private func configureAutoRefresh() {
        autoRefreshTask?.cancel()

        guard autoRefreshEnabled else {
            autoRefreshTask = nil
            return
        }

        let seconds = clampedRefreshInterval
        autoRefreshTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(seconds))
                } catch {
                    // Cancelled while sleeping — exit cleanly.
                    return
                }
                await store.loadAllData()
            }
        }
    }
}


struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .previewDisplayName("NZTA Traffic")
    }
}
