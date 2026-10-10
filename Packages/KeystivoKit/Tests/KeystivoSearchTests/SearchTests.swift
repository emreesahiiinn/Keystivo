import Foundation
@testable import KeystivoSearch
import Testing

@Suite("Calculator")
struct CalculatorTests {
    @Test(arguments: [
        ("1 + 2 * 3", 7.0), ("(1 + 2) * 3", 9), ("2 ^ 3 ^ 2", 512), ("-3 + 5", 2), ("10 / 4", 2.5),
        ("2(3+4)", 14), ("2pi", 2 * Double.pi), ("sqrt(16) + abs(-2)", 6), ("200 + 15%", 230),
        ("200 - 10%", 180), ("50% * 8", 4), ("3,5 * 2", 7), ("1.234,5 + 0,5", 1235), ("1,234.5 + 0.5", 1235),
        ("12 × 3 ÷ 4", 9), ("round(2.6)", 3), ("log(1000)", 3), ("ln(e)", 1),
    ])
    func evaluates(expression: String, expected: Double) throws {
        let value = try Calculator.evaluate(expression)
        #expect(abs(value - expected) < 1e-9, "\(expression) = \(value)")
    }

    @Test func divisionByZero() {
        #expect(throws: Calculator.Failure.divisionByZero) { try Calculator.evaluate("1/0") }
    }

    @Test(arguments: ["2 +", "(1", "foo(2)", "1 $ 2", ""])
    func invalidInput(expression: String) {
        #expect(throws: Calculator.Failure.self) { try Calculator.evaluate(expression) }
    }

    @Test func expressionDetection() {
        #expect(Calculator.looksLikeExpression("12*4"))
        #expect(Calculator.looksLikeExpression("sqrt(9)"))
        #expect(!Calculator.looksLikeExpression("Safari"))
        #expect(!Calculator.looksLikeExpression("42"))
    }

    @Test func formatting() {
        #expect(Calculator.format(1234, locale: Locale(identifier: "en_US")) == "1,234")
        #expect(Calculator.format(1234.5, locale: Locale(identifier: "tr_TR")) == "1.234,5")
    }
}

@Suite("Unit conversion")
struct UnitConverterTests {
    @Test func lengths() throws {
        let result = try #require(UnitConverter.convert("10 km to mi"))
        #expect(abs(result.result - 6.2137) < 0.001)
        #expect(result.toSymbol == "mi")
    }

    @Test func temperatures() throws {
        #expect(abs(try #require(UnitConverter.convert("100 c in f")).result - 212) < 1e-6)
        #expect(abs(try #require(UnitConverter.convert("32°f to c")).result) < 1e-6)
    }

    @Test func dataUnitsAreCaseSensitive() throws {
        #expect(try #require(UnitConverter.convert("1 GB in MB")).result == 1000)
        #expect(try #require(UnitConverter.convert("1 GiB in MiB")).result == 1024)
        #expect(try #require(UnitConverter.convert("8 Mb in MB")).result == 1)
    }

    @Test func multilingualConnectorsAndNumbers() throws {
        #expect(abs(try #require(UnitConverter.convert("3,5 kg kaç lb")).result - 7.716) < 0.01)
        #expect(UnitConverter.convert("5 kilometer nach meilen") != nil)
        #expect(abs(try #require(UnitConverter.convert("2 saat to dakika")).result - 120) < 1e-6)
    }

    @Test func attachedUnitsAndCustomDurations() throws {
        #expect(try #require(UnitConverter.convert("2h to min")).result == 120)
        #expect(try #require(UnitConverter.convert("1 week in days")).result == 7)
    }

    @Test func incompatibleUnitsFail() {
        #expect(UnitConverter.convert("10 kg to km") == nil)
        #expect(UnitConverter.convert("hello world") == nil)
    }
}

@Suite("Text transforms")
struct TextTransformTests {
    @Test func caseTransforms() {
        #expect(TextTransform.camelCase.apply("hello big world") == "helloBigWorld")
        #expect(TextTransform.snakeCase.apply("helloBigWorld") == "hello_big_world")
        #expect(TextTransform.kebabCase.apply("Hello Big World") == "hello-big-world")
        #expect(TextTransform.slug.apply("Çok Güzel Işık!", locale: Locale(identifier: "tr")) == "cok-guzel-isik")
        #expect(TextTransform.uppercase.apply("istanbul", locale: Locale(identifier: "tr")) == "İSTANBUL")
        #expect(TextTransform.sentenceCase.apply("HELLO. WORLD") == "Hello. World")
    }

    @Test func encodings() {
        #expect(TextTransform.base64Encode.apply("Keystivo") == "S2V5c3Rpdm8=")
        #expect(TextTransform.base64Decode.apply("S2V5c3Rpdm8=") == "Keystivo")
        #expect(TextTransform.urlEncode.apply("a b&c") == "a%20b%26c")
        #expect(TextTransform.urlDecode.apply("a%20b") == "a b")
        #expect(TextTransform.sha256.apply("")?.hasPrefix("e3b0c442") == true)
    }

    @Test func json() {
        #expect(TextTransform.jsonMinify.apply("{ \"a\" : [1, 2] }") == "{\"a\":[1,2]}")
        #expect(TextTransform.jsonPrettyPrint.apply("not json") == nil)
    }

    @Test func lines() {
        #expect(TextTransform.sortLines.apply("b\na\nc") == "a\nb\nc")
        #expect(TextTransform.uniqueLines.apply("a\nb\na") == "a\nb")
        #expect(TextTransform.removeLineBreaks.apply("a\n\nb") == "a b")
    }

    @Test func statistics() {
        let stats = TextStatistics("Hello world\nsecond line")
        #expect(stats.words == 4)
        #expect(stats.lines == 2)
    }
}

@Suite("Ranking")
struct RankingTests {
    @Test func usageBoostDecaysAndCaps() {
        let now = Date()
        let fresh = UsageStats(count: 10, lastUsed: now)
        let stale = UsageStats(count: 10, lastUsed: now.addingTimeInterval(-60 * 86_400))
        #expect(fresh.boost(now: now) > stale.boost(now: now))
        #expect(UsageStats(count: 1_000_000, lastUsed: now).boost(now: now) <= 250)
        #expect(UsageStats().boost(now: now) == 0)
    }
}
