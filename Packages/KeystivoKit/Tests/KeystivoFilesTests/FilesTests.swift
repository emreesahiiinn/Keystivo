import Foundation
@testable import KeystivoFiles
import Testing

@Suite("Uninstaller matching")
struct UninstallerTests {
    let identity = AppUninstaller.AppIdentity(url: URL(fileURLWithPath: "/Applications/Figma.app"), bundleID: "com.figma.Desktop", names: ["Figma"])

    @Test func matchesBundleIDsAndNames() {
        #expect(AppUninstaller.matches("com.figma.Desktop", identity: identity))
        #expect(AppUninstaller.matches("com.figma.Desktop.plist", identity: identity))
        #expect(AppUninstaller.matches("com.figma.Desktop.savedState", identity: identity))
        #expect(AppUninstaller.matches("ABCDE12345.com.figma.Desktop", identity: identity))
        #expect(AppUninstaller.matches("Figma", identity: identity))
    }

    @Test func doesNotMatchUnrelatedEntries() {
        #expect(!AppUninstaller.matches("com.figmaclone.app", identity: identity))
        #expect(!AppUninstaller.matches("Figma Helper Tools", identity: identity))
        let short = AppUninstaller.AppIdentity(url: URL(fileURLWithPath: "/Applications/Go.app"), bundleID: "com.example.go", names: ["Go"])
        #expect(!AppUninstaller.matches("Go", identity: short))
    }

    @Test func systemAppsAreProtected() {
        #expect(!AppUninstaller.isRemovable(URL(fileURLWithPath: "/System/Applications/Notes.app")))
        #expect(!AppUninstaller.isRemovable(URL(fileURLWithPath: "/tmp/not-an-app")))
    }
}

@Suite("Folder rules")
struct FolderRuleTests {
    let now = Date(timeIntervalSince1970: 1_760_000_000)

    @Test func conditions() {
        let file = FileFacts(name: "Screenshot 2025-10-09.png", kind: .image, size: 3 * 1_048_576, added: now.addingTimeInterval(-10 * 86_400))
        #expect(FolderRuleEvaluator.matches(.nameMatches("screenshot*.png"), file, now: now))
        #expect(FolderRuleEvaluator.matches(.nameContains("2025"), file, now: now))
        #expect(FolderRuleEvaluator.matches(.extensionIs([".PNG", "jpg"]), file, now: now))
        #expect(FolderRuleEvaluator.matches(.kind(.image), file, now: now))
        #expect(FolderRuleEvaluator.matches(.addedMoreThanDaysAgo(7), file, now: now))
        #expect(!FolderRuleEvaluator.matches(.addedMoreThanDaysAgo(30), file, now: now))
        #expect(FolderRuleEvaluator.matches(.largerThanMB(2), file, now: now))
    }

    @Test func allVersusAny() {
        let file = FileFacts(name: "a.pdf", kind: .pdf)
        var rule = FolderRule(name: "r", folderPath: "~/Downloads", conditions: [.kind(.pdf), .nameContains("zzz")], actions: [])
        #expect(!FolderRuleEvaluator.matches(rule, file))
        rule.matchesAll = false
        #expect(FolderRuleEvaluator.matches(rule, file))
    }

    @Test func partialDownloadsAndHiddenFilesAreIgnored() {
        let rule = FolderRule(name: "r", folderPath: "~", conditions: [.nameContains("a")], actions: [])
        #expect(!FolderRuleEvaluator.matches(rule, FileFacts(name: "a.zip.download")))
        #expect(!FolderRuleEvaluator.matches(rule, FileFacts(name: ".a")))
        #expect(!FolderRuleEvaluator.matches(rule, FileFacts(name: "a.crdownload")))
    }

    @Test func renamePatterns() {
        let file = FileFacts(name: "report.final.pdf")
        #expect(FolderRuleEvaluator.renamed("{date} {name}", facts: file, now: now) == "2025-10-09 report.final.pdf")
        #expect(FolderRuleEvaluator.renamed("{name}-{counter}.{ext}", facts: file, now: now, counter: 3) == "report.final-3.pdf")
        #expect(FolderRuleEvaluator.renamed("a/b", facts: FileFacts(name: "x", isDirectory: true), now: now) == "a-b")
    }

    @Test func fileKinds() {
        #expect(FileKind.of(.png, isDirectory: false) == .image)
        #expect(FileKind.of(.pdf, isDirectory: false) == .pdf)
        #expect(FileKind.of(.zip, isDirectory: false) == .archive)
        #expect(FileKind.of(.folder, isDirectory: true) == .folder)
        #expect(FileKind.of(.swiftSource, isDirectory: false) == .code)
    }

    @Test func uniqueNames() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("keystivo-unique-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = folder.appendingPathComponent("file.txt")
        try Data().write(to: original)
        #expect(FolderRuleEngine.unique(original).lastPathComponent == "file 2.txt")
        #expect(FolderRuleEngine.unique(folder.appendingPathComponent("new.txt")).lastPathComponent == "new.txt")
    }

    @Test func shelfDeduplicates() {
        let store = ShelfStore()
        let url = URL(fileURLWithPath: "/tmp/a.txt")
        store.add(urls: [url, url])
        store.add(text: "")
        store.add(text: "hello")
        #expect(store.items.count == 2)
        #expect(store.fileURLs == [url])
    }
}
