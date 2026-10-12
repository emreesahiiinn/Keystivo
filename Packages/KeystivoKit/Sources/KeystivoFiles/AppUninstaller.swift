import AppKit
import KeystivoCore

/// A file or folder belonging to an app.
nonisolated public struct LeftoverItem: Identifiable, Hashable, Sendable {
    public enum Category: String, Sendable, CaseIterable {
        case application, support, caches, preferences, containers, logs, savedState, launchAgents, webData, other
        public var titleKey: String { "uninstall.category.\(rawValue)" }
    }

    public var id: String { url.path }
    public let url: URL
    public let size: Int64
    public let category: Category
}

/// Removes apps together with their support files ("AppCleaner / CleanMyMac").
/// Everything goes to the Trash, so it can be recovered.
public enum AppUninstaller {
    nonisolated public struct AppIdentity: Sendable {
        public let url: URL
        public let bundleID: String
        public let names: [String]
    }

    nonisolated public static func identity(of appURL: URL) -> AppIdentity? {
        guard let bundle = Bundle(url: appURL), let bundleID = bundle.bundleIdentifier else { return nil }
        var names = [appURL.deletingPathExtension().lastPathComponent]
        for key in ["CFBundleName", "CFBundleDisplayName", "CFBundleExecutable"] {
            if let value = bundle.object(forInfoDictionaryKey: key) as? String, !names.contains(value) { names.append(value) }
        }
        return AppIdentity(url: appURL, bundleID: bundleID, names: names)
    }

    /// Apple system apps and Keystivo itself are never removable.
    nonisolated public static func isRemovable(_ appURL: URL) -> Bool {
        let path = appURL.standardizedFileURL.path
        guard !path.hasPrefix("/System/"), appURL.pathExtension == "app" else { return false }
        if let id = Bundle(url: appURL)?.bundleIdentifier, id == Bundle.main.bundleIdentifier { return false }
        return FileManager.default.isDeletableFile(atPath: path)
    }

    /// Whether a Library entry belongs to the app. Deliberately strict: exact
    /// names or bundle-ID prefixes only, so similarly named apps are untouched.
    nonisolated public static func matches(_ entryName: String, identity: AppIdentity) -> Bool {
        let lower = entryName.lowercased()
        let bundleID = identity.bundleID.lowercased()
        let stripped = (lower as NSString).deletingPathExtension
        if lower == bundleID || stripped == bundleID { return true }
        if lower.hasPrefix(bundleID + ".") || lower.hasSuffix("." + bundleID) { return true }
        // Group containers are "<TEAMID>.<bundle id or group>".
        if let dot = lower.firstIndex(of: "."), lower[lower.index(after: dot)...].hasPrefix(bundleID) { return true }
        return identity.names.contains { name in
            let candidate = name.lowercased()
            return candidate.count >= 4 && (stripped == candidate || lower == candidate)
        }
    }

    nonisolated static let locations: [(String, LeftoverItem.Category)] = [
        ("Library/Application Support", .support), ("Library/Caches", .caches), ("Library/Preferences", .preferences),
        ("Library/Containers", .containers), ("Library/Group Containers", .containers), ("Library/Logs", .logs),
        ("Library/Saved Application State", .savedState), ("Library/LaunchAgents", .launchAgents),
        ("Library/HTTPStorages", .webData), ("Library/WebKit", .webData), ("Library/Cookies", .webData),
        ("Library/Application Scripts", .other), ("Library/Preferences/ByHost", .preferences),
    ]

    /// Finds the app bundle and its leftovers with sizes (runs off the main thread).
    public static func scan(appURL: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) async -> [LeftoverItem] {
        await Task.detached(priority: .userInitiated) {
            guard let identity = identity(of: appURL) else { return [] }
            var items = [LeftoverItem(url: appURL, size: size(of: appURL), category: .application)]
            let fileManager = FileManager.default
            for (relative, category) in locations {
                let directory = home.appendingPathComponent(relative)
                guard let entries = try? fileManager.contentsOfDirectory(atPath: directory.path) else { continue }
                for entry in entries where matches(entry, identity: identity) {
                    let url = directory.appendingPathComponent(entry)
                    items.append(LeftoverItem(url: url, size: size(of: url), category: category))
                }
            }
            return items
        }.value
    }

    nonisolated static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        guard values.isDirectory == true else { return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0) }
        var total: Int64 = 0
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }) {
            for case let file as URL in enumerator {
                total += Int64((try? file.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    /// Quits the app if running, then moves every item to the Trash.
    public static func uninstall(_ items: [LeftoverItem]) async throws -> Int64 {
        if let app = items.first(where: { $0.category == .application }),
           let bundleID = Bundle(url: app.url)?.bundleIdentifier {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            running.forEach { $0.terminate() }
            // Never trash an app that's still running (it may be asking to save documents).
            for _ in 0..<50 where running.contains(where: { !$0.isTerminated }) {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if let stillRunning = running.first(where: { !$0.isTerminated }) {
                throw ActionError.failed(L("uninstaller.error.stillRunning", stillRunning.localizedName ?? bundleID))
            }
        }
        var freed: Int64 = 0
        var failures: [String] = []
        for item in items {
            if item.category == .application, !isRemovable(item.url) { failures.append(item.url.lastPathComponent); continue }
            do {
                try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                freed += item.size
            } catch {
                failures.append(item.url.lastPathComponent)
            }
        }
        if !failures.isEmpty { throw ActionError.failed(L("uninstall.error.partial", failures.joined(separator: ", "))) }
        return freed
    }
}
