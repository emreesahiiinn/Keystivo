import AppKit
import CoreServices
import KeystivoCore
import Observation
import UniformTypeIdentifiers

nonisolated public enum FileKind: String, Codable, Sendable, CaseIterable {
    case image, movie, audio, pdf, document, archive, diskImage, application, folder, code, other
    public var titleKey: String { "fileKind.\(rawValue)" }

    public static func of(_ type: UTType?, isDirectory: Bool) -> FileKind {
        if isDirectory, type?.conforms(to: .application) != true { return .folder }
        guard let type else { return .other }
        if type.conforms(to: .application) { return .application }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .movie }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .diskImage) { return .diskImage }
        if type.conforms(to: .archive) || type.identifier == "com.apple.installer-package-archive" { return .archive }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) { return .code }
        if type.conforms(to: .text) || type.conforms(to: .presentation) || type.conforms(to: .spreadsheet) || type.identifier.contains("document") { return .document }
        return .other
    }
}

/// What a rule looks at.
nonisolated public enum FileCondition: Codable, Hashable, Sendable {
    case nameContains(String)
    /// Shell-style glob, e.g. "Screenshot*.png".
    case nameMatches(String)
    case extensionIs([String])
    case kind(FileKind)
    case addedMoreThanDaysAgo(Int)
    case largerThanMB(Double)

    public var kindKey: String {
        switch self {
        case .nameContains: "nameContains"
        case .nameMatches: "nameMatches"
        case .extensionIs: "extensionIs"
        case .kind: "kind"
        case .addedMoreThanDaysAgo: "addedMoreThanDaysAgo"
        case .largerThanMB: "largerThanMB"
        }
    }
}

/// What a rule does.
nonisolated public enum FileAction: Codable, Hashable, Sendable {
    case moveTo(String)
    case copyTo(String)
    /// Pattern with {name}, {ext}, {date}, {time}, {counter}.
    case rename(String)
    case addTag(String)
    case moveToTrash
    case openWith(String)
    case runShellScript(String)
    case notify

    public var kindKey: String {
        switch self {
        case .moveTo: "moveTo"
        case .copyTo: "copyTo"
        case .rename: "rename"
        case .addTag: "addTag"
        case .moveToTrash: "moveToTrash"
        case .openWith: "openWith"
        case .runShellScript: "runShellScript"
        case .notify: "notify"
        }
    }
}

nonisolated public struct FolderRule: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var name: String
    public var folderPath: String
    public var conditions: [FileCondition]
    public var matchesAll = true
    public var actions: [FileAction]
    public var isEnabled = true

    public init(name: String, folderPath: String, conditions: [FileCondition], actions: [FileAction]) {
        self.name = name
        self.folderPath = folderPath
        self.conditions = conditions
        self.actions = actions
    }

    public var folderURL: URL { URL(fileURLWithPath: (folderPath as NSString).expandingTildeInPath, isDirectory: true) }
}

/// Facts about a file used by rule evaluation (decoupled from the disk for tests).
nonisolated public struct FileFacts: Sendable {
    public var name: String
    public var isDirectory: Bool
    public var kind: FileKind
    public var size: Int64
    public var added: Date

    public var ext: String { (name as NSString).pathExtension.lowercased() }
    public var baseName: String { (name as NSString).deletingPathExtension }

    public init(name: String, isDirectory: Bool = false, kind: FileKind = .other, size: Int64 = 0, added: Date = .now) {
        self.name = name
        self.isDirectory = isDirectory
        self.kind = kind
        self.size = size
        self.added = added
    }

    public static func read(_ url: URL) -> FileFacts? {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey, .fileSizeKey, .addedToDirectoryDateKey, .creationDateKey, .isPackageKey]) else { return nil }
        let isDirectory = values.isDirectory == true && values.isPackage != true
        return FileFacts(
            name: url.lastPathComponent, isDirectory: isDirectory,
            kind: FileKind.of(values.contentType, isDirectory: values.isDirectory == true),
            size: Int64(values.fileSize ?? 0), added: values.addedToDirectoryDate ?? values.creationDate ?? .now
        )
    }
}

/// Pure rule logic, fully unit-tested.
nonisolated public enum FolderRuleEvaluator {
    public static func matches(_ rule: FolderRule, _ facts: FileFacts, now: Date = .now) -> Bool {
        guard !rule.conditions.isEmpty, !facts.name.hasPrefix("."), !facts.name.hasSuffix(".download"),
              !facts.name.hasSuffix(".crdownload"), !facts.name.hasSuffix(".part") else { return false }
        let results = rule.conditions.map { matches($0, facts, now: now) }
        return rule.matchesAll ? results.allSatisfy { $0 } : results.contains(true)
    }

    public static func matches(_ condition: FileCondition, _ facts: FileFacts, now: Date = .now) -> Bool {
        switch condition {
        case .nameContains(let text): return facts.name.localizedCaseInsensitiveContains(text)
        case .nameMatches(let pattern): return fnmatch(pattern.lowercased(), facts.name.lowercased(), 0) == 0
        case .extensionIs(let list): return list.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }.contains(facts.ext)
        case .kind(let kind): return facts.kind == kind
        case .addedMoreThanDaysAgo(let days): return now.timeIntervalSince(facts.added) > TimeInterval(days) * 86_400
        case .largerThanMB(let megabytes): return Double(facts.size) > megabytes * 1_048_576
        }
    }

    /// Expands a rename pattern.
    public static func renamed(_ pattern: String, facts: FileFacts, now: Date = .now, counter: Int = 1) -> String {
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "HH.mm.ss"
        var result = pattern
            .replacingOccurrences(of: "{name}", with: facts.baseName)
            .replacingOccurrences(of: "{date}", with: date.string(from: now))
            .replacingOccurrences(of: "{time}", with: time.string(from: now))
            .replacingOccurrences(of: "{counter}", with: String(counter))
        let hasExtension = result.contains("{ext}")
        result = result.replacingOccurrences(of: "{ext}", with: facts.ext)
        if !hasExtension, !facts.ext.isEmpty, !facts.isDirectory { result += "." + facts.ext }
        return result.replacingOccurrences(of: "/", with: "-")
    }
}

nonisolated public struct RuleRunRecord: Identifiable, Sendable {
    public let id = UUID()
    public let date: Date
    public let ruleName: String
    public let fileName: String
    public let summary: String
    public let succeeded: Bool
}

/// Watches folders with FSEvents and applies rules ("Hazel").
@Observable
public final class FolderRuleEngine {
    public static let shared = FolderRuleEngine()

    public var rules: [FolderRule] = [] {
        didSet { if rules != oldValue { restart() } }
    }
    public var isEnabled = false {
        didSet { restart() }
    }
    public private(set) var history: [RuleRunRecord] = []
    @ObservationIgnored public var onNotify: (@MainActor (String, String) -> Void)?

    @ObservationIgnored private var stream: FSEventStreamRef?
    @ObservationIgnored private var processed: [String: Date] = [:]
    @ObservationIgnored private let debouncer = Debouncer(delay: .seconds(1.5))
    @ObservationIgnored private var sweepTimer: Timer?

    public init() {}

    private func restart() {
        stopStream()
        sweepTimer?.invalidate()
        sweepTimer = nil
        guard isEnabled else { return }
        let folders = Array(Set(rules.filter(\.isEnabled).map { $0.folderURL.path }))
        guard !folders.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            MainActor.assumeIsolated {
                let engine = Unmanaged<FolderRuleEngine>.fromOpaque(info).takeUnretainedValue()
                engine.debouncer.schedule { engine.runAll() }
            }
        }
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, folders as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
        // Age-based conditions need an occasional sweep even without file events.
        let timer = Timer(timeInterval: 1800, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runAll() }
        }
        timer.tolerance = 300
        RunLoop.main.add(timer, forMode: .common)
        sweepTimer = timer
        runAll()
    }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Evaluates every enabled rule against the top level of its folder.
    public func runAll() {
        for rule in rules where rule.isEnabled {
            run(rule)
        }
    }

    public func run(_ rule: FolderRule, dryRun: Bool = false) -> [URL] {
        let folder = rule.folderURL
        guard let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var matched: [URL] = []
        for url in entries {
            guard let facts = FileFacts.read(url), FolderRuleEvaluator.matches(rule, facts) else { continue }
            let key = "\(rule.id)|\(url.path)"
            if !dryRun, let last = processed[key], Date.now.timeIntervalSince(last) < 60 { continue }
            matched.append(url)
            guard !dryRun else { continue }
            processed[key] = .now
            apply(rule, to: url, facts: facts)
        }
        return matched
    }

    @discardableResult
    private func run(_ rule: FolderRule) -> [URL] { run(rule, dryRun: false) }

    private func apply(_ rule: FolderRule, to original: URL, facts: FileFacts) {
        var url = original
        var summaries: [String] = []
        var succeeded = true
        let fileManager = FileManager.default
        for (index, action) in rule.actions.enumerated() {
            do {
                switch action {
                case .moveTo(let path), .copyTo(let path):
                    let folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
                    try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
                    let destination = Self.unique(folder.appendingPathComponent(url.lastPathComponent))
                    if case .moveTo = action {
                        try fileManager.moveItem(at: url, to: destination)
                        url = destination
                    } else {
                        try fileManager.copyItem(at: url, to: destination)
                    }
                    summaries.append("→ \(folder.lastPathComponent)")
                case .rename(let pattern):
                    let name = FolderRuleEvaluator.renamed(pattern, facts: FileFacts.read(url) ?? facts, counter: index + 1)
                    let destination = Self.unique(url.deletingLastPathComponent().appendingPathComponent(name))
                    try fileManager.moveItem(at: url, to: destination)
                    url = destination
                    summaries.append("✎ \(name)")
                case .addTag(let tag):
                    let existing = (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
                    // NSURL keeps this working before macOS 26 (URLResourceValues.tagNames is read-only there).
                    try (url as NSURL).setResourceValue(Array(Set(existing + [tag])), forKey: .tagNamesKey)
                    summaries.append("# \(tag)")
                case .moveToTrash:
                    try fileManager.trashItem(at: url, resultingItemURL: nil)
                    summaries.append("🗑")
                case .openWith(let bundleID):
                    if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                    }
                case .runShellScript(let script):
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                    process.arguments = ["-c", script, "keystivo", url.path]
                    try process.run()
                case .notify:
                    onNotify?(rule.name, url.lastPathComponent)
                }
            } catch {
                succeeded = false
                summaries.append("⚠︎ \(error.localizedDescription)")
                DiagnosticsCenter.shared.record(.warning, module: "FolderRules", L("folderRules.error", rule.name, original.lastPathComponent), detail: error.localizedDescription)
                break
            }
        }
        history.insert(RuleRunRecord(date: .now, ruleName: rule.name, fileName: original.lastPathComponent, summary: summaries.joined(separator: " "), succeeded: succeeded), at: 0)
        if history.count > 200 { history.removeLast(history.count - 200) }
    }

    nonisolated static func unique(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var index = 2
        while true {
            var candidate = url.deletingLastPathComponent().appendingPathComponent("\(base) \(index)")
            if !ext.isEmpty { candidate.appendPathExtension(ext) }
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    public static var templates: [FolderRule] {
        let downloads = "~/Downloads"
        return [
            FolderRule(name: L("folderRules.template.screenshots"), folderPath: "~/Desktop",
                       conditions: [.nameMatches("Screenshot*"), .kind(.image)], actions: [.moveTo("~/Pictures/Screenshots")]),
            FolderRule(name: L("folderRules.template.installers"), folderPath: downloads,
                       conditions: [.kind(.diskImage), .addedMoreThanDaysAgo(3)], actions: [.moveToTrash]),
            FolderRule(name: L("folderRules.template.pdfs"), folderPath: downloads,
                       conditions: [.kind(.pdf)], actions: [.moveTo("~/Documents/PDFs"), .addTag("Downloaded")]),
            FolderRule(name: L("folderRules.template.images"), folderPath: downloads,
                       conditions: [.kind(.image)], actions: [.moveTo("~/Pictures/Downloads")]),
        ]
    }
}
