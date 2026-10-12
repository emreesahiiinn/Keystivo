import Foundation
import KeystivoCore

/// One emoji or symbol with its name in the user's language and in English.
nonisolated public struct EmojiEntry: Sendable, Hashable, Identifiable {
    public let glyph: String
    public let name: String
    public let englishName: String
    public let isSymbol: Bool

    public var id: String { glyph }
}

/// Emoji and typographic symbols, searchable by name in any supported language.
///
/// Names come from macOS's own emoji annotations (the ones the Character
/// Viewer uses), so "kalp", "Herz" and "heart" all find ❤️. Symbols use their
/// Unicode names. Everything is loaded once per language and cached.
nonisolated public enum EmojiCatalog {
    private static let resources = "/System/Library/PrivateFrameworks/CoreEmoji.framework/Versions/A/Resources"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: [EmojiEntry]] = [:]

    /// All entries, in picker order, named in `language` (an app language code such as "tr" or "zh-Hans").
    public static func entries(language: String) -> [EmojiEntry] {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[language] { return cached }
        let english = names(directory: "en")
        let local = language == "en" ? english : names(directory: directory(for: language))
        var emoji = english.keys.map { glyph in
            EmojiEntry(glyph: glyph, name: local[glyph] ?? english[glyph] ?? glyph, englishName: english[glyph] ?? "", isSymbol: false)
        }
        emoji.sort { order($0.glyph) < order($1.glyph) }
        let entries = emoji + symbols.map { glyph in
            let name = unicodeName(glyph)
            return EmojiEntry(glyph: glyph, name: name, englishName: name, isSymbol: true)
        }
        cache[language] = entries
        return entries
    }

    /// Ranked matches for `query`; an empty query returns everything in order.
    public static func search(_ query: String, language: String) -> [(entry: EmojiEntry, match: FuzzyMatch?)] {
        let all = entries(language: language)
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return all.map { ($0, nil) } }
        let matches = all.compactMap { entry -> (EmojiEntry, FuzzyMatch?)? in
            guard let match = FuzzyMatcher.bestMatch(trimmed, title: entry.name, alternates: [entry.englishName]) else { return nil }
            return (entry, match)
        }
        // The emoji people actually use come first among good matches ("kalp" → ❤️).
        let best = matches.map { $0.1?.score ?? 0 }.max() ?? 0
        let needle = FuzzyMatcher.fold(trimmed)
        func hasWord(_ name: String) -> Bool {
            FuzzyMatcher.fold(name).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0.hasPrefix(needle) }
        }
        func rank(_ pair: (EmojiEntry, FuzzyMatch?)) -> Double {
            let score = pair.1?.score ?? 0
            guard let index = popularIndex[pair.0.glyph], hasWord(pair.0.name) || hasWord(pair.0.englishName) else { return score }
            return best * 1.5 - Double(index) * 0.001 * best
        }
        // Rank each match once: short queries ("a") match thousands of entries.
        return matches.map { ($0, rank($0)) }.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// Most used emoji, most popular first.
    static let popular: [String] = [
        "❤️", "😂", "👍", "😊", "🙏", "😍", "🔥", "😭", "🥰", "✅", "🎉", "😅", "🤔", "👏", "😘", "💯", "✨", "😁", "🙂", "😉",
        "🤣", "😢", "😎", "👀", "💪", "🙌", "😆", "🥲", "😡", "👌", "💕", "😴", "🤗", "😇", "🤩", "😬", "🙄", "😔", "😱", "🤝",
        "💙", "💚", "💛", "🧡", "💜", "🖤", "🤍", "💔", "⭐", "🌟", "☀️", "🌙", "⚡", "🎂", "🎁", "🍀", "🌹", "☕", "🍕", "🚀",
        "💡", "📌", "📎", "📅", "⏰", "⚠️", "❌", "❗", "❓", "➕", "👋", "✌️", "🤞", "👎", "🫶", "🤦", "🤷", "💀", "🥳", "😋",
    ]

    static let popularIndex: [String: Int] = Dictionary(popular.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })

    // MARK: Loading

    /// CoreEmoji's localization folders use underscores and region-specific Chinese names.
    static func directory(for language: String) -> String {
        switch language {
        case "zh-Hans": "zh_CN"
        case "zh-Hant": "zh_TW"
        case "pt-BR": "pt_BR"
        default: language
        }
    }

    private static func names(directory: String) -> [String: String] {
        let path = "\(resources)/\(directory).lproj/AppleName.strings"
        guard let dictionary = NSDictionary(contentsOfFile: path) as? [String: String], !dictionary.isEmpty else {
            return directory == "en" ? fallbackNames() : [:]
        }
        return dictionary
    }

    /// Without the system annotations: every emoji-presentation code point with its Unicode name.
    private static func fallbackNames() -> [String: String] {
        var result: [String: String] = [:]
        for range in [0x1F300...0x1F5FF, 0x1F600...0x1F64F, 0x1F680...0x1F6FF, 0x1F900...0x1F9FF, 0x1FA70...0x1FAFF, 0x2600...0x27BF] {
            for value in range {
                guard let scalar = Unicode.Scalar(value), scalar.properties.isEmojiPresentation else { continue }
                let glyph = String(Character(scalar))
                result[glyph] = unicodeName(glyph)
            }
        }
        return result
    }

    static func unicodeName(_ glyph: String) -> String {
        let names = glyph.unicodeScalars.compactMap { $0.properties.name?.lowercased() }
        return names.isEmpty ? glyph : names.joined(separator: " ")
    }

    /// Smileys first, then hearts and hands, then everything else by code point.
    private static func order(_ glyph: String) -> (Int, UInt32, Int) {
        let value = glyph.unicodeScalars.first?.value ?? 0
        let group: Int = switch value {
        case 0x1F600...0x1F64F, 0x1F910...0x1F92F, 0x1F970...0x1F97A, 0x1F9D0, 0x1FAE0...0x1FAE8, 0x263A: 0
        case 0x2764, 0x2763, 0x1F493...0x1F49F, 0x1F9E1, 0x1F90D, 0x1F90E, 0x1FA75...0x1FA77, 0x1F5A4: 1
        case 0x1F44A...0x1F450, 0x1F590, 0x1F595, 0x1F596, 0x1F918...0x1F91F, 0x1F932, 0x270A...0x270D, 0x1FAF0...0x1FAF8: 2
        case 0x1F466...0x1F487, 0x1F9D1...0x1F9DF, 0x1F574...0x1F57A: 3
        case 0x1F400...0x1F43F, 0x1F980...0x1F9AE, 0x1F330...0x1F343: 4
        case 0x1F345...0x1F37F, 0x1F950...0x1F96F, 0x1F9C0...0x1F9CB: 5
        default: 6
        }
        return (group, value, glyph.unicodeScalars.count)
    }

    /// Symbols people look up most: keyboard keys, arrows, math, currency, typography.
    static let symbols: [String] = [
        "⌘", "⌥", "⇧", "⌃", "⎋", "⏎", "↩", "⌫", "⌦", "⇥", "⇪", "⏏", "⇞", "⇟", "↖", "↘", "⌽",
        "→", "←", "↑", "↓", "↔", "↕", "⇒", "⇐", "⇔", "⇢", "↗", "↙", "⟶", "⟵", "↻", "↺",
        "•", "·", "…", "—", "–", "“", "”", "‘", "’", "«", "»", "‹", "›", "„", "†", "‡", "§", "¶", "№",
        "°", "±", "×", "÷", "≠", "≈", "≤", "≥", "∞", "√", "∑", "∏", "∆", "∫", "∂", "π", "µ", "Ω", "‰", "½", "¼", "¾", "²", "³",
        "∈", "∉", "∩", "∪", "⊂", "⊃", "∀", "∃", "¬", "∧", "∨", "⌀", "℃", "℉",
        "€", "£", "¥", "₺", "₹", "₽", "₩", "₿", "¢", "$",
        "©", "®", "™", "✓", "✔", "✗", "✘", "★", "☆", "♥", "♦", "♣", "♠", "☐", "☑", "☒", "♪", "♫", "☀", "☁", "☂", "☎", "✉", "✂", "⚠",
    ]
}
