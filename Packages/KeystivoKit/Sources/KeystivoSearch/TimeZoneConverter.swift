import Foundation

/// World clock queries: "time in tokyo", "saat londra", "tokyo saati",
/// "15:00 tokyo" (your 15:00 there), "9am new york to istanbul".
nonisolated public enum TimeZoneConverter {
    public struct Result: Equatable, Sendable {
        /// The moment shown (now, or the typed time).
        public let date: Date
        public let place: String
        public let timeZone: TimeZone
        /// Where the typed time was given (nil: here and now).
        public let sourcePlace: String?
        public let sourceTimeZone: TimeZone?
    }

    static let timeWords: Set<String> = ["time", "saat", "saati", "zaman", "uhr", "uhrzeit", "heure", "hora", "ora", "время", "时间", "時間", "시간", "now", "şimdi"]
    static let connectors: Set<String> = ["in", "to", "at", "da", "de", "'da", "'de", "ta", "te", "nach", "en", "a", "em", "в", "->", "→"]

    /// City and country names (several languages) that aren't the last part of a zone identifier.
    static let aliases: [String: String] = [
        "london": "Europe/London", "londra": "Europe/London", "londres": "Europe/London", "uk": "Europe/London", "ingiltere": "Europe/London", "england": "Europe/London",
        "new york": "America/New_York", "newyork": "America/New_York", "nyc": "America/New_York", "ny": "America/New_York", "usa": "America/New_York", "amerika": "America/New_York",
        "san francisco": "America/Los_Angeles", "sf": "America/Los_Angeles", "la": "America/Los_Angeles", "silicon valley": "America/Los_Angeles", "seattle": "America/Los_Angeles",
        "beijing": "Asia/Shanghai", "pekin": "Asia/Shanghai", "peking": "Asia/Shanghai", "china": "Asia/Shanghai", "çin": "Asia/Shanghai", "北京": "Asia/Shanghai",
        "tokio": "Asia/Tokyo", "japan": "Asia/Tokyo", "japonya": "Asia/Tokyo", "東京": "Asia/Tokyo",
        "seul": "Asia/Seoul", "korea": "Asia/Seoul", "kore": "Asia/Seoul", "서울": "Asia/Seoul",
        "moskova": "Europe/Moscow", "moskau": "Europe/Moscow", "moscou": "Europe/Moscow", "russia": "Europe/Moscow", "rusya": "Europe/Moscow", "москва": "Europe/Moscow",
        "münih": "Europe/Berlin", "munich": "Europe/Berlin", "münchen": "Europe/Berlin", "germany": "Europe/Berlin", "almanya": "Europe/Berlin", "deutschland": "Europe/Berlin", "frankfurt": "Europe/Berlin", "hamburg": "Europe/Berlin",
        "france": "Europe/Paris", "fransa": "Europe/Paris", "roma": "Europe/Rome", "rom": "Europe/Rome", "italy": "Europe/Rome", "italya": "Europe/Rome",
        "spain": "Europe/Madrid", "ispanya": "Europe/Madrid", "barcelona": "Europe/Madrid", "atina": "Europe/Athens", "athen": "Europe/Athens", "viyana": "Europe/Vienna", "wien": "Europe/Vienna",
        "türkiye": "Europe/Istanbul", "turkey": "Europe/Istanbul", "ankara": "Europe/Istanbul", "izmir": "Europe/Istanbul",
        "india": "Asia/Kolkata", "hindistan": "Asia/Kolkata", "delhi": "Asia/Kolkata", "new delhi": "Asia/Kolkata", "mumbai": "Asia/Kolkata", "bangalore": "Asia/Kolkata",
        "sidney": "Australia/Sydney", "australia": "Australia/Sydney", "avustralya": "Australia/Sydney",
        "brazil": "America/Sao_Paulo", "brezilya": "America/Sao_Paulo", "rio": "America/Sao_Paulo", "são paulo": "America/Sao_Paulo",
        "boston": "America/New_York", "washington": "America/New_York", "miami": "America/New_York", "austin": "America/Chicago", "dallas": "America/Chicago",
        "canada": "America/Toronto", "kanada": "America/Toronto", "montreal": "America/Toronto", "vancouver": "America/Vancouver",
        "dubai": "Asia/Dubai", "bae": "Asia/Dubai", "uae": "Asia/Dubai", "hong kong": "Asia/Hong_Kong", "singapur": "Asia/Singapore",
    ]

    /// Zone identifiers by their lowercased city part ("new york" → America/New_York).
    static let cities: [String: String] = {
        var map: [String: String] = [:]
        for identifier in TimeZone.knownTimeZoneIdentifiers {
            guard let city = identifier.split(separator: "/").last else { continue }
            map[city.replacingOccurrences(of: "_", with: " ").lowercased()] = identifier
        }
        return map
    }()

    static func zone(named raw: String) -> (name: String, zone: TimeZone)? {
        let name = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !name.isEmpty else { return nil }
        if let identifier = aliases[name] ?? cities[name], let zone = TimeZone(identifier: identifier) {
            return (raw.trimmingCharacters(in: .punctuationCharacters).capitalized, zone)
        }
        if name.count <= 5, let zone = TimeZone(abbreviation: name.uppercased()) {
            return (name.uppercased(), zone)
        }
        return nil
    }

    /// "15:00", "15.30", "3pm", "9:30am"; returns hour and minute.
    static func clockTime(_ word: String) -> (hour: Int, minute: Int)? {
        let lower = word.lowercased()
        let pm = lower.hasSuffix("pm"), am = lower.hasSuffix("am")
        let digits = (pm || am) ? String(lower.dropLast(2)) : lower
        let parts = digits.split(whereSeparator: { $0 == ":" || $0 == "." })
        guard (1...2).contains(parts.count), let hour = Int(parts[0]) else { return nil }
        let minute = parts.count == 2 ? Int(parts[1]) : 0
        guard let minute, (0..<60).contains(minute) else { return nil }
        // A bare number is only a time with am/pm ("3pm"), never "15".
        if parts.count == 1, !(pm || am) { return nil }
        var h = hour
        if pm || am {
            guard (1...12).contains(hour) else { return nil }
            h = hour % 12 + (pm ? 12 : 0)
        }
        guard (0..<24).contains(h) else { return nil }
        return (h, minute)
    }

    public static func resolve(_ input: String, now: Date = .now, local: TimeZone = .current) -> Result? {
        let text = input.lowercased().replacingOccurrences(of: "?", with: "").replacingOccurrences(of: "'", with: " '")
        var words = text.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty, words.count <= 7 else { return nil }
        // Turkish suffixes: "tokyo'da", "londra'daki".
        words = words.map { word in
            for suffix in ["'daki", "'deki", "'da", "'de", "'ta", "'te"] where word.hasSuffix(suffix) && word.count > suffix.count {
                return String(word.dropLast(suffix.count))
            }
            return word
        }

        let time = words.firstIndex { clockTime($0) != nil }
        let hasTimeWord = words.contains { timeWords.contains($0) }
        guard time != nil || hasTimeWord else { return nil }
        let places = words.enumerated().filter { $0.offset != time && !timeWords.contains($0.element) && !connectors.contains($0.element) && !$0.element.hasPrefix("'") && $0.element != "kaç" && $0.element != "what" && $0.element != "is" }
            .map(\.element)
        // Place names can be two words ("new york"); try pairs first.
        var zones: [(name: String, zone: TimeZone)] = []
        var index = 0
        while index < places.count {
            if index + 1 < places.count, let pair = zone(named: places[index] + " " + places[index + 1]) {
                zones.append(pair)
                index += 2
            } else if let single = zone(named: places[index]) {
                zones.append(single)
                index += 1
            } else {
                return nil
            }
        }
        guard let target = zones.last, zones.count <= 2 else { return nil }

        guard let time, let clock = clockTime(words[time]) else {
            // "time in tokyo": now there.
            guard zones.count == 1 else { return nil }
            return Result(date: now, place: target.name, timeZone: target.zone, sourcePlace: nil, sourceTimeZone: nil)
        }
        // "15:00 tokyo": your 15:00 in Tokyo; "15:00 london to tokyo": London's 15:00 in Tokyo.
        let source = zones.count == 2 ? zones[0] : nil
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = source?.zone ?? local
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = clock.hour
        components.minute = clock.minute
        guard let date = calendar.date(from: components) else { return nil }
        return Result(date: date, place: target.name, timeZone: target.zone, sourcePlace: source?.name, sourceTimeZone: source?.zone)
    }
}
