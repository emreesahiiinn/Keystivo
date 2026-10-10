import Foundation

/// Result of matching a query against a candidate string.
nonisolated public struct FuzzyMatch: Sendable, Hashable {
    /// Higher is better. Zero means "no match".
    public let score: Double
    /// Character offsets (in the candidate) that matched, for highlighting.
    public let matchedOffsets: [Int]
}

/// Fast subsequence matcher tuned for launcher-style queries.
///
/// Rewards prefix matches, word-boundary hits ("vsc" → "Visual Studio Code"),
/// consecutive runs and shorter candidates. Diacritic- and case-insensitive,
/// including Turkish dotted/dotless i, so "istanbul" matches "İstanbul".
nonisolated public enum FuzzyMatcher {
    public static func match(_ query: String, in candidate: String) -> FuzzyMatch? {
        let needle = fold(query).filter { !$0.isWhitespace }
        guard !needle.isEmpty else { return FuzzyMatch(score: 1, matchedOffsets: []) }
        let hay = fold(candidate)
        guard hay.count >= needle.count else { return nil }

        let hayChars = Array(hay)
        let original = Array(candidate)
        let needleChars = Array(needle)

        // Exact substring at a word boundary is the strongest signal.
        if let range = hay.range(of: String(needleChars)) {
            let start = hay.distance(from: hay.startIndex, to: range.lowerBound)
            let atBoundary = start == 0 || isBoundary(hayChars, original, start)
            let base = start == 0 ? 1000.0 : (atBoundary ? 800.0 : 500.0)
            let score = base + Double(needleChars.count) * 10 - Double(hayChars.count) * 0.5
            return FuzzyMatch(score: score, matchedOffsets: Array(start..<(start + needleChars.count)))
        }

        var offsets: [Int] = []
        offsets.reserveCapacity(needleChars.count)
        var score = 0.0
        var hayIndex = 0
        var previousMatch = -2
        for needleChar in needleChars {
            var found = false
            // Prefer the next word-boundary occurrence when one exists ahead.
            var boundaryCandidate: Int?
            var firstCandidate: Int?
            var scan = hayIndex
            while scan < hayChars.count {
                if hayChars[scan] == needleChar {
                    if firstCandidate == nil { firstCandidate = scan }
                    if isBoundary(hayChars, original, scan) { boundaryCandidate = scan; break }
                    if scan == previousMatch + 1 { break }
                }
                scan += 1
            }
            let chosen: Int?
            if let first = firstCandidate, first == previousMatch + 1 {
                chosen = first
            } else {
                chosen = boundaryCandidate ?? firstCandidate
            }
            if let index = chosen {
                found = true
                offsets.append(index)
                if index == previousMatch + 1 {
                    score += 15
                } else if isBoundary(hayChars, original, index) {
                    score += 12
                } else {
                    score += 2 - min(Double(index - hayIndex) * 0.1, 1.5)
                }
                if index == 0 { score += 20 }
                previousMatch = index
                hayIndex = index + 1
            }
            if !found { return nil }
        }
        score -= Double(hayChars.count - needleChars.count) * 0.3
        return FuzzyMatch(score: max(score, 0.1), matchedOffsets: offsets)
    }

    /// Best match across a title and alternate strings (keywords, subtitles).
    public static func bestMatch(_ query: String, title: String, alternates: [String] = []) -> FuzzyMatch? {
        var best = match(query, in: title)
        for alternate in alternates {
            if let candidate = match(query, in: alternate) {
                // Alternate hits rank slightly below title hits and carry no highlight.
                let adjusted = FuzzyMatch(score: candidate.score * 0.8, matchedOffsets: [])
                if adjusted.score > (best?.score ?? 0) { best = adjusted }
            }
        }
        return best
    }

    /// Case/diacritic folding that preserves character count, so offsets map
    /// back onto the original string.
    public static func fold(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.count)
        for character in string {
            switch character {
            case "İ", "I", "ı": result.append("i")
            default:
                let folded = String(character).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
                result.append(folded.count == 1 ? folded.first! : character.lowercased().first ?? character)
            }
        }
        return result
    }

    private static func isBoundary(_ folded: [Character], _ original: [Character], _ index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = folded[index - 1]
        if previous == " " || previous == "-" || previous == "_" || previous == "." || previous == "/" { return true }
        // camelCase boundary in the original string.
        if index < original.count, original[index].isUppercase, original[index - 1].isLowercase { return true }
        if original.indices.contains(index), original[index].isNumber, !original[index - 1].isNumber { return true }
        return false
    }
}
