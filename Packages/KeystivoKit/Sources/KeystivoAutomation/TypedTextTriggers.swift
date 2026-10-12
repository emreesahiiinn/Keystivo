import AppKit
import Carbon.HIToolbox
import KeystivoCore

/// Watches typed characters for workflows triggered by typed text (Keyboard
/// Maestro's typed string trigger). Keyboard events are only observed while at
/// least one such trigger exists, never in secure text fields.
public final class TypedTextTriggers: EventTapHandler {
    public static let shared = TypedTextTriggers()

    /// Strings to watch for (from active workflows).
    public var triggers: Set<String> = [] {
        didSet {
            longest = triggers.map(\.count).max() ?? 0
            buffer = ""
            EventTapManager.shared.refresh()
        }
    }
    /// Called with the matched text after it has been erased.
    public var onMatch: (@MainActor (String) -> Void)?

    private var buffer = ""
    private var longest = 0

    public init() {}

    public var eventTapPriority: Int { 9 }

    public var eventTapTypes: Set<CGEventType> { triggers.isEmpty ? [] : [.keyDown, .leftMouseDown] }

    public func handleTapEvent(_ event: CGEvent, type: CGEventType) -> EventTapDisposition {
        if type == .leftMouseDown { buffer = ""; return .pass }
        guard !IsSecureEventInputEnabled() else { return .pass }
        if event.flags.contains(.maskCommand) || event.flags.contains(.maskControl) { buffer = ""; return .pass }
        switch Int(event.getIntegerValueField(.keyboardEventKeycode)) {
        case kVK_Delete:
            if !buffer.isEmpty { buffer.removeLast() }
            return .pass
        case kVK_Return, kVK_Tab, kVK_Escape, kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
            buffer = ""
            return .pass
        default:
            break
        }
        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
        guard length > 0 else { return .pass }
        buffer += String(utf16CodeUnits: chars, count: length)
        if buffer.count > max(longest, 1) * 2 { buffer = String(buffer.suffix(longest)) }
        guard let match = triggers.filter({ buffer.hasSuffix($0) }).max(by: { $0.count < $1.count }) else { return .pass }
        buffer = ""
        // The completing keystroke still arrives; erase the whole string, then run.
        Task {
            try? await Task.sleep(for: .milliseconds(30))
            for _ in 0..<match.count { SyntheticInput.pressKey(UInt16(kVK_Delete)) }
            onMatch?(match)
        }
        return .pass
    }
}
