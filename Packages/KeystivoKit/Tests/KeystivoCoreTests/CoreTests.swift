import Foundation
@testable import KeystivoCore
import Testing

@Suite("Fuzzy matching")
struct FuzzyMatcherTests {
    @Test func prefixBeatsSubstring() throws {
        let prefix = try #require(FuzzyMatcher.match("saf", in: "Safari"))
        let inner = try #require(FuzzyMatcher.match("saf", in: "Unsafe Mode"))
        #expect(prefix.score > inner.score)
        #expect(prefix.matchedOffsets == [0, 1, 2])
    }

    @Test func acronymsMatchWordBoundaries() throws {
        let match = try #require(FuzzyMatcher.match("vsc", in: "Visual Studio Code"))
        #expect(match.matchedOffsets == [0, 7, 14])
    }

    @Test func caseAndDiacriticInsensitive() {
        #expect(FuzzyMatcher.match("istanbul", in: "İstanbul") != nil)
        #expect(FuzzyMatcher.match("ayarlar", in: "Sistem Ayarları") != nil)
        #expect(FuzzyMatcher.match("cafe", in: "Café") != nil)
    }

    @Test func nonMatchesReturnNil() {
        #expect(FuzzyMatcher.match("xyz", in: "Safari") == nil)
        #expect(FuzzyMatcher.match("safarii", in: "Safari") == nil)
    }

    @Test func emptyQueryMatchesEverything() {
        #expect(FuzzyMatcher.match("", in: "Anything") != nil)
    }

    @Test func foldingPreservesLength() {
        for text in ["İĞÜŞÖÇ ığüşöç", "Straße", "日本語", "Ünïcödé"] {
            #expect(FuzzyMatcher.fold(text).count == text.count)
        }
    }

    @Test func alternatesRankBelowTitle() throws {
        let viaTitle = try #require(FuzzyMatcher.bestMatch("term", title: "Terminal"))
        let viaAlias = try #require(FuzzyMatcher.bestMatch("term", title: "Konsole", alternates: ["Terminal"]))
        #expect(viaTitle.score > viaAlias.score)
        #expect(viaAlias.matchedOffsets.isEmpty)
    }
}

@Suite("Keyboard model")
struct KeyboardTests {
    @Test func modifierRoundTrip() {
        let modifiers: KeyModifiers = [.command, .option, .shift]
        #expect(KeyModifiers(modifiers.cgFlags) == modifiers)
        #expect(KeyModifiers(modifiers.eventFlags) == modifiers)
    }

    @Test func modifierSymbolsUseAppleOrder() {
        #expect(KeyModifiers.hyper.symbols == "⌃⌥⇧⌘")
    }

    @Test func validGlobalShortcuts() {
        #expect(KeyCombo(keyCode: KeyCodes.space, modifiers: .option).isValidGlobalShortcut)
        #expect(!KeyCombo(keyCode: KeyCodes.space, modifiers: .shift).isValidGlobalShortcut)
        #expect(!KeyCombo(keyCode: 0, modifiers: []).isValidGlobalShortcut)
        // Function keys may be used alone.
        #expect(KeyCombo(keyCode: 0x7A /* F1 */, modifiers: []).isValidGlobalShortcut)
    }

    @Test func comboIsCodable() throws {
        let combo = KeyCombo(keyCode: 49, modifiers: [.command, .shift])
        let data = try JSONEncoder().encode(combo)
        #expect(try JSONDecoder().decode(KeyCombo.self, from: data) == combo)
    }

    @Test func letterKeyCodesCoverAlphabet() {
        #expect(KeyCodes.letterKeyCodes.count == 26)
        #expect(KeyCodes.letterKeyCodes["a"] == 0)
    }
}

@Suite("Action registry")
struct ActionRegistryTests {
    @Test func performsWithDefaultArguments() async throws {
        let registry = ActionRegistry()
        var received: Double?
        registry.register(ActionDescriptor(
            id: "test.volume", titleKey: "t", symbol: "speaker", category: .audio,
            parameters: [ParameterSpec("level", "p", .number(min: 0, max: 100, step: 1), default: .number(42))]
        )) { arguments, _ in
            received = arguments.double("level")
        }
        try await registry.perform(ActionInvocation("test.volume"), context: ActionContext(source: .test))
        #expect(received == 42)
        try await registry.perform(ActionInvocation("test.volume", arguments: ["level": .number(7)]), context: ActionContext(source: .test))
        #expect(received == 7)
    }

    @Test func unknownActionThrows() async {
        let registry = ActionRegistry()
        await #expect(throws: ActionError.unknownAction("nope")) {
            try await registry.perform(ActionInvocation("nope"), context: ActionContext(source: .test))
        }
    }

    @Test func chainRunsInOrderAndStopsOnError() async {
        let registry = ActionRegistry()
        var log: [String] = []
        for id in ["a", "b"] {
            registry.register(ActionDescriptor(id: id, titleKey: id, symbol: "x", category: .system)) { _, _ in log.append(id) }
        }
        registry.register(ActionDescriptor(id: "fail", titleKey: "f", symbol: "x", category: .system)) { _, _ in
            throw ActionError.failed("boom")
        }
        try? await registry.perform(chain: [ActionInvocation("a"), ActionInvocation("fail"), ActionInvocation("b")], context: ActionContext(source: .test))
        #expect(log == ["a"])
    }

    @Test func unregisterByPrefix() {
        let registry = ActionRegistry()
        registry.register(ActionDescriptor(id: "plugin.x.one", titleKey: "", symbol: "", category: .plugins)) { _, _ in }
        registry.register(ActionDescriptor(id: "plugin.x.two", titleKey: "", symbol: "", category: .plugins)) { _, _ in }
        registry.register(ActionDescriptor(id: "windows.keep", titleKey: "", symbol: "", category: .windows)) { _, _ in }
        registry.unregister(prefix: "plugin.")
        #expect(registry.descriptors.keys.sorted() == ["windows.keep"])
    }

    @Test func argumentAccessors() {
        let arguments = ActionArguments(["n": .string("12"), "b": .string("yes"), "list": .strings(["x", "y"])])
        #expect(arguments.int("n") == 12)
        #expect(arguments.bool("b") == true)
        #expect(arguments.strings("list") == ["x", "y"])
        #expect(throws: ActionError.missingArgument("missing")) { try arguments.require("missing") }
    }
}

@Suite("Persistence")
struct PersistenceTests {
    struct Sample: Codable, Equatable {
        var name: String
        var count: Int
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("keystivo-tests-\(UUID().uuidString)").appendingPathComponent("file.json")
    }

    @Test func jsonRoundTrip() throws {
        let store = JSONFileStore<Sample>(url: temporaryURL())
        guard case .missing = store.load() else { Issue.record("expected missing"); return }
        try store.save(Sample(name: "a", count: 3))
        guard case .loaded(let value) = store.load() else { Issue.record("expected loaded"); return }
        #expect(value == Sample(name: "a", count: 3))
    }

    @Test func corruptedFileIsBackedUp() throws {
        let url = temporaryURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: url)
        guard case .corrupted(_, let backup) = JSONFileStore<Sample>(url: url).load() else { Issue.record("expected corrupted"); return }
        #expect(backup.map { FileManager.default.fileExists(atPath: $0.path) } == true)
    }

    @Test func sqliteMigrationsAndQueries() throws {
        let db = try SQLiteDatabase()
        try db.migrate(["CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, data BLOB);"])
        try db.migrate(["CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, data BLOB);"]) // idempotent
        try db.run("INSERT INTO t (name, data) VALUES (?, ?)", [.text("ü"), .blob(Data([1, 2]))])
        let rows = try db.query("SELECT * FROM t")
        #expect(rows.count == 1)
        #expect(rows[0].string("name") == "ü")
        #expect(rows[0].data("data") == Data([1, 2]))
        #expect(try db.scalarInt("PRAGMA user_version;") == 1)
    }

    @Test func sqliteTransactionRollsBack() throws {
        let db = try SQLiteDatabase()
        try db.execute("CREATE TABLE t (v INTEGER);")
        #expect(throws: (any Error).self) {
            try db.transaction {
                try db.run("INSERT INTO t VALUES (1)")
                throw CancellationError()
            }
        }
        #expect(try db.scalarInt("SELECT COUNT(*) FROM t") == 0)
    }
}

@Suite("Localization")
struct LocalizationTests {
    @Test func resolvesSupportedLanguages() {
        #expect(AppLanguage.resolve(preferences: ["tr-TR"]) == "tr")
        #expect(AppLanguage.resolve(preferences: ["zh-Hant-TW"]) == "zh-Hant")
        #expect(AppLanguage.resolve(preferences: ["pt-BR"]) == "pt-BR")
        #expect(AppLanguage.resolve(preferences: ["xx"]) == "en")
    }

    @Test func switchesLanguageLive() {
        let localizer = Localizer(preference: "en")
        let english = localizer.string("common.cancel")
        #expect(english == "Cancel")
        localizer.setPreference("tr")
        #expect(localizer.languageCode == "tr")
        #expect(localizer.string("missing.key.example") == "missing.key.example")
    }

    /// Every shipped language must translate every key, with matching placeholders.
    @Test(arguments: AppLanguage.supportedCodes)
    func catalogIsComplete(code: String) {
        let localizer = Localizer(preference: code)
        let keys = localizer.allKeys()
        #expect(keys.count > 500)
        let missing = keys.filter { !localizer.hasTranslation($0, code: code) }
        #expect(missing.isEmpty, "\(code) is missing \(missing.count) keys, e.g. \(missing.prefix(5))")
    }
}
