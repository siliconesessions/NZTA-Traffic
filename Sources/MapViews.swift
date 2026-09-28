import MapKit
import SwiftUI

let trafficMapInitialRegion = MKCoordinateRegion(
    center: CLLocationCoordinate2D(latitude: -41.2865, longitude: 174.7762),
    span: MKCoordinateSpan(latitudeDelta: 14.5, longitudeDelta: 16.5)
)

extension MKCoordinateRegion {
    init(_ frame: MapFrame) {
        self.init(
            center: CLLocationCoordinate2D(latitude: frame.centerLatitude, longitude: frame.centerLongitude),
            span: MKCoordinateSpan(latitudeDelta: frame.latitudeDelta, longitudeDelta: frame.longitudeDelta)
        )
    }
}

// The map can't be panned or zoomed away from New Zealand (the Chatham
// Islands included; see NZMapArea). The bound's east edge (185°E) crosses the
// antimeridian; MapKit clamps such a boundary correctly (checked against
// MKMapView: a centre on the Chathams at -176.5° is kept, -170° is pulled
// back to -175° and 150°E to 165°E).
@MainActor let trafficMapCameraBounds = MapCameraBounds(
    centerCoordinateBounds: MKCoordinateRegion(NZMapArea.cameraCenterBounds),
    minimumDistance: 250,
    maximumDistance: NZMapArea.maximumCameraDistance
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
// congestionDrawOrder); the other layers' arrays are empty. `controls` (the
// layer picker, counts and the layer's filters) floats over the top of the
// map in Liquid Glass, with the error and status panels under it.
struct TrafficMapTabView<Controls: View>: View {
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
    let controls: Controls

    @State private var selectedDetail: TrafficMapDetail?
    // The map's width in points, for placing the two directions of a road
    // side by side (see offsetPolyline).
    @State private var mapWidth: Double = 0
    // The floating panels' height (padding included), which the map's top
    // safe area and the legend are pushed down by.
    @State private var topPanelsHeight: CGFloat = 0
    // The pin layer's markers (see clusterMapPoints), and what they were
    // worked out from. Recomputed only when the pins, or the zoom's grid
    // level, change — not on every render or camera move.
    @State private var mapItems: [TrafficMapItem] = []
    @State private var clusteredKey: ClusterKey?
    // A pin picked from a cluster's list, opened once the list's sheet has
    // closed (a camera's preview is a sheet of the window's own).
    @State private var pendingSelection: TrafficMapFeature?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

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
            .floatingPanel()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(state.message)
        }
    }


    // The panels float over the map rather than insetting it, so the map
    // still draws under their glass; the map's safe area is padded by their
    // height instead, so MapKit lays out its own controls (scale, compass,
    // zoom) below them. The legend sits top-trailing under the panels: the
    // bottom-leading corner holds the Apple Maps logo and Legal link, which
    // must stay visible.
    var body: some View {
        mapView
            .safeAreaPadding(.top, topPanelsHeight)
            .overlay(alignment: .top) {
                floatingPanels
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        geometry.size.height
                    } action: { height in
                        topPanelsHeight = height
                    }
            }
            .overlay(alignment: .topTrailing) {
                if hasMapContent {
                    MapLegend(layer: selectedLayer, showsLineStyles: differentiateWithoutColor)
                        .padding(.top, topPanelsHeight)
                        .padding(.trailing, 12)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: clusterKey) {
                await recluster(for: clusterKey)
            }
            .sheet(item: $selectedDetail, onDismiss: openPendingSelection) { detail in
                TrafficMapDetailView(detail: detail) { feature in
                    pendingSelection = feature
                    selectedDetail = nil
                }
            }
    }

    // The layer controls, then any error and the loading / empty status,
    // stacked over the top of the map. One GlassEffectContainer, so the
    // panels' glass is rendered (and blends) as a group.
    private var floatingPanels: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                controls
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .floatingPanel()

                if let errorMessage {
                    ErrorBanner(
                        message: errorMessage,
                        onRetry: onRetry.map { handler in { handler(selectedLayer) } }
                    )
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
                }

                mapStatusOverlay
                    .allowsHitTesting(false)
            }
        }
        .padding(12)
    }

    private var mapView: some View {
        Map(position: $position, bounds: trafficMapCameraBounds) {
            mapContent
        }
        // Muted, with no points of interest, so the base map's own roads and
        // shop pins don't compete with the layer's colours.
        .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
        .mapControls {
            MapZoomStepper()
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
    }

    @MapContentBuilder
    private var mapContent: some MapContent {
        if selectedLayer == .flow {
            // Each leg drawn on its own, coloured by its flow, in draw order
            // (No Data at the bottom, Congested on top). The journey-level
            // route casing is gone: its geometry is exactly the legs', and
            // drawn as one line it joined the parts with straight chords.
            ForEach(flowSegments) { segment in
                let style = lineStroke(width: flowLineWidth, accessible: segment.flowKind.accessibleLineStyle)
                MapPolyline(coordinates: sideBySide(segment.coordinates, lineWidth: style.lineWidth))
                    .stroke(segment.flowKind.color, style: style)
            }
        } else if selectedLayer == .congestion {
            ForEach(congestion) { segment in
                let style = lineStroke(width: congestionLineWidth, accessible: segment.level.accessibleLineStyle)
                MapPolyline(coordinates: sideBySide(segment.polyline, lineWidth: style.lineWidth))
                    .stroke(segment.level.color, style: style)
            }
        } else {
            ForEach(visibleMapItems) { item in
                switch item {
                case .single(let feature):
                    // The marker is a circle, so its centre is the spot.
                    Annotation(feature.title, coordinate: feature.coordinate, anchor: .center) {
                        TrafficMapMarker(feature: feature) {
                            select(feature)
                        }
                    }
                case .cluster(_, let coordinate, let members, let isCoLocated):
                    // The bubble shows the count; a title under it would
                    // repeat it.
                    Annotation(
                        "\(members.count) \(selectedLayer.clusterNoun)",
                        coordinate: coordinate,
                        anchor: .center
                    ) {
                        TrafficMapClusterMarker(
                            members: members,
                            noun: selectedLayer.clusterNoun,
                            isCoLocated: isCoLocated,
                            sizeScale: zoomScale,
                            onSelect: { openCluster(members) },
                            onList: { showMembers(members) }
                        )
                    }
                    .annotationTitles(.hidden)
                }
            }
        }
    }

    // A line's stroke: round-capped at the layer's width, or — with
    // Differentiate Without Colour on — sized and dashed by its level (see
    // AccessibleLineStyle), so the level doesn't rest on colour alone.
    private func lineStroke(width: CGFloat, accessible: AccessibleLineStyle) -> StrokeStyle {
        guard differentiateWithoutColor else {
            return StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
        }
        let scaled = width * CGFloat(accessible.widthScale)
        return StrokeStyle(
            lineWidth: scaled,
            lineCap: .round,
            lineJoin: .round,
            dash: accessible.dashPattern(lineWidth: Double(scaled)).map { CGFloat($0) }
        )
    }

    // MARK: Clustering

    // What the markers depend on: the layer, its pins (identity, position
    // and look) and the zoom's grid level.
    private struct ClusterKey: Hashable {
        let layer: TrafficMapLayer
        let content: Int
        let level: Int?
    }

    // Degrees of longitude per point for clustering; before the map is
    // laid out, a typical width stands in so the first frame isn't a pile.
    private var clusterDegreesPerPoint: Double {
        visibleSpan.longitudeDelta / (mapWidth > 0 ? mapWidth : 900)
    }

    private var clusterKey: ClusterKey {
        var hasher = Hasher()
        for feature in features {
            hasher.combine(feature.id)
            hasher.combine(feature.coordinate.latitude)
            hasher.combine(feature.coordinate.longitude)
            hasher.combine(feature.emphasis)
            hasher.combine(feature.systemImage)
            hasher.combine(feature.title)
            hasher.combine(feature.statusText)
        }
        return ClusterKey(
            layer: selectedLayer,
            content: hasher.finalize(),
            level: MapClustering.cellLevel(degreesPerPoint: clusterDegreesPerPoint)
        )
    }

    // The markers, once they belong to the layer on screen (so a layer
    // switch never shows the previous layer's pins for a frame).
    private var visibleMapItems: [TrafficMapItem] {
        clusteredKey?.layer == selectedLayer ? mapItems : []
    }

    // Reclusters for `key`. When only the zoom changed, waits briefly first:
    // a zoom that's still settling cancels this task and starts another, so
    // the pins are regrouped once, when it stops.
    private func recluster(for key: ClusterKey) async {
        if let previous = clusteredKey, previous.layer == key.layer, previous.content == key.content {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else {
                return
            }
        }
        let features = self.features
        let groups = clusterMapPoints(
            features.map { ClusterPoint(id: $0.id, coordinate: $0.coordinate) },
            degreesPerPoint: clusterDegreesPerPoint
        )
        mapItems = groups.map { group in
            if group.isSingle, let index = group.memberIndices.first {
                return .single(features[index])
            }
            return .cluster(
                id: group.id,
                coordinate: group.coordinate,
                members: group.memberIndices.map { features[$0] },
                isCoLocated: group.isCoLocated
            )
        }
        clusteredKey = key
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

    private func openPendingSelection() {
        guard let feature = pendingSelection else {
            return
        }
        pendingSelection = nil
        select(feature)
    }

    // Zooms to where the cluster's pins separate or, when zooming can't
    // separate them (the same spot, or already as close as a click zooms),
    // lists them to pick from (see clusterTapAction).
    private func openCluster(_ members: [TrafficMapFeature]) {
        let action = clusterTapAction(
            for: members.map(\.coordinate),
            visibleLatitudeDelta: visibleSpan.latitudeDelta,
            visibleLongitudeDelta: visibleSpan.longitudeDelta
        )
        switch action {
        case .zoom(let frame):
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.45)) {
                position = .region(MKCoordinateRegion(frame))
            }
        case .pick:
            showMembers(members)
        }
    }

    private func showMembers(_ members: [TrafficMapFeature]) {
        selectedDetail = .members(noun: selectedLayer.clusterNoun, members: members)
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
            return camera.routeLine ?? camera.regionName.map(regionDisplayName)
        case .event(let event, _):
            return event.locationArea ?? event.locations ?? event.regionName.map(regionDisplayName)
        case .vms(let sign, _):
            return joinNonEmpty([sign.journey?.name ?? sign.way?.name, sign.direction], separator: " - ") ?? sign.regionName.map(regionDisplayName)
        case .tim(let sign, _):
            return sign.summary ?? sign.regionName.map(regionDisplayName)
        case .evCharger(let charger, _):
            return charger.operatorName ?? charger.address
        }
    }

    var statusText: String {
        switch self {
        case .camera(let camera, _):
            return camera.statusKind.label
        case .event(let event, _):
            return joinNonEmpty([event.lifecycleLabel, event.impact ?? event.eventType], separator: " · ") ?? "Road Event"
        case .vms(let sign, _):
            return sign.hasDisplayMessage ? "VMS Sign" : "No message"
        case .tim(let sign, _):
            return sign.isBlank ? "Blank right now" : sign.headline ?? "Travel time sign"
        case .evCharger(let charger, _):
            if charger.isOutOfService {
                return joinNonEmpty(["Out of service", charger.powerSummary], separator: " · ") ?? "Out of service"
            }
            return charger.powerSummary ?? "EV Charger"
        }
    }

    // The pin's glyph: each status the tint shows has its own (see
    // ViewLogic's map pin glyphs), so no status is told by colour alone.
    var systemImage: String {
        switch self {
        case .camera(let camera, _):
            return camera.statusKind.symbol
        case .event(let event, _):
            return event.mapSymbol
        case .vms(let sign, _):
            return sign.hasDisplayMessage ? MapPinSymbol.vmsMessage : MapPinSymbol.blank
        case .tim(let sign, _):
            return sign.isBlank ? MapPinSymbol.blank : MapPinSymbol.timTimes
        case .evCharger(let charger, _):
            return charger.mapSymbol
        }
    }

    var tint: Color {
        switch self {
        case .camera(let camera, _):
            return camera.statusKind.color
        case .event(let event, _):
            return event.displayTint
        case .vms(let sign, _):
            return sign.hasDisplayMessage ? .blue : .gray
        case .tim(let sign, _):
            return sign.isBlank ? .gray : .cyan
        case .evCharger(let charger, _):
            return charger.mapTint
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
            return charger.mapEmphasis
        }
    }

    // What clicking it opens, for VoiceOver.
    var accessibilityHint: String {
        switch self {
        case .camera:
            return "Shows the camera image"
        case .event, .vms, .tim, .evCharger:
            return "Shows details"
        }
    }
}

private enum TrafficMapItem: Identifiable {
    case single(TrafficMapFeature)
    case cluster(id: String, coordinate: CLLocationCoordinate2D, members: [TrafficMapFeature], isCoLocated: Bool)

    var id: String {
        switch self {
        case .single(let feature):
            return feature.id
        case .cluster(let id, _, _, _):
            return id
        }
    }
}

private enum TrafficMapDetail: Identifiable {
    case event(RoadEvent)
    case vms(VMSSign)
    case tim(TIMSign)
    case evCharger(EVCharger)
    // A cluster's pins, to pick one from.
    case members(noun: String, members: [TrafficMapFeature])

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
        case .members(_, let members):
            return "members-" + members.map(\.id).joined(separator: ",")
        }
    }
}

// A pin's circle and glyph, shared by the map markers, a cluster's member
// list and the legend. The glyph is black on yellow, where white fails
// contrast.
private struct MapPinBadge: View {
    let systemImage: String
    let tint: Color
    var diameter: CGFloat = 20

    var body: some View {
        ZStack {
            Circle()
                .fill(tint)
            Image(systemName: systemImage)
                .font(.system(size: diameter * 0.5, weight: .bold))
                .foregroundStyle(tint == .yellow ? Color.black : .white)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
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
        .accessibilityHint(feature.accessibilityHint)
    }

    // Caution markers are yellow; a white glyph fails contrast on them.
    private var glyphColor: Color {
        feature.tint == .yellow ? .black : .white
    }
}

// A cluster of pins: its count on the page colour, ringed in the legend
// colour of its most notable member, whose glyph sits on the ring so the
// emphasis isn't told by colour alone. The count stays legible on every tint
// (white text on the solid yellow, green and cyan fills was not). Clicking
// zooms in, or lists the pins when zooming can't separate them; the context
// menu (and VoiceOver's actions) list them at any zoom.
private struct TrafficMapClusterMarker: View {
    let members: [TrafficMapFeature]
    let noun: String
    // Every pin is at the same spot: clicking lists them.
    let isCoLocated: Bool
    // Zoom-derived multiplier (see TrafficMapTabView.zoomScale) so bubbles grow
    // when zoomed in and shrink at national scale.
    var sizeScale: CGFloat = 1
    let onSelect: () -> Void
    let onList: () -> Void
    @ScaledMetric(relativeTo: .caption) private var countSize: CGFloat = 13

    // The member the cluster is coloured after (see mapEmphasis).
    private var notable: TrafficMapFeature? {
        members.max { $0.emphasis < $1.emphasis }
    }

    private var tint: Color {
        notable?.tint ?? .gray
    }

    var body: some View {
        Button(action: onSelect) {
            ZStack {
                Circle()
                    .fill(.background)
                Circle()
                    .fill(tint.opacity(0.22))
                Circle()
                    .strokeBorder(tint, lineWidth: 3.5)
                Text("\(members.count)")
                    .font(.system(size: countSize, weight: .bold))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 3)
            }
            .frame(width: diameter, height: diameter)
            .overlay(alignment: .topTrailing) {
                if let notable {
                    MapPinBadge(systemImage: notable.systemImage, tint: notable.tint, diameter: 15)
                        .offset(x: 4, y: -4)
                }
            }
            .shadow(color: .black.opacity(0.24), radius: 3, y: 1)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Show List of \(members.count) \(noun.capitalized)", systemImage: "list.bullet", action: onList)
        }
        .help(isCoLocated
              ? "\(members.count) \(noun) at the same spot — click to list them"
              : "\(members.count) \(noun) — click to zoom in")
        .accessibilityLabel("\(members.count) \(noun)")
        .accessibilityValue(notable.map { "Most notable: \($0.title), \($0.statusText)" } ?? "")
        .accessibilityHint(isCoLocated ? "Lists them" : "Zooms in")
        .accessibilityAction(named: "Show List", onList)
    }

    private var diameter: CGFloat {
        let base: CGFloat
        switch members.count {
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

// The legend: each pin status with its colour and glyph, or each line level
// with its colour — and, with Differentiate Without Colour on, the width and
// dashes the map draws it with.
private struct MapLegend: View {
    let layer: TrafficMapLayer
    let showsLineStyles: Bool

    private struct Item {
        let label: String
        let color: Color
        // A pin layer's glyph, or nil for a line layer.
        var symbol: String?
        var lineStyle = AccessibleLineStyle(widthScale: 1, dash: [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items, id: \.label) { item in
                HStack(spacing: 6) {
                    swatch(item)
                    Text(item.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .floatingPanel(cornerRadius: Radii.card + 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(layer.rawValue) legend")
        .accessibilityValue(items.map(\.label).joined(separator: ", "))
    }

    @ViewBuilder
    private func swatch(_ item: Item) -> some View {
        if let symbol = item.symbol {
            MapPinBadge(systemImage: symbol, tint: item.color, diameter: 14)
        } else {
            let width = showsLineStyles ? 3.5 * item.lineStyle.widthScale : 4
            Path { path in
                path.move(to: CGPoint(x: 3, y: 5))
                path.addLine(to: CGPoint(x: 19, y: 5))
            }
            .stroke(
                item.color,
                style: StrokeStyle(
                    lineWidth: width,
                    lineCap: .round,
                    dash: showsLineStyles ? item.lineStyle.dashPattern(lineWidth: width).map { CGFloat($0) } : []
                )
            )
            .frame(width: 22, height: 10)
        }
    }

    private var items: [Item] {
        switch layer {
        case .cameras:
            return CameraStatusKind.allCases.map { Item(label: $0.label, color: $0.color, symbol: $0.symbol) }
        case .events:
            return [
                Item(label: "Closure", color: EventImpactKind.closure.color, symbol: EventImpactKind.closure.symbol),
                Item(label: "Delays", color: EventImpactKind.delays.color, symbol: EventImpactKind.delays.symbol),
                Item(label: "Caution", color: EventImpactKind.caution.color, symbol: EventImpactKind.caution.symbol),
                Item(label: "Other", color: EventImpactKind.other.color, symbol: EventImpactKind.other.symbol),
                Item(label: "Upcoming", color: .eventUpcoming, symbol: EventLifecycleSymbol.upcoming),
                Item(label: "Resolved", color: .eventResolved, symbol: EventLifecycleSymbol.resolved)
            ]
        case .vms:
            return [
                Item(label: "Message", color: .blue, symbol: MapPinSymbol.vmsMessage),
                Item(label: "No message", color: .gray, symbol: MapPinSymbol.blank)
            ]
        case .flow:
            // Worst first, the order they stack on the map.
            return FlowKind.allCases
                .sorted { $0.drawRank > $1.drawRank }
                .map { Item(label: $0.label, color: $0.color, lineStyle: $0.accessibleLineStyle) }
        case .timSigns:
            return [
                Item(label: "Showing times", color: .cyan, symbol: MapPinSymbol.timTimes),
                Item(label: "Blank", color: .gray, symbol: MapPinSymbol.blank)
            ]
        case .evChargers:
            return [
                Item(label: "DC fast", color: .purple, symbol: MapPinSymbol.evDC),
                Item(label: "AC", color: .teal, symbol: MapPinSymbol.evAC),
                Item(label: "Out of service", color: .evOutOfService, symbol: MapPinSymbol.evOutOfService)
            ]
        case .congestion:
            return CongestionLevel.allCases
                .filter { $0 != .unknown }
                .sorted { $0.severityRank > $1.severityRank }
                .map { Item(label: $0.label, color: $0.color, lineStyle: $0.accessibleLineStyle) }
        }
    }
}

private struct TrafficMapDetailView: View {
    let detail: TrafficMapDetail
    // Opens one of a cluster's pins (see TrafficMapTabView.openPendingSelection).
    let onPick: (TrafficMapFeature) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }

            switch detail {
            case .members(_, let members):
                TrafficMapMemberList(members: members, onPick: onPick)
            case .event, .vms, .tim, .evCharger:
                ScrollView {
                    card
                }
            }
        }
        .padding(20)
        .frame(
            minWidth: 600, idealWidth: 720, maxWidth: 900,
            minHeight: 400, idealHeight: 520, maxHeight: 760
        )
    }

    @ViewBuilder
    private var card: some View {
        switch detail {
        case .event(let event):
            RoadEventCard(event: event)
        case .vms(let sign):
            VMSCard(sign: sign)
        case .tim(let sign):
            TIMCard(sign: sign)
        case .evCharger(let charger):
            EVChargerCard(charger: charger)
        case .members:
            EmptyView()
        }
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
        case .members(let noun, let members):
            return "\(members.count) \(noun) here"
        }
    }
}

// The pins under one cluster marker — for pins at the same spot, which no
// zoom can separate, the only way to reach all of them from the map. Most
// notable first, as the cluster's colour promises.
private struct TrafficMapMemberList: View {
    let members: [TrafficMapFeature]
    let onPick: (TrafficMapFeature) -> Void

    private var ordered: [TrafficMapFeature] {
        members.enumerated()
            .sorted { lhs, rhs in
                lhs.element.emphasis != rhs.element.emphasis
                    ? lhs.element.emphasis > rhs.element.emphasis
                    : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    var body: some View {
        List(ordered) { feature in
            Button {
                onPick(feature)
            } label: {
                HStack(spacing: 10) {
                    MapPinBadge(systemImage: feature.systemImage, tint: feature.tint, diameter: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(feature.title)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                        Text(joinNonEmpty([feature.statusText, feature.subtitle], separator: " · ") ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(feature.accessibilityHint)
        }
        .listStyle(.inset)
    }
}
