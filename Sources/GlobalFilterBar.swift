import SwiftUI

// The shared filter bar: Region, Highway and Search, the Filtered indicator,
// Clear (⌘E), Refresh (⌘R) and the auto-refresh menu. It owns the raw
// Highway/Search text and its 300 ms debounce, so a keystroke re-renders only
// this bar; ContentView sees the debounced values alone, at most once per
// pause in typing, and only then re-filters and re-renders the tabs.
struct GlobalFilterBar: View {
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

    var body: some View {
        HStack(spacing: 10) {
            regionPicker

            TextField("Highway (e.g. SH1)", text: $highwayFilter)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 120, maxWidth: 200)

            TextField("Search locations", text: $searchFilter)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 180, maxWidth: 360)
                .focused($searchFocused)

            if hasActiveFilters {
                Label("Filtered", systemImage: "line.3.horizontal.decrease.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .fixedSize()
                    .help(activeFilterSummary)
            }

            Button(action: onClearAll) {
                Image(systemName: "xmark.circle")
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(!hasActiveFilters)
            .help("Clear all filters (⌘E)")

            Button {
                Task {
                    await store.loadAllData(bustImageCache: true)
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(store.isRefreshing)
            .help(store.isRefreshing ? "Refreshing…" : "Refresh now (⌘R)")

            Spacer(minLength: 8)

            autoRefreshMenu
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.background)
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
        .onChange(of: clearRequest) {
            debounceTask?.cancel()
            highwayFilter = ""
            searchFilter = ""
        }
    }

    // The raw text counts at once, so the indicator follows typing.
    private var hasActiveFilters: Bool {
        !selectedRegion.isEmpty || !highwayFilter.isEmpty || !searchFilter.isEmpty || scopedFilterSummary != nil
    }

    private var activeFilterSummary: String {
        var parts: [String] = []
        if !selectedRegion.isEmpty { parts.append("Region: \(selectedRegion)") }
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
                Text(selectedRegion).tag(selectedRegion)
            }
            ForEach(store.allRegions, id: \.self) { region in
                Text(region).tag(region)
            }
        }
        .labelsHidden()
        .frame(width: 180)
        .onChange(of: store.allRegions, initial: true) {
            normalizeRegion()
        }
        .onChange(of: store.canonicalRegions) {
            normalizeRegion()
        }
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

    // Hidden control: ⌘F moves focus to the search field.
    private var searchFocusShortcut: some View {
        Button("") { searchFocused = true }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
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
            HStack(spacing: 4) {
                Image(systemName: autoRefreshEnabled
                      ? "arrow.triangle.2.circlepath.circle.fill"
                      : "arrow.triangle.2.circlepath.circle")
                    .foregroundStyle(autoRefreshEnabled ? Color.blue : .secondary)
                if autoRefreshEnabled {
                    Text(autoRefreshIntervalLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(autoRefreshEnabled
              ? "Auto-refresh every \(autoRefreshIntervalLabel)"
              : "Auto-refresh off")
    }

    private var autoRefreshIntervalLabel: String {
        AutoRefreshPolicy.shortIntervalLabel(AutoRefreshPolicy.clamp(refreshIntervalSeconds))
    }
}
