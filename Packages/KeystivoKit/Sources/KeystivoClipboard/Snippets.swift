import AppKit
import Carbon.HIToolbox
import KeystivoCore
import Observation

/// A reusable text fragment, optionally expanded by typing its keyword.
nonisolated public struct Snippet: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var name: String
    /// Typing this (e.g. ";addr") anywhere expands the snippet. Empty = launcher only.
    public var keyword: String
    public var content: String
    public var collection: String
    public var isEnabled = true

    public init(name: String, keyword: String, content: String, collection: String = "") {
        self.name = name
        self.keyword = keyword
        self.content = content
        self.collection = collection
    }
}

/// Expands placeholders in snippet content. Pure and testable.
///
/// Supported: `{date}`, `{time}`, `{datetime}`, `{date:FORMAT}` (ICU pattern),
/// `{clipboard}`, `{uuid}`, `{cursor}` (final caret position).
nonisolated public enum SnippetRenderer {
    public struct Output: Equatable, Sendable {
        public let text: String
        /// Characters between the `{cursor}` marker and the end of the text.
        public let cursorOffsetFromEnd: Int

        public init(text: String, cursorOffsetFromEnd: Int) {
            self.text = text
            self.cursorOffsetFromEnd = cursorOffsetFromEnd
        }
    }

    public static func render(_ content: String, clipboard: String?, now: Date = .now, locale: Locale = .current, uuid: () -> UUID = UUID.init) -> Output {
        var result = ""
        var cursorIndex: Int?
        var index = content.startIndex
        while index < content.endIndex {
            let character = content[index]
            if character == "{", let close = content[index...].firstIndex(of: "}") {
                let token = String(content[content.index(after: index)..<close])
                if let replacement = value(for: token, clipboard: clipboard, now: now, locale: locale, uuid: uuid) {
                    result += replacement
                    index = content.index(after: close)
                    continue
                }
                if token == "cursor" {
                    cursorIndex = result.count
                    index = content.index(after: close)
                    continue
                }
            }
            result.append(character)
            index = content.index(after: index)
        }
        let offset = cursorIndex.map { result.count - $0 } ?? 0
        return Output(text: result, cursorOffsetFromEnd: offset)
    }

    private static func value(for token: String, clipboard: String?, now: Date, locale: Locale, uuid: () -> UUID) -> String? {
        let formatter = DateFormatter()
        formatter.locale = locale
        switch token {
        case "date":
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter.string(from: now)
        case "time":
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return formatter.string(from: now)
        case "datetime":
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter.string(from: now)
        case "clipboard":
            return clipboard ?? ""
        case "uuid":
            return uuid().uuidString
        default:
            if token.hasPrefix("date:") {
                formatter.dateFormat = String(token.dropFirst(5))
                return formatter.string(from: now)
            }
            return nil
        }
    }
}

/// Watches typed characters (only while snippets with keywords exist) and
/// replaces a typed keyword with its snippet. Disabled in secure text fields.
@Observable
public final class SnippetExpander: EventTapHandler {
    public static let shared = SnippetExpander()

    public var snippets: [Snippet] = [] {
        didSet { rebuildIndex() }
    }
    public var isEnabled = true {
        didSet { EventTapManager.shared.refresh() }
    }
    /// Apps in which expansion never happens (e.g. terminals, games).
    public var excludedBundleIDs: Set<String> = []

    @ObservationIgnored private var buffer = ""
    @ObservationIgnored private var keywords: [String: Snippet] = [:]
    @ObservationIgnored private var maxKeywordLength = 0
    @ObservationIgnored private var isExpanding = false
    /// Keys typed while an expansion is being inserted; replayed afterwards so fast
    /// typing never lands in the middle of the snippet.
    @ObservationIgnored private var heldKeys: [CGEvent] = []

    public init() {}

    public var eventTapPriority: Int { 10 }

    public var eventTapTypes: Set<CGEventType> {
        isEnabled && !keywords.isEmpty ? [.keyDown, .leftMouseDown] : []
    }

    private func rebuildIndex() {
        keywords = Dictionary(
            snippets.filter { $0.isEnabled && !$0.keyword.isEmpty }.map { ($0.keyword, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        maxKeywordLength = keywords.keys.map(\.count).max() ?? 0
        buffer = ""
        EventTapManager.shared.refresh()
    }

    public func handleTapEvent(_ event: CGEvent, type: CGEventType) -> EventTapDisposition {
        if type == .leftMouseDown { buffer = ""; return .pass }
        if isExpanding {
            if type == .keyDown, event.getIntegerValueField(.eventSourceUserData) != Self.replayMarker, let copy = event.copy() {
                heldKeys.append(copy)
                return .consume
            }
            return .pass
        }
        guard !IsSecureEventInputEnabled() else { return .pass }
        if let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, excludedBundleIDs.contains(bundleID) {
            return .pass
        }
        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            buffer = ""
            return .pass
        }
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        switch keyCode {
        case kVK_Delete:
            if !buffer.isEmpty { buffer.removeLast() }
            return .pass
        case kVK_Return, kVK_Tab, kVK_Escape, kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_ANSI_KeypadEnter:
            buffer = ""
            return .pass
        default:
            break
        }
        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
        guard length > 0 else { return .pass }
        buffer += String(utf16CodeUnits: chars, count: min(length, chars.count))
        if buffer.count > max(maxKeywordLength, 1) * 2 { buffer = String(buffer.suffix(maxKeywordLength)) }

        // The keystroke completing a keyword passes through; we then erase the keyword.
        // The longest matching keyword wins, so ";email" isn't shadowed by ";e" by chance.
        if let match = keywords.filter({ buffer.hasSuffix($0.key) }).max(by: { $0.key.count < $1.key.count }) {
            buffer = ""
            let keywordLength = match.key.count
            let snippet = match.value
            Task { await self.expand(snippet, erasing: keywordLength) }
        }
        return .pass
    }

    static let replayMarker: Int64 = 0x4B53_4E50  // "KSNP"

    private func expand(_ snippet: Snippet, erasing count: Int) async {
        isExpanding = true
        try? await Task.sleep(for: .milliseconds(30))
        for _ in 0..<count { SyntheticInput.pressKey(UInt16(kVK_Delete)) }
        await Self.insert(snippet.content)
        isExpanding = false
        // Type what arrived meanwhile, in order.
        let held = heldKeys
        heldKeys = []
        for event in held {
            event.setIntegerValueField(.eventSourceUserData, value: Self.replayMarker)
            event.post(tap: .cgSessionEventTap)
            if let up = event.copy() {
                up.type = .keyUp
                up.post(tap: .cgSessionEventTap)
            }
        }
    }

    /// Keywords where one is the start of another (";e" and ";email"): the shorter
    /// one fires first, so the longer can never be typed.
    public static func shadowedKeywords(_ snippets: [Snippet]) -> [(short: String, long: String)] {
        let keywords = Set(snippets.filter { $0.isEnabled && !$0.keyword.isEmpty }.map(\.keyword)).sorted()
        var result: [(String, String)] = []
        for short in keywords {
            for long in keywords where long != short && long.hasPrefix(short) { result.append((short, long)) }
        }
        return result
    }

    /// Inserts rendered snippet text into the frontmost app through the pasteboard,
    /// restoring the user's clipboard afterwards.
    public static func insert(_ content: String, renderingPlaceholders: Bool = true) async {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        } ?? []
        let output = renderingPlaceholders
            ? SnippetRenderer.render(content, clipboard: pasteboard.string(forType: .string), locale: Localizer.shared.locale)
            : SnippetRenderer.Output(text: content, cursorOffsetFromEnd: 0)
        // The text is provided on demand, so we know when the app has actually read it
        // (slow apps such as Electron or VMs read well after the paste keystroke).
        let provider = PasteProvider(text: output.text)
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.string])
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        ClipboardMonitor.shared.markOwnWrite()
        try? await Task.sleep(for: .milliseconds(40))
        SyntheticInput.paste()
        if output.cursorOffsetFromEnd > 0 {
            try? await Task.sleep(for: .milliseconds(60))
            for _ in 0..<output.cursorOffsetFromEnd { SyntheticInput.pressKey(UInt16(kVK_LeftArrow)) }
        }
        await provider.waitUntilRead(timeout: .seconds(2))
        try? await Task.sleep(for: .milliseconds(150))
        pasteboard.clearContents()
        if !saved.isEmpty { pasteboard.writeObjects(saved) }
        ClipboardMonitor.shared.markOwnWrite()
        withExtendedLifetime(provider) {}
    }
}

/// Supplies pasted text when the receiving app asks for it.
nonisolated private final class PasteProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    let text: String
    private var read = false
    private let lock = NSLock()
    var wasRead: Bool { lock.withLock { read } }

    init(text: String) { self.text = text }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        item.setString(text, forType: type)
        lock.withLock { read = true }
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {}

    func waitUntilRead(timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        while !wasRead, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }
}
