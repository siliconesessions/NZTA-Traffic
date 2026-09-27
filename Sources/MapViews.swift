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
    case congestion = "Auckland Congestion"

    var id: String {
        rawValue
    }

    // The segmented layer picker's short label. The control makes every
    // segment as wide as the widest, so one long label ("Auckland
    // Congestion") would widen all seven to about 1,070 pt; the menu form of
    // the picker and the legend use the full `rawValue`.
    var pickerLabel: String {
        switch self {
        case .cameras:
            return "Cameras"
        case .events:
            return "Events"
        case .vms:
            return "VMS"
        case .flow:
            return "Flow"
        case .timSigns:
            return "TIM"
        case .evChargers:
            return "EV"
        case .congestion:
            return "Congestion"
        }
    }

    // What a cluster of this layer's pins holds: "12 VMS signs".
    var clusterNoun: String {
        switch self {
        case .cameras:
            return "cameras"
        case .events:
            return "road events"
        case .vms:
            return "VMS signs"
        case .flow:
            return "journey legs"
        case .timSigns:
            return "travel time signs"
        case .evChargers:
            return "EV chargers"
        case .congestion:
            return "congestion segments"
        }
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
        case .congestion:
            return "Loading Auckland congestion..."
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
            return "No journey legs match your filters"
        case .timSigns:
            return "No travel time signs found matching your filters"
        case .evChargers:
            return "No EV chargers found matching your filters"
        case .congestion:
            return "No Auckland congestion segments match your filters"
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
            return "No filtered EV chargers have usable map coordinates"
        case .congestion:
            return "No filtered Auckland congestion segments have usable geometry"
        }
    }
}

// Draws whichever layer is selected. ContentView hands it only that layer's
// data, already filtered (and, for the Flow and congestion lines, filtered
// per leg and ordered worst on top — see flowMapSegments and
// congestionDrawOrder); the other layers' arrays are empty.
struct TrafficMapTabView: View {
    let cameras: [TrafficCamera]
    let events: [RoadEvent]
    let vmsSigns: [VMSSign]
    let flowSegments: [FlowMapSegment]
    // Journey legs whose flow passes the chips, drawable or not.
    let flowLegCount: Int
    let timSigns: [TIMSign]
    let evChargers: [EVCharger]
    let congestion: [CongestionSegment]
    // The selected layer's loading state and error.
    let isLoading: Bool
    let errorMessage: String?
    @Binding var position: MapCameraPosition
    @Binding var visibleSpan: MKCoordinateSpan
    @Binding var selectedLayer: TrafficMapLayer
    let onCameraPreview: (TrafficCamera) -> Void
    // Reloads the data behind the currently selected map layer (per-layer Retry).
    var onRetry: ((TrafficMapLayer) -> Void)?

    @State private var selectedDetail: TrafficMapDetail?
    // The map's width in points, for placing the two directions of a road
    // side by side (see offsetPolyline).
    @State private var mapWidth: Double = 0
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
        case .flow, .congestion:
            return []
        }
    }

    // Map degrees of longitude per screen point, 0 until the map is laid out.
    private var degreesLongitudePerPoint: Double {
        mapWidth > 0 ? visibleSpan.longitudeDelta / mapWidth : 0
    }

    // Opposite directions of a road share (nearly) the same line: each is
    // moved half a stroke to the left of its direction of travel, so both
    // show — as their carriageways do — and neither hides the other. The
    // input is already worst-on-top, which still decides any overlap left.
    private func sideBySide(_ coordinates: [CLLocationCoordinate2D], lineWidth: CGFloat) -> [CLLocationCoordinate2D] {
        offsetPolyline(
            coordinates,
            points: Double(lineWidth) / 2 + 0.5,
            degreesLongitudePerPoint: degreesLongitudePerPoint
        )
    }

    private var flowLineWidth: CGFloat {
        5 * zoomScale
    }

    private var congestionLineWidth: CGFloat {
        6 * zoomScale
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
            return flowLegCount
        case .timSigns:
            return timSigns.count
        case .evChargers:
            return evChargers.count
        case .congestion:
            return congestion.count
        }
    }

    private var hasMapContent: Bool {
        switch selectedLayer {
        case .cameras, .events, .vms, .timSigns, .evChargers:
            return !features.isEmpty
        case .flow:
            return !flowSegments.isEmpty
        case .congestion:
            return !congestion.isEmpty
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
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(state.message)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let errorMessage {
                ErrorBanner(
                    message: errorMessage,
                    onRetry: onRetry.map { handler in { handler(selectedLayer) } }
                )
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 8)
            }

            ZStack(alignment: .topLeading) {
                Map(position: $position) {
                    if selectedLayer == .flow {
                        // Each leg drawn on its own, coloured by its flow, in
                        // draw order (No Data at the bottom, Congested on
                        // top). The journey-level route casing is gone: its
                        // geometry is exactly the legs', and drawn as one line
                        // it joined the parts with straight chords.
                        let style = StrokeStyle(lineWidth: flowLineWidth, lineCap: .round, lineJoin: .round)
                        ForEach(flowSegments) { segment in
                            MapPolyline(coordinates: sideBySide(segment.coordinates, lineWidth: flowLineWidth))
                                .stroke(segment.flowKind.color, style: style)
                        }
                    } else if selectedLayer == .congestion {
                        let style = StrokeStyle(lineWidth: congestionLineWidth, lineCap: .round, lineJoin: .round)
                        ForEach(congestion) { segment in
                            MapPolyline(coordinates: sideBySide(segment.polyline, lineWidth: congestionLineWidth))
                                .stroke(segment.level.color, style: style)
                        }
                    } else {
                        ForEach(mapItems) { item in
                            switch item {
                            case .single(let feature):
                                // The marker is a circle, so its centre is the spot.
                                Annotation(feature.title, coordinate: feature.coordinate, anchor: .center) {
                                    TrafficMapMarker(feature: feature) {
                                        select(feature)
                                    }
                                }
                            case .cluster(_, let coordinate, let members):
                                // The bubble shows the count; a title under it
                                // would repeat it.
                                Annotation(
                                    "\(members.count) \(selectedLayer.clusterNoun)",
                                    coordinate: coordinate,
                                    anchor: .center
                                ) {
                                    TrafficMapClusterMarker(
                                        count: members.count,
                                        noun: selectedLayer.clusterNoun,
                                        tint: clusterTint(members),
                                        sizeScale: zoomScale
                                    ) {
                                        zoomIn(toCluster: members)
                                    }
                                }
                                .annotationTitles(.hidden)
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
                .onGeometryChange(for: Double.self) { geometry in
                    Double(geometry.size.width)
                } action: { width in
                    mapWidth = width
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

    // A cluster takes the legend colour of its most notable member (see
    // mapEmphasis): an events cluster is red only when it holds a closure.
    private func clusterTint(_ members: [TrafficMapFeature]) -> Color {
        members.max { $0.emphasis < $1.emphasis }?.tint ?? .gray
    }

    // A multiplier that grows polylines and cluster bubbles as the user zooms
    // in and shrinks them when zoomed out to the whole country, so strokes stay
    // legible at street level without smothering the national view. Derived
    // from the visible span (degrees) and clamped to a tasteful range.
    private var zoomScale: CGFloat {
        let maxSpan = max(visibleSpan.latitudeDelta, visibleSpan.longitudeDelta)
        // ~0.05° (street) → 1.6×, ~8°+ (national) → 0.7×, interpolated between.
        let clamped = min(max(maxSpan, 0.05), 8.0)
        let t = (clamped - 0.05) / (8.0 - 0.05)
        return 1.6 - t * (1.6 - 0.7)
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
            return joinNonEmpty([event.lifecycleLabel, event.impact ?? event.eventType], separator: " · ") ?? "Road Event"
        case .vms(let sign, _):
            return sign.hasDisplayMessage ? "VMS Sign" : "No message"
        case .tim(let sign, _):
            return sign.isBlank ? "Blank right now" : sign.headline ?? "Travel time sign"
        case .evCharger(let charger, _):
            return charger.powerSummary ?? "EV Charger"
        }
    }

    var systemImage: String {
        switch self {
        case .camera(let camera, _):
            return camera.isOnline ? "video.fill" : "video.slash"
        case .event(let event, _):
            // The glyph carries the lifecycle too, so it isn't colour-only.
            if event.isResolved {
                return "checkmark.circle.fill"
            }
            return event.isUpcoming ? "calendar" : "exclamationmark.triangle.fill"
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
            return event.displayTint
        case .vms(let sign, _):
            return sign.hasDisplayMessage ? .blue : .gray
        case .tim(let sign, _):
            return sign.isBlank ? .gray : .cyan
        case .evCharger(let charger, _):
            return charger.isDC ? .purple : .teal
        }
    }

    // How much this pin should stand out, for colouring a cluster.
    var emphasis: Int {
        switch self {
        case .camera(let camera, _):
            return camera.mapEmphasis
        case .event(let event, _):
            return event.mapEmphasis
        case .vms(let sign, _):
            return sign.hasDisplayMessage ? 1 : 0
        case .tim(let sign, _):
            return sign.isBlank ? 0 : 1
        case .evCharger(let charger, _):
            return charger.isDC ? 1 : 0
        }
    }
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

// A cluster of pins: its count on the page colour, ringed in the legend
// colour of its most notable member. The count stays legible on every tint
// (white text on the solid yellow, green and cyan fills was not).
private struct TrafficMapClusterMarker: View {
    let count: Int
    let noun: String
    let tint: Color
    // Zoom-derived multiplier (see TrafficMapTabView.zoomScale) so bubbles grow
    // when zoomed in and shrink at national scale.
    var sizeScale: CGFloat = 1
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            ZStack {
                Circle()
                    .fill(.background)
                Circle()
                    .fill(tint.opacity(0.22))
                Circle()
                    .strokeBorder(tint, lineWidth: 3.5)
                Text("\(count)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
            }
            .frame(width: diameter, height: diameter)
            .shadow(color: .black.opacity(0.24), radius: 3, y: 1)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("\(count) \(noun) — click to zoom in")
        .accessibilityLabel("\(count) \(noun)")
        .accessibilityHint("Zooms in")
    }

    private var diameter: CGFloat {
        let base: CGFloat
        switch count {
        case ..<10:
            base = 32
        case ..<50:
            base = 38
        case ..<200:
            base = 44
        default:
            base = 50
        }
        // Clamp so the bubble never gets so small the count is unreadable nor so
        // large it dominates the map.
        return min(max(base * sizeScale, 26), 64)
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
        .overlay {
            RoundedRectangle(cornerRadius: Radii.card)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    private var items: [(label: String, color: Color)] {
        switch layer {
        case .cameras:
            return [("Online", .green), ("Maintenance", .orange), ("Offline", .red)]
        case .events:
            return [
                ("Closure", EventImpactKind.closure.color),
                ("Delays", EventImpactKind.delays.color),
                ("Caution", EventImpactKind.caution.color),
                ("Upcoming", .eventUpcoming),
                ("Other / Resolved", .eventResolved)
            ]
        case .vms:
            return [("Message", .blue), ("No message", .gray)]
        case .flow:
            // Worst first, the order they stack on the map.
            return FlowKind.allCases
                .sorted { $0.drawRank > $1.drawRank }
                .map { ($0.label, $0.color) }
        case .timSigns:
            return [("Showing times", .cyan), ("Blank", .gray)]
        case .evChargers:
            return [("DC fast", .purple), ("AC", .teal)]
        case .congestion:
            return CongestionLevel.allCases
                .filter { $0 != .unknown }
                .sorted { $0.severityRank > $1.severityRank }
                .map { ($0.label, $0.color) }
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

