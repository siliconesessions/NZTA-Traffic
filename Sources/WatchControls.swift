import SwiftUI

// The watchlist's controls on the cards: a star button for a camera or
// journey, context-menu items (also offered to VoiceOver as actions) to
// watch the item or the highways it's on, and a "Watching" badge on events on
// watched roads. They read and edit `TrafficStore.watchlist` through the
// environment (ContentView provides the store), and hide themselves where no
// store is provided.

/// What a watch control acts on.
enum WatchSubject: Equatable {
    case camera(id: String)
    case journey(id: String)
    // Events aren't watched themselves, only the highways they're on.
    case highwaysOnly

    fileprivate var noun: String? {
        switch self {
        case .camera:
            return "Camera"
        case .journey:
            return "Journey"
        case .highwaysOnly:
            return nil
        }
    }

    fileprivate func isWatched(in watchlist: Watchlist) -> Bool {
        switch self {
        case .camera(let id):
            return watchlist.isWatching(cameraID: id)
        case .journey(let id):
            return watchlist.isWatching(journeyID: id)
        case .highwaysOnly:
            return false
        }
    }

    fileprivate func setWatched(_ isWatched: Bool, in watchlist: inout Watchlist) {
        switch self {
        case .camera(let id):
            watchlist.setWatching(cameraID: id, isWatched)
        case .journey(let id):
            watchlist.setWatching(journeyID: id, isWatched)
        case .highwaysOnly:
            break
        }
    }
}

/// A star that watches or unwatches a camera or journey.
struct WatchStarButton: View {
    let subject: WatchSubject
    let name: String
    // Drawn over a camera image: on a material disc so it reads on any frame.
    var onImage = false
    @Environment(TrafficStore.self) private var store: TrafficStore?

    var body: some View {
        if let store, subject != .highwaysOnly {
            let isWatched = subject.isWatched(in: store.watchlist)
            Button {
                store.updateWatchlist { subject.setWatched(!isWatched, in: &$0) }
            } label: {
                Image(systemName: isWatched ? "star.fill" : "star")
                    .font(onImage ? .callout.weight(.semibold) : .body)
                    .foregroundStyle(isWatched ? Color.yellow : (onImage ? Color.primary : Color.secondary))
                    .frame(width: onImage ? 28 : 22, height: onImage ? 28 : 22)
                    .background {
                        if onImage {
                            Circle().fill(.regularMaterial)
                        }
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(isWatched ? "Stop watching \(name)" : "Watch \(name)")
            .accessibilityLabel(isWatched ? "Stop watching \(name)" : "Watch \(name)")
            .accessibilityAddTraits(isWatched ? .isSelected : [])
        }
    }
}

/// Watch / Stop Watching items for a card's context menu (and VoiceOver
/// actions): the item itself, then each highway it's on.
struct WatchMenuItems: View {
    let subject: WatchSubject
    let highwayKeys: Set<String>
    @Environment(TrafficStore.self) private var store: TrafficStore?

    var body: some View {
        if let store {
            let watchlist = store.watchlist
            if let noun = subject.noun {
                let isWatched = subject.isWatched(in: watchlist)
                Button(
                    isWatched ? "Stop Watching \(noun)" : "Watch \(noun)",
                    systemImage: isWatched ? "star.slash" : "star"
                ) {
                    store.updateWatchlist { subject.setWatched(!isWatched, in: &$0) }
                }
            }
            ForEach(sortedHighwayKeys(highwayKeys), id: \.self) { key in
                let isWatched = watchlist.isWatching(highway: key)
                Button(
                    isWatched ? "Stop Watching \(highwayLabel(key))" : "Watch \(highwayLabel(key))",
                    systemImage: isWatched ? "star.slash" : "road.lanes"
                ) {
                    store.updateWatchlist { watchlist in
                        if isWatched {
                            watchlist.unwatchHighway(key)
                        } else {
                            watchlist.watchHighway(key)
                        }
                    }
                }
            }
        }
    }
}

extension View {
    /// The watch items as this card's context menu and VoiceOver actions.
    func watchContextMenu(_ subject: WatchSubject, highwayKeys: Set<String>) -> some View {
        contextMenu {
            WatchMenuItems(subject: subject, highwayKeys: highwayKeys)
        }
        .accessibilityActions {
            WatchMenuItems(subject: subject, highwayKeys: highwayKeys)
        }
    }
}

/// "Watching" on an event that's on a watched highway or journey.
struct WatchedEventBadge: View {
    let event: RoadEvent
    @Environment(TrafficStore.self) private var store: TrafficStore?

    var body: some View {
        if let store, !store.watchlist.isEmpty, store.watchlist.watches(event) {
            Label("Watching", systemImage: "star.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.yellow.opacity(0.22), in: Capsule())
                .help("On a road you watch")
        }
    }
}

/// The "Watching" chip in the Cameras, Road Events and Travel Times filter
/// bars: only what the watchlist covers.
struct WatchingFilterChip: View {
    @Binding var isOn: Bool

    var body: some View {
        FilterChip(label: "Watching", tint: .yellow, isOn: $isOn)
            .help(isOn
                  ? "Showing only what you watch — click to show everything"
                  : "Show only the highways, cameras and journeys you watch")
    }
}

/// Settings › Watchlist: closure notifications, and what is watched.
struct WatchlistSettingsSections: View {
    let store: TrafficStore
    @AppStorage(ClosureNotificationSettings.enabledKey) private var notifiesClosures = false
    @State private var permissionDenied = false
    @State private var newHighway = ""

    var body: some View {
        Section {
            Toggle("Notify me about new closures on watched roads", isOn: $notifiesClosures)
            if permissionDenied {
                Text("NZ Traffic isn't allowed to send notifications. Allow them in System Settings › Notifications, then turn this on again.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Checked after each refresh, with the window open or closed — turn on auto-refresh to hear about closures as they happen. Closures already in force when NZ Traffic starts aren't announced.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onChange(of: notifiesClosures) { _, isOn in
            guard isOn else {
                return
            }
            // Ask only now, when the user first wants notifications.
            Task {
                let granted = await ClosureNotifier.requestAuthorization()
                permissionDenied = !granted
                if !granted {
                    notifiesClosures = false
                }
            }
        }

        Section {
            if store.watchlist.isEmpty {
                Text("Nothing yet. Click the star on a camera or journey, or Control-click a card to watch the highway it's on.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(watchedEntries) { entry in
                watchedRow(entry.name, systemImage: entry.systemImage) {
                    store.updateWatchlist { entry.remove(from: &$0) }
                }
            }
            HStack {
                TextField("Add a highway", text: $newHighway, prompt: Text("e.g. SH1 or State Highway 20A"))
                    .onSubmit(addHighway)
                Button("Watch", action: addHighway)
                    .disabled(canonicalHighwayKey(newHighway) == nil)
            }
        } header: {
            Text("Watchlist")
        } footer: {
            Text("The Watching filter shows only these. A highway covers every camera, event and journey on it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // One row per watched highway, camera and journey. Ids carry the kind:
    // highway "1" and camera "1" are different rows.
    private struct WatchedEntry: Identifiable {
        enum Kind {
            case highway
            case camera
            case journey
        }

        let kind: Kind
        let key: String
        let name: String

        var id: String {
            "\(kind)-\(key)"
        }

        var systemImage: String {
            switch kind {
            case .highway:
                return "road.lanes"
            case .camera:
                return "video"
            case .journey:
                return "speedometer"
            }
        }

        func remove(from watchlist: inout Watchlist) {
            switch kind {
            case .highway:
                watchlist.unwatchHighway(key)
            case .camera:
                watchlist.setWatching(cameraID: key, false)
            case .journey:
                watchlist.setWatching(journeyID: key, false)
            }
        }
    }

    // Highways in road order, then cameras and journeys by name; an id not
    // in the current data (yet) is still listed.
    private var watchedEntries: [WatchedEntry] {
        let watchlist = store.watchlist
        let highways = watchlist.sortedHighways.map {
            WatchedEntry(kind: .highway, key: $0, name: highwayLabel($0))
        }
        let cameras = watchlist.cameraIDs.map { id in
            WatchedEntry(kind: .camera, key: id, name: store.cameras.first { $0.id == id }?.displayName ?? "Camera \(id)")
        }
        let journeys = watchlist.journeyIDs.map { id in
            WatchedEntry(
                kind: .journey,
                key: id,
                name: store.journeys.first { $0.id == id }.map { "\($0.displayName) journey" } ?? "Journey \(id)"
            )
        }
        let byName: (WatchedEntry, WatchedEntry) -> Bool = {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return highways + cameras.sorted(by: byName) + journeys.sorted(by: byName)
    }

    private func watchedRow(_ name: String, systemImage: String, onRemove: @escaping () -> Void) -> some View {
        LabeledContent {
            Button("Remove", action: onRemove)
                .accessibilityLabel("Stop watching \(name)")
        } label: {
            Label(name, systemImage: systemImage)
        }
    }

    private func addHighway() {
        guard canonicalHighwayKey(newHighway) != nil else {
            return
        }
        let raw = newHighway
        store.updateWatchlist { $0.watchHighway(raw) }
        newHighway = ""
    }
}
