import Foundation

// App identity (product name, bundle ID, API User-Agent) and the one-time
// migration from the pre-rename identity. The migration tests run on
// in-memory dictionaries and a throwaway temporary folder — never the real
// UserDefaults domains or ~/Library/Application Support.
func runIdentityTests(_ t: TestRunner) {
    testUserAgent(t)
    testBundleMetadata(t)
    testDiagnosticsTitle(t)
    testLegacyDefaultsImport(t)
    testSupportFolderPlan(t)
    testSupportFolderMove(t)
}

private func testUserAgent(_ t: TestRunner) {
    t.group("API User-Agent")

    t.equal(
        AppIdentity.userAgent(version: "3.0.0"),
        "NZTraffic/3.0.0 (macOS; +https://github.com/siliconesessions/NZTA-Traffic)",
        "User-Agent names the product, version and project URL"
    )
    t.equal(
        AppIdentity.userAgent(version: nil),
        "NZTraffic/0.0.0 (macOS; +https://github.com/siliconesessions/NZTA-Traffic)",
        "missing version falls back to the constant"
    )
    t.equal(
        AppIdentity.userAgent(version: "  "),
        AppIdentity.userAgent(version: nil),
        "blank version falls back to the constant"
    )
    let hostile = AppIdentity.userAgent(version: "3.0 beta\r\nX-Injected: 1")
    t.check(!hostile.contains("\r") && !hostile.contains("\n"), "version can't inject header line breaks")
    t.check(hostile.hasPrefix("NZTraffic/3.0betaX-Injected1 ("), "version is reduced to HTTP token characters")
    // The test executable has no Info.plist, so this exercises the bundle path
    // with the fallback; the app reads CFBundleShortVersionString.
    let fromBundle = AppIdentity.userAgent(bundle: .main)
    t.check(
        fromBundle.hasPrefix("NZTraffic/") && fromBundle.hasSuffix("(macOS; +\(AppIdentity.projectURL))"),
        "bundle-derived User-Agent keeps the product token and contact URL"
    )
}

// Pins that the shipped Info.plist and the Xcode project agree with
// AppIdentity, so the two build paths can't drift apart on identity.
private func testBundleMetadata(_ t: TestRunner) {
    t.group("bundle identity")

    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let plistURL = root.appendingPathComponent("Resources/Info.plist")
    guard
        let data = try? Data(contentsOf: plistURL),
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    else {
        t.check(false, "Resources/Info.plist is readable")
        return
    }
    t.equal(plist["CFBundleIdentifier"] as? String, AppIdentity.bundleIdentifier, "Info.plist bundle ID")
    t.equal(plist["CFBundleName"] as? String, AppIdentity.productName, "Info.plist CFBundleName")
    t.equal(plist["CFBundleDisplayName"] as? String, AppIdentity.productName, "Info.plist CFBundleDisplayName")
    t.equal(plist["CFBundleExecutable"] as? String, "NZTraffic", "Info.plist executable name")
    // The icon comes from Resources/AppIcon.icon via actool, which supplies
    // CFBundleIconName / CFBundleIconFile; a hand-set key would shadow it.
    t.check(plist["CFBundleIconFile"] == nil, "Info.plist leaves CFBundleIconFile to actool")
    t.check(plist["CFBundleIconName"] == nil, "Info.plist leaves CFBundleIconName to actool")
    testIconComposerIcon(t, root: root)
    let copyright = plist["NSHumanReadableCopyright"] as? String ?? ""
    t.check(copyright.contains("siliconesessions"), "copyright names the author")
    t.check(copyright.contains("NZ Transport Agency Waka Kotahi"), "copyright still credits the data source")
    t.check(!AppIdentity.productName.contains("NZTA"), "product name doesn't use the NZTA mark")

    let projectURL = root.appendingPathComponent("NZTraffic.xcodeproj/project.pbxproj")
    guard let project = try? String(contentsOf: projectURL, encoding: .utf8) else {
        t.check(false, "NZTraffic.xcodeproj/project.pbxproj is readable")
        return
    }
    let bundleIDLines = project
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { $0.hasPrefix("PRODUCT_BUNDLE_IDENTIFIER") }
    t.check(!bundleIDLines.isEmpty, "project sets PRODUCT_BUNDLE_IDENTIFIER")
    t.check(
        bundleIDLines.allSatisfy { $0 == "PRODUCT_BUNDLE_IDENTIFIER = \(AppIdentity.bundleIdentifier);" },
        "every Xcode configuration uses the permanent bundle ID"
    )
}

// The app icon is an Icon Composer document that both build paths compile
// with actool: its icon.json must parse and name only images it contains,
// Xcode must build it as the AppIcon, and build_app.sh must compile it too.
private func testIconComposerIcon(_ t: TestRunner, root: URL) {
    let iconURL = root.appendingPathComponent("Resources/AppIcon.icon")
    guard
        let data = try? Data(contentsOf: iconURL.appendingPathComponent("icon.json")),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        t.check(false, "Resources/AppIcon.icon/icon.json is readable JSON")
        return
    }
    let groups = json["groups"] as? [[String: Any]] ?? []
    let imageNames = groups
        .flatMap { $0["layers"] as? [[String: Any]] ?? [] }
        .compactMap { $0["image-name"] as? String }
    t.check(!imageNames.isEmpty, "the icon has at least one image layer")
    t.check(
        imageNames.allSatisfy {
            FileManager.default.fileExists(atPath: iconURL.appendingPathComponent("Assets/\($0)").path)
        },
        "every layer's image exists in AppIcon.icon/Assets"
    )
    let platforms = (json["supported-platforms"] as? [String: Any])?["squares"] as? [String] ?? []
    t.check(platforms.contains("macOS"), "the icon supports macOS")

    let project = (try? String(contentsOf: root.appendingPathComponent("NZTraffic.xcodeproj/project.pbxproj"), encoding: .utf8)) ?? ""
    let appIconLines = project
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { $0.hasPrefix("ASSETCATALOG_COMPILER_APPICON_NAME") }
    t.check(
        appIconLines.count == 2 && appIconLines.allSatisfy { $0 == "ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;" },
        "both target configurations build AppIcon"
    )
    t.check(project.contains("AppIcon.icon in Resources"), "AppIcon.icon is in the target's Resources phase")
    t.check(!project.contains(".icns"), "the Xcode project no longer bundles a hand-made .icns")

    let script = (try? String(contentsOf: root.appendingPathComponent("build_app.sh"), encoding: .utf8)) ?? ""
    t.check(
        script.contains("actool") && script.contains("--app-icon AppIcon") && script.contains("Resources/AppIcon.icon"),
        "build_app.sh compiles the same icon with actool"
    )
}

private func testDiagnosticsTitle(_ t: TestRunner) {
    t.group("diagnostics title")

    let report = DiagnosticsReport(
        appVersion: "3.0.0",
        appBuild: "15",
        generatedAt: Date(timeIntervalSince1970: 0),
        lastUpdated: nil,
        isOnline: true,
        sections: [],
        preferences: [:]
    )
    let lines = report.formattedText().split(separator: "\n", omittingEmptySubsequences: false)
    t.equal(lines.first.map(String.init), "NZ Traffic — Diagnostics Report", "report is titled with the product name")
    t.equal(lines.dropFirst().first.map(String.init), String(repeating: "=", count: 31), "underline matches the title width")
}

private func testLegacyDefaultsImport(_ t: TestRunner) {
    t.group("legacy defaults import")

    let flag = LegacyMigration.defaultsImportedKey
    t.equal(LegacyMigration.legacyDefaultsDomain, "com.local.NZTATrafficMac", "reads the pre-rename bundle ID's domain")

    // Shaped like the old domain's persistent dictionary (Bools and Ints come
    // back from cfprefs as NSNumber).
    let legacy: [String: Any] = [
        "nzta.autoRefreshEnabled": NSNumber(value: true),
        "nzta.refreshIntervalSeconds": NSNumber(value: 300),
        "nzta.hasSeenWelcome": NSNumber(value: true),
        "nzta.event.island": "north",
        "NSWindow Frame main-AppWindow-1": "100 100 1180 780 0 0 1728 1079 "
    ]

    // First launch after the rename: everything is copied, then the flag set.
    var store: [String: Any] = [:]
    let copied = LegacyMigration.importLegacyDefaults(legacy: legacy, current: store) { value, key in
        store[key] = value
    }
    t.equal(copied, 5, "every legacy key is imported into an empty domain")
    t.equal((store["nzta.refreshIntervalSeconds"] as? NSNumber)?.intValue, 300, "numeric value survives the import")
    t.equal(store["nzta.event.island"] as? String, "north", "string value survives the import")
    t.equal((store["nzta.hasSeenWelcome"] as? NSNumber)?.boolValue, true, "hasSeenWelcome carries over")
    t.equal(store[flag] as? Bool, true, "import records the done flag")

    // Second launch: the flag short-circuits, nothing is written.
    var writes = 0
    let again = LegacyMigration.importLegacyDefaults(legacy: legacy, current: store) { _, _ in writes += 1 }
    t.check(again == nil && writes == 0, "import runs only once")

    // A value the new domain already has is never overwritten.
    let current: [String: Any] = ["nzta.refreshIntervalSeconds": NSNumber(value: 60)]
    let plan = LegacyMigration.defaultsToImport(legacy: legacy, current: current)
    t.equal(plan?.count, 4, "keys already present are skipped")
    t.check(plan?["nzta.refreshIntervalSeconds"] == nil, "existing value wins over the legacy one")

    // Fresh install (no legacy domain): nothing to copy, but still marked done
    // so later launches don't re-read the old domain.
    var fresh: [String: Any] = [:]
    let none = LegacyMigration.importLegacyDefaults(legacy: nil, current: fresh) { value, key in
        fresh[key] = value
    }
    t.equal(none, 0, "no legacy domain imports nothing")
    t.equal(fresh.count, 1, "only the done flag is written on a fresh install")
    t.equal(fresh[flag] as? Bool, true, "fresh install is marked done")

    // A stray flag in the legacy domain is not treated as data.
    let strayPlan = LegacyMigration.defaultsToImport(legacy: [flag: true, "nzta.hideEmptyVMS": false], current: [:])
    t.check(strayPlan?[flag] == nil && strayPlan?.count == 1, "the done flag itself is never copied")
}

private func testSupportFolderPlan(_ t: TestRunner) {
    t.group("support folder plan")

    let base = URL(fileURLWithPath: "/virtual/Application Support", isDirectory: true)
    let legacy = base.appendingPathComponent("NZTATraffic", isDirectory: true)
    let current = base.appendingPathComponent("NZTraffic", isDirectory: true)

    func plan(directories: Set<String>, files: Set<String> = []) -> LegacyMigration.SupportFolderPlan {
        LegacyMigration.supportFolderPlan(
            applicationSupport: base,
            isDirectory: { directories.contains($0.lastPathComponent) },
            exists: { directories.contains($0.lastPathComponent) || files.contains($0.lastPathComponent) }
        )
    }

    t.equal(plan(directories: ["NZTATraffic"]), .move(from: legacy, to: current), "legacy folder moves to the new name")
    t.equal(plan(directories: ["NZTATraffic", "NZTraffic"]), .none, "an existing new folder wins")
    t.equal(plan(directories: []), .none, "nothing to move on a fresh install")
    t.equal(plan(directories: [], files: ["NZTATraffic"]), .none, "a legacy file (not a folder) is left alone")
    t.equal(plan(directories: ["NZTATraffic"], files: ["NZTraffic"]), .none, "never moves over an existing item")
}

// One real move in a throwaway temporary folder, to cover the FileManager path.
private func testSupportFolderMove(_ t: TestRunner) {
    t.group("support folder move")

    let fileManager = FileManager.default
    let base = fileManager.temporaryDirectory
        .appendingPathComponent("nz-traffic-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: base) }

    let legacyCache = base.appendingPathComponent("NZTATraffic/OfflineCache", isDirectory: true)
    let payload = Data(#"{"response":{"camera":[]}}"#.utf8)
    do {
        try fileManager.createDirectory(at: legacyCache, withIntermediateDirectories: true)
        try payload.write(to: legacyCache.appendingPathComponent("cameras.json"))
    } catch {
        t.check(false, "could not create the temporary legacy folder: \(error)")
        return
    }

    t.check(LegacyMigration.migrateSupportFolder(applicationSupport: base, fileManager: fileManager), "legacy folder is moved")
    let moved = base.appendingPathComponent("NZTraffic/OfflineCache/cameras.json")
    t.equal(try? Data(contentsOf: moved), payload, "cached section bytes survive the move")
    t.check(!fileManager.fileExists(atPath: base.appendingPathComponent("NZTATraffic").path), "legacy folder is gone after the move")
    t.check(!LegacyMigration.migrateSupportFolder(applicationSupport: base, fileManager: fileManager), "second run is a no-op")

    // If an old build recreates its folder later, the new folder still wins and
    // the legacy one is left untouched.
    try? fileManager.createDirectory(at: legacyCache, withIntermediateDirectories: true)
    t.check(!LegacyMigration.migrateSupportFolder(applicationSupport: base, fileManager: fileManager), "never overwrites the new folder")
    t.check(fileManager.fileExists(atPath: legacyCache.path), "legacy folder is left in place when both exist")
    t.equal(try? Data(contentsOf: moved), payload, "new folder contents are untouched")
}
