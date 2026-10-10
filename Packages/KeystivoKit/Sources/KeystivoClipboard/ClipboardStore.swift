import CryptoKit
import Foundation
import KeystivoCore

nonisolated public enum ClipboardKind: String, Codable, Sendable, CaseIterable {
    case text, richText, url, file, image, color

    public var symbolName: String {
        switch self {
        case .text: "text.alignleft"
        case .richText: "textformat"
        case .url: "link"
        case .file: "doc"
        case .image: "photo"
        case .color: "paintpalette"
        }
    }

    public var titleKey: String { "clipboard.kind.\(rawValue)" }
}

nonisolated public struct ClipboardItem: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var kind: ClipboardKind
    /// Plain-text representation used for display and search.
    public var text: String
    /// RTF data for rich text, PNG for images.
    public var data: Data?
    public var filePaths: [String]
    public var sourceBundleID: String?
    public var createdAt: Date
    public var lastUsedAt: Date
    public var isPinned: Bool
    public var contentHash: String

    public init(id: Int64 = 0, kind: ClipboardKind, text: String, data: Data? = nil, filePaths: [String] = [],
                sourceBundleID: String? = nil, createdAt: Date = .now, lastUsedAt: Date = .now, isPinned: Bool = false) {
        self.id = id
        self.kind = kind
        self.text = text
        self.data = data
        self.filePaths = filePaths
        self.sourceBundleID = sourceBundleID
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.isPinned = isPinned
        self.contentHash = Self.hash(kind: kind, text: text, data: data, files: filePaths)
    }

    public static func hash(kind: ClipboardKind, text: String, data: Data?, files: [String]) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(kind.rawValue.utf8))
        hasher.update(data: Data(text.utf8))
        if kind == .image, let data { hasher.update(data: data) }
        hasher.update(data: Data(files.joined(separator: "\n").utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Single-line preview.
    public var preview: String {
        let collapsed = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return collapsed.trimmingCharacters(in: .whitespaces)
    }
}

/// SQLite-backed history. An actor, so disk I/O never blocks the UI.
public actor ClipboardStore {
    private let db: SQLiteDatabase

    public init(url: URL) throws {
        db = try SQLiteDatabase(url: url)
        try Self.migrate(db)
    }

    /// In-memory store (tests and "don't persist history" privacy mode).
    public init(inMemory: Void = ()) throws {
        db = try SQLiteDatabase()
        try Self.migrate(db)
    }

    private static func migrate(_ db: SQLiteDatabase) throws {
        try db.migrate([
            """
            CREATE TABLE items (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                kind TEXT NOT NULL,
                text TEXT NOT NULL,
                data BLOB,
                files TEXT NOT NULL DEFAULT '',
                source TEXT,
                created REAL NOT NULL,
                used REAL NOT NULL,
                pinned INTEGER NOT NULL DEFAULT 0,
                hash TEXT NOT NULL UNIQUE
            );
            CREATE INDEX items_used ON items(pinned DESC, used DESC);
            """,
        ])
    }

    /// Inserts or, for duplicate content, bumps the existing item to the top.
    @discardableResult
    public func add(_ item: ClipboardItem) throws -> Int64 {
        if let existing = try db.query("SELECT id FROM items WHERE hash = ?", [.text(item.contentHash)]).first?.int("id") {
            try db.run("UPDATE items SET used = ?, source = COALESCE(?, source) WHERE id = ?",
                       [.real(item.lastUsedAt.timeIntervalSince1970), item.sourceBundleID.map(SQLValue.text) ?? .null, .integer(existing)])
            return existing
        }
        return try db.run(
            "INSERT INTO items (kind, text, data, files, source, created, used, pinned, hash) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [
                .text(item.kind.rawValue), .text(item.text), item.data.map(SQLValue.blob) ?? .null,
                .text(item.filePaths.joined(separator: "\n")), item.sourceBundleID.map(SQLValue.text) ?? .null,
                .real(item.createdAt.timeIntervalSince1970), .real(item.lastUsedAt.timeIntervalSince1970),
                .integer(item.isPinned ? 1 : 0), .text(item.contentHash),
            ]
        )
    }

    public func items(matching query: String = "", kind: ClipboardKind? = nil, limit: Int = 200, includeData: Bool = false) throws -> [ClipboardItem] {
        var sql = "SELECT id, kind, text, \(includeData ? "data" : "CASE WHEN kind = 'image' THEN data ELSE NULL END AS data"), files, source, created, used, pinned FROM items"
        var conditions: [String] = []
        var values: [SQLValue] = []
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            for word in trimmed.split(separator: " ") {
                conditions.append("(text LIKE ? ESCAPE '\\' OR files LIKE ? ESCAPE '\\')")
                let pattern = "%" + String(word).replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
                values.append(.text(pattern))
                values.append(.text(pattern))
            }
        }
        if let kind {
            conditions.append("kind = ?")
            values.append(.text(kind.rawValue))
        }
        if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
        sql += " ORDER BY pinned DESC, used DESC LIMIT \(limit)"
        return try db.query(sql, values).map(Self.item(from:))
    }

    public func item(id: Int64) throws -> ClipboardItem? {
        try db.query("SELECT * FROM items WHERE id = ?", [.integer(id)]).first.map(Self.item(from:))
    }

    public func touch(id: Int64) throws {
        try db.run("UPDATE items SET used = ? WHERE id = ?", [.real(Date.now.timeIntervalSince1970), .integer(id)])
    }

    public func setPinned(id: Int64, pinned: Bool) throws {
        try db.run("UPDATE items SET pinned = ? WHERE id = ?", [.integer(pinned ? 1 : 0), .integer(id)])
    }

    public func delete(id: Int64) throws {
        try db.run("DELETE FROM items WHERE id = ?", [.integer(id)])
    }

    public func clear(keepPinned: Bool = true) throws {
        try db.run(keepPinned ? "DELETE FROM items WHERE pinned = 0" : "DELETE FROM items")
        try db.execute("VACUUM;")
    }

    /// Enforces retention: max item count and max age (pinned items are kept).
    public func prune(maxItems: Int, maxAge: TimeInterval?) throws {
        if let maxAge {
            try db.run("DELETE FROM items WHERE pinned = 0 AND used < ?", [.real(Date.now.timeIntervalSince1970 - maxAge)])
        }
        try db.run("""
            DELETE FROM items WHERE pinned = 0 AND id NOT IN (
                SELECT id FROM items WHERE pinned = 0 ORDER BY used DESC LIMIT ?
            )
            """, [.integer(Int64(maxItems))])
    }

    public func count() throws -> Int {
        Int(try db.scalarInt("SELECT COUNT(*) FROM items"))
    }

    private static func item(from row: SQLRow) -> ClipboardItem {
        var item = ClipboardItem(
            id: row.int("id") ?? 0,
            kind: ClipboardKind(rawValue: row.string("kind") ?? "") ?? .text,
            text: row.string("text") ?? "",
            data: row.data("data"),
            filePaths: (row.string("files") ?? "").split(separator: "\n").map(String.init),
            sourceBundleID: row.string("source"),
            createdAt: Date(timeIntervalSince1970: row.double("created") ?? 0),
            lastUsedAt: Date(timeIntervalSince1970: row.double("used") ?? 0),
            isPinned: row.bool("pinned")
        )
        item.contentHash = row.string("hash") ?? item.contentHash
        return item
    }
}
