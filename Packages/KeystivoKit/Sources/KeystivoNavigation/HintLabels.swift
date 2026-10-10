import Foundation

/// Generates short, prefix-free hint labels ("AS", "AD", …) for on-screen elements.
nonisolated public enum HintLabelGenerator {
    /// Home-row first, then the rest of the letters: fast to reach on any layout.
    public static let defaultAlphabet = "asdfghjklqwertyuiopzxcvbnm"

    /// Produces `count` unique labels using the fewest characters possible.
    ///
    /// Labels are prefix-free: no label is a prefix of another, so a match is
    /// unambiguous the moment the last character is typed.
    public static func labels(count: Int, alphabet: String = defaultAlphabet) -> [String] {
        var seen = Set<Character>()
        let characters = alphabet.lowercased().filter { $0.isLetter && seen.insert($0).inserted }.map { String($0) }
        guard count > 0, characters.count >= 2 else { return [] }

        // Breadth-first expansion of a trie: expanded nodes fall behind `offset`,
        // so the remaining slice contains only leaves, which are prefix-free and
        // as short as possible.
        var hints = [""]
        var offset = 0
        while hints.count - offset < count || hints.count == 1 {
            let hint = hints[offset]
            offset += 1
            for character in characters { hints.append(hint + character) }
        }
        return Array(hints[offset..<(offset + count)])
    }

    /// Whether every label is unique and none is a prefix of another.
    public static func isPrefixFree(_ labels: [String]) -> Bool {
        let set = Set(labels)
        guard set.count == labels.count else { return false }
        for label in labels {
            for length in 1..<max(label.count, 1) where set.contains(String(label.prefix(length))) {
                return false
            }
        }
        return true
    }
}
