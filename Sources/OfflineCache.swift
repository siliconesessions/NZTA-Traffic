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
        case failed
        /// No directory (previews): the cache is off.
        case disabled
    }

    // nil disables the cache: every operation is a no-op (used by previews).
    private let directory: URL?
    // Digest of what each section's file holds, as last read or written this
    // session. An identical refresh then skips rewriting the file.
    private var knownDigests: [DataSection: ContentDigest] = [:]

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

    init(directory: URL? = OfflineCache.defaultDirectory) {
        self.directory = directory
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// Saves a section's bytes. When they match what the file already holds
    /// (the usual case — most feeds rarely change between ticks) the file is
    /// not rewritten; only its modification date moves forward, so it still
    /// records when the data was last confirmed current.
    @discardableResult
    func write(_ data: Data, digest: ContentDigest? = nil, section: DataSection) -> WriteResult {
        guard let url = fileURL(for: section) else {
            return .disabled
        }
        let digest = digest ?? ContentDigest(of: data)
        let fileManager = FileManager.default
        if knownDigests[section] == digest, fileManager.fileExists(atPath: url.path) {
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            return .unchanged
        }
        do {
            if let directory {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try data.write(to: url, options: .atomic)
            knownDigests[section] = digest
            return .written
        } catch {
            knownDigests[section] = nil
            return .failed
        }
    }

    func read(section: DataSection) -> Entry? {
        guard let url = fileURL(for: section),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        let digest = ContentDigest(of: data)
        knownDigests[section] = digest
        return Entry(data: data, digest: digest, savedAt: modificationDate(of: url))
    }

    func savedAt(section: DataSection) -> Date? {
        fileURL(for: section).flatMap(modificationDate(of:))
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
