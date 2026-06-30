import SwiftUI

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
        HStack(spacing: 0) {
            // A slim accent bar carries the stat's tint instead of flooding the
            // whole card, so it reads as part of the card family and sits well
            // on a dark window.
            Rectangle()
                .fill(stat.tint)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(stat.value)
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                Text(stat.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 16)
            .padding(.horizontal, 14)
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: Radii.card))
        .overlay(
            RoundedRectangle(cornerRadius: Radii.card)
                .stroke(Color.cardStroke, lineWidth: 1)
        )
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
            .clipShape(RoundedRectangle(cornerRadius: Radii.card))
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
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

struct EventImpactFilterRow: View {
    @Binding var showClosures: Bool
    @Binding var showDelays: Bool
    @Binding var showCaution: Bool
    @Binding var showOther: Bool
    @Binding var showPlanned: Bool
    @Binding var showUnplanned: Bool
    @Binding var island: EventIslandFilter

    var body: some View {
        HStack(spacing: 8) {
            Text("Show")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            FilterChip(label: "Closures", tint: .red, isOn: $showClosures)
            FilterChip(label: "Delays", tint: .orange, isOn: $showDelays)
            FilterChip(label: "Caution", tint: .yellow, isOn: $showCaution)
            FilterChip(label: "Other", tint: .gray, isOn: $showOther)
            Divider().frame(height: 16)
            FilterChip(label: "Planned", tint: .blue, isOn: $showPlanned)
            FilterChip(label: "Incident", tint: .indigo, isOn: $showUnplanned)
            Divider().frame(height: 16)
            Picker("Island", selection: $island) {
                ForEach(EventIslandFilter.allCases) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 130)
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

extension CongestionLevel {
    var color: Color {
        switch self {
        case .freeFlow:
            return .green
        case .moderate:
            return .yellow
        case .heavy:
            return .orange
        case .congested:
            return .red
        case .unknown:
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        if hasError {
            return "failed to load"
        }
        if isLoading {
            return "loading"
        }
        return "\(count)"
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
    // When supplied, a "Retry" button is shown that re-fetches just this
    // section (see TrafficStore.reload). Nil keeps the banner purely informational.
    var onRetry: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let onRetry {
                Button("Retry", action: onRetry)
                    .controlSize(.small)
                    .help("Reload this section")
            }
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

// Top-of-window banner shown when the app is offline or is displaying data from
// the on-disk cache rather than a live fetch. Styled distinctly from ErrorBanner
// (amber / informational rather than red / error) because cached data is still
// useful — it just may be stale.
struct OfflineBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
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

// Native empty state that explains when filters are the reason a section is
// empty and offers a one-tap way to clear them.
struct FilterableEmptyState: View {
    let systemImage: String
    let title: String
    let hasActiveFilters: Bool
    let onClearFilters: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if hasActiveFilters {
                Text("Active filters may be hiding results.")
            } else {
                Text("Try refreshing, or check back shortly.")
            }
        } actions: {
            if hasActiveFilters {
                Button("Clear Filters", action: onClearFilters)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 360)
    }
}

// MARK: - Keyboard list navigation

// Makes a list/grid item keyboard-focusable with a visible accent focus ring
// and wires the arrow keys (↑/← previous, ↓/→ next) to move focus to the
// adjacent item in `orderedIDs`. Mouse clicks and any existing button action are
// left untouched — this only adds a parallel keyboard path. `onActivate`, when
// supplied, fires on Return/Space so the focused item can be "opened" from the
// keyboard; rows without a detail action omit it.
private struct KeyboardNavigableItem<ID: Hashable>: ViewModifier {
    let id: ID
    let orderedIDs: [ID]
    @FocusState.Binding var focusedID: ID?
    var onActivate: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .focusable()
            .focused($focusedID, equals: id)
            .overlay {
                RoundedRectangle(cornerRadius: Radii.card)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .opacity(focusedID == id ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .onMoveCommand(perform: moveFocus)
            .onKeyPress(.return, action: activate)
            .onKeyPress(.space, action: activate)
    }

    private func activate() -> KeyPress.Result {
        guard let onActivate else {
            return .ignored
        }
        onActivate()
        return .handled
    }

    private func moveFocus(_ direction: MoveCommandDirection) {
        // Anchor on the current focus, falling back to the first item so an
        // arrow press from "nothing focused" still enters the list.
        guard let current = focusedID ?? orderedIDs.first,
              let index = orderedIDs.firstIndex(of: current) else {
            return
        }
        let nextIndex: Int
        switch direction {
        case .up, .left:
            nextIndex = index - 1
        case .down, .right:
            nextIndex = index + 1
        @unknown default:
            return
        }
        guard orderedIDs.indices.contains(nextIndex) else {
            return
        }
        focusedID = orderedIDs[nextIndex]
    }
}

extension View {
    // Apply to each row/card inside a ForEach. `orderedIDs` is the visible,
    // already-filtered list of ids in display order so arrow keys follow what
    // the user actually sees.
    func keyboardNavigable<ID: Hashable>(
        id: ID,
        in orderedIDs: [ID],
        focus: FocusState<ID?>.Binding,
        onActivate: (() -> Void)? = nil
    ) -> some View {
        modifier(
            KeyboardNavigableItem(
                id: id,
                orderedIDs: orderedIDs,
                focusedID: focus,
                onActivate: onActivate
            )
        )
    }
}

struct SettingsView: View {
    @AppStorage("nzta.autoRefreshEnabled") private var autoRefreshEnabled = false
    @AppStorage("nzta.refreshIntervalSeconds") private var refreshIntervalSeconds = 120
    @AppStorage("nzta.hideEmptyVMS") private var hideEmptyVMS = true

    var body: some View {
        Form {
            Section("Auto-Refresh") {
                Toggle("Automatically refresh data", isOn: $autoRefreshEnabled)
                Picker("Interval", selection: $refreshIntervalSeconds) {
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("2 minutes").tag(120)
                    Text("5 minutes").tag(300)
                    Text("10 minutes").tag(600)
                }
                .disabled(!autoRefreshEnabled)
            }
            Section("Display") {
                Toggle("Hide VMS signs with no active message", isOn: $hideEmptyVMS)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 260)
    }
}

