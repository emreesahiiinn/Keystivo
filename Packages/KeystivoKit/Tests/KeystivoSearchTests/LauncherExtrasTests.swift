import Foundation
@testable import KeystivoSearch
import Testing

@Suite("Currency conversion")
struct CurrencyConverterTests {
    let known: Set<String> = ["USD", "EUR", "TRY", "GBP", "JPY", "CHF"]

    @Test func parsesCommonForms() {
        #expect(CurrencyConverter.parse("100 usd to try", known: known) == .init(amount: 100, from: "USD", to: "TRY"))
        #expect(CurrencyConverter.parse("100 dolar kaç tl", known: known) == .init(amount: 100, from: "USD", to: "TRY"))
        #expect(CurrencyConverter.parse("100$ in €", known: known) == .init(amount: 100, from: "USD", to: "EUR"))
        #expect(CurrencyConverter.parse("€50 usd", known: known) == .init(amount: 50, from: "EUR", to: "USD"))
        #expect(CurrencyConverter.parse("1.250,50 eur to gbp", known: known) == .init(amount: 1250.5, from: "EUR", to: "GBP"))
        #expect(CurrencyConverter.parse("20 euro", known: known) == .init(amount: 20, from: "EUR", to: nil))
    }

    @Test func ignoresNonCurrencyText() {
        #expect(CurrencyConverter.parse("100 km to mi", known: known) == nil)
        #expect(CurrencyConverter.parse("usd", known: known) == nil)
        #expect(CurrencyConverter.parse("100 usd to usd", known: known) == nil)
        #expect(CurrencyConverter.parse("5 + 3", known: known) == nil)
    }

    @Test func parsesECBFeedAndConverts() throws {
        let xml = """
        <gesmes:Envelope><Cube><Cube time='2026-10-09'>
        <Cube currency='USD' rate='1.1000'/><Cube currency='TRY' rate='44.00'/><Cube currency='JPY' rate='165.0'/>
        </Cube></Cube></gesmes:Envelope>
        """
        let table = try #require(ExchangeRates.parse(Data(xml.utf8)))
        #expect(table.date == "2026-10-09")
        #expect(table.codes == ["EUR", "USD", "TRY", "JPY"])
        #expect(abs((table.convert(110, from: "USD", to: "EUR") ?? 0) - 100) < 0.0001)
        #expect(abs((table.convert(1, from: "USD", to: "TRY") ?? 0) - 40) < 0.0001)
        #expect(table.convert(1, from: "USD", to: "XYZ") == nil)
    }
}

@Suite("World clock")
struct TimeZoneConverterTests {
    let istanbul = TimeZone(identifier: "Europe/Istanbul")!
    // 2026-10-10 12:00 in Istanbul (09:00 UTC).
    let now = Date(timeIntervalSince1970: 1_791_622_800)

    @Test func currentTimeElsewhere() throws {
        let tokyo = try #require(TimeZoneConverter.resolve("time in tokyo", now: now, local: istanbul))
        #expect(tokyo.timeZone.identifier == "Asia/Tokyo")
        #expect(tokyo.date == now)
        #expect(TimeZoneConverter.resolve("saat londra", now: now, local: istanbul)?.timeZone.identifier == "Europe/London")
        #expect(TimeZoneConverter.resolve("new york saati", now: now, local: istanbul)?.timeZone.identifier == "America/New_York")
        #expect(TimeZoneConverter.resolve("tokyo'da saat kaç", now: now, local: istanbul)?.timeZone.identifier == "Asia/Tokyo")
    }

    @Test func convertsATypedTime() throws {
        let result = try #require(TimeZoneConverter.resolve("15:00 tokyo", now: now, local: istanbul))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = result.timeZone
        // 15:00 Istanbul (UTC+3) is 21:00 Tokyo (UTC+9).
        #expect(calendar.component(.hour, from: result.date) == 21)
        let pm = try #require(TimeZoneConverter.resolve("9am london to tokyo", now: now, local: istanbul))
        #expect(pm.sourceTimeZone?.identifier == "Europe/London")
        calendar.timeZone = pm.timeZone
        #expect(calendar.component(.hour, from: pm.date) == 17)
    }

    @Test func leavesAppSearchesAlone() {
        #expect(TimeZoneConverter.resolve("time machine", now: now, local: istanbul) == nil)
        #expect(TimeZoneConverter.resolve("screen time", now: now, local: istanbul) == nil)
        #expect(TimeZoneConverter.resolve("tokyo", now: now, local: istanbul) == nil)
        #expect(TimeZoneConverter.resolve("15:00", now: now, local: istanbul) == nil)
        #expect(TimeZoneConverter.resolve("saat 3", now: now, local: istanbul) == nil)
    }
}

@Suite("Emoji catalog")
struct EmojiCatalogTests {
    @Test func findsEmojiByLocalAndEnglishNames() throws {
        let turkish = EmojiCatalog.search("kırmızı kalp", language: "tr")
        #expect(turkish.first?.entry.glyph == "❤️")
        let english = EmojiCatalog.search("red heart", language: "tr")
        #expect(english.contains { $0.entry.glyph == "❤️" })
        #expect(EmojiCatalog.search("Herz", language: "de").contains { $0.entry.glyph == "❤️" })
    }

    @Test func includesSymbolsAndStartsWithSmileys() throws {
        let all = EmojiCatalog.entries(language: "en")
        #expect(all.count > 1500)
        #expect(all.contains { $0.glyph == "⌘" && $0.isSymbol })
        let first = try #require(all.first?.glyph.unicodeScalars.first?.value)
        #expect((0x1F600...0x1F64F).contains(first) || first == 0x263A || (0x1F910...0x1F92F).contains(first))
        #expect(EmojiCatalog.directory(for: "zh-Hant") == "zh_TW")
    }
}

@Suite("File search ranking")
struct FileSearchRankingTests {
    func file(_ name: String) -> FileResult {
        FileResult(path: "/Users/test/\(name)", name: name, isDirectory: false, modified: nil)
    }

    @Test func exactAndPrefixNamesComeFirst() {
        let results = [file("old-report-notes.txt"), file("report.pdf"), file("annual report.docx"), file("reports 2025.xlsx")]
        let ranked = FileSearch.rank(results, query: "report").map(\.name)
        #expect(ranked == ["report.pdf", "reports 2025.xlsx", "old-report-notes.txt", "annual report.docx"])
    }

    @Test func cloudFoldersGetFriendlyNames() {
        let path = NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs/Taxes/2025.pdf"
        #expect(FileResult(path: path, name: "2025.pdf", isDirectory: false, modified: nil).parentPath == "iCloud Drive/Taxes")
        #expect(FileResult.isUserDocumentLocation(NSHomeDirectory() + "/Library/CloudStorage/Dropbox/a.txt"))
        #expect(!FileResult.isUserDocumentLocation(NSHomeDirectory() + "/Library/Caches/a.txt"))
    }
}

@Suite("Emoji ranking")
struct EmojiRankingTests {
    @Test func commonEmojiComeFirst() {
        #expect(EmojiCatalog.search("kalp", language: "tr").first?.entry.glyph == "❤️")
        #expect(EmojiCatalog.search("heart", language: "en").first?.entry.glyph == "❤️")
        #expect(EmojiCatalog.search("fire", language: "en").first?.entry.glyph == "🔥")
    }
}
