import AppKit
import SwiftUI

@main
struct NZTATrafficApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1180, height: 780)
        .commands {
            NZTATrafficCommands()
        }

        Window("NZTA Traffic Help", id: "help") {
            AppHelpView()
        }
        .defaultSize(width: 780, height: 760)
    }
}

struct NZTATrafficCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About NZTA Traffic") {
                showAboutPanel()
            }
        }

        CommandGroup(replacing: .help) {
            Button("NZTA Traffic Help") {
                openWindow(id: "help")
            }
            .keyboardShortcut("/", modifiers: [.command, .shift])
        }
    }

    private func showAboutPanel() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        let credits = """
        A native macOS viewer for live New Zealand traffic cameras, road events, Variable Message Signs, and map layers.

        Traffic and travel information is provided by Waka Kotahi NZ Transport Agency and participating regional councils. NZTA Traffic is an independent viewer for that public data.

        The app fetches live data directly from the NZTA Traffic and Travel REST API v4 and uses Apple MapKit for map display. It does not include analytics, accounts, tracking, or an app-specific backend.
        """

        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "NZTA Traffic",
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
