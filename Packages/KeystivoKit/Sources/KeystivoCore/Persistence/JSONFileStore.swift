import Foundation

/// Loads and saves a Codable value as pretty-printed JSON, atomically, keeping a
/// backup of files that fail to decode so user data is never silently lost.
public nonisolated struct JSONFileStore<Value: Codable>: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public enum LoadResult {
        case loaded(Value)
        case missing
        case corrupted(any Error, backup: URL?)
    }

    public func load() -> LoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            let data = try Data(contentsOf: url)
            return .loaded(try Self.decoder.decode(Value.self, from: data))
        } catch {
            let backup = url.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date.now.timeIntervalSince1970)).json")
            let moved = (try? FileManager.default.copyItem(at: url, to: backup)) != nil
            return .corrupted(error, backup: moved ? backup : nil)
        }
    }

    public func save(_ value: Value) throws {
        let data = try Self.encoder.encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }
}
