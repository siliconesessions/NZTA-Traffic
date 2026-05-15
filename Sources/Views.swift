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
}

struct ContentView: View {
    @StateObject private var store = TrafficStore()
    @AppStorage("nzta.autoRefreshEnabled") private var autoRefreshEnabled = false
    @AppStorage("nzta.refreshIntervalSeconds") private var refreshIntervalSeconds = 120
    @AppStorage("nzta.hideEmptyVMS") private var hideEmptyVMS = true
    @AppStorage("nzta.event.showClosures") private var showEventClosures = true
    @AppStorage("nzta.event.showDelays") private var showEventDelays = true
    @AppStorage("nzta.event.showCaution") private var showEventCaution = true
    @AppStorage("nzta.event.showOther") private var showEventOther = true
    @AppStorage("nzta.camera.showOnline") private var showCameraOnline = true
    @AppStorage("nzta.camera.showOffline") private var showCameraOffline = true
    @AppStorage("nzta.camera.showMaintenance") private var showCameraMaintenance = true
    @AppStorage("nzta.flow.showFreeFlow") private var showFlowFreeFlow = true
    @AppStorage("nzta.flow.showModerate") private var showFlowModerate = true
    @AppStorage("nzta.flow.showSlow") private var showFlowSlow = true
    @AppStorage("nzta.flow.showCongested") private var showFlowCongested = true
    @AppStorage("nzta.flow.showNoData") private var showFlowNoData = false
    @State private var selectedTab: TrafficTab = .cameras
    @State private var selectedRegion = ""
    @State private var highwayFilter = ""
    @State private var searchFilter = ""
    @State private var selectedCamera: TrafficCamera?
    @State private var autoRefreshTask: Task<Void, Never>?
    @State private var mapPosition = MapCameraPosition.region(trafficMapInitialRegion)
    @State private var mapVisibleSpan: MKCoordinateSpan = trafficMapInitialRegion.span
    @State private var mapSelectedLayer: TrafficMapLayer = .cameras

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filters
            Divider()
            tabPicker
            Divider()
            if selectedTab != .about {
                scopedFilterBar
                Divider()
            }
            tabContent
        }
        .frame(minWidth: 980, minHeight: 680)
        .background(Color.primary.opacity(0.025))
        .task {
            await store.loadAllData()
        }
        .onAppear {
            refreshIntervalSeconds = clampedRefreshInterval
            configureAutoRefresh()
        }
        .onDisappear {
            autoRefreshTask?.cancel()
        }
        .onChange(of: autoRefreshEnabled) {
            configureAutoRefresh()
        }
        .onChange(of: refreshIntervalSeconds) {
            refreshIntervalSeconds = clampedRefreshInterval
            configureAutoRefresh()
        }
        .sheet(item: $selectedCamera) { camera in
            CameraPreviewView(camera: camera, cacheToken: store.imageCacheToken)
        }
    }

    private var clampedRefreshInterval: Int {
        min(600, max(30, refreshIntervalSeconds))
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
                    Text("Updated")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(lastUpdatedText)
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)

            ProgressView(value: store.loadProgress)
                .progressViewStyle(.linear)
                .tint(.blue)
                .opacity(store.isRefreshing ? 1 : 0)
                .animation(.easeInOut(duration: 0.25), value: store.isRefreshing)
                .padding(.horizontal, 20)
                .padding(.bottom, 4)
        }
        .background(.background)
    }

    private var lastUpdatedText: String {
        guard let lastUpdated = store.lastUpdated else {
            return "Not yet"
        }
        return lastUpdated.formatted(date: .omitted, time: .standard)
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
                .frame(width: 160)

            TextField("Search locations", text: $searchFilter)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 220)

            Button {
                Task {
                    await store.loadAllData()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(store.isRefreshing)
            .help("Refresh now (⌘R)")

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

    private var tabPicker: some View {
        Picker("Section", selection: $selectedTab) {
            ForEach(TrafficTab.allCases) { tab in
                Text(tab.rawValue).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.background)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .cameras:
            CamerasTabView(
                cameras: scopedCameras(),
                isLoading: store.isLoading(.cameras),
                errorMessage: store.errors[.cameras],
                cacheToken: store.imageCacheToken,
                onPreview: { selectedCamera = $0 }
            )
        case .events:
            RoadEventsTabView(
                events: scopedEvents(),
                isLoading: store.isLoading(.events),
                errorMessage: store.errors[.events]
            )
        case .vms:
            VMSTabView(
                signs: scopedVMSSigns(),
                isLoading: store.isLoading(.vms),
                errorMessage: store.errors[.vms],
                hideEmpty: hideEmptyVMS
            )
        case .travelTimes:
            TravelTimesTabView(
                journeys: scopedJourneys(),
                isLoading: store.isLoading(.journeys),
                errorMessage: store.errors[.journeys]
            )
        case .trafficMap:
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
        case .about:
            AboutView()
        }
    }

    private var scopedFilterBar: some View {
        HStack {
            scopedFilterContent
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(height: 48)
        .background(.background)
    }

    @ViewBuilder
    private var scopedFilterContent: some View {
        switch selectedTab {
        case .cameras:
            cameraStatusFilters
        case .events:
            eventImpactFilters
        case .vms:
            EmptyVMSToggleRow(hideEmpty: $hideEmptyVMS)
        case .travelTimes:
            flowFilters
        case .trafficMap:
            mapTabFilterBar
        case .about:
            EmptyView()
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
            showOther: $showEventOther
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
        let base = store.filteredCameras(region: selectedRegion, highway: highwayFilter, search: searchFilter)
        let allowed = allowedCameraStatuses
        return base.filter { allowed.contains($0.statusKind) }
    }

    private func scopedEvents() -> [RoadEvent] {
        let base = store.filteredEvents(region: selectedRegion, highway: highwayFilter, search: searchFilter)
        let allowed = allowedEventImpacts
        return base.filter { allowed.contains($0.impactKind) }
    }

    private func scopedVMSSigns() -> [VMSSign] {
        let base = store.filteredVMSSigns(region: selectedRegion, highway: highwayFilter, search: searchFilter)
        return hideEmptyVMS ? base.filter(\.hasDisplayMessage) : base
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
        let base = store.filteredJourneys(region: selectedRegion, highway: highwayFilter, search: searchFilter)
        let allowed = allowedFlowKinds
        return base.filter { allowed.contains($0.overallFlowKind) }
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
                    try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                } catch {
                    return
                }

                guard !Task.isCancelled else {
                    return
                }

                await store.loadAllData()
            }
        }
    }
}

struct CamerasTabView: View {
    let cameras: [TrafficCamera]
    let isLoading: Bool
    let errorMessage: String?
    let cacheToken: Int
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
                    EmptyStateView(systemImage: "video.slash", title: "No cameras found matching your filters")
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

private let trafficMapInitialRegion = MKCoordinateRegion(
    center: CLLocationCoordinate2D(latitude: -41.2865, longitude: 174.7762),
    span: MKCoordinateSpan(latitudeDelta: 14.5, longitudeDelta: 16.5)
)

enum TrafficMapLayer: String, CaseIterable, Identifiable {
    case cameras = "Cameras"
    case events = "Road Events"
    case vms = "VMS Signs"
    case flow = "Traffic Flow"

    var id: String {
        rawValue
    }

    var loadingTitle: String {
        switch self {
        case .cameras:
            return "Loading traffic cameras..."
        case .events:
            return "Loading road events..."
        case .vms:
            return "Loading VMS signs..."
        case .flow:
            return "Loading travel times..."
        }
    }

    var emptyTitle: String {
        switch self {
        case .cameras:
            return "No cameras found matching your filters"
        case .events:
            return "No road events found matching your filters"
        case .vms:
            return "No VMS signs found matching your filters"
        case .flow:
            return "No journeys found matching your filters"
        }
    }

    var noCoordinatesTitle: String {
        switch self {
        case .cameras:
            return "No filtered cameras have usable map coordinates"
        case .events:
            return "No filtered road events have usable map coordinates"
        case .vms:
            return "No filtered VMS signs have usable map coordinates"
        case .flow:
            return "No filtered journey legs have usable geometry"
        }
    }
}

struct TrafficMapTabView: View {
    let cameras: [TrafficCamera]
    let events: [RoadEvent]
    let vmsSigns: [VMSSign]
    let journeys: [TrafficJourney]
    let camerasLoading: Bool
    let eventsLoading: Bool
    let vmsLoading: Bool
    let journeysLoading: Bool
    let cameraErrorMessage: String?
    let eventErrorMessage: String?
    let vmsErrorMessage: String?
    let journeyErrorMessage: String?
    @Binding var position: MapCameraPosition
    @Binding var visibleSpan: MKCoordinateSpan
    @Binding var selectedLayer: TrafficMapLayer
    let onCameraPreview: (TrafficCamera) -> Void

    @State private var selectedDetail: TrafficMapDetail?

    private var features: [TrafficMapFeature] {
        switch selectedLayer {
        case .cameras:
            return cameras.compactMap { camera in
                guard let coordinate = camera.mapCoordinate else {
                    return nil
                }
                return .camera(camera, coordinate)
            }
        case .events:
            return events.compactMap { event in
                guard let coordinate = event.mapCoordinate else {
                    return nil
                }
                return .event(event, coordinate)
            }
        case .vms:
            return vmsSigns.compactMap { sign in
                guard let coordinate = sign.mapCoordinate else {
                    return nil
                }
                return .vms(sign, coordinate)
            }
        case .flow:
            return []
        }
    }

    private var flowLegs: [FlowLegOverlay] {
        guard selectedLayer == .flow else {
            return []
        }
        var overlays: [FlowLegOverlay] = []
        for journey in journeys {
            for leg in journey.legs {
                guard !leg.polylineLatitudes.isEmpty else {
                    continue
                }
                let key = "\(journey.id)|\(leg.id)"
                overlays.append(
                    FlowLegOverlay(
                        id: key,
                        coordinates: leg.polyline,
                        flowKind: leg.flowKind
                    )
                )
            }
        }
        return overlays
    }

    private var totalCount: Int {
        switch selectedLayer {
        case .cameras:
            return cameras.count
        case .events:
            return events.count
        case .vms:
            return vmsSigns.count
        case .flow:
            return journeys.count
        }
    }

    private var hasMapContent: Bool {
        switch selectedLayer {
        case .cameras, .events, .vms:
            return !features.isEmpty
        case .flow:
            return !flowLegs.isEmpty
        }
    }

    private var isLoading: Bool {
        switch selectedLayer {
        case .cameras:
            return camerasLoading
        case .events:
            return eventsLoading
        case .vms:
            return vmsLoading
        case .flow:
            return journeysLoading
        }
    }

    private var errorMessage: String? {
        switch selectedLayer {
        case .cameras:
            return cameraErrorMessage
        case .events:
            return eventErrorMessage
        case .vms:
            return vmsErrorMessage
        case .flow:
            return journeyErrorMessage
        }
    }

    private enum MapOverlayState {
        case loading(String)
        case empty(String)
        case noCoordinates(String)

        var message: String {
            switch self {
            case .loading(let text), .empty(let text), .noCoordinates(let text):
                return text
            }
        }
    }

    private var mapOverlayState: MapOverlayState? {
        if isLoading && totalCount == 0 {
            return .loading(selectedLayer.loadingTitle)
        }
        if totalCount == 0 {
            return .empty(selectedLayer.emptyTitle)
        }
        if !hasMapContent {
            return .noCoordinates(selectedLayer.noCoordinatesTitle)
        }
        return nil
    }

    @ViewBuilder
    private var mapStatusOverlay: some View {
        if let state = mapOverlayState {
            HStack(spacing: 8) {
                switch state {
                case .loading:
                    ProgressView()
                        .controlSize(.small)
                case .empty:
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                case .noCoordinates:
                    Image(systemName: "location.slash")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                Text(state.message)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(state.message)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let errorMessage {
                ErrorBanner(message: errorMessage)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
            }

            ZStack(alignment: .topLeading) {
                Map(position: $position) {
                    if selectedLayer == .flow {
                        ForEach(flowLegs) { leg in
                            MapPolyline(coordinates: leg.coordinates)
                                .stroke(leg.flowKind.color, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                        }
                    } else {
                        ForEach(mapItems) { item in
                            switch item {
                            case .single(let feature):
                                Annotation(feature.title, coordinate: feature.coordinate, anchor: .bottom) {
                                    TrafficMapMarker(feature: feature) {
                                        select(feature)
                                    }
                                }
                            case .cluster(_, let coordinate, let members):
                                Annotation(
                                    "\(members.count) \(selectedLayer.rawValue.lowercased())",
                                    coordinate: coordinate,
                                    anchor: .center
                                ) {
                                    TrafficMapClusterMarker(count: members.count, layer: selectedLayer) {
                                        zoomIn(toCluster: members)
                                    }
                                }
                            }
                        }
                    }
                }
                .mapControls {
                    MapCompass()
                    MapScaleView()
                }
                .onMapCameraChange(frequency: .onEnd) { context in
                    visibleSpan = context.region.span
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                mapStatusOverlay
                    .padding(16)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $selectedDetail) { detail in
            TrafficMapDetailView(detail: detail)
        }
    }

    private var mapItems: [TrafficMapItem] {
        clusterMapFeatures(features, span: visibleSpan)
    }

    private func select(_ feature: TrafficMapFeature) {
        switch feature {
        case .camera(let camera, _):
            onCameraPreview(camera)
        case .event(let event, _):
            selectedDetail = .event(event)
        case .vms(let sign, _):
            selectedDetail = .vms(sign)
        }
    }

    private func zoomIn(toCluster members: [TrafficMapFeature]) {
        guard !members.isEmpty else {
            return
        }

        var minLatitude = Double.greatestFiniteMagnitude
        var maxLatitude = -Double.greatestFiniteMagnitude
        var minLongitude = Double.greatestFiniteMagnitude
        var maxLongitude = -Double.greatestFiniteMagnitude

        for member in members {
            let coordinate = member.coordinate
            minLatitude = min(minLatitude, coordinate.latitude)
            maxLatitude = max(maxLatitude, coordinate.latitude)
            minLongitude = min(minLongitude, coordinate.longitude)
            maxLongitude = max(maxLongitude, coordinate.longitude)
        }

        let center = CLLocationCoordinate2D(
            latitude: (minLatitude + maxLatitude) / 2,
            longitude: (minLongitude + maxLongitude) / 2
        )

        let bboxLatitude = (maxLatitude - minLatitude) * 1.6
        let bboxLongitude = (maxLongitude - minLongitude) * 1.6
        let targetLatitude = max(min(bboxLatitude, visibleSpan.latitudeDelta * 0.5), 0.01)
        let targetLongitude = max(min(bboxLongitude, visibleSpan.longitudeDelta * 0.5), 0.01)

        withAnimation(.easeInOut(duration: 0.45)) {
            position = .region(MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: targetLatitude, longitudeDelta: targetLongitude)
            ))
        }
    }
}

private enum TrafficMapFeature: Identifiable {
    case camera(TrafficCamera, CLLocationCoordinate2D)
    case event(RoadEvent, CLLocationCoordinate2D)
    case vms(VMSSign, CLLocationCoordinate2D)

    var id: String {
        switch self {
        case .camera(let camera, _):
            return "camera-\(camera.id)"
        case .event(let event, _):
            return "event-\(event.id)"
        case .vms(let sign, _):
            return "vms-\(sign.id)"
        }
    }

    var coordinate: CLLocationCoordinate2D {
        switch self {
        case .camera(_, let coordinate),
             .event(_, let coordinate),
             .vms(_, let coordinate):
            return coordinate
        }
    }

    var title: String {
        switch self {
        case .camera(let camera, _):
            return camera.displayName
        case .event(let event, _):
            return event.displayTitle
        case .vms(let sign, _):
            return sign.displayName
        }
    }

    var subtitle: String? {
        switch self {
        case .camera(let camera, _):
            return camera.routeLine ?? camera.regionName
        case .event(let event, _):
            return event.locationArea ?? event.locations ?? event.regionName
        case .vms(let sign, _):
            return joinNonEmpty([sign.journey?.name ?? sign.way?.name, sign.direction], separator: " - ") ?? sign.regionName
        }
    }

    var statusText: String {
        switch self {
        case .camera(let camera, _):
            if camera.isOnline {
                return "Online"
            }
            return camera.underMaintenance ? "Maintenance" : "Offline"
        case .event(let event, _):
            return event.impact ?? event.eventType ?? "Road Event"
        case .vms(let sign, _):
            return sign.hasDisplayMessage ? "VMS Sign" : "No message"
        }
    }

    var systemImage: String {
        switch self {
        case .camera(let camera, _):
            return camera.isOnline ? "video.fill" : "video.slash"
        case .event:
            return "exclamationmark.triangle.fill"
        case .vms:
            return "signpost.right.fill"
        }
    }

    var tint: Color {
        switch self {
        case .camera(let camera, _):
            if camera.isOnline {
                return .green
            }
            return camera.underMaintenance ? .orange : .red
        case .event(let event, _):
            if event.isClosure {
                return .red
            }
            if event.hasDelays {
                return .orange
            }
            if event.impact?.range(of: "caution", options: .caseInsensitive) != nil {
                return .yellow
            }
            return .gray
        case .vms(let sign, _):
            return sign.hasDisplayMessage ? .blue : .gray
        }
    }
}

private struct FlowLegOverlay: Identifiable {
    let id: String
    let coordinates: [CLLocationCoordinate2D]
    let flowKind: FlowKind
}

private enum TrafficMapItem: Identifiable {
    case single(TrafficMapFeature)
    case cluster(id: String, coordinate: CLLocationCoordinate2D, members: [TrafficMapFeature])

    var id: String {
        switch self {
        case .single(let feature):
            return feature.id
        case .cluster(let id, _, _):
            return id
        }
    }

    var coordinate: CLLocationCoordinate2D {
        switch self {
        case .single(let feature):
            return feature.coordinate
        case .cluster(_, let coordinate, _):
            return coordinate
        }
    }
}

private let clusterDisableSpan: Double = 0.2
private let clusterCellDivisor: Double = 30.0

private func clusterMapFeatures(
    _ features: [TrafficMapFeature],
    span: MKCoordinateSpan
) -> [TrafficMapItem] {
    let maxSpan = max(span.latitudeDelta, span.longitudeDelta)

    guard features.count > 1, maxSpan >= clusterDisableSpan else {
        return features.map { .single($0) }
    }

    let cellSize = maxSpan / clusterCellDivisor
    guard cellSize > 0 else {
        return features.map { .single($0) }
    }

    var buckets: [String: [TrafficMapFeature]] = [:]
    for feature in features {
        let xCell = Int((feature.coordinate.longitude / cellSize).rounded(.down))
        let yCell = Int((feature.coordinate.latitude / cellSize).rounded(.down))
        let key = "\(xCell)|\(yCell)"
        buckets[key, default: []].append(feature)
    }

    return buckets.map { key, members in
        if members.count == 1 {
            return .single(members[0])
        }
        let count = Double(members.count)
        let centroid = CLLocationCoordinate2D(
            latitude: members.reduce(0.0) { $0 + $1.coordinate.latitude } / count,
            longitude: members.reduce(0.0) { $0 + $1.coordinate.longitude } / count
        )
        return .cluster(id: "cluster-\(key)", coordinate: centroid, members: members)
    }
}

private enum TrafficMapDetail: Identifiable {
    case event(RoadEvent)
    case vms(VMSSign)

    var id: String {
        switch self {
        case .event(let event):
            return "event-\(event.id)"
        case .vms(let sign):
            return "vms-\(sign.id)"
        }
    }
}

private struct TrafficMapMarker: View {
    let feature: TrafficMapFeature
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            ZStack {
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(feature.tint)
                    .shadow(color: .black.opacity(0.24), radius: 3, y: 2)

                Image(systemName: feature.systemImage)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(y: -2)
            }
            .frame(width: 38, height: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(feature.title) - \(feature.statusText)")
        .accessibilityLabel("\(feature.title), \(feature.statusText)")
    }
}

private struct TrafficMapClusterMarker: View {
    let count: Int
    let layer: TrafficMapLayer
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            ZStack {
                Circle()
                    .fill(layer.clusterTint)
                Circle()
                    .stroke(Color.white, lineWidth: 2.5)
                Text("\(count)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .monospacedDigit()
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("\(count) \(layer.rawValue.lowercased()) — click to zoom in")
        .accessibilityLabel("\(count) \(layer.rawValue.lowercased())")
    }

    private var diameter: CGFloat {
        switch count {
        case ..<10:
            return 32
        case ..<50:
            return 38
        case ..<200:
            return 44
        default:
            return 50
        }
    }
}

private extension TrafficMapLayer {
    var clusterTint: Color {
        switch self {
        case .cameras:
            return .blue
        case .events:
            return .red
        case .vms:
            return .indigo
        case .flow:
            return .blue
        }
    }
}

private struct TrafficMapDetailView: View {
    let detail: TrafficMapDetail
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }

            ScrollView {
                switch detail {
                case .event(let event):
                    RoadEventCard(event: event)
                case .vms(let sign):
                    VMSCard(sign: sign)
                }
            }
        }
        .padding(20)
        .frame(width: 720, height: 520)
    }

    private var title: String {
        switch detail {
        case .event(let event):
            return event.displayTitle
        case .vms(let sign):
            return sign.displayName
        }
    }
}

struct RoadEventsTabView: View {
    let events: [RoadEvent]
    let isLoading: Bool
    let errorMessage: String?

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
                    EmptyStateView(systemImage: "exclamationmark.triangle", title: "No events found matching your filters")
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let errorMessage {
                    ErrorBanner(message: errorMessage)
                }

                if isLoading && signs.isEmpty {
                    LoadingView(title: "Loading VMS signs...")
                } else if signs.isEmpty {
                    EmptyStateView(systemImage: "signpost.right", title: "No VMS signs found matching your filters")
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
                    EmptyStateView(
                        systemImage: "speedometer",
                        title: "No journeys match your filters"
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

struct JourneyCard: View {
    let journey: TrafficJourney

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(journey.displayName)
                    .font(.headline)

                Spacer()

                if let region = journey.regionName {
                    Badge(text: region, tint: .black)
                }

                Badge(text: journey.overallFlowKind.label, tint: journey.overallFlowKind.color)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            if let summary = summaryLine {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 10)
            } else {
                Spacer().frame(height: 10)
            }

            if !journey.legs.isEmpty {
                Divider()
                ForEach(Array(journey.legs.enumerated()), id: \.offset) { index, leg in
                    JourneyLegRow(leg: leg)
                    if index < journey.legs.count - 1 {
                        Divider()
                    }
                }
            } else {
                Text("No leg data available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    private var summaryLine: String? {
        var parts: [String] = []
        if let current = journey.totalCurrentTime {
            parts.append("Now \(formatTimeInterval(current))")
        }
        if let free = journey.totalFreeFlowTime {
            parts.append("Free flow \(formatTimeInterval(free))")
        }
        if let delay = journey.congestionDelay, delay > 0 {
            parts.append("Delay +\(formatTimeInterval(delay))")
        }
        if let avgSpeed = journey.averageSpeed {
            parts.append("Avg \(Int(avgSpeed.rounded())) km/h")
        }
        if let length = journey.totalLength, length > 0 {
            parts.append(String(format: "%.1f km total", length))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }
}

struct JourneyLegRow: View {
    let leg: TrafficJourneyLeg

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(leg.flowKind.color)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: directionIcon)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(leg.name ?? "Leg")
                        .font(.subheadline)
                        .lineLimit(1)
                }
                if let detail = detailLine {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            HStack(spacing: 14) {
                if let speed = leg.speed, speed > 0 {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(Int(speed.rounded()))")
                            .font(.callout.monospacedDigit())
                        Text("km/h")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if let timeText = currentTimeText {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(timeText)
                            .font(.callout.monospacedDigit().weight(.medium))
                        if let freeText = freeFlowText {
                            Text("free \(freeText)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(minWidth: 56, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var directionIcon: String {
        switch leg.direction?.uppercased() {
        case "I":
            return "arrow.up.right"
        case "D":
            return "arrow.down.left"
        default:
            return "arrow.left.and.right"
        }
    }

    private var detailLine: String? {
        var parts: [String] = []
        if let direction = leg.direction, !direction.isEmpty {
            switch direction.uppercased() {
            case "I":
                parts.append("Increasing")
            case "D":
                parts.append("Decreasing")
            default:
                parts.append(direction)
            }
        }
        if let length = leg.totalLength, length > 0 {
            parts.append(String(format: "%.1f km", length))
        }
        if let limit = leg.effectiveSpeedLimit, limit > 0 {
            parts.append("limit \(Int(limit.rounded())) km/h")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var currentTimeText: String? {
        guard let seconds = leg.currentTimeSeconds else {
            return nil
        }
        return formatTimeInterval(seconds)
    }

    private var freeFlowText: String? {
        guard let seconds = leg.freeFlowTime, seconds > 0 else {
            return nil
        }
        return formatTimeInterval(seconds)
    }
}

struct CameraCard: View {
    let camera: TrafficCamera
    let cacheToken: Int
    let onPreview: () -> Void

    var body: some View {
        Button(action: onPreview) {
            VStack(alignment: .leading, spacing: 0) {
                AsyncImage(url: camera.thumbnailURL(cacheToken: cacheToken)) { phase in
                    ZStack {
                        Rectangle()
                            .fill(Color.primary.opacity(0.08))

                        switch phase {
                        case .empty:
                            ProgressView()
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                        case .failure:
                            CameraPlaceholder(text: camera.isOnline ? "Image unavailable" : "Offline")
                        @unknown default:
                            CameraPlaceholder(text: "Image unavailable")
                        }
                    }
                    .frame(height: 170)
                    .clipped()
                }

                VStack(alignment: .leading, spacing: 9) {
                    Text(camera.displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    if let description = camera.description {
                        Text(description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    if let routeLine = camera.routeLine {
                        Label(routeLine, systemImage: "location.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    HStack(spacing: 8) {
                        if let region = camera.regionName {
                            Badge(text: region, tint: .black)
                        }
                        if !camera.isOnline {
                            Badge(text: camera.underMaintenance ? "Maintenance" : "Offline", tint: .red)
                        }
                    }
                }
                .padding(14)
            }
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

struct CameraPlaceholder: View {
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "video.slash")
                .font(.title2)
            Text(text)
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(.secondary)
    }
}

struct CameraPreviewView: View {
    let camera: TrafficCamera
    let cacheToken: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(camera.displayName)
                        .font(.title3.weight(.semibold))
                    if let description = camera.description {
                        Text(description)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }

            AsyncImage(url: camera.imageURL(cacheToken: cacheToken)) { phase in
                ZStack {
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))

                    switch phase {
                    case .empty:
                        ProgressView()
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                    case .failure:
                        CameraPlaceholder(text: "Image unavailable")
                    @unknown default:
                        CameraPlaceholder(text: "Image unavailable")
                    }
                }
            }
            .frame(minWidth: 760, minHeight: 470)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(20)
    }
}

struct RoadEventCard: View {
    let event: RoadEvent

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(impactColor)
                .frame(width: 5)

            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .top, spacing: 12) {
                    Text(event.displayTitle)
                        .font(.headline)
                        .lineLimit(nil)

                    Spacer()

                    if let impact = event.impact {
                        Badge(text: impact, tint: impactColor)
                    }
                }

                if let location = event.locationArea {
                    Label(location, systemImage: "location.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let comments = event.eventComments {
                    Text(comments)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let alternativeRoute = event.alternativeRouteText {
                    Text("Alternative Route: \(alternativeRoute)")
                        .font(.callout.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                EventMetaGrid(event: event)
            }
            .padding(16)
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    private var impactColor: Color {
        if event.isClosure {
            return .red
        }
        if event.hasDelays {
            return .orange
        }
        if event.impact?.range(of: "caution", options: .caseInsensitive) != nil {
            return .yellow
        }
        return .gray
    }
}

struct EventMetaGrid: View {
    let event: RoadEvent

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), alignment: .leading)], alignment: .leading, spacing: 8) {
            if let eventType = event.eventType {
                SmallMeta(text: eventType, systemImage: "tag")
            }
            if let started = formatTrafficDate(event.startDate) {
                SmallMeta(text: "Started: \(started)", systemImage: "clock")
            }
            if let expected = formatTrafficDate(event.expectedResolution) {
                SmallMeta(text: "Expected: \(expected)", systemImage: "calendar")
            }
            if let source = event.informationSource {
                SmallMeta(text: "Source: \(source)", systemImage: "info.circle")
            }
            if let status = event.status {
                SmallMeta(text: status, systemImage: "checkmark.circle")
            }
        }
    }
}

struct SmallMeta: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }
}

struct VMSCard: View {
    let sign: VMSSign

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Label(sign.displayName, systemImage: "location.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.white.opacity(0.68))
                    .lineLimit(2)
                Spacer()
                if let region = sign.regionName {
                    Text(region)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.58))
                }
            }

            Text(sign.formattedMessage.uppercased())
                .font(.system(size: 21, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(red: 1.0, green: 0.74, blue: 0.18))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 92)
                .lineLimit(nil)

            if let updated = formatTrafficDate(sign.lastMessageUpdate ?? sign.lastUpdate) {
                Text("Updated \(updated)")
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.52))
            }
        }
        .padding(18)
        .background(Color(red: 0.09, green: 0.13, blue: 0.18))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(red: 0.28, green: 0.34, blue: 0.42), lineWidth: 3)
        )
    }
}

struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                AboutSection(title: "About This App") {
                    Text("NZTA Traffic is a native macOS app for monitoring live traffic cameras, road events, and Variable Message Signs across New Zealand. It is designed as a quiet desktop view of operational traffic information, with shared filters and a map view for spatial context.")
                }

                AboutSection(title: "What It Shows") {
                    VStack(alignment: .leading, spacing: 8) {
                        BulletText("Traffic camera thumbnails and full-size camera previews.")
                        BulletText("Road events, including closures, delays, location details, comments, routes, dates, and available metadata.")
                        BulletText("Variable Message Sign content, including travel-time messages and signs that currently have no displayed message.")
                        BulletText("A switchable map layer for cameras, road events, and VMS signs.")
                    }
                }

                AboutSection(title: "Data Sources") {
                    VStack(alignment: .leading, spacing: 8) {
                        BulletText("Traffic Cameras: trafficnz.info/service/traffic/rest/4/cameras/all")
                        BulletText("Road Events: trafficnz.info/service/traffic/rest/4/events/all/10")
                        BulletText("VMS Signs: trafficnz.info/service/traffic/rest/4/signs/vms/all")
                    }
                }

                AboutSection(title: "Updates and Privacy") {
                    Text("The app fetches live data directly with URLSession and refreshes only when you open the app, press Refresh, or enable auto-refresh. It does not collect analytics, create user accounts, or send personal data to an app backend. Map display uses Apple MapKit.")
                }

                AboutSection(title: "Data Notes") {
                    Text("Traffic information can lag behind roadside conditions, camera images can be temporarily unavailable, and some map positions are approximate when the source feed provides line geometry instead of a single point. Use official road signage and instructions when travelling.")
                }

                AboutSection(title: "Attribution") {
                    Text("Traffic and travel information is provided by Waka Kotahi NZ Transport Agency and participating regional councils. This app is an independent viewer for that public data.")
                }

                AboutSection(title: "Help") {
                    Text("Open Help > NZTA Traffic Help from the macOS menu bar for detailed guidance on filters, tabs, map layers, refresh behavior, and troubleshooting.")
                }
            }
            .font(.body)
            .foregroundStyle(.primary)
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }
}

struct AppHelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("NZTA Traffic Help")
                        .font(.largeTitle.weight(.semibold))
                    Text("A guide to using the macOS traffic viewer for cameras, road events, VMS signs, and map layers.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                AboutSection(title: "Purpose") {
                    Text("NZTA Traffic is an information viewer for live traffic data. It is not a navigation system or official travel instruction source. Always follow current road signs, authority instructions, and the conditions in front of you.")
                }

                AboutSection(title: "Shared Controls") {
                    VStack(alignment: .leading, spacing: 8) {
                        BulletText("Region limits cameras, road events, VMS signs, and map layers to the selected region.")
                        BulletText("Highway searches route, journey, way, and location fields such as SH1 or SH16.")
                        BulletText("Search matches names, locations, descriptions, event comments, regions, and VMS message text where available.")
                        BulletText("Refresh reloads all live data sources and refreshes camera image cache tokens.")
                        BulletText("Auto-refresh reloads data every 30 to 600 seconds while enabled.")
                    }
                }

                AboutSection(title: "Traffic Cameras") {
                    VStack(alignment: .leading, spacing: 8) {
                        BulletText("The camera tab shows thumbnails, names, region, route or direction metadata, and offline or maintenance status.")
                        BulletText("Click a camera card, or a camera pin on the map, to open the full-size camera preview.")
                        BulletText("If an image is unavailable, the source camera may be offline, under maintenance, slow to update, or temporarily unavailable.")
                    }
                }

                AboutSection(title: "Road Events") {
                    VStack(alignment: .leading, spacing: 8) {
                        BulletText("Events are sorted by severity so closures and delays appear before lower-impact items.")
                        BulletText("Event cards can include location, impact, comments, alternative routes, dates, source, supplier, and status metadata.")
                        BulletText("Map event pins use red for closures, orange for delays, yellow for caution, and gray for other or unknown impact.")
                        BulletText("Some map positions are approximate because the source feed can provide line geometry rather than a single point.")
                    }
                }

                AboutSection(title: "VMS Signs") {
                    VStack(alignment: .leading, spacing: 8) {
                        BulletText("VMS cards show the current sign message and the source update time when supplied.")
                        BulletText("Message formatting tokens are cleaned up before display, so travel-time rows show readable destinations and values.")
                        BulletText("Signs with no active message display as No message.")
                        BulletText("On the map, blue VMS pins have an active message and gray VMS pins have no active message.")
                    }
                }

                AboutSection(title: "Map") {
                    VStack(alignment: .leading, spacing: 8) {
                        BulletText("Use the map layer control to switch between Cameras, Road Events, and VMS Signs.")
                        BulletText("The shared Region, Highway, and Search filters apply to the active map layer.")
                        BulletText("Mapped shows the number of filtered items with usable coordinates.")
                        BulletText("Without coordinates shows filtered items that cannot be placed on the map.")
                        BulletText("Reset Map returns the map to the initial New Zealand view.")
                    }
                }

                AboutSection(title: "Troubleshooting") {
                    VStack(alignment: .leading, spacing: 8) {
                        BulletText("If a section is empty, clear filters first, then press Refresh.")
                        BulletText("If a section shows an error banner, that live source failed while other loaded sections may still be usable.")
                        BulletText("If a camera preview is stale or missing, press Refresh and check whether the camera is marked offline or maintenance.")
                        BulletText("If a road event is not mapped, the live event may not include usable geometry or coordinates.")
                        BulletText("If macOS blocks the app on first launch, Control-click the app, choose Open, and confirm the prompt.")
                    }
                }

                AboutSection(title: "Data and Privacy") {
                    VStack(alignment: .leading, spacing: 8) {
                        BulletText("Traffic data is requested directly from the NZTA Traffic and Travel REST API v4.")
                        BulletText("The map uses Apple MapKit.")
                        BulletText("The app does not include analytics, accounts, tracking, or an app-specific backend.")
                        BulletText("Last Updated means the app completed a refresh. It does not mean every source item changed at that time.")
                    }
                }
            }
            .font(.body)
            .foregroundStyle(.primary)
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .frame(minWidth: 640, minHeight: 520)
    }
}

struct AboutSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.title3.weight(.semibold))
            content
                .foregroundStyle(.secondary)
                .lineSpacing(3)
        }
    }
}

struct BulletText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .frame(width: 5, height: 5)
                .foregroundStyle(.secondary)
            Text(text)
        }
    }
}

struct StatsRow: View {
    let stats: [StatItem]

    var body: some View {
        HStack(spacing: 14) {
            ForEach(stats) { stat in
                StatCard(stat: stat)
            }
        }
    }
}

struct StatItem: Identifiable {
    let id = UUID()
    let title: String
    let value: String
    let tint: Color
}

struct StatCard: View {
    let stat: StatItem

    var body: some View {
        VStack(spacing: 4) {
            Text(stat.value)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(stat.title)
                .font(.caption.weight(.medium))
                .opacity(0.9)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 14)
        .background(stat.tint)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct Badge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(tint == .yellow ? .black : .white)
            .background(tint)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct FilterChip: View {
    let label: String
    let tint: Color
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.caption)
                    .foregroundStyle(isOn ? tint : .secondary)
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isOn ? .primary : .secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isOn ? tint.opacity(0.15) : Color.primary.opacity(0.05))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct EventImpactFilterRow: View {
    @Binding var showClosures: Bool
    @Binding var showDelays: Bool
    @Binding var showCaution: Bool
    @Binding var showOther: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("Show")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            FilterChip(label: "Closures", tint: .red, isOn: $showClosures)
            FilterChip(label: "Delays", tint: .orange, isOn: $showDelays)
            FilterChip(label: "Caution", tint: .yellow, isOn: $showCaution)
            FilterChip(label: "Other", tint: .gray, isOn: $showOther)
        }
    }
}

struct EmptyVMSToggleRow: View {
    @Binding var hideEmpty: Bool

    var body: some View {
        Toggle("Hide signs with no active message", isOn: $hideEmpty)
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.caption.weight(.medium))
    }
}

struct CameraStatusFilterRow: View {
    @Binding var showOnline: Bool
    @Binding var showOffline: Bool
    @Binding var showMaintenance: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("Show")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            FilterChip(label: "Online", tint: .green, isOn: $showOnline)
            FilterChip(label: "Offline", tint: .red, isOn: $showOffline)
            FilterChip(label: "Maintenance", tint: .orange, isOn: $showMaintenance)
        }
    }
}

struct FlowFilterRow: View {
    @Binding var showFreeFlow: Bool
    @Binding var showModerate: Bool
    @Binding var showSlow: Bool
    @Binding var showCongested: Bool
    @Binding var showNoData: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("Show")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            FilterChip(label: "Free Flow", tint: .green, isOn: $showFreeFlow)
            FilterChip(label: "Moderate", tint: .yellow, isOn: $showModerate)
            FilterChip(label: "Slow", tint: .orange, isOn: $showSlow)
            FilterChip(label: "Congested", tint: .red, isOn: $showCongested)
            FilterChip(label: "No Data", tint: .gray, isOn: $showNoData)
        }
    }
}

extension FlowKind {
    var color: Color {
        switch self {
        case .freeFlow:
            return .green
        case .moderate:
            return .yellow
        case .slow:
            return .orange
        case .congested:
            return .red
        case .noData:
            return .gray
        }
    }
}

struct DataSectionPill: View {
    let icon: String
    let label: String
    let count: Int
    let isLoading: Bool
    let hasError: Bool

    var body: some View {
        HStack(spacing: 6) {
            indicator
            Text(displayCount)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.05))
        .clipShape(Capsule())
        .help(helpText)
    }

    @ViewBuilder
    private var indicator: some View {
        if isLoading {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 12, height: 12)
        } else if hasError {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
        } else {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.blue)
        }
    }

    private var displayCount: String {
        if hasError {
            return "—"
        }
        if isLoading && count == 0 {
            return "…"
        }
        return "\(count)"
    }

    private var helpText: String {
        if hasError {
            return "\(label): failed to load"
        }
        if isLoading {
            return "\(label): loading…"
        }
        return "\(label): \(count) loaded"
    }
}

struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(14)
        .background(Color.red.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.red.opacity(0.25), lineWidth: 1)
        )
    }
}

struct LoadingView: View {
    let title: String

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 360)
    }
}

struct EmptyStateView: View {
    let systemImage: String
    let title: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(.secondary.opacity(0.45))
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 360)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .previewDisplayName("NZTA Traffic")
    }
}
