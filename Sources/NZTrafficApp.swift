import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Scene identifiers used with openWindow(id:).
enum SceneID {
    static let main = "main"
    static let help = "help"
}

@main
struct NZTrafficApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // The single TrafficStore is owned at the App level (rather than inside
    // ContentView) so the main window, the MenuBarExtra, and the Export
    // Diagnostics command all read the same live data. AppController runs the
    // window-independent parts: the launch load, auto-refresh settings and
    // activity, and the Dock badge.
    @State private var store: TrafficStore
    @State private var controller: AppController
    // Tab requests for the main window (a notification click opens Road
    // Events), shared with ContentView and the menu bar.
    @State private var navigator: AppNavigator

    init() {
        // Carry preferences and the offline cache over from the pre-rename
        // bundle ID / folder. Must run first: before any @AppStorage read and
        // before TrafficStore's OfflineCache creates the new folder.
        LegacyMigration.runAtLaunch()
        // A bounded shared cache for camera images, reused across launches
        // (image URLs only change on an explicit refresh). The images send
        // ETag/Last-Modified, so the per-refresh reload (see
        // TrafficStore.cameraImageGeneration) is usually a cheap 304. The
        // traffic JSON is sent no-store and never cached here.
        URLCache.shared = URLCache(
            memoryCapacity: 50_000_000,
            diskCapacity: 200_000_000,
            directory: nil
        )
        // `App` is @MainActor-isolated, so its init can build the
        // main-actor-isolated TrafficStore directly.
        let store = TrafficStore()
        let navigator = AppNavigator()
        let controller = AppController(store: store, navigator: navigator)
        _store = State(initialValue: store)
        _controller = State(initialValue: controller)
        _navigator = State(initialValue: navigator)
        // Xcode previews must not load live data (see PreviewSupport.swift).
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" {
            controller.start()
        }
    }

    var body: some Scene {
        // A single main window: reopening it (menu bar, Dock, Window menu)
        // brings back the same one, and refreshing never depends on it.
        Window(AppIdentity.productName, id: SceneID.main) {
            ContentView(store: store)
                .environment(navigator)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1180, height: 780)
        .defaultLaunchBehavior(.presented)
        .commands {
            NZTrafficCommands(store: store)
        }

        Window("NZ Traffic Help", id: SceneID.help) {
            AppHelpView()
        }
        .defaultSize(width: 780, height: 760)

        Settings {
            SettingsView(store: store)
        }

        MenuBarExtra("NZ Traffic", systemImage: "car.fill") {
            MenuBarContent(store: store)
        }
    }
}

struct NZTrafficCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    let store: TrafficStore

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About NZ Traffic") {
                showAboutPanel()
            }
        }

        CommandGroup(replacing: .help) {
            Button("NZ Traffic Help") {
                openWindow(id: SceneID.help)
            }
            .keyboardShortcut("?", modifiers: .command)
            Divider()
            Button("Export Diagnostics…") {
                exportDiagnostics()
            }
            Button("Clear Offline Cache…") {
                confirmClearOfflineCache()
            }
        }
    }

    // Write a plain-text diagnostics report (counts, per-section status and
    // errors, offline-cache files, OS and app version, preferences — no
    // personal data) to a user-chosen location, and say so if that fails.
    private func exportDiagnostics() {
        Task { @MainActor in
            let report = await store.diagnosticsReport()
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.plainText]
            panel.nameFieldStringValue = "NZ-Traffic-Diagnostics.txt"
            panel.canCreateDirectories = true
            panel.title = "Export Diagnostics"
            panel.message = "Save a diagnostics report (counts, data status, recent errors, offline cache, preferences, app and macOS version)."
            guard panel.runModal() == .OK, let url = panel.url else {
                return
            }
            do {
                try report.formattedText().write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    // The same escape hatch as Settings › Clear Offline Cache, reachable from
    // the menu bar even if a window can't be used.
    private func confirmClearOfflineCache() {
        let alert = NSAlert()
        alert.messageText = "Clear the offline cache?"
        alert.informativeText = ClearOfflineCacheText.explanation
        alert.addButton(withTitle: "Clear and Reload")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        Task {
            await store.clearOfflineCache()
        }
    }

    private func showAboutPanel() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? AppIdentity.fallbackVersion
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        let hosts = TrafficAPIService.dataHosts.formatted(.list(type: .and))
        let credits = """
        A native macOS viewer for live New Zealand traffic cameras, road events, VMS signs, travel times and map layers.

        \(AppCredits.attribution)

        \(AppCredits.evAttribution)

        \(AppCredits.notAffiliated)

        Data is fetched directly from \(hosts); the map uses Apple MapKit. The last good data is saved in \(AppCredits.offlineCachePath) for offline use. No analytics, accounts, tracking or app backend.
        """

        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: AppIdentity.productName,
            .applicationVersion: version,
            .version: "Build \(build)",
            .credits: NSAttributedString(
                string: credits,
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            )
        ]

        if let icon = NSApplication.shared.applicationIconImage {
            options[.applicationIcon] = icon
        }

        NSApplication.shared.orderFrontStandardAboutPanel(options: options)
    }
}

// Lightweight at-a-glance menu shown from the macOS menu bar. Reads the same
// shared TrafficStore as the main window (observed, so counts stay live) and
// offers refresh / open-window / quit. Intentionally minimal — it is a glance,
// not a second UI. Times are absolute because a menu doesn't re-render on a
// timer ("5 minutes ago" would freeze).
struct MenuBarContent: View {
    let store: TrafficStore
    @Environment(\.openWindow) private var openWindow
    @AppStorage("nzta.showResolvedEvents") private var showResolvedEvents = false

    private var onlineCameras: Int {
        store.cameras.filter(\.isOnline).count
    }

    var body: some View {
        Text("NZ Traffic")
            .font(.headline)
        Divider()
        Text("Cameras: \(store.cameras.count) (\(onlineCameras) online)")
        Text("Road events: \(store.visibleEventCount(showResolved: showResolvedEvents))")
        Text(activeClosuresText)
        if !store.watchlist.isEmpty {
            Text("On roads you watch: \(store.watchedActiveClosureCount)")
        }
        Text("VMS signs: \(store.vmsSigns.count)")
        Text("Travel times: \(store.journeys.count)")
        Text(updatedText)
        if let banner = store.freshnessBanner {
            Text(banner.shortMessage)
        }
        Divider()
        Button("Refresh Now") {
            Task { await store.loadAllData(bustImageCache: true) }
        }
        .disabled(store.isRefreshing)
        Button("Open NZ Traffic") {
            // Brings the main window forward, or reopens it if it was closed.
            openWindow(id: SceneID.main)
            NSApp.activate()
        }
        Divider()
        Button("Quit NZ Traffic") {
            NSApplication.shared.terminate(nil)
        }
    }

    // Qualified when the count comes from saved data rather than a live fetch.
    private var activeClosuresText: String {
        let line = "Active closures: \(store.criticalAlertCount)"
        return store.eventsAreProvisional ? "\(line) (saved data)" : line
    }

    private var updatedText: String {
        guard let updated = store.lastUpdated else {
            return "Not yet updated"
        }
        let dateStyle: Date.FormatStyle.DateStyle = Calendar.current.isDateInToday(updated) ? .omitted : .abbreviated
        return "Updated \(updated.formatted(date: dateStyle, time: .shortened))"
    }
}
