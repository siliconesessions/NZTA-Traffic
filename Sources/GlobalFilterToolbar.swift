import SwiftUI

// The window toolbar: Region and Highway on the leading side, the refresh
// status in the middle, Clear Filters (⌘E, which doubles as the Filtered
// indicator), Refresh (⌘R) and the auto-refresh menu on the trailing side,
// and Search as the toolbar's search field (⌘F focuses it).
//
// A ViewModifier so it can own the raw Highway/Search text and its 300 ms
// debounce: a keystroke re-renders only this modifier, never the content it
// wraps. ContentView sees the debounced values alone, at most once per pause
// in typing, and only then re-filters and re-renders the tabs.
struct GlobalFilterToolbar: ViewModifier {
    let store: TrafficStore
    @Binding var selectedRegion: String
    @Binding var debouncedHighway: String
    @Binding var debouncedSearch: String
    // What the visible tab's own chips are hiding (nil when nothing), for the
    // Filtered indicator, its tooltip and whether Clear is enabled.
    let scopedFilterSummary: String?
    // Bumped by ContentView (Clear, or an empty state's Clear Filters) to
    // clear the text fields here.
    let clearRequest: Int
    let onClearAll: () -> Void

    @SceneStorage("nzta.scene.highway") private var highwayFilter = ""
    @SceneStorage("nzta.scene.search") private var searchFilter = ""
    @AppStorage(AutoRefreshPolicy.enabledKey) private var autoRefreshEnabled = false
    @AppStorage(AutoRefreshPolicy.intervalKey) private var refreshIntervalSeconds = AutoRefreshPolicy.defaultInterval
    @State private var debounceTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

    func body(content: Content) -> some View {
        content
            .toolbar { toolbarContent }
            // The sidebar and the filters say what this is; the window's
            // name stays in the Window menu. Leaves the toolbar room for the
            // filters and a full-width search field.
            .toolbar(removing: .title)
            .searchable(text: $searchFilter, placement: .toolbar, prompt: "Search locations")
            .searchFocused($searchFocused)
            .background { searchFocusShortcut }
            .onAppear {
                // Seed the debounced filters from any @SceneStorage-restored values.
                debouncedHighway = highwayFilter
                debouncedSearch = searchFilter
            }
            .onDisappear {
                debounceTask?.cancel()
            }
            .onChange(of: highwayFilter) {
                scheduleDebounce()
            }
            .onChange(of: searchFilter) {
                scheduleDebounce()
            }
            // On the content rather than the picker: a toolbar item in the
            // overflow menu may not be installed, and a restored region NZTA
            // no longer lists must still fall back to All Regions.
            .onChange(of: store.allRegions, initial: true) {
                normalizeRegion()
            }
            .onChange(of: store.canonicalRegions) {
                normalizeRegion()
            }
            .onChange(of: clearRequest) {
                debounceTask?.cancel()
                highwayFilter = ""
                searchFilter = ""
            }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            regionPicker
            highwayField
        }

        ToolbarItem(placement: .status) {
            RefreshStatusLabel(store: store)
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarItemGroup(placement: .primaryAction) {
            clearFiltersButton
            refreshButton
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            autoRefreshMenu
        }
    }

    // MARK: - Filters

    // The raw text counts at once, so the indicator follows typing.
    private var hasActiveFilters: Bool {
        !selectedRegion.isEmpty || !highwayFilter.isEmpty || !searchFilter.isEmpty || scopedFilterSummary != nil
    }

    private var activeFilterSummary: String {
        var parts: [String] = []
        if !selectedRegion.isEmpty { parts.append("Region: \(regionDisplayName(selectedRegion))") }
        if !highwayFilter.isEmpty { parts.append("Highway: \(highwayFilter)") }
        if !searchFilter.isEmpty { parts.append("Search: \(searchFilter)") }
        if let scopedFilterSummary { parts.append(scopedFilterSummary) }
        return parts.isEmpty ? "No active filters" : parts.joined(separator: " · ")
    }

    // Coalesce rapid keystrokes in the highway/search fields so filtering and
    // sorting run at most once per 300 ms of typing rather than per keystroke.
    private func scheduleDebounce() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else {
                return
            }
            if debouncedHighway != highwayFilter {
                debouncedHighway = highwayFilter
            }
            if debouncedSearch != searchFilter {
                debouncedSearch = searchFilter
            }
        }
    }

    // A restored region the list doesn't have yet (the list is still
    // loading) keeps a row of its own, so the picker never shows blank while
    // the filter applies. Once NZTA's region list has loaded, a region it
    // doesn't have falls back to All Regions (see normalizedRegionSelection).
    private var regionPicker: some View {
        Picker("Region", selection: $selectedRegion) {
            Text("All Regions").tag("")
            if !selectedRegion.isEmpty, !store.allRegions.contains(selectedRegion) {
                Text(regionDisplayName(selectedRegion)).tag(selectedRegion)
            }
            ForEach(store.allRegions, id: \.self) { region in
                Text(regionDisplayName(region)).tag(region)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .help("Region")
    }

    private func normalizeRegion() {
        let normalized = normalizedRegionSelection(
            selectedRegion,
            available: store.allRegions,
            listIsComplete: !store.canonicalRegions.isEmpty
        )
        if normalized != selectedRegion {
            selectedRegion = normalized
        }
    }

    private var highwayField: some View {
        TextField("Highway", text: $highwayFilter, prompt: Text("Highway (e.g. SH1)"))
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .frame(width: 140)
            .help("Show one state highway, e.g. SH1, SH 2 or State Highway 20")
    }

    // Hidden control: ⌘F moves focus to the toolbar search field.
    private var searchFocusShortcut: some View {
        Button("") { searchFocused = true }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    // MARK: - Actions

    // Also the Filtered indicator: filled and orange while anything filters
    // the visible results, with the filters listed in its tooltip.
    private var clearFiltersButton: some View {
        Button(action: onClearAll) {
            Label(
                "Clear Filters",
                systemImage: hasActiveFilters
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle"
            )
            .foregroundStyle(hasActiveFilters ? Color.orange : Color.secondary)
        }
        .keyboardShortcut("e", modifiers: .command)
        .disabled(!hasActiveFilters)
        .help(hasActiveFilters ? "Filtered — \(activeFilterSummary). Clear all filters (⌘E)" : "No active filters")
        .accessibilityValue(hasActiveFilters ? activeFilterSummary : "")
    }

    private var refreshButton: some View {
        Button {
            Task {
                await store.loadAllData(bustImageCache: true)
            }
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(store.isRefreshing)
        .help(store.isRefreshing ? "Refreshing…" : "Refresh now (⌘R)")
    }

    private var autoRefreshMenu: some View {
        Menu {
            Toggle("Enable Auto-refresh", isOn: $autoRefreshEnabled)
            Divider()
            Picker("Interval", selection: $refreshIntervalSeconds) {
                ForEach(AutoRefreshPolicy.intervalOptions, id: \.self) { seconds in
                    Text(AutoRefreshPolicy.intervalLabel(seconds)).tag(seconds)
                }
            }
            .disabled(!autoRefreshEnabled)
        } label: {
            // The icon alone while off; with the interval ("5m") while on.
            Label {
                Text(autoRefreshEnabled ? autoRefreshIntervalLabel : "Auto-refresh")
            } icon: {
                Image(systemName: autoRefreshEnabled
                      ? "arrow.triangle.2.circlepath.circle.fill"
                      : "arrow.triangle.2.circlepath.circle")
                    .foregroundStyle(autoRefreshEnabled ? Color.blue : .secondary)
            }
            .labelStyle(AutoRefreshLabelStyle(showsTitle: autoRefreshEnabled))
            .font(.callout.monospacedDigit())
        }
        .accessibilityLabel("Auto-refresh")
        .accessibilityValue(autoRefreshEnabled ? "Every \(autoRefreshIntervalLabel)" : "Off")
        .fixedSize()
        .help(autoRefreshEnabled
              ? "Auto-refresh every \(autoRefreshIntervalLabel)"
              : "Auto-refresh off")
    }

    private var autoRefreshIntervalLabel: String {
        AutoRefreshPolicy.shortIntervalLabel(AutoRefreshPolicy.clamp(refreshIntervalSeconds))
    }
}

private struct AutoRefreshLabelStyle: LabelStyle {
    let showsTitle: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            if showsTitle {
                configuration.title
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// The toolbar's status: "Refreshing…" with the load's progress, or when data
// last arrived from a live fetch (see TrafficStore.lastUpdated). Re-rendered
// every 30 s by the TimelineView so the relative time and the stale warning
// age on their own, not only when something else redraws the window.
struct RefreshStatusLabel: View {
    let store: TrafficStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 6) {
                if store.isRefreshing {
                    ProgressView(value: store.loadProgress)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                    Text("Refreshing…")
                        .foregroundStyle(.secondary)
                } else {
                    let isStale = AutoRefreshPolicy.isDataStale(lastUpdated: store.lastUpdated, now: context.date)
                    if isStale {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help("Data may be stale — refresh to update")
                    }
                    Text(statusText)
                        .foregroundStyle(isStale ? Color.orange : .secondary)
                }
            }
            .font(.callout.monospacedDigit())
            .fixedSize()
            .accessibilityElement(children: .combine)
        }
    }

    private var statusText: String {
        guard let lastUpdated = store.lastUpdated else {
            // No live fetch has succeeded yet this launch.
            return store.savedSections.isEmpty ? "Not updated yet" : "Showing saved data"
        }
        return "Updated \(lastUpdated.formatted(.relative(presentation: .named)))"
    }
}
