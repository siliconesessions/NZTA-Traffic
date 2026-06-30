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
        VStack(spacing: 4) {
            Text(stat.value)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
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

