import MapKit
import SwiftUI

enum TrafficTab: String, CaseIterable, Identifiable {
    case cameras = "Traffic Cameras"
    case events = "Road Events"
    case vms = "VMS Signs"
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
    @State private var selectedTab: TrafficTab = .cameras
    @State private var selectedRegion = ""
    @State private var highwayFilter = ""
    @State private var searchFilter = ""
    @State private var selectedCamera: TrafficCamera?
    @State private var autoRefreshTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filters
            Divider()
            tabPicker
            Divider()
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
        HStack(spacing: 14) {
            Image(systemName: "car.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text("NZTA Traffic")
                    .font(.title2.weight(.semibold))
                Text("Live cameras, road events, and VMS signs across New Zealand")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if store.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }

            VStack(alignment: .trailing, spacing: 2) {
                Text("Last Updated")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(store.lastUpdated?.formatted(date: .abbreviated, time: .standard) ?? "Not yet")
                    .font(.caption.weight(.medium))
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(.background)
    }

    private var filters: some View {
        HStack(alignment: .bottom, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Region")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker("Region", selection: $selectedRegion) {
                    Text("All Regions").tag("")
                    ForEach(store.allRegions, id: \.self) { region in
                        Text(region).tag(region)
                    }
                }
                .labelsHidden()
                .frame(width: 210)
            }

            FilterTextField(title: "Highway", placeholder: "SH1, SH16", text: $highwayFilter)
                .frame(width: 160)

            FilterTextField(title: "Search", placeholder: "Search locations", text: $searchFilter)
                .frame(minWidth: 240)

            Button {
                Task {
                    await store.loadAllData()
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(store.isRefreshing)

            Spacer(minLength: 10)

            Toggle("Auto-refresh", isOn: $autoRefreshEnabled)
                .toggleStyle(.switch)

            Stepper(value: $refreshIntervalSeconds, in: 30...600, step: 30) {
                Text("\(clampedRefreshInterval) sec")
                    .font(.callout.monospacedDigit())
                    .frame(width: 70, alignment: .trailing)
            }
            .disabled(!autoRefreshEnabled)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.background)
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
                cameras: store.filteredCameras(region: selectedRegion, highway: highwayFilter, search: searchFilter),
                isLoading: store.isLoading(.cameras),
                errorMessage: store.errors[.cameras],
                cacheToken: store.imageCacheToken,
                onPreview: { selectedCamera = $0 }
            )
        case .events:
            RoadEventsTabView(
                events: store.filteredEvents(region: selectedRegion, highway: highwayFilter, search: searchFilter),
                isLoading: store.isLoading(.events),
                errorMessage: store.errors[.events]
            )
        case .vms:
            VMSTabView(
                signs: store.filteredVMSSigns(region: selectedRegion, highway: highwayFilter, search: searchFilter),
                isLoading: store.isLoading(.vms),
                errorMessage: store.errors[.vms]
            )
        case .trafficMap:
            TrafficMapTabView(
                cameras: store.filteredCameras(region: selectedRegion, highway: highwayFilter, search: searchFilter),
                events: store.filteredEvents(region: selectedRegion, highway: highwayFilter, search: searchFilter),
                vmsSigns: store.filteredVMSSigns(region: selectedRegion, highway: highwayFilter, search: searchFilter),
                camerasLoading: store.isLoading(.cameras),
                eventsLoading: store.isLoading(.events),
                vmsLoading: store.isLoading(.vms),
                cameraErrorMessage: store.errors[.cameras],
                eventErrorMessage: store.errors[.events],
                vmsErrorMessage: store.errors[.vms],
                onCameraPreview: { selectedCamera = $0 }
            )
        case .about:
            AboutView()
        }
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

struct FilterTextField: View {
    let title: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
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

private enum TrafficMapLayer: String, CaseIterable, Identifiable {
    case cameras = "Cameras"
    case events = "Road Events"
    case vms = "VMS Signs"

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
        }
    }
}

struct TrafficMapTabView: View {
    let cameras: [TrafficCamera]
    let events: [RoadEvent]
    let vmsSigns: [VMSSign]
    let camerasLoading: Bool
    let eventsLoading: Bool
    let vmsLoading: Bool
    let cameraErrorMessage: String?
    let eventErrorMessage: String?
    let vmsErrorMessage: String?
    let onCameraPreview: (TrafficCamera) -> Void

    @State private var selectedLayer: TrafficMapLayer = .cameras
    @State private var selectedDetail: TrafficMapDetail?
    @State private var position = MapCameraPosition.region(trafficMapInitialRegion)

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
        }
    }

    private var totalCount: Int {
        switch selectedLayer {
        case .cameras:
            return cameras.count
        case .events:
            return events.count
        case .vms:
            return vmsSigns.count
        }
    }

    private var unmappedCount: Int {
        totalCount - features.count
    }

    private var isLoading: Bool {
        switch selectedLayer {
        case .cameras:
            return camerasLoading
        case .events:
            return eventsLoading
        case .vms:
            return vmsLoading
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
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let errorMessage {
                ErrorBanner(message: errorMessage)
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .padding(.bottom, 12)
            }

            TrafficMapStatusBar(
                selectedLayer: $selectedLayer,
                totalCount: totalCount,
                mappedCount: features.count,
                unmappedCount: unmappedCount,
                isLoading: isLoading,
                onReset: {
                    position = .region(trafficMapInitialRegion)
                }
            )

            Divider()

            if isLoading && totalCount == 0 {
                LoadingView(title: selectedLayer.loadingTitle)
            } else if totalCount == 0 {
                EmptyStateView(systemImage: "map", title: selectedLayer.emptyTitle)
            } else if features.isEmpty {
                EmptyStateView(systemImage: "location.slash", title: selectedLayer.noCoordinatesTitle)
            } else {
                Map(position: $position) {
                    ForEach(features) { feature in
                        Annotation(feature.title, coordinate: feature.coordinate, anchor: .bottom) {
                            TrafficMapMarker(feature: feature) {
                                select(feature)
                            }
                        }
                    }
                }
                .mapControls {
                    MapCompass()
                    MapScaleView()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $selectedDetail) { detail in
            TrafficMapDetailView(detail: detail)
        }
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

private struct TrafficMapStatusBar: View {
    @Binding var selectedLayer: TrafficMapLayer
    let totalCount: Int
    let mappedCount: Int
    let unmappedCount: Int
    let isLoading: Bool
    let onReset: () -> Void

    var body: some View {
        HStack(spacing: 18) {
            Picker("Map Layer", selection: $selectedLayer) {
                ForEach(TrafficMapLayer.allCases) { layer in
                    Text(layer.rawValue).tag(layer)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 360)

            Label("\(mappedCount) mapped", systemImage: "mappin.and.ellipse")
                .font(.callout.weight(.medium))

            Label("\(unmappedCount) without coordinates", systemImage: "location.slash")
                .font(.callout)
                .foregroundStyle(unmappedCount == 0 ? Color.secondary : Color.orange)

            Text("\(totalCount) filtered")
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                Text("Refreshing")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Button {
                onReset()
            } label: {
                Label("Reset Map", systemImage: "scope")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.background)
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
                        StatItem(title: "Active VMS Signs", value: "\(signs.count)", tint: .orange)
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
