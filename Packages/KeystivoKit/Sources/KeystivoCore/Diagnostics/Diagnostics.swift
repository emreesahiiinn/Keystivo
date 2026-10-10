import Foundation
import Observation
import os

/// Unified logging entry points, one category per module.
public nonisolated enum Log {
    public static let subsystem = Bundle.main.bundleIdentifier ?? "com.keystivo.Keystivo"

    public static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}

nonisolated public enum DiagnosticLevel: String, Codable, Sendable, CaseIterable, Comparable {
    case info, warning, error

    private var rank: Int {
        switch self {
        case .info: 0
        case .warning: 1
        case .error: 2
        }
    }

    public static func < (lhs: DiagnosticLevel, rhs: DiagnosticLevel) -> Bool { lhs.rank < rhs.rank }

    public var symbolName: String {
        switch self {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }
}

nonisolated public struct DiagnosticEntry: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public let date: Date
    public let level: DiagnosticLevel
    public let module: String
    public let message: String
    public let detail: String?

    public init(level: DiagnosticLevel, module: String, message: String, detail: String? = nil, date: Date = .now) {
        id = UUID()
        self.date = date
        self.level = level
        self.module = module
        self.message = message
        self.detail = detail
    }
}

/// Collects user-visible problems (permission failures, API errors, broken automations)
/// for the "Permissions & Diagnostics" center. Keeps a bounded in-memory ring.
@Observable
public final class DiagnosticsCenter {
    public static let shared = DiagnosticsCenter()

    public private(set) var entries: [DiagnosticEntry] = []
    public private(set) var unseenErrorCount = 0
    public var capacity = 400

    @ObservationIgnored private let logger = Log.logger("Diagnostics")

    public init() {}

    public func record(_ level: DiagnosticLevel, module: String, _ message: String, detail: String? = nil) {
        let entry = DiagnosticEntry(level: level, module: module, message: message, detail: detail)
        entries.insert(entry, at: 0)
        if entries.count > capacity { entries.removeLast(entries.count - capacity) }
        if level == .error { unseenErrorCount += 1 }
        switch level {
        case .info: logger.info("[\(module, privacy: .public)] \(message, privacy: .public)")
        case .warning: logger.warning("[\(module, privacy: .public)] \(message, privacy: .public)")
        case .error: logger.error("[\(module, privacy: .public)] \(message, privacy: .public) \(detail ?? "", privacy: .public)")
        }
    }

    public func record(_ error: any Error, module: String, context: String? = nil) {
        let message = context.map { "\($0): \(error.localizedDescription)" } ?? error.localizedDescription
        record(.error, module: module, message, detail: String(describing: error))
    }

    public func markSeen() { unseenErrorCount = 0 }

    public func clear() {
        entries.removeAll()
        unseenErrorCount = 0
    }

    /// Plain-text export for bug reports.
    public func exportText() -> String {
        let formatter = ISO8601DateFormatter()
        return entries.reversed().map { entry in
            var line = "\(formatter.string(from: entry.date)) [\(entry.level.rawValue.uppercased())] [\(entry.module)] \(entry.message)"
            if let detail = entry.detail { line += "\n    \(detail)" }
            return line
        }.joined(separator: "\n")
    }
}
