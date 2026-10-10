import AppKit
import KeystivoCore
import Observation

nonisolated public struct ShelfItem: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let url: URL?
    public let text: String?
    public let addedAt = Date.now

    public init(url: URL) {
        self.url = url
        text = nil
    }

    public init(text: String) {
        url = nil
        self.text = text
    }

    public var title: String { url?.lastPathComponent ?? text?.prefix(60).description ?? "" }
}

/// A temporary holding area for dragged files and text ("Yoink / Dropover").
@Observable
public final class ShelfStore {
    public static let shared = ShelfStore()

    public private(set) var items: [ShelfItem] = []

    public init() {}

    public func add(urls: [URL]) {
        for url in urls where !items.contains(where: { $0.url == url }) {
            items.append(ShelfItem(url: url))
        }
    }

    public func add(text: String) {
        guard !text.isEmpty else { return }
        items.append(ShelfItem(text: text))
    }

    /// Reads files or text from a pasteboard (drop or clipboard).
    @discardableResult
    public func add(from pasteboard: NSPasteboard) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            add(urls: urls)
            return true
        }
        if let text = pasteboard.string(forType: .string) {
            add(text: text)
            return true
        }
        return false
    }

    public func remove(_ item: ShelfItem) { items.removeAll { $0.id == item.id } }
    public func clear() { items.removeAll() }

    public var fileURLs: [URL] { items.compactMap(\.url) }

    /// Moves every shelved file into `folder`.
    public func moveAll(to folder: URL) throws {
        for item in items {
            guard let url = item.url else { continue }
            try FileManager.default.moveItem(at: url, to: folder.appendingPathComponent(url.lastPathComponent))
        }
        items.removeAll { $0.url != nil }
    }
}
