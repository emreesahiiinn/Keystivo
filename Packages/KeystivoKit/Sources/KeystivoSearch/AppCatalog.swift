import AppKit
import KeystivoCore
import Observation

nonisolated public struct AppRecord: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let bundleID: String?
    /// Additional searchable names (English bundle name, executable name).
    public let aliases: [String]

    public var url: URL { URL(fileURLWithPath: path) }

    public init(path: String, name: String, bundleID: String?, aliases: [String]) {
        self.path = path
        self.name = name
        self.bundleID = bundleID
        self.aliases = aliases
    }
}

/// Frequency/recency statistics that bias ranking toward what the user picks.
nonisolated public struct UsageStats: Codable, Hashable, Sendable {
    public var count: Int
    public var lastUsed: Date

    public init(count: Int = 0, lastUsed: Date = .distantPast) {
        self.count = count
        self.lastUsed = lastUsed
    }

    /// Bonus added to a fuzzy score. Decays with age; capped so a perfect text
    /// match on an unused item still wins over a weak match on a popular one.
    public func boost(now: Date = .now) -> Double {
        guard count > 0 else { return 0 }
        let days = max(now.timeIntervalSince(lastUsed) / 86_400, 0)
        let recency = 1 / (1 + days / 7)
        return min(log2(Double(count) + 1) * 40 * recency, 250)
    }
}

/// Index of installed applications with localized names.
@Observable
public final class AppCatalog {
    public static let shared = AppCatalog()

    public private(set) var apps: [AppRecord] = []
    public private(set) var lastScan: Date?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var watchers: [any DispatchSourceFileSystemObject] = []
    @ObservationIgnored private var pendingRescan: DispatchWorkItem?

    nonisolated public static let searchDirectories: [String] = [
        "/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
        "/System/Library/CoreServices/Applications", NSHomeDirectory() + "/Applications",
    ]

    public init() {}

    /// Rescans when the index is older than `maxAge`.
    public func refreshIfNeeded(maxAge: TimeInterval = 300) {
        if let lastScan, Date.now.timeIntervalSince(lastScan) < maxAge { return }
        rescan()
    }

    public func rescan() {
        startWatching()
        guard scanTask == nil else { return }
        scanTask = Task {
            let records = await Task.detached(priority: .utility) { Self.scan() }.value
            apps = records
            lastScan = .now
            scanTask = nil
        }
    }

    /// Rescans shortly after apps are installed or removed (folder change events, no polling).
    private func startWatching() {
        guard watchers.isEmpty else { return }
        for directory in ["/Applications", NSHomeDirectory() + "/Applications", "/Applications/Setapp"] {
            let descriptor = open(directory, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.scheduleRescan() }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            watchers.append(source)
        }
    }

    private func scheduleRescan() {
        pendingRescan?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.rescan() }
        }
        pendingRescan = work
        // Installers write in bursts; wait until the copy settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    nonisolated static func scan() -> [AppRecord] {
        var seen = Set<String>()
        var records: [AppRecord] = []
        let fileManager = FileManager.default
        var directories = searchDirectories
        directories.append("/System/Library/CoreServices")
        // One level of plain folders too: Setapp, vendor suites (Adobe…), Chrome Apps.
        for directory in ["/Applications", NSHomeDirectory() + "/Applications"] {
            guard let contents = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
            for entry in contents where !entry.hasSuffix(".app") && !entry.hasPrefix(".") && entry != "Utilities" {
                let path = (directory as NSString).appendingPathComponent(entry)
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue { directories.append(path) }
            }
        }
        for directory in directories {
            guard let contents = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
            for entry in contents where entry.hasSuffix(".app") {
                let path = (directory as NSString).appendingPathComponent(entry)
                if directory == "/System/Library/CoreServices", entry != "Finder.app" { continue }
                guard let bundle = Bundle(path: path) else { continue }
                let bundleID = bundle.bundleIdentifier
                let key = bundleID ?? path
                guard seen.insert(key).inserted else { continue }
                if (bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool) == true,
                   (bundle.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool) == true { continue }
                let display = fileManager.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
                var aliases: [String] = []
                if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String, name != display { aliases.append(name) }
                let fileName = (entry as NSString).deletingPathExtension
                if fileName != display, !aliases.contains(fileName) { aliases.append(fileName) }
                records.append(AppRecord(path: path, name: display, bundleID: bundleID, aliases: aliases))
            }
        }
        return records.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    nonisolated public struct Match: Sendable {
        public let app: AppRecord
        public let match: FuzzyMatch
        public let score: Double
    }

    public func search(_ query: String, usage: [String: UsageStats] = [:], limit: Int = 12) -> [Match] {
        apps.compactMap { app -> Match? in
            guard let match = FuzzyMatcher.bestMatch(query, title: app.name, alternates: app.aliases) else { return nil }
            let boost = usage[app.bundleID ?? app.path]?.boost() ?? 0
            return Match(app: app, match: match, score: match.score + boost)
        }
        .sorted { $0.score > $1.score }
        .prefix(limit)
        .map { $0 }
    }

    public func app(bundleID: String) -> AppRecord? {
        apps.first { $0.bundleID == bundleID }
    }
}
