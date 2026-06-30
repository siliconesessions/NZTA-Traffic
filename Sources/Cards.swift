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
        .clipShape(RoundedRectangle(cornerRadius: Radii.card))
        .overlay(
            RoundedRectangle(cornerRadius: Radii.card)
                .stroke(Color.cardStroke, lineWidth: 1)
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
                .accessibilityLabel("Traffic flow: \(leg.flowKind.label)")

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
        // Surface the flow state as text so it isn't conveyed by the dot's
        // colour alone (skipped for legs with no live flow data).
        if leg.flowKind != .noData {
            parts.append(leg.flowKind.label)
        }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onPreview) {
            VStack(alignment: .leading, spacing: 0) {
                AsyncImage(
                    url: camera.thumbnailURL(cacheToken: cacheToken),
                    transaction: Transaction(animation: reduceMotion ? nil : .easeInOut(duration: 0.3))
                ) { phase in
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
            .clipShape(RoundedRectangle(cornerRadius: Radii.card))
            .overlay(
                RoundedRectangle(cornerRadius: Radii.card)
                    .stroke(Color.cardStroke, lineWidth: 1)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

            AsyncImage(
                url: camera.imageURL(cacheToken: cacheToken),
                transaction: Transaction(animation: reduceMotion ? nil : .easeInOut(duration: 0.3))
            ) { phase in
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
                .fill(impactColor)
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
                        if let impact = event.impact {
                            Badge(text: impact, tint: impactColor)
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

                Divider()

                EventMetaGrid(event: event)
            }
            .padding(16)
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: Radii.card))
        .overlay(
            RoundedRectangle(cornerRadius: Radii.card)
                .stroke(Color.cardStroke, lineWidth: 1)
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

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), alignment: .leading)], alignment: .leading, spacing: 8) {
            if let eventType = event.eventType {
                SmallMeta(text: eventType, systemImage: "tag")
            }
            if let started = startedText {
                SmallMeta(text: started, systemImage: "clock")
            }
            if let updated = updatedText {
                SmallMeta(text: updated, systemImage: "arrow.clockwise")
            }
            if let ends = endsText {
                SmallMeta(text: ends, systemImage: "calendar")
            }
            if let island = event.eventIsland {
                SmallMeta(text: island, systemImage: "map")
            }
            if let source = event.informationSource {
                SmallMeta(text: "Source: \(source)", systemImage: "info.circle")
            }
            if let status = event.status {
                SmallMeta(text: status, systemImage: "checkmark.circle")
            }
        }
    }

    // Prefer a relative reading ("Started 2 days ago"); fall back to the
    // absolute NZ date when the timestamp can't be parsed into a relative one.
    private var startedText: String? {
        if let relative = formatRelativeTrafficDate(event.startDate) {
            return "Started \(relative)"
        }
        return formatTrafficDate(event.startDate).map { "Started: \($0)" }
    }

    private var updatedText: String? {
        formatRelativeTrafficDate(event.eventModified).map { "Updated \($0)" }
    }

    // The API rarely sends `endDate`; when absent fall back to the planned
    // resolution estimate so the card still carries a "when" cue.
    private var endsText: String? {
        if let relative = formatRelativeTrafficDate(event.endDate) {
            return "Ends \(relative)"
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
        .overlay(
            RoundedRectangle(cornerRadius: Radii.card)
                .stroke(Color.vmsCardBorder, lineWidth: 1)
        )
    }
}

