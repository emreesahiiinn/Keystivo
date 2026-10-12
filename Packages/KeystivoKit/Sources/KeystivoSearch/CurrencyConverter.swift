import Foundation

/// Parses currency conversions such as "100 usd to try", "100$ kaç tl",
/// "€50 in usd", "100 dolar" (to the local currency).
nonisolated public enum CurrencyConverter {
    public struct Request: Equatable, Sendable {
        public let amount: Double
        public let from: String
        /// nil: convert to the user's local currency.
        public let to: String?
    }

    /// Common names and symbols per ISO code, across the app's languages.
    static let aliases: [String: String] = {
        var map: [String: String] = [:]
        let table: [String: [String]] = [
            "USD": ["$", "us$", "dollar", "dollars", "dolar", "dolları", "doları", "dólar", "dólares", "dollaro", "dollari", "доллар", "доллара", "долларов", "美元", "ドル", "달러"],
            "EUR": ["€", "euro", "euros", "avro", "evro", "евро", "欧元", "ユーロ", "유로"],
            "TRY": ["₺", "tl", "lira", "türk lirası", "turkish lira", "лира", "里拉", "リラ", "리라"],
            "GBP": ["£", "pound", "pounds", "sterlin", "sterling", "pfund", "libra", "sterlina", "фунт", "英镑", "ポンド", "파운드"],
            "JPY": ["¥", "yen", "円", "иена", "日元", "엔"],
            "CNY": ["yuan", "rmb", "renminbi", "юань", "人民币", "元", "위안"],
            "CHF": ["franc", "frank", "franken", "franco", "франк"],
            "KRW": ["₩", "won", "вон", "韩元", "ウォン", "원"],
            "INR": ["₹", "rupee", "rupi", "рупия"],
            "RUB": ["₽", "ruble", "rubel", "rublo", "рубль", "рубля", "рублей"],
            "BRL": ["r$", "real", "reais"],
            "CAD": ["c$", "ca$"],
            "AUD": ["a$", "au$"],
        ]
        for (code, names) in table {
            for name in names { map[name] = code }
        }
        return map
    }()

    static let connectors: Set<String> = ["to", "in", "into", "=", "->", "→", "kaç", "kac", "nach", "en", "a", "em", "para", "в", "到", "は", "로"]

    /// Resolves a currency word or symbol to an ISO code from `known` (or the alias table).
    static func code(_ raw: String, known: Set<String>) -> String? {
        let word = raw.lowercased().trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: "$€£¥₺₩₹₽")))
        if word.isEmpty { return nil }
        let upper = word.uppercased()
        if upper.count == 3, known.contains(upper) { return upper }
        return aliases[word]
    }

    /// `known`: ISO codes that have rates (an alias still needs its code to be known).
    public static func parse(_ input: String, known: Set<String>) -> Request? {
        var text = input.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "?", with: "")
        // Split symbols glued to numbers: "$100", "100€", "100tl".
        for symbol in ["$", "€", "£", "¥", "₺", "₩", "₹", "₽"] {
            text = text.replacingOccurrences(of: symbol, with: " \(symbol) ")
        }
        var words = UnitConverter.tokenize(text).filter { !$0.isEmpty }
        guard words.count >= 2 else { return nil }
        // A leading currency symbol: "$ 100 to try" → "100 $ to try".
        if Calculator.parseNumber(words[0]) == nil, words.count >= 2, Calculator.parseNumber(words[1]) != nil, code(words[0], known: known) != nil {
            words.swapAt(0, 1)
        }
        guard let amount = Calculator.parseNumber(words[0]) else { return nil }
        let rest = Array(words.dropFirst())
        let connectorIndex = rest.firstIndex { connectors.contains($0.lowercased()) }
        let sourceWords = connectorIndex.map { Array(rest[..<$0]) } ?? rest
        var targetWords = connectorIndex.map { Array(rest[($0 + 1)...]) } ?? []
        // "100 usd try": two words, the second is the target.
        var source = sourceWords.joined(separator: " ")
        if connectorIndex == nil, sourceWords.count == 2, code(source, known: known) == nil,
           code(sourceWords[0], known: known) != nil, code(sourceWords[1], known: known) != nil {
            source = sourceWords[0]
            targetWords = [sourceWords[1]]
        }
        guard let from = code(source, known: known) else { return nil }
        if targetWords.isEmpty { return Request(amount: amount, from: from, to: nil) }
        guard let to = code(targetWords.joined(separator: " "), known: known), to != from else { return nil }
        return Request(amount: amount, from: from, to: to)
    }
}

/// Daily reference rates from the European Central Bank (no account or key).
/// Fetched only when a conversion is typed, cached on disk for a day.
public actor ExchangeRates {
    public static let shared = ExchangeRates()

    public struct Table: Codable, Sendable, Equatable {
        /// Units per euro.
        public var rates: [String: Double]
        public var date: String
        public var fetchedAt: Date

        public var codes: Set<String> { Set(rates.keys) }

        /// Converts between any two currencies in the table.
        public func convert(_ amount: Double, from: String, to: String) -> Double? {
            guard let fromRate = rates[from], let toRate = rates[to], fromRate > 0 else { return nil }
            return amount / fromRate * toRate
        }
    }

    public static let sourceURL = URL(string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml")!
    private let cacheURL: URL
    private var table: Table?
    private var loading: Task<Table?, Never>?

    public init(cacheURL: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Keystivo/exchange-rates.json")) {
        self.cacheURL = cacheURL
    }

    /// Rates already in memory or on disk (may be stale), without any network access.
    public func cached() -> Table? {
        if table == nil, let data = try? Data(contentsOf: cacheURL) {
            table = try? JSONDecoder().decode(Table.self, from: data)
        }
        return table
    }

    /// Fresh rates: downloads when the cache is older than 12 hours.
    public func current() async -> Table? {
        if let cached = cached(), Date.now.timeIntervalSince(cached.fetchedAt) < 12 * 3600 { return cached }
        if let loading { return await loading.value }
        let task = Task { () -> Table? in
            var request = URLRequest(url: Self.sourceURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
            request.setValue("Keystivo", forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  var parsed = Self.parse(data) else { return nil }
            parsed.fetchedAt = .now
            return parsed
        }
        loading = task
        let fresh = await task.value
        loading = nil
        if let fresh {
            table = fresh
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(fresh).write(to: cacheURL, options: .atomic)
            return fresh
        }
        return cached()
    }

    /// Parses the ECB XML: `<Cube time='2026-10-09'>` with `<Cube currency='USD' rate='1.0823'/>`.
    public static func parse(_ data: Data) -> Table? {
        guard let xml = String(data: data, encoding: .utf8) else { return nil }
        var rates: [String: Double] = ["EUR": 1]
        let ratePattern = /currency=['"]([A-Z]{3})['"]\s+rate=['"]([0-9.]+)['"]/
        for match in xml.matches(of: ratePattern) {
            if let value = Double(match.2) { rates[String(match.1)] = value }
        }
        guard rates.count > 1 else { return nil }
        let date = xml.firstMatch(of: /time=['"]([0-9-]{10})['"]/).map { String($0.1) } ?? ""
        return Table(rates: rates, date: date, fetchedAt: .now)
    }
}
