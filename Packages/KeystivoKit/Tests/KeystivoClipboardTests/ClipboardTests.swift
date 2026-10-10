import Foundation
@testable import KeystivoClipboard
import Testing

@Suite("Clipboard store")
struct ClipboardStoreTests {
    @Test func duplicatesBumpInsteadOfInserting() async throws {
        let store = try ClipboardStore()
        let first = try await store.add(ClipboardItem(kind: .text, text: "hello", lastUsedAt: Date(timeIntervalSince1970: 1)))
        try await store.add(ClipboardItem(kind: .text, text: "other", lastUsedAt: Date(timeIntervalSince1970: 2)))
        let again = try await store.add(ClipboardItem(kind: .text, text: "hello", lastUsedAt: Date(timeIntervalSince1970: 3)))
        #expect(first == again)
        #expect(try await store.count() == 2)
        #expect(try await store.items().first?.text == "hello")
    }

    @Test func searchMatchesAllWordsAndEscapesWildcards() async throws {
        let store = try ClipboardStore()
        try await store.add(ClipboardItem(kind: .text, text: "Meeting notes for Monday"))
        try await store.add(ClipboardItem(kind: .text, text: "100% done_now"))
        #expect(try await store.items(matching: "notes monday").count == 1)
        #expect(try await store.items(matching: "100%").count == 1)
        #expect(try await store.items(matching: "_").count == 1)
        #expect(try await store.items(matching: "absent").isEmpty)
    }

    @Test func pinnedItemsSurvivePruneAndClear() async throws {
        let store = try ClipboardStore()
        let pinned = try await store.add(ClipboardItem(kind: .text, text: "keep", lastUsedAt: .distantPast))
        try await store.setPinned(id: pinned, pinned: true)
        for index in 0..<10 { try await store.add(ClipboardItem(kind: .text, text: "item \(index)")) }
        try await store.prune(maxItems: 3, maxAge: nil)
        #expect(try await store.count() == 4)
        try await store.clear(keepPinned: true)
        #expect(try await store.items().map(\.text) == ["keep"])
    }

    @Test func pruneByAge() async throws {
        let store = try ClipboardStore()
        try await store.add(ClipboardItem(kind: .text, text: "old", lastUsedAt: Date(timeIntervalSinceNow: -10 * 86_400)))
        try await store.add(ClipboardItem(kind: .text, text: "new"))
        try await store.prune(maxItems: 100, maxAge: 86_400)
        #expect(try await store.items().map(\.text) == ["new"])
    }

    @Test func kindFilterAndFiles() async throws {
        let store = try ClipboardStore()
        try await store.add(ClipboardItem(kind: .file, text: "a.txt, b.txt", filePaths: ["/tmp/a.txt", "/tmp/b.txt"]))
        try await store.add(ClipboardItem(kind: .url, text: "https://example.com"))
        let files = try await store.items(kind: .file)
        #expect(files.count == 1)
        #expect(files[0].filePaths == ["/tmp/a.txt", "/tmp/b.txt"])
    }

    @Test func previewIsFirstLine() {
        #expect(ClipboardItem(kind: .text, text: "  first line  \nsecond").preview == "first line")
    }
}

@Suite("Snippet rendering")
struct SnippetRendererTests {
    let date = Date(timeIntervalSince1970: 1_760_000_000) // 2025-10-09

    @Test func placeholders() {
        let output = SnippetRenderer.render("Hi {clipboard}! {date:yyyy-MM-dd} {uuid}", clipboard: "Ada", now: date, locale: Locale(identifier: "en_US_POSIX"), uuid: { UUID(uuidString: "00000000-0000-0000-0000-000000000001")! })
        #expect(output.text == "Hi Ada! 2025-10-09 00000000-0000-0000-0000-000000000001")
        #expect(output.cursorOffsetFromEnd == 0)
    }

    @Test func cursorMarker() {
        let output = SnippetRenderer.render("<b>{cursor}</b>", clipboard: nil)
        #expect(output.text == "<b></b>")
        #expect(output.cursorOffsetFromEnd == 4)
    }

    @Test func unknownTokensStayLiteral() {
        #expect(SnippetRenderer.render("{unknown} {", clipboard: nil).text == "{unknown} {")
    }

    @Test func localizedDates() {
        let turkish = SnippetRenderer.render("{date}", clipboard: nil, now: date, locale: Locale(identifier: "tr_TR")).text
        #expect(turkish.contains("Eki") || turkish.contains("Ekim"))
    }
}
