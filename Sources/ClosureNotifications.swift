import AppKit
import Observation
import UserNotifications

// Closure notifications for watched roads, and the small navigator that lets
// a click on one bring up the main window on Road Events. Which closures to
// announce and what the notifications say is pure logic in Watchlist.swift;
// this file only posts them (UserNotifications) and handles the click.

enum ClosureNotificationSettings {
    /// Settings › "Notify me about new closures on watched roads" (off by
    /// default; turning it on asks for permission).
    static let enabledKey = "nzta.notifyWatchedClosures"
}

/// Window-independent navigation requests for the main window: the App can
/// ask for a tab (a notification click) whether or not the window is open.
@Observable
@MainActor
final class AppNavigator {
    /// A tab the main window should switch to; ContentView takes it and
    /// clears it.
    var requestedTab: TrafficTab?
    /// Opens (or brings forward) the main window. ContentView hands over its
    /// `openWindow` action when it appears.
    @ObservationIgnored var openMainWindow: (() -> Void)?

    func show(_ tab: TrafficTab) {
        requestedTab = tab
        if let openMainWindow {
            openMainWindow()
        } else if let window = NSApp.windows.first(where: {
            // SwiftUI suffixes a Window scene's id ("main-AppWindow-1").
            $0.identifier?.rawValue.hasPrefix(SceneID.main) == true
        }) {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
    }
}

/// Posts "Road closed on SH1" notifications for closures the store reports as
/// new on watched roads — only while the setting is on — and opens Road
/// Events when one is clicked. It is the notification centre's delegate, so
/// it also lets them show while NZ Traffic is frontmost.
@MainActor
final class ClosureNotifier: NSObject, UNUserNotificationCenterDelegate {
    private let navigator: AppNavigator
    private let defaults: UserDefaults

    init(navigator: AppNavigator, defaults: UserDefaults = .standard) {
        self.navigator = navigator
        self.defaults = defaults
    }

    /// Becomes the delegate. Called at launch, so a click that launches or
    /// reactivates the app is handled.
    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    var isEnabled: Bool {
        defaults.bool(forKey: ClosureNotificationSettings.enabledKey)
    }

    func post(_ closures: [RoadEvent], watchlist: Watchlist) {
        guard isEnabled else {
            return
        }
        let center = UNUserNotificationCenter.current()
        for item in closureNotificationContents(for: closures, watchlist: watchlist) {
            let content = UNMutableNotificationContent()
            content.title = item.title
            content.body = item.body
            content.sound = .default
            content.threadIdentifier = "watched-closures"
            let request = UNNotificationRequest(identifier: item.identifier, content: content, trigger: nil)
            // Best-effort: without permission the request is simply dropped.
            center.add(request) { _ in }
        }
    }

    /// Asks for permission to post alerts; false when it was refused (now or
    /// earlier, in System Settings).
    static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            self.navigator.show(.events)
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
