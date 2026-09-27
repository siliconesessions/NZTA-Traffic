import AppKit
import Observation

// Window-independent app services, owned by the App rather than a window so
// they keep working with the main window closed (the menu-bar extra keeps the
// app running):
// - starts the store's launch load (saved data first, then live);
// - feeds the store the `nzta.*` auto-refresh settings — whenever they change,
//   from the toolbar's auto-refresh menu, Settings or the Welcome sheet — and the app's
//   activity, so refreshing continues, more slowly, in the background;
// - keeps the Dock badge in step with the active-closure count.
@MainActor
final class AppController {
    private let store: TrafficStore
    private let defaults: UserDefaults
    private var observers: [NSObjectProtocol] = []
    private var badgeTask: Task<Void, Never>?
    private var isStarted = false

    init(store: TrafficStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
    }

    func start() {
        guard !isStarted else {
            return
        }
        isStarted = true
        migrateRefreshInterval()
        applyAutoRefreshSettings()
        observeSettingsAndActivity()
        startDockBadgeUpdates()
        startLaunchLoad()
    }

    // The launch load, bracketed by LaunchGuard's flag: set now, cleared when
    // the first refresh finishes (or on a normal quit), so only a launch that
    // died in between leaves it behind.
    private func startLaunchLoad() {
        let key = LaunchGuard.unfinishedLaunchKey
        let discard = LaunchGuard.shouldDiscardSavedData(previousLaunchUnfinished: defaults.bool(forKey: key))
        defaults.set(true, forKey: key)
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.markLaunchFinished()
            }
        })
        let launch = store.start(discardingSavedData: discard)
        Task {
            await launch.value
            self.markLaunchFinished()
        }
    }

    private func markLaunchFinished() {
        if defaults.bool(forKey: LaunchGuard.unfinishedLaunchKey) {
            defaults.set(false, forKey: LaunchGuard.unfinishedLaunchKey)
        }
    }

    // The interval floor rose from 30 s to 60 s; carry an older stored value
    // (or anything else outside 60–600 s) into range once, so the pickers
    // show a selection.
    private func migrateRefreshInterval() {
        let stored = defaults.object(forKey: AutoRefreshPolicy.intervalKey) as? Int
        if let migrated = AutoRefreshPolicy.migratedStoredInterval(stored) {
            defaults.set(migrated, forKey: AutoRefreshPolicy.intervalKey)
        }
    }

    // The one path from the auto-refresh settings to the scheduler. Unchanged
    // values are a no-op in the store, so reacting to every defaults change
    // (window frames are saved there too) is cheap.
    private func applyAutoRefreshSettings() {
        let interval = defaults.object(forKey: AutoRefreshPolicy.intervalKey) as? Int
        store.configureAutoRefresh(AutoRefreshSettings(
            isEnabled: defaults.bool(forKey: AutoRefreshPolicy.enabledKey),
            storedInterval: interval ?? AutoRefreshPolicy.defaultInterval
        ))
    }

    private func observeSettingsAndActivity() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyAutoRefreshSettings()
            }
        })

        let activityNotifications: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.willCloseNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification
        ]
        for name in activityNotifications {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.scheduleActivityUpdate()
                }
            })
        }
    }

    // Window notifications arrive before the window has actually been ordered
    // out, so read the state on the next turn of the main actor.
    private func scheduleActivityUpdate() {
        Task { [weak self] in
            self?.updateActivity()
        }
    }

    private func updateActivity() {
        let app = NSApplication.shared
        // Any on-screen window the user could be reading: the main window,
        // Help or Settings (panels and the status-item window can't become
        // main).
        let hasVisibleWindow = app.windows.contains { window in
            window.isVisible
                && !window.isMiniaturized
                && window.canBecomeMain
                && window.occlusionState.contains(.visible)
        }
        store.updateAppActivity(isAppActive: app.isActive, hasVisibleWindow: hasVisibleWindow)
    }

    // Active closures on the Dock icon ("3?" when they come from saved data),
    // updated from the store whether or not a window is open.
    private func startDockBadgeUpdates() {
        let store = store
        badgeTask = Task {
            for await label in Observations({ store.dockBadgeLabel }) {
                NSApplication.shared.dockTile.badgeLabel = label
            }
        }
    }
}

// Closing the main window must not quit the app: the menu-bar extra, the Dock
// badge and auto-refresh carry on without it, and the menu bar's
// "Open NZ Traffic" brings the window back.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
