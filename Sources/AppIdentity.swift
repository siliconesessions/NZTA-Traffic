import Foundation

// The app's identity — product name, permanent bundle identifier, the
// User-Agent sent to the traffic API, and the Application Support folder —
// plus the one-time migration from the pre-rename identity ("NZTA Traffic",
// bundle ID com.local.NZTATrafficMac). Foundation-only, like Models.swift, so
// run_tests.sh compiles and tests it standalone. The product is deliberately
// not named after the agency: "NZTA" only appears where it credits the data
// source.
enum AppIdentity {
    static let productName = "NZ Traffic"
    static let bundleIdentifier = "io.github.siliconesessions.nztraffic"
    static let projectURL = "https://github.com/siliconesessions/NZTA-Traffic"
    // Folder under Application Support that holds the offline cache.
    static let supportFolderName = "NZTraffic"
    // Stands in for the version when there's no bundle Info.plist to read (the
    // standalone test executable, or a bare `swiftc` build).
    static let fallbackVersion = "0.0.0"

    /// The User-Agent the API client sends, e.g.
    /// `NZTraffic/3.0.0 (macOS; +https://github.com/siliconesessions/NZTA-Traffic)`,
    /// so the API operator can attribute load to a version and find the project.
    static func userAgent(version: String?) -> String {
        // A product version must be an HTTP token (RFC 9110 §5.6.2): drop
        // anything else so an odd version string can't corrupt the header.
        let token = (version ?? "").unicodeScalars.filter(httpTokenCharacters.contains)
        let resolved = token.isEmpty ? fallbackVersion : String(token)
        return "NZTraffic/\(resolved) (macOS; +\(projectURL))"
    }

    private static let httpTokenCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$%&'*+-.^_`|~"
    )

    /// The User-Agent for the running app, versioned from the bundle's
    /// `CFBundleShortVersionString`.
    static func userAgent(bundle: Bundle = .main) -> String {
        userAgent(version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
    }
}

// The wording About, Help, the About panel and the Road Events tab share for
// data credits, licences and the notices NZTA's terms of use ask for. Kept
// here (Foundation-only) so the tests can check it covers every host the API
// client contacts (TrafficAPIService.dataSources).
enum AppCredits {
    static let dataProvider = "NZ Transport Agency Waka Kotahi (NZTA)"
    static let licenceName = "Creative Commons Attribution 4.0 International (CC BY 4.0)"
    static let licenceURL = "https://creativecommons.org/licenses/by/4.0/"
    static let termsURL = "https://www.nzta.govt.nz/traffic-and-travel-information/use-our-data/terms-of-use"
    static let releasesURL = AppIdentity.projectURL + "/releases"

    static let attribution = "Traffic and travel information is provided by \(dataProvider) and participating regional councils, and used under the \(licenceName) licence. Road event, sign and journey text is reformatted for display."

    // CC BY 4.0 asks for the credit, a licence link and a note of changes.
    static let evAttribution = "EV charging station data: EV Roam, NZ Transport Agency Waka Kotahi, licensed under CC BY 4.0. Connector details are reformatted for display."

    static let notAffiliated = "NZ Traffic is an independent viewer for this public data. It is not affiliated with or endorsed by NZTA."

    // NZTA terms of use, clause 3(c): users must be told the events feed
    // covers only "notable", officially verified events.
    static let notableEventsNotice = "Road events cover notable events — ones that may cause delays or need caution — and are published only once NZTA or another official source has verified them, so not every incident on the road is listed."

    /// Where the offline cache lives (OfflineCache.defaultDirectory).
    static let offlineCachePath = "~/Library/Application Support/\(AppIdentity.supportFolderName)/OfflineCache"

    static let offlineCacheNote = "The last successful camera, road event, VMS and travel time responses are saved in \(offlineCachePath) so they can be shown offline, and camera images are cached (up to 200 MB) in the app's Caches folder. Clear Offline Cache (Settings or the Help menu) deletes both."

    // Ad-hoc signed and not notarized, so a downloaded copy is quarantined.
    // macOS 15 removed the Control-click › Open override; this is the flow
    // from macOS 15 on (the app needs macOS 27).
    static let gatekeeperSteps = [
        "Open NZ Traffic once. macOS says Apple could not verify it is free of malware; click Done.",
        "Open System Settings › Privacy & Security, scroll down to Security, and click Open Anyway next to the message about NZ Traffic.",
        "Enter your password (or use Touch ID), then click Open Anyway again when macOS asks. You only need to do this once per download."
    ]
    static let quarantineCommand = "xattr -dr com.apple.quarantine \"/Applications/NZ Traffic.app\""
}

// One-time carry-over of state the pre-rename build left behind. Changing the
// bundle identifier moves the app to a new UserDefaults domain (every `nzta.*`
// preference, including hasSeenWelcome) and the offline cache used to live in
// Application Support/NZTATraffic. Run from the App's init — before any
// @AppStorage read and before the OfflineCache creates its folder — so the
// migrated values are what the UI sees on the first launch after the rename.
// Everything is best-effort and idempotent, and the legacy defaults domain is
// only read, never deleted. The decisions are pure functions over in-memory
// values so the tests never touch the real ~/Library.
enum LegacyMigration {
    static let legacyDefaultsDomain = "com.local.NZTATrafficMac"
    static let legacySupportFolderName = "NZTATraffic"
    // Set in the new domain once the import has run, so it runs at most once
    // (the `nzta.` prefix matches the app's other keys).
    static let defaultsImportedKey = "nzta.migration.legacyDefaultsImported"

    /// The legacy key/values to copy into the current defaults domain, or nil
    /// when the import has already run. A key the current domain already has
    /// is never overwritten.
    static func defaultsToImport(legacy: [String: Any]?, current: [String: Any]) -> [String: Any]? {
        guard current[defaultsImportedKey] == nil else {
            return nil
        }
        return (legacy ?? [:]).filter { key, _ in
            key != defaultsImportedKey && current[key] == nil
        }
    }

    /// Applies `defaultsToImport` through an injected setter, then records the
    /// done flag (also when there was nothing to import, e.g. a fresh install,
    /// so later launches skip the work). Returns how many keys were copied, or
    /// nil when the import had already run.
    @discardableResult
    static func importLegacyDefaults(
        legacy: [String: Any]?,
        current: [String: Any],
        set: (_ value: Any, _ key: String) -> Void
    ) -> Int? {
        guard let values = defaultsToImport(legacy: legacy, current: current) else {
            return nil
        }
        for (key, value) in values {
            set(value, key)
        }
        set(true, defaultsImportedKey)
        return values.count
    }

    /// Live wiring: copies the legacy domain into `defaults`. Reads persistent
    /// domains directly, so values that only exist in NSGlobalDomain or the
    /// registration domain don't count as "already present".
    static func importLegacyDefaults(
        into defaults: UserDefaults = .standard,
        currentDomain: String? = Bundle.main.bundleIdentifier
    ) {
        guard let currentDomain, currentDomain != legacyDefaultsDomain else {
            return
        }
        let current = defaults.persistentDomain(forName: currentDomain) ?? [:]
        guard current[defaultsImportedKey] == nil else {
            return
        }
        importLegacyDefaults(
            legacy: defaults.persistentDomain(forName: legacyDefaultsDomain),
            current: current
        ) { value, key in
            defaults.set(value, forKey: key)
        }
    }

    enum SupportFolderPlan: Equatable {
        case none
        case move(from: URL, to: URL)
    }

    /// Move Application Support/NZTATraffic to …/NZTraffic only when the legacy
    /// folder exists and nothing is at the new path yet — an existing new
    /// folder (the new build already ran) always wins.
    static func supportFolderPlan(
        applicationSupport: URL,
        isDirectory: (URL) -> Bool,
        exists: (URL) -> Bool
    ) -> SupportFolderPlan {
        let legacy = applicationSupport.appendingPathComponent(legacySupportFolderName, isDirectory: true)
        let current = applicationSupport.appendingPathComponent(AppIdentity.supportFolderName, isDirectory: true)
        guard isDirectory(legacy), !exists(current) else {
            return .none
        }
        return .move(from: legacy, to: current)
    }

    /// Performs `supportFolderPlan` inside `applicationSupport`. Returns true
    /// when the legacy folder was moved; a failed move is silently ignored
    /// (the cache simply starts empty).
    @discardableResult
    static func migrateSupportFolder(applicationSupport: URL, fileManager: FileManager = .default) -> Bool {
        let plan = supportFolderPlan(
            applicationSupport: applicationSupport,
            isDirectory: { url in
                var isDirectory: ObjCBool = false
                return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            },
            exists: { url in fileManager.fileExists(atPath: url.path) }
        )
        guard case let .move(from, to) = plan else {
            return false
        }
        return (try? fileManager.moveItem(at: from, to: to)) != nil
    }

    /// Everything the app runs once at launch, against the real user domain
    /// and Application Support folder. Skipped inside Xcode previews, which
    /// must never touch the user's real state (see PreviewSupport.swift).
    static func runAtLaunch(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" else {
            return
        }
        importLegacyDefaults()
        let fileManager = FileManager.default
        if let applicationSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) {
            migrateSupportFolder(applicationSupport: applicationSupport, fileManager: fileManager)
        }
    }
}
