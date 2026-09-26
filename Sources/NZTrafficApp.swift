import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct NZTrafficApp: App {
    // The single TrafficStore is owned at the App level (rather than inside
    // ContentView) so the main window, the MenuBarExtra, and the Export
    // Diagnostics command all read the same live data.
    @State private var store: TrafficStore

    init() {
        // Carry preferences and the offline cache over from the pre-rename
        // bundle ID / folder. Must run first: before any @AppStorage read and
        // before TrafficStore's OfflineCache creates the new folder.
        LegacyMigration.runAtLaunch()
        // A bounded shared cache lets camera images persist across refreshes and
        // app launches; AsyncImage (URLSession.shared) revalidates via HTTP
        // headers instead of re-downloading everything on every refresh tick.
        URLCache.shared = URLCache(
            memoryCapacity: 50_000_000,
            diskCapacity: 200_000_000,
            directory: nil
        )
        // `App` is @MainActor-isolated, so its init can build the
        // main-actor-isolated TrafficStore directly.
        _store = State(initialValue: TrafficStore())
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1180, height: 780)
        .commands {
            NZTrafficCommands(store: store)
        }

        Window("NZ Traffic Help", id: "help") {
            AppHelpView()
        }
        .defaultSize(width: 780, height: 760)

        Settings {
            SettingsView()
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
                openWindow(id: "help")
            }
            .keyboardShortcut("?", modifiers: .command)
            Divider()
            Button("Export Diagnostics…") {
                exportDiagnostics()
            }
        }
    }

    // Write a plain-text diagnostics report (counts, recent per-section errors,
    // preferences, app version — no personal data) to a user-chosen location.
    private func exportDiagnostics() {
        let report = store.diagnosticsReport()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "NZ-Traffic-Diagnostics.txt"
        panel.canCreateDirectories = true
        panel.title = "Export Diagnostics"
        panel.message = "Save a diagnostics report (counts, recent errors, preferences, app version)."
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        try? report.formattedText().write(to: url, atomically: true, encoding: .utf8)
    }

    private func showAboutPanel() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        let credits = """
        A native macOS viewer for live New Zealand traffic cameras, road events, Variable Message Signs, and map layers.

        Traffic and travel information is provided by NZ Transport Agency Waka Kotahi (NZTA) and participating regional councils, under CC BY 4.0. NZ Traffic is an independent viewer for that public data and is not affiliated with or endorsed by NZTA.

        The app fetches live data directly from the NZTA Traffic and Travel REST API v5 and uses Apple MapKit for map display. It does not include analytics, accounts, tracking, or an app-specific backend.
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
// not a second UI.
struct MenuBarContent: View {
    let store: TrafficStore
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
        Text("Active closures: \(store.criticalAlertCount)")
        Text("VMS signs: \(store.vmsSigns.count)")
        Text("Travel times: \(store.journeys.count)")
        if let updated = store.lastUpdated {
            Text("Updated \(updated.formatted(.relative(presentation: .named)))")
        } else {
            Text("Not yet updated")
        }
        Divider()
        Button("Refresh Now") {
            Task { await store.loadAllData(bustImageCache: true) }
        }
        .disabled(store.isRefreshing)
        Button("Open NZ Traffic") {
            activateMainWindow()
        }
        Divider()
        Button("Quit NZ Traffic") {
            NSApplication.shared.terminate(nil)
        }
    }

    // Bring the app and its existing main window forward.
    private func activateMainWindow() {
        NSApp.activate()
        for window in NSApplication.shared.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }
}
