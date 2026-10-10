import AppKit
import KeystivoCore

nonisolated public struct FileResult: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let modified: Date?
    public var url: URL { URL(fileURLWithPath: path) }
    public var parentPath: String { (path as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
}

/// Spotlight-backed file and folder search (no own index, no disk crawling).
public final class FileSearch {
    public static let shared = FileSearch()

    private var query: NSMetadataQuery?
    private var continuation: CheckedContinuation<[FileResult], Never>?
    private var observer: (any NSObjectProtocol)?

    public init() {}

    /// Searches file names; cancels any search still in flight.
    public func search(_ text: String, limit: Int = 40, foldersOnly: Bool = false) async -> [FileResult] {
        cancel()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return [] }

        let query = NSMetadataQuery()
        var predicates: [NSPredicate] = trimmed.split(separator: " ").map { word in
            NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, "*\(word)*")
        }
        if foldersOnly {
            predicates.append(NSPredicate(format: "%K == %@", NSMetadataItemContentTypeKey, "public.folder"))
        }
        query.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        query.searchScopes = [NSMetadataQueryUserHomeScope, "/Applications"]
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
        self.query = query

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish(limit: limit) }
            }
            query.start()
            // Spotlight can be slow on first use; never hang the launcher.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.finish(limit: limit)
            }
        }
    }

    private func finish(limit: Int) {
        guard let query, let continuation else { return }
        query.disableUpdates()
        var results: [FileResult] = []
        for index in 0..<min(query.resultCount, limit * 3) {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            if path.contains("/Library/") || path.contains("/.") { continue }
            let type = item.value(forAttribute: NSMetadataItemContentTypeKey) as? String
            results.append(FileResult(
                path: path,
                name: item.value(forAttribute: NSMetadataItemFSNameKey) as? String ?? (path as NSString).lastPathComponent,
                isDirectory: type == "public.folder",
                modified: item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date
            ))
            if results.count >= limit { break }
        }
        query.stop()
        cleanup()
        continuation.resume(returning: results)
    }

    public func cancel() {
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: [])
        }
        query?.stop()
        cleanup()
    }

    private func cleanup() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        query = nil
        continuation = nil
    }
}
