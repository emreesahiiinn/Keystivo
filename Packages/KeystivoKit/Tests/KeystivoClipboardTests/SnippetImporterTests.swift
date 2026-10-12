import Foundation
@testable import KeystivoClipboard
import Testing

@Suite("Snippet import")
struct SnippetImporterTests {
    @Test func readsRaycastExports() throws {
        let json = #"[{"name":"Signature","text":"Best,\nEmre {date format=\"yyyy-MM-dd\"}","keyword":";sig"},{"text":"{clipboard} and {cursor}"}]"#
        let snippets = try SnippetImporter.parse(Data(json.utf8), fileName: "snippets.json")
        #expect(snippets.count == 2)
        #expect(snippets[0].keyword == ";sig")
        #expect(snippets[0].content == "Best,\nEmre {date:yyyy-MM-dd}")
        #expect(snippets[1].content == "{clipboard} and {cursor}")
        #expect(snippets[1].keyword.isEmpty)
    }

    @Test func readsEspansoMatches() throws {
        let yaml = """
        matches:
          - trigger: ":mail"
            replace: "emre@example.com"
          - trigger: ":addr"
            label: Address
            replace: |
              Street 1
              Istanbul
          - trigger: ':clip'
            replace: "Copied: {{clipboard}}$|$"
        """
        let snippets = try SnippetImporter.parse(Data(yaml.utf8), fileName: "base.yml")
        #expect(snippets.map(\.keyword) == [":mail", ":addr", ":clip"])
        #expect(snippets[1].name == "Address")
        #expect(snippets[1].content == "Street 1\nIstanbul")
        #expect(snippets[2].content == "Copied: {clipboard}{cursor}")
    }

    @Test func readsCSVWithAndWithoutHeaders() throws {
        let withHeader = "abbreviation,snippet,label\n;hi,\"Hello, world\",Greeting\n;q,\"He said \"\"hi\"\"\nthen left\",Quote\n"
        let a = try SnippetImporter.parse(Data(withHeader.utf8), fileName: "textexpander.csv")
        #expect(a.count == 2)
        #expect(a[0].name == "Greeting" && a[0].keyword == ";hi" && a[0].content == "Hello, world")
        #expect(a[1].content == "He said \"hi\"\nthen left")
        let bare = try SnippetImporter.parse(Data(";x,Expansion\n".utf8), fileName: "list.csv")
        #expect(bare.first?.keyword == ";x" && bare.first?.content == "Expansion")
    }

    @Test func rejectsUnknownContent() {
        #expect(throws: SnippetImporter.Failure.unrecognized) {
            try SnippetImporter.parse(Data("[]".utf8), fileName: "empty.json")
        }
    }
}
