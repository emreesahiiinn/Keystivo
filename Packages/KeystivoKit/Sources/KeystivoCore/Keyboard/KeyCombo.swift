import AppKit
import Carbon.HIToolbox

/// Modifier keys in a layout-independent, Codable form.
nonisolated public struct KeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let option = KeyModifiers(rawValue: 1 << 1)
    public static let control = KeyModifiers(rawValue: 1 << 2)
    public static let shift = KeyModifiers(rawValue: 1 << 3)
    public static let function = KeyModifiers(rawValue: 1 << 4)

    /// ⌃⌥⇧⌘ — the conventional "hyper" chord.
    public static let hyper: KeyModifiers = [.command, .option, .control, .shift]

    public init(_ flags: NSEvent.ModifierFlags) {
        var value: KeyModifiers = []
        if flags.contains(.command) { value.insert(.command) }
        if flags.contains(.option) { value.insert(.option) }
        if flags.contains(.control) { value.insert(.control) }
        if flags.contains(.shift) { value.insert(.shift) }
        if flags.contains(.function) { value.insert(.function) }
        self = value
    }

    public init(_ flags: CGEventFlags) {
        var value: KeyModifiers = []
        if flags.contains(.maskCommand) { value.insert(.command) }
        if flags.contains(.maskAlternate) { value.insert(.option) }
        if flags.contains(.maskControl) { value.insert(.control) }
        if flags.contains(.maskShift) { value.insert(.shift) }
        if flags.contains(.maskSecondaryFn) { value.insert(.function) }
        self = value
    }

    public var carbonFlags: UInt32 {
        var flags: UInt32 = 0
        if contains(.command) { flags |= UInt32(cmdKey) }
        if contains(.option) { flags |= UInt32(optionKey) }
        if contains(.control) { flags |= UInt32(controlKey) }
        if contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }

    public var cgFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if contains(.command) { flags.insert(.maskCommand) }
        if contains(.option) { flags.insert(.maskAlternate) }
        if contains(.control) { flags.insert(.maskControl) }
        if contains(.shift) { flags.insert(.maskShift) }
        if contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }

    public var eventFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.command) { flags.insert(.command) }
        if contains(.option) { flags.insert(.option) }
        if contains(.control) { flags.insert(.control) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.function) { flags.insert(.function) }
        return flags
    }

    /// Symbols in Apple's canonical order: ⌃⌥⇧⌘.
    public var symbols: String {
        var result = ""
        if contains(.function) { result += "fn" }
        if contains(.control) { result += "⌃" }
        if contains(.option) { result += "⌥" }
        if contains(.shift) { result += "⇧" }
        if contains(.command) { result += "⌘" }
        return result
    }
}

/// A keyboard shortcut: a physical key plus modifiers.
nonisolated public struct KeyCombo: Codable, Hashable, Sendable, CustomStringConvertible {
    public var keyCode: UInt16
    public var modifiers: KeyModifiers

    public init(keyCode: UInt16, modifiers: KeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public init(_ keyCode: Int, _ modifiers: KeyModifiers) {
        self.init(keyCode: UInt16(keyCode), modifiers: modifiers)
    }

    public init?(event: NSEvent) {
        guard event.type == .keyDown || event.type == .keyUp else { return nil }
        self.init(keyCode: event.keyCode, modifiers: KeyModifiers(event.modifierFlags))
    }

    /// Shortcuts without ⌘/⌥/⌃ are only valid for function keys, to avoid
    /// hijacking normal typing.
    public var isValidGlobalShortcut: Bool {
        if !modifiers.intersection([.command, .option, .control]).isEmpty { return true }
        return KeyCodes.isFunctionKey(keyCode)
    }

    @MainActor public var keyDisplay: String { KeyCodes.displayName(for: keyCode) }

    @MainActor public var displayString: String { modifiers.symbols + keyDisplay }

    public var description: String { modifiers.symbols + "#\(keyCode)" }
}

/// Virtual key code helpers and human-readable key names.
nonisolated public enum KeyCodes {
    public static let returnKey = UInt16(kVK_Return)
    public static let tab = UInt16(kVK_Tab)
    public static let space = UInt16(kVK_Space)
    public static let delete = UInt16(kVK_Delete)
    public static let escape = UInt16(kVK_Escape)
    public static let leftArrow = UInt16(kVK_LeftArrow)
    public static let rightArrow = UInt16(kVK_RightArrow)
    public static let upArrow = UInt16(kVK_UpArrow)
    public static let downArrow = UInt16(kVK_DownArrow)
    public static let grave = UInt16(kVK_ANSI_Grave)
    public static let keypadEnter = UInt16(kVK_ANSI_KeypadEnter)

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    private static let specialKeys: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_Escape: "⎋",
        kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑",
        kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_ANSI_KeypadEnter: "⌤", kVK_Help: "?⃝", kVK_ANSI_KeypadClear: "⌧",
        kVK_ANSI_Keypad0: "Num0", kVK_ANSI_Keypad1: "Num1", kVK_ANSI_Keypad2: "Num2",
        kVK_ANSI_Keypad3: "Num3", kVK_ANSI_Keypad4: "Num4", kVK_ANSI_Keypad5: "Num5",
        kVK_ANSI_Keypad6: "Num6", kVK_ANSI_Keypad7: "Num7", kVK_ANSI_Keypad8: "Num8",
        kVK_ANSI_Keypad9: "Num9", kVK_ANSI_KeypadPlus: "Num+", kVK_ANSI_KeypadMinus: "Num-",
        kVK_ANSI_KeypadMultiply: "Num*", kVK_ANSI_KeypadDivide: "Num/",
        kVK_ANSI_KeypadDecimal: "Num.", kVK_ANSI_KeypadEquals: "Num=",
        kVK_VolumeUp: "🔊", kVK_VolumeDown: "🔉", kVK_Mute: "🔇",
    ]

    /// US-ANSI fallbacks when the current layout cannot translate a key.
    private static let ansiKeys: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
        kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
        kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
        kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
        kVK_ANSI_Z: "Z", kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8",
        kVK_ANSI_9: "9", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[",
        kVK_ANSI_RightBracket: "]", kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";",
        kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
        kVK_ANSI_Grave: "`",
    ]

    /// Letters a–z mapped to US-ANSI key codes (layout-independent positions).
    public static let letterKeyCodes: [Character: UInt16] = {
        var map: [Character: UInt16] = [:]
        for (code, name) in ansiKeys where name.count == 1 {
            if let char = name.lowercased().first, char.isLetter { map[char] = UInt16(code) }
        }
        return map
    }()

    public static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        functionKeys[Int(keyCode)] != nil
    }

    public static func isModifierKey(_ keyCode: UInt16) -> Bool {
        [kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift, kVK_Option, kVK_RightOption,
         kVK_Control, kVK_RightControl, kVK_Function, kVK_CapsLock].contains(Int(keyCode))
    }

    @MainActor public static func displayName(for keyCode: UInt16) -> String {
        let code = Int(keyCode)
        if let name = functionKeys[code] ?? specialKeys[code] { return name }
        if let translated = KeyboardLayout.character(for: keyCode), !translated.isEmpty,
           translated.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            return translated.uppercased()
        }
        return ansiKeys[code] ?? "#\(keyCode)"
    }
}

/// Translates virtual key codes using the user's current keyboard layout,
/// so shortcuts display correctly on Turkish-Q, German, AZERTY, etc.
public enum KeyboardLayout {
    public static func character(for keyCode: UInt16, modifiers: UInt32 = 0) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
            ?? TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
            let rawData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(rawData).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer -> String? in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            var deadKeyState: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDisplay), (modifiers >> 8) & 0xFF,
                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState, chars.count, &length, &chars
            )
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }
}
