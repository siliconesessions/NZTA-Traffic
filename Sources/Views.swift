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

// The Travel Times tab shows either NZTA's highway journeys or the roadside
// travel-time (TIM) boards.
enum TravelTimesMode: String, CaseIterable, Identifiable {
    case journeys = "Journeys"
    case boards = "Boards"

    var id: String {
        rawValue
    }
}

struct ContentView: View {
    @State private var store: TrafficStore
    @AppStorage(AutoRefreshPolicy.enabledKey) private var autoRefreshEnabled = false
    @AppStorage("nzta.hideEmptyVMS") private var hideEmptyVMS = true
    @AppStorage("nzta.event.showClosures") private var showEventClosures = true
    @AppStorage("nzta.event.showDelays") private var showEventDelays = true
    @AppStorage("nzta.event.showCaution") private var showEventCaution = true
    @AppStorage("nzta.event.showOther") private var showEventOther = true
    @AppStorage("nzta.event.showPlanned") private var showEventPlanned = true
    @AppStorage("nzta.event.showUnplanned") private var showEventUnplanned = true
    // Resolved events stay in the feed for about a day after they end; they
    // are hidden everywhere (lists, map, counts) unless this is on.
    @AppStorage("nzta.showResolvedEvents") private var showResolvedEvents = false
    @AppStorage("nzta.event.island") private var eventIslandFilter: EventIslandFilter = .all
    @AppStorage("nzta.camera.showOnline") private var showCameraOnline = true
    @AppStorage("nzta.camera.showOffline") private var showCameraOffline = true
    @AppStorage("nzta.camera.showMaintenance") private var showCameraMaintenance = true
    @AppStorage("nzta.flow.showFreeFlow") private var showFlowFreeFlow = true
    @AppStorage("nzta.flow.showModerate") private var showFlowModerate = true
    @AppStorage("nzta.flow.showSlow") private var showFlowSlow = true
    @AppStorage("nzta.flow.showCongested") private var showFlowCongested = true
    @AppStorage("nzta.flow.showNoData") private var showFlowNoData = false
    @AppStorage("nzta.map.hideBlankTIM") private var hideBlankTIMSigns = false
    // The "Watching" chip (Cameras, Road Events, Travel Times and their map
    // layers): only what the watchlist covers.
    @AppStorage("nzta.filter.watchingOnly") private var watchingOnly = false
    @SceneStorage("nzta.scene.travelTimesMode") private var travelTimesMode: TravelTimesMode = .journeys
    @SceneStorage("nzta.scene.selectedTab") private var selectedTab: TrafficTab = .cameras
    @SceneStorage("nzta.scene.region") private var selectedRegion = ""
    @State private var selectedCamera: TrafficCamera?
    @State private var mapPosition = MapCameraPosition.region(trafficMapInitialRegion)
    @State private var mapVisibleSpan: MKCoordinateSpan = trafficMapInitialRegion.span
    @SceneStorage("nzta.scene.mapLayer") private var mapSelectedLayer: TrafficMapLayer = .cameras
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // The Highway and Search filters after GlobalFilterToolbar's 300 ms
    // debounce. The toolbar owns the raw text, so typing re-renders only it.
    @State private var debouncedHighway = ""
    @State private var debouncedSearch = ""
    // Bumped to make GlobalFilterToolbar clear its text fields.
    @State private var filterClearRequest = 0
    @AppStorage("nzta.hasSeenWelcome") private var hasSeenWelcome = false
    @State private var showWelcome = false

    // Injectable store so previews/tests can supply one backed by a stubbed
    // API service; defaults to a live store for the app. @MainActor because
    // TrafficStore is main-actor-isolated; the default is built in-body (not as
    // a default argument) to keep that call on the main actor.
    @MainActor init(store: TrafficStore? = nil) {
        _store = State(initialValue: store ?? TrafficStore())
    }

    var body: some View {
        sectionTabs
            .modifier(filterToolbar)
            .frame(minWidth: 980, minHeight: 680)
            .background { tabShortcuts }
            .onChange(of: selectedRegion) {
                reframeMapForRegion()
            }
            .modifier(windowLifecycle)
            // The cards' watch controls edit the store's watchlist.
            .environment(store)
    }

    // The launch refresh, tab requests from the App (a notification click),
    // the welcome sheet and the camera preview sheet.
    private var windowLifecycle: some ViewModifier {
        ContentWindowLifecycle(
            store: store,
            selectedTab: $selectedTab,
            selectedCamera: $selectedCamera,
            showWelcome: $showWelcome,
            hasSeenWelcome: hasSeenWelcome,
            onFinishWelcome: finishWelcome
        )
    }

    private var filterToolbar: GlobalFilterToolbar {
        GlobalFilterToolbar(
            store: store,
            selectedRegion: $selectedRegion,
            debouncedHighway: $debouncedHighway,
            debouncedSearch: $debouncedSearch,
            scopedFilterSummary: scopedFilterSummary(visibleScopedSection),
            clearRequest: filterClearRequest,
            onClearAll: clearAllFilters
        )
    }
}

// ContentView's window-level behaviour, kept out of its body so that stays
// small for the type-checker.
private struct ContentWindowLifecycle: ViewModifier {
    let store: TrafficStore
    @Binding var selectedTab: TrafficTab
    @Binding var selectedCamera: TrafficCamera?
    @Binding var showWelcome: Bool
    let hasSeenWelcome: Bool
    let onFinishWelcome: (Bool) -> Void
    @Environment(AppNavigator.self) private var navigator: AppNavigator?
    @Environment(\.openWindow) private var openWindow

    // Data older than this is refreshed when the window (re)appears.
    private static let reopenRefreshAge: TimeInterval = 120

    func body(content: Content) -> some View {
        content
            .task {
                // The App starts the launch load (saved data, then live) and owns
                // auto-refresh and the Dock badge, so none of that depends on this
                // window. Reopening the window after a while shows fresh data.
                await store.refreshIfStale(maxAge: Self.reopenRefreshAge)
            }
            .onAppear {
                if !hasSeenWelcome {
                    showWelcome = true
                }
                // Lets the App reopen this window (a notification click).
                let openWindow = openWindow
                navigator?.openMainWindow = { openWindow(id: SceneID.main) }
                takeRequestedTab()
            }
            .onChange(of: navigator?.requestedTab) {
                takeRequestedTab()
            }
            .sheet(item: $selectedCamera) { camera in
                CameraPreviewView(
                    camera: camera,
                    cacheToken: store.imageCacheToken,
                    imageGeneration: store.cameraImageGeneration
                )
            }
            .sheet(isPresented: $showWelcome) {
                WelcomeView(onFinish: onFinishWelcome)
            }
    }

    private func takeRequestedTab() {
        guard let navigator, let tab = navigator.requestedTab else {
            return
        }
        selectedTab = tab
        navigator.requestedTab = nil
    }
}

extension ContentView {
    // Turning auto-refresh on here reaches the scheduler the same way the
    // Settings toggle does: through the `nzta.*` default (see AppController).
    private func finishWelcome(enableAutoRefresh: Bool) {
        if enableAutoRefresh {
            autoRefreshEnabled = true
        }
        hasSeenWelcome = true
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

    // The shared Region / Highway / Search filters, as applied.
    private var hasSharedFilters: Bool {
        !selectedRegion.isEmpty || !debouncedHighway.isEmpty || !debouncedSearch.isEmpty
    }

    // Whether anything — the shared filters or this section's own chips — may
    // be hiding results, for a section's empty state.
    private func hasActiveFilters(_ section: ScopedFilterSection) -> Bool {
        hasSharedFilters || scopedFilterSummary(section) != nil
    }

    // Clears the shared filters and the visible section's chips (⌘E, or an
    // empty state's Clear Filters).
    private func clearAllFilters() {
        selectedRegion = ""
        filterClearRequest += 1
        // Clear the debounced copies immediately so results update at once.
        debouncedHighway = ""
        debouncedSearch = ""
        resetScopedFilters(visibleScopedSection)
    }

    // Freshness banner above every tab's content (see FreshnessBanner):
    // offline, couldn't reach NZTA, or saved data on screen while the live
    // load runs. Hidden while everything shown is live. Its age re-renders
    // every 30 s.
    @ViewBuilder
    private var offlineBanner: some View {
        if let banner = store.freshnessBanner {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                OfflineBanner(
                    message: banner.message(relativeTo: context.date),
                    isWarning: banner.isWarning,
                    isUpdating: banner.isUpdating
                )
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
    }

    // Chrome for a tab's scoped (per-section) filter row. No background of
    // its own: it sits in the tab's top safe-area bar, where content
    // scrolling under it gets the system scroll-edge effect.
    private func scopedBar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack {
            content()
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(minHeight: 44)
    }

    // One tab's page: the freshness banner and the tab's scoped filters in a
    // bar under the toolbar, above the section content.
    private func tabPage<Filters: View, Content: View>(
        @ViewBuilder filters: () -> Filters,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let filters = filters()
        return content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.primary.opacity(0.025))
            .safeAreaBar(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    offlineBanner
                    scopedBar { filters }
                }
            }
    }

    // A tab without scoped filters (the Map floats its own over the map, and
    // About has none): only the freshness banner.
    private func plainTabPage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaBar(edge: .top, spacing: 0) {
                offlineBanner
            }
    }

    // Section navigation: a sidebar (collapsible to a tab bar) so the
    // toolbar is free for the filters and actions. Each section's badge is
    // its count (see sectionBadgeText); each tab is its own
    // computed property to keep the expression small for the type-checker.
    private var sectionTabs: some View {
        TabView(selection: $selectedTab) {
            Tab(TrafficTab.cameras.rawValue, systemImage: TrafficTab.cameras.icon, value: TrafficTab.cameras) {
                camerasTab
            }
            .badge(sectionBadge(count: store.cameras.count, section: .cameras))

            Tab(TrafficTab.events.rawValue, systemImage: TrafficTab.events.icon, value: TrafficTab.events) {
                eventsTab
            }
            .badge(sectionBadge(count: store.visibleEventCount(showResolved: showResolvedEvents), section: .events))

            Tab(TrafficTab.vms.rawValue, systemImage: TrafficTab.vms.icon, value: TrafficTab.vms) {
                vmsTab
            }
            .badge(sectionBadge(count: store.vmsSigns.count, section: .vms))

            Tab(TrafficTab.travelTimes.rawValue, systemImage: TrafficTab.travelTimes.icon, value: TrafficTab.travelTimes) {
                travelTimesTab
            }
            .badge(sectionBadge(count: store.journeys.count, section: .journeys))

            Tab(TrafficTab.trafficMap.rawValue, systemImage: TrafficTab.trafficMap.icon, value: TrafficTab.trafficMap) {
                mapTab
            }

            Tab(TrafficTab.about.rawValue, systemImage: TrafficTab.about.icon, value: TrafficTab.about) {
                plainTabPage { AboutView() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }

    private func sectionBadge(count: Int, section: DataSection) -> Text? {
        sectionBadgeText(
            count: count,
            isLoading: store.isLoading(section),
            hasError: store.errors[section] != nil
        )
        .map { Text($0) }
    }

    private var camerasTab: some View {
        tabPage {
            cameraStatusFilters
        } content: {
            CamerasTabView(
                cameras: scopedCameras(),
                isLoading: store.isLoading(.cameras),
                errorMessage: store.errors[.cameras],
                cacheToken: store.imageCacheToken,
                imageGeneration: store.cameraImageGeneration,
                hasActiveFilters: hasActiveFilters(.cameras),
                onClearFilters: clearAllFilters,
                onPreview: { selectedCamera = $0 },
                onRetry: { Task { await store.reload(.cameras) } }
            )
        }
    }

    private var eventsTab: some View {
        tabPage {
            eventImpactFilters
        } content: {
            RoadEventsTabView(
                events: scopedEvents(),
                isLoading: store.isLoading(.events),
                errorMessage: store.errors[.events],
                hasActiveFilters: hasActiveFilters(.events),
                onClearFilters: clearAllFilters,
                onRetry: { Task { await store.reload(.events) } }
            )
        }
    }

    private var vmsTab: some View {
        tabPage {
            EmptyVMSToggleRow(hideEmpty: $hideEmptyVMS)
        } content: {
            let signs = scopedVMSSigns()
            VMSTabView(
                signs: signs,
                isLoading: store.isLoading(.vms),
                errorMessage: store.errors[.vms],
                hideEmpty: hideEmptyVMS,
                hiddenBlankCount: hideEmptyVMS ? sharedVMSSigns().count - signs.count : 0,
                hasActiveFilters: hasActiveFilters(.vms),
                onClearFilters: clearAllFilters,
                onShowBlank: { hideEmptyVMS = false },
                onRetry: { Task { await store.reload(.vms) } }
            )
        }
    }

    private var travelTimesTab: some View {
        tabPage {
            travelTimesFilters
        } content: {
            switch travelTimesMode {
            case .journeys:
                journeysContent
            case .boards:
                boardsContent
            }
        }
    }

    // Journeys or Boards, then that view's own filters.
    private var travelTimesFilters: some View {
        HStack(spacing: 12) {
            Picker("Show", selection: $travelTimesMode) {
                ForEach(TravelTimesMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("NZTA's highway journeys, or the roadside travel-time boards")
            Divider().frame(height: 16)
            switch travelTimesMode {
            case .journeys:
                flowFilters
                WatchingFilterChip(isOn: $watchingOnly)
            case .boards:
                BlankTIMToggleRow(hideBlank: $hideBlankTIMSigns)
            }
        }
    }

    private var boardsContent: some View {
        let shown = scopedTIMSigns()
        let matching = store.filteredTIMSigns(region: selectedRegion, highway: debouncedHighway, search: debouncedSearch)
        return TravelTimeBoardsView(
            listing: timBoardListing(shown, regionOrder: store.canonicalRegions),
            hiddenBlankCount: matching.count - shown.count,
            isLoading: store.isLoading(.timSigns),
            errorMessage: store.errors[.timSigns],
            hasActiveFilters: hasActiveFilters(.timSigns),
            onClearFilters: clearAllFilters,
            onShowBlank: { hideBlankTIMSigns = false },
            onRetry: { Task { await store.reload(.timSigns) } }
        )
    }

    private var journeysContent: some View {
        Group {
            let all = sharedJourneys()
            let noDataHidden = showFlowNoData ? 0 : all.filter { $0.overallFlowKind == .noData }.count
            TravelTimesTabView(
                journeys: scopedJourneys(),
                totalCount: all.count,
                hiddenWithoutLiveData: noDataHidden,
                isLoading: store.isLoading(.journeys),
                errorMessage: store.errors[.journeys],
                hasActiveFilters: hasActiveFilters(.flow),
                onClearFilters: clearAllFilters,
                onShowAll: showAllJourneys,
                onRetry: { Task { await store.reload(.journeys) } },
                motorways: motorwayGroups()
            )
        }
    }

    // Travel Times' "Show All": every flow chip on, No Data included.
    private func showAllJourneys() {
        showFlowFreeFlow = true
        showFlowModerate = true
        showFlowSlow = true
        showFlowCongested = true
        showFlowNoData = true
    }

    private var mapTab: some View {
        plainTabPage {
            TrafficMapTabView(
                cameras: mapSelectedLayer == .cameras ? scopedCameras() : [],
                events: mapSelectedLayer == .events ? scopedEvents() : [],
                vmsSigns: mapSelectedLayer == .vms ? scopedVMSSigns() : [],
                flowSegments: mapSelectedLayer == .flow ? mapFlowSegments() : [],
                flowLegCount: mapSelectedLayer == .flow ? mapFlowLegCounts().total : 0,
                timSigns: mapSelectedLayer == .timSigns ? scopedTIMSigns() : [],
                evChargers: mapSelectedLayer == .evChargers ? scopedEVChargers() : [],
                congestion: mapSelectedLayer == .congestion ? scopedCongestion() : [],
                isLoading: mapLayerIsLoading,
                errorMessage: mapLayerErrorMessage,
                position: $mapPosition,
                visibleSpan: $mapVisibleSpan,
                selectedLayer: $mapSelectedLayer,
                onCameraPreview: { selectedCamera = $0 },
                onRetry: { layer in Task { await reloadMapLayer(layer) } },
                controls: mapTabFilterBar
            )
        }
    }

    private var mapLayerIsLoading: Bool {
        switch mapSelectedLayer {
        case .cameras:
            return store.isLoading(.cameras)
        case .events:
            return store.isLoading(.events)
        case .vms:
            return store.isLoading(.vms)
        case .flow:
            return store.isLoading(.journeys)
        case .timSigns:
            return store.isLoading(.timSigns)
        case .evChargers:
            return store.isLoadingEVChargers
        case .congestion:
            return store.isLoading(.congestion)
        }
    }

    private var mapLayerErrorMessage: String? {
        switch mapSelectedLayer {
        case .cameras:
            return store.errors[.cameras]
        case .events:
            return store.errors[.events]
        case .vms:
            return store.errors[.vms]
        case .flow:
            return store.errors[.journeys]
        case .timSigns:
            return store.errors[.timSigns]
        case .evChargers:
            return store.evChargersError
        case .congestion:
            return store.errors[.congestion]
        }
    }

    // Reload the data source backing the given map layer (per-layer Retry).
    private func reloadMapLayer(_ layer: TrafficMapLayer) async {
        switch layer {
        case .cameras:
            await store.reload(.cameras)
        case .events:
            await store.reload(.events)
        case .vms:
            await store.reload(.vms)
        case .flow:
            await store.reload(.journeys)
        case .timSigns:
            await store.reload(.timSigns)
        case .congestion:
            await store.reload(.congestion)
        case .evChargers:
            await store.reloadEVChargers()
        }
    }

    // The map's floating glass panel, in two rows so the layer's own filters
    // never squeeze the layer picker (at the default 1,180 pt window a single
    // row ran to 1,470 pt): the layer, its counts, Zoom to Results and Reset
    // on top; the layer's chips — or a note on how the shared filters apply
    // to it — underneath.
    private var mapTabFilterBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                mapLayerPicker
                Spacer(minLength: 8)
                mapCountLabels
                Button {
                    frameMapOnResults()
                } label: {
                    Label("Zoom to Results", systemImage: "viewfinder")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Zoom to the layer's filtered results")
                Button {
                    resetMapView()
                } label: {
                    Label("Show All of New Zealand", systemImage: "scope")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Show all of New Zealand")
            }
            mapLayerFilters
        }
    }

    private func resetMapView() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.45)) {
            mapPosition = .region(trafficMapInitialRegion)
        }
    }

    // Frames what the selected layer shows under the current filters; leaves
    // the map alone when none of it has a position (nothing loaded yet).
    private func frameMapOnResults() {
        guard let frame = mapFrame(fitting: mapLayerCoordinates()) else {
            return
        }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.45)) {
            mapPosition = .region(MKCoordinateRegion(frame))
        }
    }

    // Picking a region frames that region's results on the map (so the Map
    // tab opens on them); All Regions goes back to the whole country.
    private func reframeMapForRegion() {
        if selectedRegion.isEmpty {
            resetMapView()
        } else {
            frameMapOnResults()
        }
    }

    // Every position the selected layer would draw under the current filters.
    private func mapLayerCoordinates() -> [CLLocationCoordinate2D] {
        switch mapSelectedLayer {
        case .cameras:
            return scopedCameras().compactMap(\.mapCoordinate)
        case .events:
            return scopedEvents().compactMap(\.mapCoordinate)
        case .vms:
            return scopedVMSSigns().compactMap(\.mapCoordinate)
        case .flow:
            return mapFlowSegments().flatMap(\.coordinates)
        case .timSigns:
            return scopedTIMSigns().compactMap(\.mapCoordinate)
        case .evChargers:
            return scopedEVChargers().compactMap(\.mapCoordinate)
        case .congestion:
            return scopedCongestion().flatMap(\.polyline)
        }
    }

    // Segmented while it fits, a pop-up menu in a narrower window. Laid out
    // first in its row, so it is offered all the width the counts leave.
    private var mapLayerPicker: some View {
        ViewThatFits(in: .horizontal) {
            mapLayerPickerContent(fullNames: false)
                .pickerStyle(.segmented)
                .fixedSize()
            mapLayerPickerContent(fullNames: true)
                .pickerStyle(.menu)
                .fixedSize()
        }
        .layoutPriority(1)
    }

    private func mapLayerPickerContent(fullNames: Bool) -> some View {
        Picker("Layer", selection: $mapSelectedLayer) {
            ForEach(TrafficMapLayer.allCases) { layer in
                Text(fullNames ? layer.rawValue : layer.pickerLabel).tag(layer)
            }
        }
        .labelsHidden()
        .help(mapSelectedLayer.rawValue)
    }

    private var mapCountLabels: some View {
        let counts = mapCounts
        return HStack(spacing: 12) {
            Label("\(counts.mapped) mapped", systemImage: "mappin.and.ellipse")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()

            if counts.unmapped > 0 {
                Label("\(counts.unmapped) off-map", systemImage: "location.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize()
            }
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
        case .timSigns:
            BlankTIMToggleRow(hideBlank: $hideBlankTIMSigns)
        case .evChargers:
            FilterBarNote(text: "Region places each charger by its location; Highway matches chargers with a state highway address.")
        case .congestion:
            congestionNote
        }
    }

    // The congestion feed is Auckland's motorways only, so another region
    // leaves the layer empty: say why.
    @ViewBuilder
    private var congestionNote: some View {
        if !selectedRegion.isEmpty, !matchesRegion("Auckland", selectedRegion: selectedRegion) {
            FilterBarNote(
                text: "Auckland motorways only — nothing to show for \(selectedRegion).",
                systemImage: "exclamationmark.triangle"
            )
        } else {
            FilterBarNote(text: "Auckland motorways only. Both directions are drawn side by side.")
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
            // Legs, filtered per leg exactly as the map draws them.
            let counts = mapFlowLegCounts()
            return MapCounts(mapped: counts.mapped, total: counts.total)
        case .timSigns:
            let items = scopedTIMSigns()
            let mapped = items.filter { $0.mapCoordinate != nil }.count
            return MapCounts(mapped: mapped, total: items.count)
        case .evChargers:
            let items = scopedEVChargers()
            let mapped = items.filter { $0.mapCoordinate != nil }.count
            return MapCounts(mapped: mapped, total: items.count)
        case .congestion:
            let total = store.congestion.filter {
                $0.matches(region: selectedRegion, highway: debouncedHighway, search: debouncedSearch)
            }.count
            return MapCounts(mapped: scopedCongestion().count, total: total)
        }
    }

    private var cameraStatusFilters: some View {
        HStack(spacing: 8) {
            CameraStatusFilterRow(
                showOnline: $showCameraOnline,
                showOffline: $showCameraOffline,
                showMaintenance: $showCameraMaintenance
            )
            WatchingFilterChip(isOn: $watchingOnly)
        }
    }

    private var eventImpactFilters: some View {
        HStack(spacing: 8) {
            EventImpactFilterRow(
                showClosures: $showEventClosures,
                showDelays: $showEventDelays,
                showCaution: $showEventCaution,
                showOther: $showEventOther,
                showPlanned: $showEventPlanned,
                showUnplanned: $showEventUnplanned,
                showResolved: $showResolvedEvents,
                island: $eventIslandFilter
            )
            WatchingFilterChip(isOn: $watchingOnly)
        }
    }

    // MARK: - Section (chip) filters

    // The chip filters that belong to the visible tab — or, on the Map, to
    // the visible layer.
    private var visibleScopedSection: ScopedFilterSection? {
        switch selectedTab {
        case .cameras:
            return .cameras
        case .events:
            return .events
        case .vms:
            return .vms
        case .travelTimes:
            return travelTimesMode == .boards ? .timSigns : .flow
        case .trafficMap:
            switch mapSelectedLayer {
            case .cameras:
                return .cameras
            case .events:
                return .events
            case .vms:
                return .vms
            case .flow:
                return .flow
            case .timSigns:
                return .timSigns
            case .evChargers, .congestion:
                return nil
            }
        case .about:
            return nil
        }
    }

    // What a section's chips hide beyond its defaults, e.g. "Hidden: Offline,
    // Maintenance" — nil when they're at their defaults. The defaults
    // themselves (No Data journeys, blank VMS signs, resolved events) aren't
    // counted as filtering: the sections explain those where they apply.
    private func scopedFilterSummary(_ section: ScopedFilterSection?) -> String? {
        var hidden: [String] = []
        switch section {
        case .cameras:
            if !showCameraOnline { hidden.append("Online") }
            if !showCameraOffline { hidden.append("Offline") }
            if !showCameraMaintenance { hidden.append("Maintenance") }
            if watchingOnly { hidden.append("cameras you don't watch") }
        case .events:
            if !showEventClosures { hidden.append("Closures") }
            if !showEventDelays { hidden.append("Delays") }
            if !showEventCaution { hidden.append("Caution") }
            if !showEventOther { hidden.append("Other") }
            if !showEventPlanned { hidden.append("Planned") }
            if !showEventUnplanned { hidden.append("Incident") }
            if eventIslandFilter != .all { hidden.append("outside the \(eventIslandFilter.label)") }
            if watchingOnly { hidden.append("roads you don't watch") }
        case .flow:
            if !showFlowFreeFlow { hidden.append("Free Flow") }
            if !showFlowModerate { hidden.append("Moderate") }
            if !showFlowSlow { hidden.append("Slow") }
            if !showFlowCongested { hidden.append("Congested") }
            // The Flow map layer draws every leg; only the journey list
            // applies the Watching chip.
            if watchingOnly, selectedTab == .travelTimes { hidden.append("journeys you don't watch") }
        case .timSigns:
            if hideBlankTIMSigns { hidden.append("blank boards") }
        case .vms, nil:
            break
        }
        return hidden.isEmpty ? nil : "Hidden: " + hidden.joined(separator: ", ")
    }

    // Back to the defaults for everything scopedFilterSummary counts.
    private func resetScopedFilters(_ section: ScopedFilterSection?) {
        switch section {
        case .cameras:
            showCameraOnline = true
            showCameraOffline = true
            showCameraMaintenance = true
            watchingOnly = false
        case .events:
            showEventClosures = true
            showEventDelays = true
            showEventCaution = true
            showEventOther = true
            showEventPlanned = true
            showEventUnplanned = true
            eventIslandFilter = .all
            watchingOnly = false
        case .flow:
            showFlowFreeFlow = true
            showFlowModerate = true
            showFlowSlow = true
            showFlowCongested = true
            watchingOnly = false
        case .timSigns:
            hideBlankTIMSigns = false
        case .vms, nil:
            break
        }
    }

    // MARK: - Slices from the store

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
        store.scopedCameras(
            region: selectedRegion,
            highway: debouncedHighway,
            search: debouncedSearch,
            statuses: allowedCameraStatuses,
            watchingOnly: watchingOnly
        )
    }

    private func scopedEvents() -> [RoadEvent] {
        store.scopedEvents(
            region: selectedRegion,
            highway: debouncedHighway,
            search: debouncedSearch,
            impacts: allowedEventImpacts,
            showPlanned: showEventPlanned,
            showUnplanned: showEventUnplanned,
            showResolved: showResolvedEvents,
            island: eventIslandFilter,
            watchingOnly: watchingOnly
        )
    }

    // VMS signs matching the shared filters, blank ones included.
    private func sharedVMSSigns() -> [VMSSign] {
        store.filteredVMSSigns(region: selectedRegion, highway: debouncedHighway, search: debouncedSearch)
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

    // Journeys matching the shared filters, before the flow chips.
    private func sharedJourneys() -> [TrafficJourney] {
        store.filteredJourneys(region: selectedRegion, highway: debouncedHighway, search: debouncedSearch)
    }

    private func scopedJourneys() -> [TrafficJourney] {
        store.scopedJourneys(
            region: selectedRegion,
            highway: debouncedHighway,
            search: debouncedSearch,
            flows: allowedFlowKinds,
            watchingOnly: watchingOnly
        )
    }

    // The Flow map filters each leg on its own flow (see flowMapSegments).
    private func mapFlowSegments() -> [FlowMapSegment] {
        store.mapFlowSegments(region: selectedRegion, highway: debouncedHighway, search: debouncedSearch, flows: allowedFlowKinds)
    }

    private func mapFlowLegCounts() -> (mapped: Int, total: Int) {
        flowMapLegCounts(for: sharedJourneys(), allowedKinds: allowedFlowKinds)
    }

    private func scopedTIMSigns() -> [TIMSign] {
        store.scopedTIMSigns(region: selectedRegion, highway: debouncedHighway, search: debouncedSearch, hideBlank: hideBlankTIMSigns)
    }

    private func scopedEVChargers() -> [EVCharger] {
        store.filteredEVChargers(region: selectedRegion, highway: debouncedHighway, search: debouncedSearch)
    }

    // Auckland congestion as text for Travel Times, under the shared
    // filters, in the feed's travel order (see congestionListGroups).
    private func motorwayGroups() -> [CongestionListGroup] {
        let shown = Set(scopedCongestion().map(\.id))
        return congestionListGroups(store.congestion) { shown.contains($0.id) }
    }

    private func scopedCongestion() -> [CongestionSegment] {
        store.filteredCongestion(region: selectedRegion, highway: debouncedHighway, search: debouncedSearch)
    }
}

// A group of per-section chip filters. The Map shares the tabs' chips for
// its cameras, events, VMS and flow layers, and has its own for TIM boards.
private enum ScopedFilterSection {
    case cameras
    case events
    case vms
    case flow
    case timSigns
}


#if DEBUG
// Runs against `TrafficStore.preview()` (PreviewSupport.swift): canned sample
// data served in-process, no live network, and no offline-cache writes.
#Preview("Main window") {
    ContentView(store: .preview())
}
#endif
