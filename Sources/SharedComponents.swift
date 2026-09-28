import SwiftUI

// The stats side by side while they fit; at larger text sizes, or in a
// narrow window, they wrap into a grid instead of truncating.
struct StatsRow: View {
    let stats: [StatItem]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                cards
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], spacing: 14) {
                cards
            }
        }
    }

    private var cards: some View {
        ForEach(stats) { stat in
            StatCard(stat: stat)
        }
    }
}

struct StatItem: Identifiable {
    let title: String
    let value: String
    let tint: Color

    // Titles are unique within a row, so a stat keeps its identity across
    // renders and its card is updated in place rather than rebuilt.
    var id: String {
        title
    }
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
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(stat.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 16)
            .padding(.horizontal, 14)
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: Radii.card))
        .overlay { CardBorder() }
        // One VoiceOver stop that names the stat before its number
        // ("Active Closures, 12"), not two fragments number-first.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stat.title)
        .accessibilityValue(stat.value)
    }
}

// The hairline around a content card; stronger with Increase Contrast.
struct CardBorder: View {
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        RoundedRectangle(cornerRadius: Radii.card)
            .stroke(contrast == .increased ? Color.cardStrokeIncreased : Color.cardStroke, lineWidth: 1)
    }
}

// A small label with a tinted wash and edge. The text is the primary label
// colour, which stays above 4.5:1 on every tint in light and dark; white on
// the solid system colours measured 1.9–3.6:1 (green, orange, teal, red), and
// a black region badge vanished on a dark card. Use `.badgeNeutral` for
// information that carries no status, such as a region.
struct Badge: View {
    let text: String
    let tint: Color
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radii.card)
        Text(text)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(.primary)
            .background(tint.opacity(contrast == .increased ? 0.28 : 0.18), in: shape)
            .overlay {
                shape.strokeBorder(tint.opacity(contrast == .increased ? 1 : 0.6), lineWidth: 1)
            }
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
                // Never wraps or squeezes to nothing: a row that runs out of
                // room switches to its compact menu instead (see
                // FilterRowFitting).
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isOn ? .primary : .secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isOn ? tint.opacity(0.15) : Color.primary.opacity(0.05))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(isOn ? "Showing \(label) — click to hide" : "Hiding \(label) — click to show")
        .accessibilityLabel("Show \(label)")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

// A filter row's chips when they fit with their labels; otherwise a compact
// menu holding the same toggles, so a narrow window never squeezes the chips
// into unlabelled ovals.
struct FilterRowFitting<Chips: View, MenuItems: View>: View {
    let menuTitle: String
    let hiddenCount: Int
    @ViewBuilder let chips: Chips
    @ViewBuilder let menuItems: MenuItems

    var body: some View {
        ViewThatFits(in: .horizontal) {
            chips
            Menu {
                menuItems
            } label: {
                Label(
                    hiddenCount == 0 ? menuTitle : "\(menuTitle) (\(hiddenCount) hidden)",
                    systemImage: hiddenCount == 0
                        ? "line.3.horizontal.decrease.circle"
                        : "line.3.horizontal.decrease.circle.fill"
                )
                .font(.caption.weight(.medium))
            }
            .controlSize(.small)
            .fixedSize()
        }
    }
}

// The "Show" caption that leads a chip row.
private struct FilterRowLabel: View {
    var body: some View {
        Text("Show")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .fixedSize()
    }
}

struct EventImpactFilterRow: View {
    @Binding var showClosures: Bool
    @Binding var showDelays: Bool
    @Binding var showCaution: Bool
    @Binding var showOther: Bool
    @Binding var showPlanned: Bool
    @Binding var showUnplanned: Bool
    @Binding var showResolved: Bool
    @Binding var island: EventIslandFilter

    private var hiddenCount: Int {
        [showClosures, showDelays, showCaution, showOther, showPlanned, showUnplanned]
            .filter { !$0 }.count + (island == .all ? 0 : 1)
    }

    var body: some View {
        FilterRowFitting(menuTitle: "Event Filters", hiddenCount: hiddenCount) {
            HStack(spacing: 8) {
                FilterRowLabel()
                FilterChip(label: "Closures", tint: .red, isOn: $showClosures)
                FilterChip(label: "Delays", tint: .orange, isOn: $showDelays)
                FilterChip(label: "Caution", tint: .yellow, isOn: $showCaution)
                FilterChip(label: "Other", tint: .gray, isOn: $showOther)
                Divider().frame(height: 16)
                FilterChip(label: "Planned", tint: .blue, isOn: $showPlanned)
                FilterChip(label: "Incident", tint: .indigo, isOn: $showUnplanned)
                FilterChip(label: "Resolved", tint: .eventResolved, isOn: $showResolved)
                    .help("Also show events NZTA has marked resolved (hidden by default)")
                Divider().frame(height: 16)
                islandPicker
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
            }
        } menuItems: {
            Toggle("Closures", isOn: $showClosures)
            Toggle("Delays", isOn: $showDelays)
            Toggle("Caution", isOn: $showCaution)
            Toggle("Other", isOn: $showOther)
            Divider()
            Toggle("Planned", isOn: $showPlanned)
            Toggle("Incident", isOn: $showUnplanned)
            Toggle("Resolved", isOn: $showResolved)
            Divider()
            islandPicker
                .pickerStyle(.inline)
        }
    }

    private var islandPicker: some View {
        Picker("Island", selection: $island) {
            ForEach(EventIslandFilter.allCases) { filter in
                Text(filter.label).tag(filter)
            }
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
            .fixedSize()
    }
}

// The Map's travel-time-sign layer: many boards go blank (overnight most do).
struct BlankTIMToggleRow: View {
    @Binding var hideBlank: Bool

    var body: some View {
        Toggle("Hide blank boards", isOn: $hideBlank)
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.caption.weight(.medium))
            .fixedSize()
            .help("Hide travel time signs that aren't showing any times right now")
    }
}

// A one-line note in a filter bar, e.g. how the shared filters apply to a
// map layer that has no chips of its own.
struct FilterBarNote: View {
    let text: String
    var systemImage = "info.circle"

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

struct CameraStatusFilterRow: View {
    @Binding var showOnline: Bool
    @Binding var showOffline: Bool
    @Binding var showMaintenance: Bool

    var body: some View {
        FilterRowFitting(
            menuTitle: "Status",
            hiddenCount: [showOnline, showOffline, showMaintenance].filter { !$0 }.count
        ) {
            HStack(spacing: 8) {
                FilterRowLabel()
                FilterChip(label: "Online", tint: .green, isOn: $showOnline)
                FilterChip(label: "Offline", tint: .red, isOn: $showOffline)
                FilterChip(label: "Maintenance", tint: .orange, isOn: $showMaintenance)
            }
        } menuItems: {
            Toggle("Online", isOn: $showOnline)
            Toggle("Offline", isOn: $showOffline)
            Toggle("Maintenance", isOn: $showMaintenance)
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
        FilterRowFitting(
            menuTitle: "Flow",
            hiddenCount: [showFreeFlow, showModerate, showSlow, showCongested, showNoData].filter { !$0 }.count
        ) {
            HStack(spacing: 8) {
                FilterRowLabel()
                FilterChip(label: "Free Flow", tint: .green, isOn: $showFreeFlow)
                FilterChip(label: "Moderate", tint: .yellow, isOn: $showModerate)
                FilterChip(label: "Slow", tint: .orange, isOn: $showSlow)
                FilterChip(label: "Congested", tint: .red, isOn: $showCongested)
                FilterChip(label: "No Data", tint: .gray, isOn: $showNoData)
            }
        } menuItems: {
            Toggle("Free Flow", isOn: $showFreeFlow)
            Toggle("Moderate", isOn: $showModerate)
            Toggle("Slow", isOn: $showSlow)
            Toggle("Congested", isOn: $showCongested)
            Toggle("No Data", isOn: $showNoData)
        }
    }
}

extension EventImpactKind {
    var color: Color {
        switch self {
        case .closure:
            return .red
        case .delays:
            return .orange
        case .caution:
            return .yellow
        case .other:
            return .gray
        }
    }
}

// Camera status colours: the map pins, legend and card badges.
extension CameraStatusKind {
    var color: Color {
        switch self {
        case .online:
            return .green
        case .maintenance:
            return .orange
        case .offline:
            return .red
        }
    }
}

extension EVCharger {
    /// Grey when out of service, else purple for DC fast and teal for AC.
    var mapTint: Color {
        if isOutOfService {
            return .evOutOfService
        }
        return isDC ? .purple : .teal
    }
}

extension RoadEvent {
    /// Card stripe, impact badge and map pin colour: the impact colour for
    /// events in force now, purple for upcoming ones and grey for resolved
    /// ones — so a red closure is always a live closure.
    var displayTint: Color {
        if isResolved {
            return .eventResolved
        }
        if isUpcoming {
            return .eventUpcoming
        }
        return impactKind.color
    }

    /// "Upcoming" / "Resolved" for events not in force now; nil otherwise.
    var lifecycleLabel: String? {
        isActive ? nil : statusKind.label
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
    // A shape per level for the text list, beside the level's name.
    var symbol: String {
        switch self {
        case .freeFlow:
            return "circle"
        case .moderate:
            return "circle.lefthalf.filled"
        case .heavy:
            return "circle.fill"
        case .congested:
            return "exclamationmark.circle.fill"
        case .unknown:
            return "questionmark.circle"
        }
    }

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

struct ErrorBanner: View {
    let message: String
    // When supplied, a "Retry" button is shown that re-fetches just this
    // section (see TrafficStore.reload). Nil keeps the banner purely informational.
    var onRetry: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("Error")
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
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.red.opacity(0.25), lineWidth: 1)
        }
    }
}

// Top-of-window banner shown while the data on screen isn't freshly
// confirmed (see FreshnessBanner). Offline / couldn't-reach states are amber
// warnings, styled distinctly from ErrorBanner (red) because saved data is
// still useful — it just may be stale. Saved data shown while the live load
// runs is neutral: nothing has gone wrong.
struct OfflineBanner: View {
    let message: String
    var isWarning = true
    var isUpdating = false

    var body: some View {
        HStack(spacing: 10) {
            if isUpdating {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: isWarning ? "wifi.slash" : "clock.arrow.circlepath")
                    .foregroundStyle(isWarning ? Color.orange : Color.secondary)
            }
            Text(message)
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(isWarning ? Color.orange.opacity(0.12) : Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isWarning ? Color.orange.opacity(0.3) : Color.cardStroke, lineWidth: 1)
        }
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

// Items a section's display settings hide by default (journeys with no live
// data, blank VMS signs), and how to show them.
struct HiddenItemsHint {
    let message: String
    let actionTitle: String
    let action: () -> Void
}

// Native empty state that explains when filters are the reason a section is
// empty and offers a one-tap way to clear them — or, when nothing is being
// filtered, what the section's defaults are hiding and how to show it.
extension EnvironmentValues {
    /// The Watching chip is on for the visible tab but nothing is watched
    /// yet, so it hides everything (set by ContentView).
    @Entry var watchingFilterHasNothingToShow = false
}

struct FilterableEmptyState: View {
    @Environment(\.watchingFilterHasNothingToShow) private var watchingNothing
    let systemImage: String
    let title: String
    // The shared filters or this section's chips are hiding something.
    let hasActiveFilters: Bool
    let onClearFilters: () -> Void
    var hiddenByDefault: HiddenItemsHint?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if hasActiveFilters && watchingNothing {
                Text("Watching is on, but you aren't watching anything yet. Watch a highway, camera or journey, or clear the filters.")
            } else if hasActiveFilters {
                Text("Active filters may be hiding results.")
            } else if let hiddenByDefault {
                Text(hiddenByDefault.message)
            } else {
                Text("Try refreshing, or check back shortly.")
            }
        } actions: {
            if hasActiveFilters {
                Button("Clear Filters", action: onClearFilters)
            }
            if let hiddenByDefault {
                Button(hiddenByDefault.actionTitle, action: hiddenByDefault.action)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 360)
    }
}

// MARK: - Keyboard list navigation

// A list/grid item that takes keyboard focus, shows an accent focus ring (in
// place of the system focus effect, so the two don't stack), and fires
// `onActivate` on Return/Space so the focused item can be "opened" from the
// keyboard; rows without a detail action omit it. Mouse clicks and any
// existing button action are untouched — this only adds a keyboard path.
private struct KeyboardFocusableItem<ID: Hashable>: ViewModifier {
    let id: ID
    @FocusState.Binding var focusedID: ID?
    var onActivate: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .focusable()
            .focusEffectDisabled()
            .focused($focusedID, equals: id)
            .overlay {
                RoundedRectangle(cornerRadius: Radii.card)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .opacity(focusedID == id ? 1 : 0)
                    .allowsHitTesting(false)
            }
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
}

// The arrow keys for a list or grid of keyboard-focusable items, on the
// container: a key press on a focused item bubbles up to it, and the
// container can take focus itself (Tab), so an arrow press from there enters
// the list at its first item. ←/→ step one item, ↑/↓ a row of `columns` (see
// gridFocusTarget). Presses that would leave the list are passed on, so the
// scroll view still scrolls.
private struct KeyboardNavigableContainer<ID: Hashable>: ViewModifier {
    let orderedIDs: [ID]
    let columns: Int
    @FocusState.Binding var focusedID: ID?

    func body(content: Content) -> some View {
        content
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
                move(press.key)
            }
    }

    private func move(_ key: KeyEquivalent) -> KeyPress.Result {
        let direction: GridMove
        switch key {
        case .upArrow:
            direction = .up
        case .downArrow:
            direction = .down
        case .leftArrow:
            direction = .left
        case .rightArrow:
            direction = .right
        default:
            return .ignored
        }
        let current = focusedID.flatMap { orderedIDs.firstIndex(of: $0) }
        guard let target = gridFocusTarget(
            from: current,
            count: orderedIDs.count,
            columns: columns,
            move: direction
        ) else {
            return .ignored
        }
        focusedID = orderedIDs[target]
        return .handled
    }
}

extension View {
    // Apply to each row/card inside a ForEach.
    func keyboardFocusable<ID: Hashable>(
        id: ID,
        focus: FocusState<ID?>.Binding,
        onActivate: (() -> Void)? = nil
    ) -> some View {
        modifier(KeyboardFocusableItem(id: id, focusedID: focus, onActivate: onActivate))
    }

    // Apply to the list or grid holding those items. `orderedIDs` is the
    // visible, already-filtered list in display order, so the arrow keys
    // follow what the user sees; `columns` is the grid's current column count.
    func keyboardNavigation<ID: Hashable>(
        over orderedIDs: [ID],
        columns: Int = 1,
        focus: FocusState<ID?>.Binding
    ) -> some View {
        modifier(KeyboardNavigableContainer(orderedIDs: orderedIDs, columns: columns, focusedID: focus))
    }
}

// Shared by Settings and the Help menu's Clear Offline Cache… confirmation.
enum ClearOfflineCacheText {
    static let explanation = "NZ Traffic deletes the traffic data it saved for offline use and its cached camera images, then reloads everything from NZTA. Use this if saved data looks wrong or keeps causing problems."
}

struct SettingsView: View {
    let store: TrafficStore
    @AppStorage(AutoRefreshPolicy.enabledKey) private var autoRefreshEnabled = false
    @AppStorage(AutoRefreshPolicy.intervalKey) private var refreshIntervalSeconds = AutoRefreshPolicy.defaultInterval
    @AppStorage("nzta.hideEmptyVMS") private var hideEmptyVMS = true
    @AppStorage("nzta.showResolvedEvents") private var showResolvedEvents = false
    @State private var isConfirmingClear = false
    @State private var isClearing = false

    var body: some View {
        Form {
            Section {
                Toggle("Automatically refresh data", isOn: $autoRefreshEnabled)
                Picker("Interval", selection: $refreshIntervalSeconds) {
                    ForEach(AutoRefreshPolicy.intervalOptions, id: \.self) { seconds in
                        Text(AutoRefreshPolicy.intervalLabel(seconds)).tag(seconds)
                    }
                }
                .disabled(!autoRefreshEnabled)
            } header: {
                Text("Auto-Refresh")
            } footer: {
                Text("Keeps running with the window closed, so the menu bar and Dock badge stay current. Slows down while NZ Traffic is in the background with no window showing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Display") {
                Toggle("Hide VMS signs with no active message", isOn: $hideEmptyVMS)
                Toggle("Show resolved road events", isOn: $showResolvedEvents)
            }
            WatchlistSettingsSections(store: store)
            Section("Offline Cache") {
                LabeledContent {
                    Button("Clear Offline Cache…") {
                        isConfirmingClear = true
                    }
                    .disabled(isClearing)
                } label: {
                    Text("Saved traffic data and camera images")
                    Text("Shown when NZTA can’t be reached.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 620)
        .confirmationDialog("Clear the offline cache?", isPresented: $isConfirmingClear) {
            Button("Clear and Reload", role: .destructive) {
                clearOfflineCache()
            }
        } message: {
            Text(ClearOfflineCacheText.explanation)
        }
    }

    private func clearOfflineCache() {
        isClearing = true
        Task {
            await store.clearOfflineCache()
            isClearing = false
        }
    }
}
