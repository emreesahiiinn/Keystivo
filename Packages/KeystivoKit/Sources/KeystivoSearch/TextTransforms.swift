import CryptoKit
import Foundation

/// Quick text actions ("metin için hızlı aksiyonlar"). Pure and testable.
nonisolated public enum TextTransform: String, CaseIterable, Codable, Sendable, Identifiable {
    case uppercase, lowercase, titleCase, sentenceCase, camelCase, snakeCase, kebabCase, slug
    case trimWhitespace, removeLineBreaks, sortLines, uniqueLines, reverseLines
    case urlEncode, urlDecode, base64Encode, base64Decode, jsonPrettyPrint, jsonMinify
    case sha256, md5

    public var id: String { rawValue }
    public var titleKey: String { "transform.\(rawValue)" }

    public var symbolName: String {
        switch self {
        case .uppercase, .lowercase, .titleCase, .sentenceCase: "textformat"
        case .camelCase, .snakeCase, .kebabCase, .slug: "character.cursor.ibeam"
        case .trimWhitespace, .removeLineBreaks: "scissors"
        case .sortLines, .uniqueLines, .reverseLines: "list.bullet"
        case .urlEncode, .urlDecode: "link"
        case .base64Encode, .base64Decode: "lock.doc"
        case .jsonPrettyPrint, .jsonMinify: "curlybraces"
        case .sha256, .md5: "number"
        }
    }

    public func apply(_ text: String, locale: Locale = .current) -> String? {
        switch self {
        case .uppercase: return text.uppercased(with: locale)
        case .lowercase: return text.lowercased(with: locale)
        case .titleCase: return text.capitalized(with: locale)
        case .sentenceCase:
            var result = ""
            var capitalizeNext = true
            for character in text.lowercased(with: locale) {
                if capitalizeNext, character.isLetter {
                    result += String(character).uppercased(with: locale)
                    capitalizeNext = false
                } else {
                    result.append(character)
                }
                if ".!?\n".contains(character) { capitalizeNext = true }
            }
            return result
        case .camelCase:
            let words = Self.words(text)
            guard let first = words.first else { return "" }
            return first.lowercased() + words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined()
        case .snakeCase: return Self.words(text).map { $0.lowercased() }.joined(separator: "_")
        case .kebabCase: return Self.words(text).map { $0.lowercased() }.joined(separator: "-")
        case .slug:
            let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: locale)
                .replacingOccurrences(of: "ı", with: "i")
            return Self.words(folded).map { $0.lowercased() }.joined(separator: "-")
        case .trimWhitespace:
            return text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        case .removeLineBreaks:
            return text.components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " ")
        case .sortLines:
            return text.components(separatedBy: .newlines).sorted { $0.localizedStandardCompare($1) == .orderedAscending }.joined(separator: "\n")
        case .uniqueLines:
            var seen = Set<String>()
            return text.components(separatedBy: .newlines).filter { seen.insert($0).inserted }.joined(separator: "\n")
        case .reverseLines:
            return text.components(separatedBy: .newlines).reversed().joined(separator: "\n")
        case .urlEncode:
            return text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?/")))
        case .urlDecode:
            return text.removingPercentEncoding
        case .base64Encode:
            return Data(text.utf8).base64EncodedString()
        case .base64Decode:
            guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
            return String(data: data, encoding: .utf8)
        case .jsonPrettyPrint, .jsonMinify:
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
            let options: JSONSerialization.WritingOptions = self == .jsonPrettyPrint ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.withoutEscapingSlashes]
            guard let output = try? JSONSerialization.data(withJSONObject: object, options: options.union(.fragmentsAllowed)) else { return nil }
            return String(data: output, encoding: .utf8)
        case .sha256:
            return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        case .md5:
            return Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Splits on non-alphanumerics and camelCase boundaries.
    static func words(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previous: Character?
        for character in text {
            if character.isLetter || character.isNumber {
                if let previous, previous.isLowercase, character.isUppercase, !current.isEmpty {
                    words.append(current)
                    current = ""
                }
                current.append(character)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
            previous = character
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}

/// Text statistics for the "count" quick action.
nonisolated public struct TextStatistics: Equatable, Sendable {
    public let characters: Int
    public let charactersWithoutSpaces: Int
    public let words: Int
    public let lines: Int

    public init(_ text: String) {
        characters = text.count
        charactersWithoutSpaces = text.filter { !$0.isWhitespace }.count
        var wordCount = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in wordCount += 1 }
        words = wordCount
        lines = text.isEmpty ? 0 : text.components(separatedBy: .newlines).count
    }
}
