import Foundation

// Refresh-lifecycle policy: which sections a refresh covers, the auto-refresh
// cadence, the freshness banner, the Dock badge wording and the single-flight
// helper the store uses to coalesce loads. Foundation-only and free of
// SwiftUI/AppKit, like Models.swift, so run_tests.sh compiles and tests it
// standalone; TrafficStore and the App wire it to the live state.

/// A live data section the store loads, reports errors for and (for the
/// four cacheable ones) persists in the offline cache.
enum DataSection: String, CaseIterable, Identifiable, Sendable {
    case cameras
    case events
    case vms
    case journeys
    case timSigns
    case congestion

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .cameras:
            return "Cameras"
        case .events:
            return "Road Events"
        case .vms:
            return "VMS Signs"
        case .journeys:
            return "Travel Times"
        case .timSigns:
            return "TIM Signs"
        case .congestion:
            return "Congestion"
        }
    }

    /// Persisted by the offline cache as raw JSON. These are also the
    /// sections the freshness banner and the Dock badge caveat talk about.
    var isCacheable: Bool {
        switch self {
        case .cameras, .events, .vms, .journeys:
            return true
        case .timSigns, .congestion:
            return false
        }
    }

    static let cacheable: [DataSection] = allCases.filter(\.isCacheable)

    /// What a refresh waits for before it counts as finished. Journeys is
    /// left out on purpose: the endpoint spends 14–17 s computing server-side,
    /// so it loads alongside with its own loading flag instead of holding the
    /// whole refresh (and the Refresh button) back.
    static let refreshedTogether: [DataSection] = [.cameras, .events, .vms, .timSigns, .congestion]
}

/// The auto-refresh setting pair as stored under `nzta.autoRefreshEnabled` /
/// `nzta.refreshIntervalSeconds`, with the interval already clamped.
struct AutoRefreshSettings: Equatable, Sendable {
    var isEnabled: Bool
    var interval: Int

    init(isEnabled: Bool, storedInterval: Int) {
        self.isEnabled = isEnabled
        interval = AutoRefreshPolicy.clamp(storedInterval)
    }
}

enum AutoRefreshPolicy {
    // The @AppStorage keys (unchanged since before the rename).
    static let enabledKey = "nzta.autoRefreshEnabled"
    static let intervalKey = "nzta.refreshIntervalSeconds"

    // NZTA's own map caches for 60 s and every JSON response is no-store and
    // uncompressed (about 2.7 MB a refresh), so a minute is the floor.
    static let minimumInterval = 60
    static let maximumInterval = 600
    static let defaultInterval = 120
    static let intervalOptions = [60, 120, 300, 600]

    // Background cadence (app inactive and no window on screen): three times
    // the chosen interval, but never slower than 15 minutes (or than the
    // chosen interval itself), so the Dock badge and menu-bar counts stay
    // roughly current without polling at full rate for nobody.
    static let backgroundMultiplier = 3
    static let backgroundCeiling = 900

    // A refresh older than this marks the header's "Updated" time as stale.
    static let staleDataAge: TimeInterval = 600

    // Camera images are re-requested (a conditional GET, usually a 304) when
    // the cameras section refreshes, but not more often than this. It is
    // shorter than the 60 s minimum interval so ordinary ticks, whose load
    // times jitter by a few seconds, are never skipped.
    static let cameraImageReloadSpacing: TimeInterval = 30

    static func clamp(_ seconds: Int) -> Int {
        min(maximumInterval, max(minimumInterval, seconds))
    }

    /// The value to write back for a stored interval outside 60–600 s (for
    /// example the old 30 s option), or nil when it is fine as it is or unset.
    static func migratedStoredInterval(_ stored: Int?) -> Int? {
        guard let stored else {
            return nil
        }
        let clamped = clamp(stored)
        return clamped == stored ? nil : clamped
    }

    static func backgroundInterval(for base: Int) -> Int {
        let interval = clamp(base)
        return max(interval, min(interval * backgroundMultiplier, backgroundCeiling))
    }

    /// The interval to use now: the chosen one while the app is frontmost or a
    /// window is on screen, the slower background one otherwise.
    static func effectiveInterval(base: Int, isAppActive: Bool, hasVisibleWindow: Bool) -> Int {
        isAppActive || hasVisibleWindow ? clamp(base) : backgroundInterval(for: base)
    }

    /// Seconds to wait before the next automatic refresh, counted from the
    /// start of the last refresh of any kind (so a manual refresh pushes the
    /// next tick back). Zero when one is due now or none has run yet.
    static func delayUntilNextRefresh(lastAttempt: Date?, now: Date, interval: Int) -> TimeInterval {
        guard let lastAttempt else {
            return 0
        }
        return max(0, lastAttempt.addingTimeInterval(TimeInterval(interval)).timeIntervalSince(now))
    }

    static func shouldReloadCameraImages(lastReload: Date?, now: Date) -> Bool {
        guard let lastReload else {
            return true
        }
        return now.timeIntervalSince(lastReload) >= cameraImageReloadSpacing
    }

    /// Reload once connectivity comes back, but only if something on screen
    /// is unconfirmed — a failed fetch, or data replayed from the offline cache.
    static func shouldReloadOnReconnect(wasOnline: Bool, isOnline: Bool, hasUnconfirmedData: Bool) -> Bool {
        !wasOnline && isOnline && hasUnconfirmedData
    }

    static func isDataStale(lastUpdated: Date?, now: Date) -> Bool {
        guard let lastUpdated else {
            return false
        }
        return now.timeIntervalSince(lastUpdated) > staleDataAge
    }

    /// "1 minute", "2 minutes", "10 minutes" — the interval picker labels.
    static func intervalLabel(_ seconds: Int) -> String {
        guard seconds % 60 == 0 else {
            return "\(seconds) seconds"
        }
        let minutes = seconds / 60
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    /// "1m", "10m" — the compact label next to the auto-refresh control.
    static func shortIntervalLabel(_ seconds: Int) -> String {
        seconds % 60 == 0 ? "\(seconds / 60)m" : "\(seconds)s"
    }
}

/// Breaks a crash loop on saved data. A flag is set when a launch starts and
/// cleared once its first refresh finishes, or when the app quits normally.
/// Finding it still set means the previous launch died in between — most
/// likely while drawing the saved data it had just replayed — so that saved
/// copy is discarded instead of being shown again.
enum LaunchGuard {
    static let unfinishedLaunchKey = "nzta.launch.unfinished"

    static func shouldDiscardSavedData(previousLaunchUnfinished: Bool) -> Bool {
        previousLaunchUnfinished
    }
}

/// What the freshness banner under the header needs to know about one
/// cacheable section.
struct SectionFreshness: Equatable, Sendable {
    var hasData: Bool
    /// The data on screen was replayed from the offline cache.
    var isSaved: Bool
    /// The latest live fetch failed (the data on screen is older).
    var lastFetchFailed: Bool
    var isLoading: Bool
    /// When the data on screen was fetched live, or written to the cache.
    var dataDate: Date?
}

/// The banner under the header whenever what's on screen isn't freshly
/// confirmed. Only `.offline` and `.unreachable` are warnings: saved data shown
/// while the first live load of a launch runs is normal, not an outage.
enum FreshnessBanner: Equatable, Sendable {
    /// No network. `since` is the oldest data on screen.
    case offline(since: Date?)
    /// Online, but a live fetch failed and older data is being shown.
    case unreachable(since: Date?)
    /// Replayed from the offline cache while the live load runs.
    case updating(since: Date?)
    /// Replayed from the offline cache; no load is running and none failed
    /// (e.g. NZTA sent an empty list, so the saved copy was kept).
    case saved(since: Date?)

    static func make(isOnline: Bool, sections: [SectionFreshness]) -> FreshnessBanner? {
        let shown = sections.filter(\.hasData)
        if !isOnline {
            return .offline(since: oldestDate(in: shown))
        }
        let failed = shown.filter(\.lastFetchFailed)
        if !failed.isEmpty {
            return .unreachable(since: oldestDate(in: failed))
        }
        let saved = shown.filter(\.isSaved)
        guard !saved.isEmpty else {
            return nil
        }
        let since = oldestDate(in: saved)
        return saved.contains(where: \.isLoading) ? .updating(since: since) : .saved(since: since)
    }

    // The worst case: the banner reports the oldest data being shown.
    private static func oldestDate(in sections: [SectionFreshness]) -> Date? {
        sections.compactMap(\.dataDate).min()
    }

    var isWarning: Bool {
        switch self {
        case .offline, .unreachable:
            return true
        case .updating, .saved:
            return false
        }
    }

    var isUpdating: Bool {
        if case .updating = self {
            return true
        }
        return false
    }

    func message(relativeTo now: Date) -> String {
        switch self {
        case .offline(let since):
            guard let since else {
                return "Offline — no internet connection."
            }
            return "Offline — showing data from \(describeDataAge(since, relativeTo: now))."
        case .unreachable(let since):
            guard let since else {
                return "Couldn’t reach NZTA — showing the last data received."
            }
            return "Couldn’t reach NZTA — showing data from \(describeDataAge(since, relativeTo: now))."
        case .updating(let since):
            guard let since else {
                return "Showing saved data — updating…"
            }
            return "Showing saved data from \(describeDataAge(since, relativeTo: now)) — updating…"
        case .saved(let since):
            guard let since else {
                return "Showing saved data."
            }
            return "Showing saved data from \(describeDataAge(since, relativeTo: now))."
        }
    }

    /// Timeless wording for the menu-bar menu, which can't re-render on a timer.
    var shortMessage: String {
        switch self {
        case .offline:
            return "Offline — showing saved data"
        case .unreachable:
            return "Couldn’t reach NZTA — showing saved data"
        case .updating:
            return "Showing saved data — updating…"
        case .saved:
            return "Showing saved data"
        }
    }
}

/// "less than a minute ago", "5 minutes ago", "2 hours ago", "3 days ago".
func describeDataAge(_ date: Date, relativeTo now: Date) -> String {
    let age = now.timeIntervalSince(date)
    guard age >= 60 else {
        return "less than a minute ago"
    }
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = Locale(identifier: "en_NZ")
    formatter.unitsStyle = .full
    formatter.dateTimeStyle = .numeric
    return formatter.localizedString(for: date, relativeTo: now)
}

enum DockBadge {
    /// The Dock badge: the active-closure count, or nothing when there are
    /// none. A trailing "?" marks a count taken from saved data (replayed from
    /// the offline cache, or kept after the events fetch failed).
    static func label(activeClosures: Int, isProvisional: Bool) -> String? {
        guard activeClosures > 0 else {
            return nil
        }
        return isProvisional ? "\(activeClosures)?" : "\(activeClosures)"
    }
}

/// Coalesces concurrent work per key: while a job for a key is running, later
/// callers await the same job instead of starting another. Main-actor bound,
/// like the store that uses it, so the in-flight table needs no locking.
@MainActor
final class SingleFlight<Key: Hashable & Sendable, Value: Sendable> {
    private var inFlight: [Key: Task<Value, Never>] = [:]

    init() {}

    func isRunning(_ key: Key) -> Bool {
        inFlight[key] != nil
    }

    var runningKeys: Set<Key> {
        Set(inFlight.keys)
    }

    /// Runs `operation` for `key`, or joins the run already in flight. The
    /// job runs as its own task, so a caller being cancelled doesn't cancel
    /// the work other callers are waiting on.
    func run(_ key: Key, _ operation: @escaping @MainActor () async -> Value) async -> Value {
        if let running = inFlight[key] {
            return await running.value
        }
        let task = Task { @MainActor in
            let value = await operation()
            // Cleared by the job itself, before any waiter resumes, so a
            // caller arriving after it finished starts a fresh run rather than
            // joining a completed one.
            self.inFlight[key] = nil
            return value
        }
        inFlight[key] = task
        return await task.value
    }
}
