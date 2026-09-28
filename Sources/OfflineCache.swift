import CryptoKit
import Foundation

/// SHA-256 of a response body. Lets the store and the offline cache tell an
/// unchanged feed from a new one without keeping the previous bytes around.
struct ContentDigest: Hashable, Sendable {
    private let value: SHA256.Digest

    init(of data: Data) {
        value = SHA256.hash(data: data)
    }
}

// Persists raw section JSON to Application Support so the app can show the last
// known data while offline or when a fetch fails. This is the one place the app
// keeps API data on disk (see the offline-cache exception in CLAUDE.md). All IO
// is actor-isolated to keep it off the main actor, and every operation is
// best-effort: failures silently no-op rather than disrupting live data.
// Foundation-only, so run_tests.sh exercises it against a temporary folder.
actor OfflineCache {
    /// A section's cached bytes, their digest and when they were last saved
    /// (or last confirmed unchanged — see `write`).
    struct Entry: Sendable {
        let data: Data
        let digest: ContentDigest
        let savedAt: Date?
    }

    /// One cached file, for Export Diagnostics.
    struct FileInfo: Equatable, Sendable {
        let section: DataSection
        let byteCount: Int
        let savedAt: Date?
    }

    enum WriteResult: Equatable, Sendable {
        case written
        /// Same bytes as the file already holds: only its date was refreshed.
        case unchanged
        /// Changed bytes arriving within `minimumRewriteInterval` of the
        /// section's last write: held in memory (and served by `read`) until
        /// the interval has passed or `flush()` runs.
        case deferred
        case failed
        /// No directory (previews): the cache is off.
        case disabled
    }

    // nil disables the cache: every operation is a no-op (used by previews).
    private let directory: URL?
    // Digest of what each section's file holds, as last read or written this
    // session. An identical refresh then skips rewriting the file.
    private var knownDigests: [DataSection: ContentDigest] = [:]
    // Journeys (~1.5 MB) and events change on most ticks; rewriting them
    // every refresh of a menu-bar app that runs for weeks adds up to
    // gigabytes of SSD writes a day. A changed section is therefore written
    // at most once per interval, the newest bytes waiting here meanwhile.
    private let minimumRewriteInterval: TimeInterval
    private var lastWrites: [DataSection: Date] = [:]
    private var pending: [DataSection: (data: Data, digest: ContentDigest, at: Date)] = [:]
    private let clock: @Sendable () -> Date

    /// How often a changing section is rewritten at most (the app's value).
    static let defaultRewriteInterval: TimeInterval = 600

    /// Application Support/NZTraffic/OfflineCache — the app's real cache.
    /// (Builds before the rename used …/NZTATraffic; LegacyMigration moves
    /// that folder here at launch, before this is first created.)
    static var defaultDirectory: URL {
        let fileManager = FileManager.default
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent(AppIdentity.supportFolderName, isDirectory: true)
            .appendingPathComponent("OfflineCache", isDirectory: true)
    }

    init(
        directory: URL? = OfflineCache.defaultDirectory,
        minimumRewriteInterval: TimeInterval = OfflineCache.defaultRewriteInterval,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory
        self.minimumRewriteInterval = minimumRewriteInterval
        self.clock = clock
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// Saves a section's bytes. When they match what the file already holds
    /// (the usual case — most feeds rarely change between ticks) the file is
    /// not rewritten; only its modification date moves forward, so it still
    /// records when the data was last confirmed current. Changed bytes within
    /// `minimumRewriteInterval` of the section's last write are deferred.
    @discardableResult
    func write(_ data: Data, digest: ContentDigest? = nil, section: DataSection) -> WriteResult {
        guard let url = fileURL(for: section) else {
            return .disabled
        }
        let digest = digest ?? ContentDigest(of: data)
        let now = clock()
        let fileManager = FileManager.default
        if knownDigests[section] == digest, fileManager.fileExists(atPath: url.path) {
            pending[section] = nil
            try? fileManager.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
            return .unchanged
        }
        if let last = lastWrites[section], now.timeIntervalSince(last) < minimumRewriteInterval,
           fileManager.fileExists(atPath: url.path) {
            pending[section] = (data, digest, now)
            return .deferred
        }
        return writeFile(data, digest: digest, at: now, section: section)
    }

    /// Writes any deferred sections now (the app calls this when it goes
    /// inactive and before it quits).
    func flush() {
        for (section, entry) in pending {
            writeFile(entry.data, digest: entry.digest, at: entry.at, section: section)
        }
    }

    @discardableResult
    private func writeFile(_ data: Data, digest: ContentDigest, at date: Date, section: DataSection) -> WriteResult {
        pending[section] = nil
        guard let url = fileURL(for: section) else {
            return .disabled
        }
        let fileManager = FileManager.default
        do {
            if let directory {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try data.write(to: url, options: .atomic)
            // Dated by the cache's clock, like the confirmations above.
            try? fileManager.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            knownDigests[section] = digest
            lastWrites[section] = clock()
            return .written
        } catch {
            knownDigests[section] = nil
            return .failed
        }
    }

    func read(section: DataSection) -> Entry? {
        if let entry = pending[section] {
            return Entry(data: entry.data, digest: entry.digest, savedAt: entry.at)
        }
        guard let url = fileURL(for: section),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        let digest = ContentDigest(of: data)
        knownDigests[section] = digest
        return Entry(data: data, digest: digest, savedAt: modificationDate(of: url))
    }

    func savedAt(section: DataSection) -> Date? {
        if let entry = pending[section] {
            return entry.at
        }
        return fileURL(for: section).flatMap(modificationDate(of:))
    }

    /// The cached files that exist, in section order (Export Diagnostics).
    func fileInfo() -> [FileInfo] {
        DataSection.cacheable.compactMap { section in
            guard let url = fileURL(for: section),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
                return nil
            }
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            return FileInfo(section: section, byteCount: size, savedAt: attributes[.modificationDate] as? Date)
        }
    }

    /// Deletes every cached section (Settings › Clear Offline Cache). Returns
    /// false if a file that exists couldn't be removed.
    @discardableResult
    func removeAll() -> Bool {
        knownDigests.removeAll()
        pending.removeAll()
        lastWrites.removeAll()
        guard directory != nil else {
            return true
        }
        let fileManager = FileManager.default
        var removedEverything = true
        for section in DataSection.cacheable {
            guard let url = fileURL(for: section), fileManager.fileExists(atPath: url.path) else {
                continue
            }
            if (try? fileManager.removeItem(at: url)) == nil {
                removedEverything = false
            }
        }
        return removedEverything
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func fileURL(for section: DataSection) -> URL? {
        directory?.appendingPathComponent("\(section.rawValue).json", isDirectory: false)
    }
}
