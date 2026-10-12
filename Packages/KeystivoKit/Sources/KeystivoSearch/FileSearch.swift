import AppKit
import KeystivoCore

nonisolated public struct FileResult: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let modified: Date?
    public var url: URL { URL(fileURLWithPath: path) }
    public var parentPath: String {
        let parent = (path as NSString).deletingLastPathComponent
        for (prefix, name) in Self.friendlyLocations where parent.hasPrefix(prefix) {
            return name + parent.dropFirst(prefix.count)
        }
        return parent.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    /// Cloud folders shown by their names instead of their Library paths.
    static let friendlyLocations: [(String, String)] = [
        (NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs", "iCloud Drive"),
        (NSHomeDirectory() + "/Library/CloudStorage/", ""),
    ]

    /// Library folders that hold user documents (iCloud Drive, Dropbox, Google Drive, OneDrive…).
    static func isUserDocumentLocation(_ path: String) -> Bool {
        path.contains("/Library/Mobile Documents/") || path.contains("/Library/CloudStorage/")
    }
}

/// Spotlight-backed file and folder search (no own index, no disk crawling).
public final class FileSearch {
    public static let shared = FileSearch()

    private var query: NSMetadataQuery?
    private var continuation: CheckedContinuation<[FileResult], Never>?
    private var observer: (any NSObjectProtocol)?

    public init() {}

    /// Searches file names (best name matches first, then most recent); cancels
    /// any search still in flight. With `recentsWhenEmpty`, an empty query lists
    /// recently used files.
    public func search(_ text: String, limit: Int = 40, foldersOnly: Bool = false, recentsWhenEmpty: Bool = false) async -> [FileResult] {
        cancel()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let recents = trimmed.isEmpty && recentsWhenEmpty
        guard trimmed.count >= 2 || recents else { return [] }

        let query = NSMetadataQuery()
        var predicates: [NSPredicate]
        if recents {
            let since = Date.now.addingTimeInterval(-14 * 86_400) as NSDate
            predicates = [NSPredicate(format: "%K >= %@", "kMDItemLastUsedDate", since)]
            query.sortDescriptors = [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)]
        } else {
            predicates = trimmed.split(separator: " ").map { word in
                NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, "*\(word)*")
            }
            query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
        }
        if foldersOnly {
            predicates.append(NSPredicate(format: "%K == %@", NSMetadataItemContentTypeKey, "public.folder"))
        }
        query.predicate = Self.predicate(matching: predicates)
        query.searchScopes = recents ? [NSMetadataQueryUserHomeScope] : [NSMetadataQueryUserHomeScope, "/Applications", "/Volumes"]
        self.query = query
        let queryID = ObjectIdentifier(query)

        let results = await withCheckedContinuation { continuation in
            self.continuation = continuation
            observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish(queryID, limit: limit * 3) }
            }
            query.start()
            // Spotlight can be slow on first use; never hang the launcher.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.finish(queryID, limit: limit * 3)
            }
        }
        guard !recents else { return Array(results.filter { !$0.path.hasSuffix(".app") }.prefix(limit)) }
        return Array(Self.rank(results, query: trimmed).prefix(limit))
    }

    /// Name match quality first (exact, prefix, word, anywhere), recency second.
    nonisolated static func rank(_ results: [FileResult], query: String) -> [FileResult] {
        let needle = query.lowercased()
        func quality(_ result: FileResult) -> Int {
            let name = result.name.lowercased()
            let stem = (name as NSString).deletingPathExtension
            if name == needle || stem == needle { return 0 }
            if name.hasPrefix(needle) { return 1 }
            if name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(needle) }) { return 2 }
            return 3
        }
        return results.enumerated().sorted { lhs, rhs in
            let (left, right) = (quality(lhs.element), quality(rhs.element))
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    /// NSMetadataQuery throws (an Objective-C exception Swift can't catch) for an
    /// AND compound predicate with a single subpredicate, so only combine 2+.
    nonisolated static func predicate(matching predicates: [NSPredicate]) -> NSPredicate {
        predicates.count == 1 ? predicates[0] : NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
    }

    private func finish(_ finished: ObjectIdentifier, limit: Int) {
        // A timer from an older search must not cut the current one short.
        guard let query, ObjectIdentifier(query) == finished, let continuation else { return }
        query.disableUpdates()
        var results: [FileResult] = []
        for index in 0..<min(query.resultCount, limit * 3) {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            if path.contains("/.") || (path.contains("/Library/") && !FileResult.isUserDocumentLocation(path)) { continue }
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
