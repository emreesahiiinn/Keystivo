import Foundation
import KeystivoCore

/// Recent screenshots kept as PNG files (CleanShot-style history), newest first.
nonisolated public final class CaptureHistory: @unchecked Sendable {
    public static let shared = CaptureHistory()

    public struct Entry: Identifiable, Hashable, Sendable {
        public let url: URL
        public let date: Date
        public var id: URL { url }
    }

    public let folder: URL
    private let lock = NSLock()
    /// How many captures to keep.
    public var limit = 30

    public init(folder: URL = AppPaths.applicationSupport.appendingPathComponent("Captures", isDirectory: true)) {
        self.folder = folder
    }

    /// Stores a capture and trims the oldest beyond `limit`.
    @discardableResult
    public func add(_ png: Data, date: Date = .now) -> URL? {
        lock.withLock {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = "capture-\(Int(date.timeIntervalSince1970 * 1000)).png"
            let url = folder.appendingPathComponent(name)
            guard (try? png.write(to: url, options: .atomic)) != nil else { return nil }
            for old in entriesUnlocked().dropFirst(max(limit, 1)) { try? FileManager.default.removeItem(at: old.url) }
            return url
        }
    }

    public var entries: [Entry] { lock.withLock { entriesUnlocked() } }

    public func remove(_ entry: Entry) {
        lock.withLock { _ = try? FileManager.default.removeItem(at: entry.url) }
    }

    public func clear() {
        lock.withLock {
            for entry in entriesUnlocked() { try? FileManager.default.removeItem(at: entry.url) }
        }
    }

    private func entriesUnlocked() -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        return files.filter { $0.pathExtension == "png" }.compactMap { url in
            let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return Entry(url: url, date: date)
        }
        .sorted { $0.date > $1.date }
    }
}
