import AppKit
import SwiftUI

struct JourneyCard: View {
    let journey: TrafficJourney

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(journey.displayName)
                    .font(.headline)

                Spacer()

                if let region = journey.regionName {
                    Badge(text: region, tint: .badgeNeutral)
                }

                Badge(text: journey.overallFlowKind.label, tint: journey.overallFlowKind.color)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            slowestLegCallout

            if journey.directions.isEmpty {
                Text("No leg data available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            } else {
                // One section per direction: its totals, then its legs in
                // travel order. (The feed interleaves the two directions.)
                ForEach(journey.directions) { direction in
                    Divider()
                    JourneyDirectionHeader(summary: direction)
                    ForEach(direction.legs) { leg in
                        Divider()
                        JourneyLegRow(leg: leg)
                    }
                }
            }
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: Radii.card))
        .overlay { CardBorder() }
    }

    // The journey's bottleneck. Only highlighted when it's genuinely slow or
    // congested so the callout flags a problem rather than restating free flow.
    private var bottleneckLeg: TrafficJourneyLeg? {
        guard let leg = journey.slowestLeg,
              leg.flowKind == .slow || leg.flowKind == .congested else {
            return nil
        }
        return leg
    }

    @ViewBuilder
    private var slowestLegCallout: some View {
        if let leg = bottleneckLeg {
            HStack(spacing: 8) {
                Image(systemName: "tortoise.fill")
                    .font(.caption2)
                    .foregroundStyle(leg.flowKind.color)
                    .accessibilityHidden(true)
                Text("Slowest leg")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(leg.name ?? "Leg")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                if let speed = leg.speed, speed > 0, let speedText = formatWholeNumber(speed) {
                    Text("\(speedText) km/h")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Badge(text: leg.flowKind.label, tint: leg.flowKind.color)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            .accessibilityElement(children: .combine)
        }
    }
}

extension JourneyDirection {
    var systemImage: String {
        switch self {
        case .increasing:
            return "arrow.up.right"
        case .decreasing:
            return "arrow.down.left"
        case .unspecified:
            return "arrow.left.and.right"
        }
    }
}

// A journey direction's heading row: "Northland Boundary → Waikato Boundary"
// over its own now / free-flow / delay / length and live coverage.
struct JourneyDirectionHeader: View {
    let summary: JourneyDirectionSummary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: summary.direction.systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.label)
                    .font(.subheadline.weight(.semibold))
                Text(summary.detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.03))
        .accessibilityElement(children: .combine)
    }
}

struct JourneyLegRow: View {
    let leg: TrafficJourneyLeg

    var body: some View {
        HStack(spacing: 12) {
            // The flow is also in the detail line as text, so the dot's
            // colour isn't the only cue; VoiceOver hears it once, there.
            Circle()
                .fill(leg.flowKind.color)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(leg.name ?? "Leg")
                    .font(.subheadline)
                    .lineLimit(1)
                if let detail = detailLine {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            HStack(spacing: 14) {
                if let speed = leg.speed, speed > 0, let speedText = formatWholeNumber(speed) {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(speedText)
                            .font(.callout.monospacedDigit())
                        Text("km/h")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if let issue = leg.dataIssue {
                    dataIssueLabel(issue)
                } else if let timeText = currentTimeText {
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
        // One VoiceOver stop per leg: name, flow and length, then speed and
        // time.
        .accessibilityElement(children: .combine)
    }

    // Stands in for the leg's time when NZTA's figures are implausible: the
    // leg is left out of the direction totals, and the tooltip says why and
    // what was reported.
    private func dataIssueLabel(_ issue: JourneyLegDataIssue) -> some View {
        var reported: [String] = []
        if let seconds = leg.currentTimeSeconds {
            reported.append(formatTimeInterval(seconds))
        }
        if let freeText = freeFlowText {
            reported.append("free flow \(freeText)")
        }
        let reportedText = reported.isEmpty ? "" : " NZTA reported \(reported.joined(separator: ", "))."
        let explanation = "\(issue.explanation)\(reportedText) It's left out of the journey totals."
        // Same two-line shape as the time it replaces, so columns stay aligned.
        return VStack(alignment: .trailing, spacing: 1) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
            Text("data issue")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 56, alignment: .trailing)
        .help(explanation)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Data issue. \(explanation)")
    }

    private var detailLine: String? {
        var parts: [String] = []
        // Surface the flow state as text so it isn't conveyed by the dot's
        // colour alone (skipped for legs with no live flow data). Direction is
        // left to the section heading the row sits under.
        if leg.flowKind != .noData {
            parts.append(leg.flowKind.label)
        }
        if let length = leg.totalLength, length > 0 {
            parts.append(String(format: "%.1f km", length))
        }
        if let limit = leg.effectiveSpeedLimit, limit > 0, let limitText = formatWholeNumber(limit) {
            parts.append("limit \(limitText) km/h")
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
    // Bumped when the cameras section refreshes; see CameraImage.
    let imageGeneration: Int
    let onPreview: () -> Void

    var body: some View {
        Button(action: onPreview) {
            VStack(alignment: .leading, spacing: 0) {
                // The live frame, scaled to the card. The static thumbnail is
                // only a labelled fallback: it's years old (see thumbUrl).
                CameraImage(
                    url: camera.liveImageURL(cacheToken: cacheToken),
                    fallbackURL: camera.stillThumbnailURL,
                    generation: imageGeneration,
                    contentMode: .fill,
                    failureText: camera.isOnline ? "Image unavailable" : "Offline"
                )
                .frame(height: 170)
                .clipped()
                .accessibilityLabel("\(camera.displayName) camera image")

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
                            Badge(text: region, tint: .badgeNeutral)
                        }
                        if camera.statusKind != .online {
                            Badge(text: camera.statusKind.label, tint: camera.statusKind.color)
                        }
                    }
                }
                .padding(14)
            }
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: Radii.card))
            .overlay { CardBorder() }
        }
        .buttonStyle(.plain)
        // One VoiceOver stop: the camera's name, then its status and where
        // it is.
        .accessibilityLabel(camera.displayName)
        .accessibilityValue(accessibilityDetails)
        .accessibilityHint("Opens a larger view")
    }

    private var accessibilityDetails: String {
        joinNonEmpty(
            [camera.statusKind.label, camera.description, camera.routeLine, camera.regionName],
            separator: ". "
        ) ?? ""
    }
}

// A camera frame that refreshes in place. When `generation` changes (the
// cameras section refreshed) it re-requests the same URL with a revalidating
// load — the camera JPEGs send ETag/Last-Modified, so an unchanged frame is a
// cheap 304 — and keeps the current frame on screen until the new one arrives,
// so auto-refresh never flashes a spinner. A new URL (⌘R's `?t=` token) loads
// fresh. Plain AsyncImage can do neither: it never reloads an unchanged URL,
// and resetting its identity blanks the image while it reloads. When the live
// frame can't load and nothing is showing yet, `fallbackURL` (the camera's
// static thumbnail) is shown instead, marked "Not live".
struct CameraImage: View {
    let url: URL?
    var fallbackURL: URL?
    let generation: Int
    var contentMode: ContentMode = .fill
    var failureText = "Image unavailable"
    @State private var image: NSImage?
    @State private var isShowingFallback = false
    @State private var didFail = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let userAgent = AppIdentity.userAgent()

    private struct LoadKey: Equatable {
        let url: URL?
        let generation: Int
    }

    private enum LoadResult {
        case loaded(NSImage)
        case failed
        case cancelled
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.primary.opacity(0.08))

            if let image {
                // Filled to the frame it's given and cropped there, so a wide
                // frame never makes the view (and the Not Live label's
                // corner) bigger than the card shows.
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .clipped()
            } else if didFail || (url == nil && fallbackURL == nil) {
                CameraPlaceholder(text: failureText)
            } else {
                ProgressView()
            }
        }
        .overlay(alignment: .bottomLeading) {
            if isShowingFallback, image != nil {
                NotLiveLabel()
                    .padding(8)
            }
        }
        .task(id: LoadKey(url: url, generation: generation)) {
            await load()
        }
    }

    private func load() async {
        if let url {
            switch await fetch(url) {
            case .loaded(let loaded):
                show(loaded, isFallback: false)
                return
            case .cancelled:
                return
            case .failed:
                break
            }
        }
        // The live frame failed, or there isn't one. A frame already on
        // screen stays; with nothing showing, try the static still.
        guard image == nil else {
            return
        }
        if let fallbackURL {
            switch await fetch(fallbackURL) {
            case .loaded(let loaded):
                show(loaded, isFallback: true)
                return
            case .cancelled:
                return
            case .failed:
                break
            }
        }
        didFail = true
    }

    private func fetch(_ url: URL) async -> LoadResult {
        // First load: whatever the URL cache allows. Reloads: always ask the
        // server, sending the cached validators.
        var request = URLRequest(
            url: url,
            cachePolicy: image == nil ? .useProtocolCachePolicy : .reloadRevalidatingCacheData
        )
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled else {
                return .cancelled
            }
            guard let status = (response as? HTTPURLResponse)?.statusCode,
                  (200..<300).contains(status),
                  let loaded = NSImage(data: data) else {
                return .failed
            }
            return .loaded(loaded)
        } catch {
            // Cancelled (scrolled away, or a newer load took over): keep
            // whatever frame is showing.
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                return .cancelled
            }
            return .failed
        }
    }

    private func show(_ loaded: NSImage, isFallback: Bool) {
        // Fade in the first frame only; later frames swap in place.
        let animation: Animation? = reduceMotion || image != nil ? nil : .easeInOut(duration: 0.3)
        withAnimation(animation) {
            image = loaded
            isShowingFallback = isFallback
            didFail = false
        }
    }
}

// Marks a camera card showing the static thumbnail rather than a live frame.
private struct NotLiveLabel: View {
    var body: some View {
        Label("Not live", systemImage: "clock.badge.exclamationmark")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.regularMaterial, in: Capsule())
            .help("The live image couldn't load. This is an old still from NZTA, not the current view.")
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
    // Follows the cameras section, so an open preview keeps updating.
    let imageGeneration: Int
    @Environment(\.dismiss) private var dismiss

    // The legacy /camera/view/<id> page (camera.viewUrl) now 404s — trafficnz.info
    // redirects to journeys.nzta.govt.nz and the old view path is dead. Link to the
    // working full-resolution image path instead so the button isn't a dead link.
    private var largerViewURL: URL? {
        camera.imageURL(cacheToken: cacheToken)
    }

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
                if let largerViewURL {
                    Button {
                        NSWorkspace.shared.open(largerViewURL)
                    } label: {
                        Label("Open full image", systemImage: "arrow.up.forward.app")
                    }
                    .help("Open the full-resolution camera image in your browser")
                }
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }

            CameraImage(
                url: camera.imageURL(cacheToken: cacheToken),
                generation: imageGeneration,
                contentMode: .fit
            )
            .frame(minWidth: 760, minHeight: 470)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("\(camera.displayName) camera image")
        }
        .padding(20)
    }
}

struct RoadEventCard: View {
    let event: RoadEvent

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(event.displayTint)
                .frame(width: 5)

            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .top, spacing: 12) {
                    Text(event.displayTitle)
                        .font(.headline)
                        .lineLimit(nil)

                    Spacer()

                    HStack(spacing: 6) {
                        Badge(
                            text: event.isPlanned ? "Planned" : "Incident",
                            tint: event.isPlanned ? .blue : .indigo
                        )
                        if let impactBadgeText {
                            Badge(text: impactBadgeText, tint: event.displayTint)
                        }
                    }
                }

                if let direction = event.directionText {
                    Label(direction, systemImage: directionSymbol)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                if let location = event.locationArea {
                    Label(location, systemImage: "location.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let near = event.nearestLandmark {
                    Label(near, systemImage: "mappin.and.ellipse")
                        .font(.caption)
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

                if let restrictions = event.restrictions {
                    Label("Restrictions: \(restrictions)", systemImage: "exclamationmark.octagon")
                        .font(.callout.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                EventMetaGrid(event: event)
            }
            .padding(16)
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: Radii.card))
        .overlay { CardBorder() }
        // One VoiceOver stop per event instead of a dozen fragments: what
        // and where in the label, the rest in the value.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityValue(accessibilityDetails)
    }

    // "Road Closed, Upcoming. Slip. Northbound. Kaikōura" — impact and
    // lifecycle first, since that is what the card's colour says.
    private var accessibilitySummary: String {
        joinNonEmpty(
            [
                joinNonEmpty([event.impact, event.lifecycleLabel], separator: ", "),
                event.displayTitle,
                event.directionText,
                event.locationArea
            ],
            separator: ". "
        ) ?? event.displayTitle
    }

    private var accessibilityDetails: String {
        var parts: [String?] = [
            event.isPlanned ? "Planned" : "Incident",
            event.nearestLandmark.map { "Near \($0)" },
            event.eventComments,
            event.alternativeRouteText.map { "Alternative route: \($0)" },
            event.restrictions.map { "Restrictions: \($0)" }
        ]
        parts += EventMetaGrid.items(for: event).map(\.text)
        return joinNonEmpty(parts, separator: ". ") ?? ""
    }

    // "Road Closed", or "Upcoming · Road Closed" / "Resolved · Road Closed"
    // for events not in force now, tinted by lifecycle (see displayTint).
    private var impactBadgeText: String? {
        joinNonEmpty([event.lifecycleLabel, event.impact], separator: " · ")
    }

    // Pick a directional glyph from the carriageway text; default to a
    // two-way arrow for "Both Directions" or anything unrecognised.
    private var directionSymbol: String {
        guard let direction = event.directionText?.lowercased() else {
            return "arrow.left.and.right"
        }
        if direction.contains("north") {
            return "arrow.up"
        }
        if direction.contains("south") {
            return "arrow.down"
        }
        if direction.contains("east") {
            return "arrow.right"
        }
        if direction.contains("west") {
            return "arrow.left"
        }
        return "arrow.left.and.right"
    }
}

struct EventMetaGrid: View {
    let event: RoadEvent

    struct Item: Hashable {
        let text: String
        let systemImage: String
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(Self.items(for: event), id: \.self) { item in
                SmallMeta(text: item.text, systemImage: item.systemImage)
            }
        }
    }

    // The type, dates, island, source and — for a current event — its raw
    // status. Shared with the card's VoiceOver value.
    static func items(for event: RoadEvent) -> [Item] {
        var items: [Item] = []
        if let eventType = event.eventType {
            items.append(Item(text: eventType, systemImage: "tag"))
        }
        if let started = startedText(event) {
            items.append(Item(text: started, systemImage: "clock"))
        }
        if let updated = formatRelativeTrafficDate(event.eventModified).map({ "Updated \($0)" }) {
            items.append(Item(text: updated, systemImage: "arrow.clockwise"))
        }
        if let ends = endsText(event) {
            items.append(Item(text: ends, systemImage: "calendar"))
        }
        if let island = event.eventIsland {
            items.append(Item(text: island, systemImage: "map"))
        }
        if let source = event.informationSource {
            items.append(Item(text: "Source: \(source)", systemImage: "info.circle"))
        }
        // Upcoming/Resolved already lead the impact badge; only a current
        // event's status (Active, or an unrecognised raw value) is shown here.
        if event.isActive, let status = event.statusKind.label {
            items.append(
                Item(
                    text: status,
                    systemImage: event.statusKind == .active ? "dot.radiowaves.left.and.right" : "questionmark.circle"
                )
            )
        }
        return items
    }

    // Tense follows the date: "Started 2 days ago", or for a scheduled event
    // "Starts in 1 day · Sun 27 Sep, 8:00 pm". Falls back to the absolute NZ
    // reading when the timestamp can't be parsed.
    private static func startedText(_ event: RoadEvent) -> String? {
        if let phrase = eventDatePhrase(event.startDate, past: "Started", future: "Starts") {
            return phrase
        }
        return formatTrafficDate(event.startDate).map { "Start: \($0)" }
    }

    // "Ends in 3 days" / "Ended 2 hours ago". Most events carry `endDate`; the
    // few that don't fall back to the planned resolution estimate so the card
    // still has a "when" cue.
    private static func endsText(_ event: RoadEvent) -> String? {
        if let phrase = eventDatePhrase(event.endDate, past: "Ended", future: "Ends") {
            return phrase
        }
        return formatTrafficDate(event.expectedResolution).map { "Expected: \($0)" }
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

struct EVChargerCard: View {
    let charger: EVCharger

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label(charger.displayName, systemImage: "bolt.fill")
                    .font(.headline)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.primary)

                Spacer()

                if let power = charger.powerSummary {
                    Badge(text: power, tint: charger.isDC ? .purple : .teal)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Divider()

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), alignment: .leading)], alignment: .leading, spacing: 8) {
                if let op = charger.operatorName {
                    SmallMeta(text: op, systemImage: "building.2")
                }
                if let address = charger.address {
                    SmallMeta(text: address, systemImage: "mappin.and.ellipse")
                }
                if let connectors = charger.connectorSummary {
                    SmallMeta(text: connectors, systemImage: "powerplug")
                }
                if let count = charger.connectorCount {
                    SmallMeta(text: "\(count) connector\(count == 1 ? "" : "s")", systemImage: "number")
                }
                if let is24Hours = charger.is24Hours {
                    SmallMeta(text: is24Hours ? "Open 24 hours" : "Limited hours", systemImage: "clock")
                }
                if let hasCost = charger.hasChargingCost {
                    SmallMeta(text: hasCost ? "Charging cost applies" : "Free charging", systemImage: "dollarsign.circle")
                }
            }
            .padding(16)
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: Radii.card))
        .overlay { CardBorder() }
        .accessibilityElement(children: .combine)
    }
}

struct TIMCard: View {
    let sign: TIMSign

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label(sign.displayName, systemImage: "clock.fill")
                    .font(.headline)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Spacer()

                if let region = sign.regionName {
                    Badge(text: region, tint: .badgeNeutral)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Divider()

            if sign.lines.isEmpty {
                Text("No travel times available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(16)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(sign.lines.enumerated()), id: \.offset) { index, line in
                        TIMLineRow(line: line)
                        if index < sign.lines.count - 1 {
                            Divider()
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: Radii.card))
        .overlay { CardBorder() }
        .accessibilityElement(children: .combine)
    }
}

private struct TIMLineRow: View {
    let line: TIMLine

    var body: some View {
        HStack(spacing: 12) {
            Text(line.destination ?? "—")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)

            Spacer()

            if let time = line.timeText {
                Text(time)
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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
                .font(.system(.title2, design: .monospaced, weight: .bold))
                .foregroundStyle(Color.vmsCardMessage)
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
        .background(Color.vmsCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Radii.card))
        .overlay {
            RoundedRectangle(cornerRadius: Radii.card)
                .stroke(Color.vmsCardBorder, lineWidth: 1)
        }
        // One VoiceOver stop: the sign, then its message in normal case (the
        // upper-cased monospaced text can be read out letter by letter).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sign: \(sign.displayName)")
        .accessibilityValue(
            joinNonEmpty(
                [
                    sign.formattedMessage,
                    sign.regionName,
                    formatTrafficDate(sign.lastMessageUpdate ?? sign.lastUpdate).map { "Updated \($0)" }
                ],
                separator: ". "
            ) ?? ""
        )
    }
}

