import MapKit
import SwiftUI

let trafficMapInitialRegion = MKCoordinateRegion(
    center: CLLocationCoordinate2D(latitude: -41.2865, longitude: 174.7762),
    span: MKCoordinateSpan(latitudeDelta: 14.5, longitudeDelta: 16.5)
)

enum TrafficMapLayer: String, CaseIterable, Identifiable {
    case cameras = "Cameras"
    case events = "Road Events"
    case vms = "VMS Signs"
    case flow = "Traffic Flow"
    case timSigns = "Travel Time Signs"
    case evChargers = "EV Chargers"

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
        case .timSigns:
            return "Loading travel time signs..."
        case .evChargers:
            return "Loading EV chargers..."
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
        case .timSigns:
            return "No travel time signs found matching your filters"
        case .evChargers:
            return "No EV chargers available"
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
        case .timSigns:
            return "No filtered travel time signs have usable map coordinates"
        case .evChargers:
            return "No EV chargers have usable map coordinates"
        }
    }
}

struct TrafficMapTabView: View {
    let cameras: [TrafficCamera]
    let events: [RoadEvent]
    let vmsSigns: [VMSSign]
    let journeys: [TrafficJourney]
    let timSigns: [TIMSign]
    let evChargers: [EVCharger]
    let camerasLoading: Bool
    let eventsLoading: Bool
    let vmsLoading: Bool
    let journeysLoading: Bool
    let timSignsLoading: Bool
    let evChargersLoading: Bool
    let cameraErrorMessage: String?
    let eventErrorMessage: String?
    let vmsErrorMessage: String?
    let journeyErrorMessage: String?
    let timSignsErrorMessage: String?
    let evChargersErrorMessage: String?
    @Binding var position: MapCameraPosition
    @Binding var visibleSpan: MKCoordinateSpan
    @Binding var selectedLayer: TrafficMapLayer
    let onCameraPreview: (TrafficCamera) -> Void

    @State private var selectedDetail: TrafficMapDetail?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        case .timSigns:
            return timSigns.compactMap { sign in
                guard let coordinate = sign.mapCoordinate else {
                    return nil
                }
                return .tim(sign, coordinate)
            }
        case .evChargers:
            return evChargers.compactMap { charger in
                guard let coordinate = charger.mapCoordinate else {
                    return nil
                }
                return .evCharger(charger, coordinate)
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

    private var journeyRoutes: [FlowRouteOverlay] {
        guard selectedLayer == .flow else {
            return []
        }
        return journeys.compactMap { journey in
            let coordinates = journey.routePolyline
            guard coordinates.count >= 2 else {
                return nil
            }
            return FlowRouteOverlay(
                id: "route|\(journey.id)",
                coordinates: coordinates,
                flowKind: journey.overallFlowKind
            )
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
        case .flow:
            return journeys.count
        case .timSigns:
            return timSigns.count
        case .evChargers:
            return evChargers.count
        }
    }

    private var hasMapContent: Bool {
        switch selectedLayer {
        case .cameras, .events, .vms, .timSigns, .evChargers:
            return !features.isEmpty
        case .flow:
            return !flowLegs.isEmpty || !journeyRoutes.isEmpty
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
        case .timSigns:
            return timSignsLoading
        case .evChargers:
            return evChargersLoading
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
        case .timSigns:
            return timSignsErrorMessage
        case .evChargers:
            return evChargersErrorMessage
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
                        // Full journey route as a single casing underneath, with
                        // the live per-leg segments drawn on top for detail.
                        ForEach(journeyRoutes) { route in
                            MapPolyline(coordinates: route.coordinates)
                                .stroke(route.flowKind.color.opacity(0.4), style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
                        }
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
                .mapStyle(.standard)
                .mapControls {
                    MapCompass()
                    MapScaleView()
                }
                .onMapCameraChange(frequency: .onEnd) { context in
                    visibleSpan = context.region.span
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topTrailing) {
                    if hasMapContent {
                        MapLegend(layer: selectedLayer)
                            .padding(16)
                            .allowsHitTesting(false)
                    }
                }

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
        case .tim(let sign, _):
            selectedDetail = .tim(sign)
        case .evCharger(let charger, _):
            selectedDetail = .evCharger(charger)
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

        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.45)) {
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
    case tim(TIMSign, CLLocationCoordinate2D)
    case evCharger(EVCharger, CLLocationCoordinate2D)

    var id: String {
        switch self {
        case .camera(let camera, _):
            return "camera-\(camera.id)"
        case .event(let event, _):
            return "event-\(event.id)"
        case .vms(let sign, _):
            return "vms-\(sign.id)"
        case .tim(let sign, _):
            return "tim-\(sign.id)"
        case .evCharger(let charger, _):
            return "evcharger-\(charger.id)"
        }
    }

    var coordinate: CLLocationCoordinate2D {
        switch self {
        case .camera(_, let coordinate),
             .event(_, let coordinate),
             .vms(_, let coordinate),
             .tim(_, let coordinate),
             .evCharger(_, let coordinate):
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
        case .tim(let sign, _):
            return sign.displayName
        case .evCharger(let charger, _):
            return charger.displayName
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
        case .tim(let sign, _):
            return sign.summary ?? sign.regionName
        case .evCharger(let charger, _):
            return charger.operatorName ?? charger.address
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
        case .tim(let sign, _):
            return sign.headline ?? "Travel time sign"
        case .evCharger(let charger, _):
            return charger.powerSummary ?? "EV Charger"
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
        case .tim:
            return "clock.fill"
        case .evCharger:
            return "bolt.fill"
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
        case .tim:
            return .cyan
        case .evCharger(let charger, _):
            return charger.isDC ? .purple : .teal
        }
    }
}

private struct FlowLegOverlay: Identifiable {
    let id: String
    let coordinates: [CLLocationCoordinate2D]
    let flowKind: FlowKind
}

private struct FlowRouteOverlay: Identifiable {
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
    case tim(TIMSign)
    case evCharger(EVCharger)

    var id: String {
        switch self {
        case .event(let event):
            return "event-\(event.id)"
        case .vms(let sign):
            return "vms-\(sign.id)"
        case .tim(let sign):
            return "tim-\(sign.id)"
        case .evCharger(let charger):
            return "evcharger-\(charger.id)"
        }
    }
}

private struct TrafficMapMarker: View {
    let feature: TrafficMapFeature
    let onSelect: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            ZStack {
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(feature.tint)
                    .shadow(color: .black.opacity(0.24), radius: 3, y: 2)

                Image(systemName: feature.systemImage)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(glyphColor)
                    .offset(y: -2)
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .scaleEffect(isHovered ? 1.15 : 1.0)
            .animation(.easeInOut(duration: 0.12), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("\(feature.title) - \(feature.statusText)")
        .accessibilityLabel("\(feature.title), \(feature.statusText)")
    }

    // Caution markers are yellow; a white glyph fails contrast on them.
    private var glyphColor: Color {
        feature.tint == .yellow ? .black : .white
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
                    .shadow(color: .black.opacity(0.5), radius: 1.5, y: 0.5)
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
        case .timSigns:
            return .cyan
        case .evChargers:
            return .green
        }
    }
}

private struct MapLegend: View {
    let layer: TrafficMapLayer

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items, id: \.label) { item in
                HStack(spacing: 6) {
                    Circle()
                        .fill(item.color)
                        .frame(width: 9, height: 9)
                    Text(item.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Radii.card))
        .overlay(
            RoundedRectangle(cornerRadius: Radii.card)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .accessibilityHidden(true)
    }

    private var items: [(label: String, color: Color)] {
        switch layer {
        case .cameras:
            return [("Online", .green), ("Maintenance", .orange), ("Offline", .red)]
        case .events:
            return [("Closure", .red), ("Delays", .orange), ("Caution", .yellow), ("Other", .gray)]
        case .vms:
            return [("Message", .blue), ("No message", .gray)]
        case .flow:
            return FlowKind.allCases.map { ($0.label, $0.color) }
        case .timSigns:
            return [("Travel time", .cyan)]
        case .evChargers:
            return [("DC fast", .purple), ("AC", .teal)]
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
                case .tim(let sign):
                    TIMCard(sign: sign)
                case .evCharger(let charger):
                    EVChargerCard(charger: charger)
                }
            }
        }
        .padding(20)
        .frame(
            minWidth: 600, idealWidth: 720, maxWidth: 900,
            minHeight: 400, idealHeight: 520, maxHeight: 760
        )
    }

    private var title: String {
        switch detail {
        case .event(let event):
            return event.displayTitle
        case .vms(let sign):
            return sign.displayName
        case .tim(let sign):
            return sign.displayName
        case .evCharger(let charger):
            return charger.displayName
        }
    }
}

