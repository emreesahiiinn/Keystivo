@testable import KeystivoNavigation
import KeystivoCore
import Testing

@Suite("Hint labels")
struct HintLabelTests {
    @Test(arguments: [1, 5, 26, 27, 100, 676, 1000])
    func labelsAreUniqueAndPrefixFree(count: Int) {
        let labels = HintLabelGenerator.labels(count: count)
        #expect(labels.count == count)
        #expect(HintLabelGenerator.isPrefixFree(labels))
    }

    @Test func shortLabelsWhenFewElements() {
        let labels = HintLabelGenerator.labels(count: 9)
        #expect(labels.allSatisfy { $0.count == 1 })
        #expect(labels.first == "a")
    }

    @Test func labelsStayShort() {
        #expect(HintLabelGenerator.labels(count: 600).allSatisfy { $0.count <= 2 })
    }

    @Test func customAlphabetIgnoresDuplicatesAndSymbols() {
        let labels = HintLabelGenerator.labels(count: 4, alphabet: "aab1;b")
        #expect(Set(labels.flatMap { Array($0) }).isSubset(of: ["a", "b"]))
        #expect(HintLabelGenerator.isPrefixFree(labels))
    }

    @Test func invalidAlphabetReturnsNothing() {
        #expect(HintLabelGenerator.labels(count: 3, alphabet: "a").isEmpty)
    }
}

@Suite("Hint matcher")
struct HintMatcherTests {
    let labels = ["a", "s", "da", "ds"]
    let titles = ["Save", "Cancel", "Open Recent", "Delete"]

    @Test func singleLetterMatches() {
        var matcher = HintMatcher(labels: labels, titles: titles)
        #expect(matcher.type("s") == .matched(1))
    }

    @Test func prefixNarrowsThenMatches() {
        var matcher = HintMatcher(labels: labels, titles: titles)
        #expect(matcher.type("d") == .pending(visible: [2, 3]))
        #expect(matcher.type("s") == .matched(3))
    }

    @Test func typingIsCaseInsensitive() {
        var matcher = HintMatcher(labels: labels.map { $0.uppercased() }, titles: titles)
        #expect(matcher.type("A") == .matched(0))
    }

    @Test func wrongLetterIsNoMatch() {
        var matcher = HintMatcher(labels: labels, titles: titles)
        #expect(matcher.type("z") == .noMatch)
    }

    @Test func backspaceRestoresCandidates() {
        var matcher = HintMatcher(labels: labels, titles: titles)
        _ = matcher.type("d")
        #expect(matcher.backspace() == .pending(visible: [0, 1, 2, 3]))
    }

    @Test func searchModeMatchesTitles() {
        var matcher = HintMatcher(labels: labels, titles: titles)
        matcher.setMode(.search)
        for character in "del" { _ = matcher.type(character) }
        #expect(matcher.confirm() == .matched(3))
    }

    @Test func searchSelectionWraps() {
        var matcher = HintMatcher(labels: labels, titles: titles)
        matcher.setMode(.search)
        _ = matcher.type("e")
        let results = matcher.searchResults()
        #expect(results.count >= 2)
        _ = matcher.moveSelection(by: -1)
        #expect(matcher.searchSelection == results.count - 1)
    }

    @Test func activationFromModifiers() {
        #expect(HintActivation(modifiers: []) == .click)
        #expect(HintActivation(modifiers: .shift) == .rightClick)
        #expect(HintActivation(modifiers: .command) == .commandClick)
        #expect(HintActivation(modifiers: .option) == .doubleClick)
        #expect(HintActivation(modifiers: .control) == .moveMouse)
    }
}

@Suite("Element search fixes")
struct ElementSearchTests {
    @Test func selectionResetsWhileTyping() {
        var matcher = HintMatcher(labels: ["a", "s", "d"], titles: ["Save", "Save As", "Share"])
        matcher.setMode(.search)
        _ = matcher.type("s")
        _ = matcher.moveSelection(by: 2)
        #expect(matcher.searchSelection == 2)
        _ = matcher.type("a")
        #expect(matcher.searchSelection == 0, "a narrower query starts at its best match")
        guard case .matched(let index) = matcher.confirm() else {
            Issue.record("Return must still activate a result")
            return
        }
        #expect([0, 1].contains(index))
    }

    @Test func functionKeysAreNotQueryText() {
        #expect(HintMatcher.isTypable("a"))
        #expect(HintMatcher.isTypable("ş"))
        #expect(HintMatcher.isTypable(" "))
        #expect(!HintMatcher.isTypable(Character(UnicodeScalar(0xF702)!)), "left arrow")
        #expect(!HintMatcher.isTypable(Character(UnicodeScalar(0xF729)!)), "home")
        #expect(!HintMatcher.isTypable("\u{7F}"))
    }
}
