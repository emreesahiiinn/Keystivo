import Foundation
import SQLite3

public nonisolated struct SQLiteError: Error, CustomStringConvertible, Sendable {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite error \(code): \(message)" }
}

/// Bindable SQLite value.
public nonisolated enum SQLValue: Sendable, Hashable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

/// One result row with typed column access by name.
public nonisolated struct SQLRow: Sendable {
    public let columns: [String: SQLValue]

    public func int(_ name: String) -> Int64? {
        if case .integer(let value) = columns[name] { return value }
        return nil
    }

    public func double(_ name: String) -> Double? {
        switch columns[name] {
        case .real(let value): value
        case .integer(let value): Double(value)
        default: nil
        }
    }

    public func string(_ name: String) -> String? {
        if case .text(let value) = columns[name] { return value }
        return nil
    }

    public func data(_ name: String) -> Data? {
        if case .blob(let value) = columns[name] { return value }
        return nil
    }

    public func bool(_ name: String) -> Bool { (int(name) ?? 0) != 0 }
}

nonisolated(unsafe) private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal, dependency-free SQLite wrapper. Not thread-safe by itself: own it
/// from a single actor.
public nonisolated final class SQLiteDatabase {
    private var handle: OpaquePointer?

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard status == SQLITE_OK else { throw SQLiteError(code: status, message: "open failed") }
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA foreign_keys=ON;")
    }

    /// In-memory database for tests.
    public init(inMemory: Void = ()) throws {
        let status = sqlite3_open(":memory:", &handle)
        guard status == SQLITE_OK else { throw SQLiteError(code: status, message: "open failed") }
    }

    deinit { sqlite3_close_v2(handle) }

    private var lastError: SQLiteError {
        SQLiteError(code: sqlite3_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
    }

    public func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw lastError }
    }

    @discardableResult
    public func run(_ sql: String, _ values: [SQLValue] = []) throws -> Int64 {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else { throw lastError }
        return sqlite3_last_insert_rowid(handle)
    }

    public func query(_ sql: String, _ values: [SQLValue] = []) throws -> [SQLRow] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var rows: [SQLRow] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw lastError }
            var columns: [String: SQLValue] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                columns[name] = switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: .integer(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT: .real(sqlite3_column_double(statement, index))
                case SQLITE_TEXT: .text(String(cString: sqlite3_column_text(statement, index)))
                case SQLITE_BLOB:
                    if let bytes = sqlite3_column_blob(statement, index) {
                        .blob(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index))))
                    } else {
                        .blob(Data())
                    }
                default: .null
                }
            }
            rows.append(SQLRow(columns: columns))
        }
        return rows
    }

    public func scalarInt(_ sql: String, _ values: [SQLValue] = []) throws -> Int64 {
        try query(sql, values).first?.columns.values.first.flatMap {
            if case .integer(let value) = $0 { value } else { nil }
        } ?? 0
    }

    public func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            try body()
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    /// `user_version`-based schema migrations.
    public func migrate(_ migrations: [String]) throws {
        let current = max(0, Int(try scalarInt("PRAGMA user_version;")))
        guard current < migrations.count else { return }
        try transaction {
            for index in current..<migrations.count {
                try execute(migrations[index])
            }
            try execute("PRAGMA user_version = \(migrations.count);")
        }
    }

    private func prepare(_ sql: String, _ values: [SQLValue]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32 = switch value {
            case .null: sqlite3_bind_null(statement, index)
            case .integer(let int): sqlite3_bind_int64(statement, index, int)
            case .real(let double): sqlite3_bind_double(statement, index, double)
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, SQLITE_TRANSIENT)
            case .blob(let data):
                data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
                }
            }
            guard status == SQLITE_OK else {
                sqlite3_finalize(statement)
                throw lastError
            }
        }
        return statement
    }
}
