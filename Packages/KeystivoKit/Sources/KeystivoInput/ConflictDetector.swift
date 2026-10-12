import AppKit
import KeystivoCore

/// Anything that can be triggered by a key chord or gesture, for conflict analysis.
nonisolated public struct TriggerBinding: Hashable, Sendable, Identifiable {
    public enum Trigger: Hashable, Sendable {
        case keyCombo(KeyCombo)
        case trackpad(TrackpadGesture)
        case mouse(MouseGesture)
    }

    public enum Origin: String, Hashable, Sendable {
        case keystivo
        case system
        case commonAppShortcut
    }

    public let id: String
    public let trigger: Trigger
    public let title: String
    public let origin: Origin
    /// nil = global; otherwise the apps where the binding is active.
    public let scope: Set<String>?

    public init(id: String, trigger: Trigger, title: String, origin: Origin, scope: Set<String>? = nil) {
        self.id = id
        self.trigger = trigger
        self.title = title
        self.origin = origin
        self.scope = scope
    }
}

nonisolated public struct BindingConflict: Hashable, Sendable, Identifiable {
    public enum Severity: Int, Comparable, Sendable {
        /// App-specific binding intentionally overrides a global one.
        case override = 0
        case warning = 1
        case error = 2
        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var id: String { [first.id, second.id].sorted().joined(separator: "|") }
    public let first: TriggerBinding
    public let second: TriggerBinding
    public let severity: Severity
}

/// Finds overlapping shortcuts and gestures ("gesture ve kısayol çakışmalarını tespit etme").
nonisolated public enum ConflictDetector {
    public static func detect(_ bindings: [TriggerBinding]) -> [BindingConflict] {
        var conflicts: [BindingConflict] = []
        let grouped = Dictionary(grouping: bindings, by: \.trigger)
        for (_, group) in grouped where group.count > 1 {
            for i in 0..<group.count {
                for j in (i + 1)..<group.count {
                    let a = group[i]
                    let b = group[j]
                    guard a.origin == .keystivo || b.origin == .keystivo else { continue }
                    guard let severity = severity(a, b) else { continue }
                    conflicts.append(BindingConflict(first: a, second: b, severity: severity))
                }
            }
        }
        return conflicts.sorted { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            return lhs.first.title < rhs.first.title
        }
    }

    static func severity(_ a: TriggerBinding, _ b: TriggerBinding) -> BindingConflict.Severity? {
        switch (a.scope, b.scope) {
        case (nil, nil):
            if a.origin == .keystivo && b.origin == .keystivo { return .error }
            return b.origin == .commonAppShortcut || a.origin == .commonAppShortcut ? .warning : .error
        case (let scopeA?, let scopeB?):
            return scopeA.isDisjoint(with: scopeB) ? nil : .error
        default:
            // One global, one app-specific: the app-specific binding wins in its apps.
            return (a.origin == .keystivo && b.origin == .keystivo) ? .override : .warning
        }
    }
}

/// Reads shortcuts and gestures macOS itself uses, so Keystivo can warn about clashes.
public enum SystemBindings {
    /// Enabled entries of System Settings › Keyboard › Keyboard Shortcuts.
    public static func symbolicHotKeys() -> [TriggerBinding] {
        guard let defaults = UserDefaults(suiteName: "com.apple.symbolichotkeys"),
              let hotKeys = defaults.dictionary(forKey: "AppleSymbolicHotKeys") else { return [] }
        var result: [TriggerBinding] = []
        for (key, raw) in hotKeys {
            guard let entry = raw as? [String: Any], (entry["enabled"] as? Bool) == true,
                  let value = entry["value"] as? [String: Any],
                  let parameters = value["parameters"] as? [Int], parameters.count == 3,
                  parameters[1] != 65535,
                  let rawFlags = UInt(exactly: parameters[2]), let keyCode = UInt16(exactly: parameters[1]) else { continue }
            let flags = NSEvent.ModifierFlags(rawValue: rawFlags)
            // Arrow and function keys carry the fn flag here, but recorded shortcuts never do.
            let combo = KeyCombo(keyCode: keyCode, modifiers: KeyModifiers(flags).subtracting(.function))
            let name = symbolicNames[Int(key) ?? -1].map { L($0) } ?? L("conflict.systemShortcut", key)
            result.append(TriggerBinding(id: "system.hotkey.\(key)", trigger: .keyCombo(combo), title: name, origin: .system))
        }
        return result
    }

    /// Well-known IDs from com.apple.symbolichotkeys.
    static let symbolicNames: [Int: String] = [
        7: "system.hotkey.moveFocusMenuBar", 8: "system.hotkey.moveFocusDock", 9: "system.hotkey.moveFocusWindow",
        27: "system.hotkey.moveFocusNextWindow", 28: "system.hotkey.screenshot", 29: "system.hotkey.screenshotClipboard",
        30: "system.hotkey.screenshotArea", 31: "system.hotkey.screenshotAreaClipboard", 32: "system.hotkey.missionControl",
        33: "system.hotkey.appWindows", 36: "system.hotkey.showDesktop", 60: "system.hotkey.previousInputSource",
        61: "system.hotkey.nextInputSource", 64: "system.hotkey.spotlight", 65: "system.hotkey.finderSearch",
        79: "system.hotkey.spaceLeft", 81: "system.hotkey.spaceRight", 118: "system.hotkey.desktop1",
        119: "system.hotkey.desktop2", 120: "system.hotkey.desktop3", 121: "system.hotkey.desktop4",
        160: "system.hotkey.launchpad", 162: "system.hotkey.accessibility", 163: "system.hotkey.notificationCenter",
        175: "system.hotkey.doNotDisturb", 184: "system.hotkey.screenshotToolbar", 190: "system.hotkey.quickNote",
    ]

    /// Shortcuts virtually every app uses; global bindings on these are suspicious.
    public static func commonAppShortcuts() -> [TriggerBinding] {
        let keys: [(Character, String)] = [
            ("c", "common.copy"), ("v", "common.paste"), ("x", "common.cut"), ("z", "common.undo"), ("a", "common.selectAll"),
            ("s", "common.save"), ("q", "common.quit"), ("w", "common.closeWindow"), ("t", "common.newTab"), ("n", "common.new"),
            ("f", "common.find"), ("p", "common.print"), ("o", "common.open"), ("h", "common.hide"), ("m", "common.minimize"),
        ]
        var result = keys.compactMap { key, title -> TriggerBinding? in
            guard let code = KeyCodes.letterKeyCodes[key] else { return nil }
            return TriggerBinding(id: "common.\(key)", trigger: .keyCombo(KeyCombo(keyCode: code, modifiers: .command)), title: L(title), origin: .commonAppShortcut)
        }
        result.append(TriggerBinding(id: "common.cmdTab", trigger: .keyCombo(KeyCombo(keyCode: KeyCodes.tab, modifiers: .command)), title: L("common.appSwitcher"), origin: .system))
        result.append(TriggerBinding(id: "common.cmdSpace", trigger: .keyCombo(KeyCombo(keyCode: KeyCodes.space, modifiers: .command)), title: L("system.hotkey.spotlight"), origin: .system))
        return result
    }

    /// Trackpad gestures enabled in System Settings › Trackpad.
    public static func trackpadGestures() -> [TriggerBinding] {
        let domains = ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"]
        var settings: [String: Int] = [:]
        for domain in domains {
            guard let values = UserDefaults(suiteName: domain)?.dictionaryRepresentation() else { continue }
            for (key, value) in values { if let number = value as? Int { settings[key] = max(settings[key] ?? 0, number) } }
        }
        var result: [TriggerBinding] = []
        func add(_ id: String, _ gestures: [TrackpadGesture], _ title: String) {
            for gesture in gestures {
                result.append(TriggerBinding(id: "system.gesture.\(id).\(gesture.fingers)\(gesture.direction?.rawValue ?? "")", trigger: .trackpad(gesture), title: L(title), origin: .system))
            }
        }
        func swipes(_ fingers: Int, _ directions: [GestureDirection]) -> [TrackpadGesture] {
            directions.map { TrackpadGesture(kind: .swipe, fingers: fingers, direction: $0) }
        }
        if settings["TrackpadThreeFingerHorizSwipeGesture"] == 2 { add("spaces3", swipes(3, [.left, .right]), "system.gesture.switchSpaces") }
        if settings["TrackpadThreeFingerVertSwipeGesture"] == 2 { add("mission3", swipes(3, [.up, .down]), "system.gesture.missionControl") }
        if settings["TrackpadFourFingerHorizSwipeGesture"] == 2 { add("spaces4", swipes(4, [.left, .right]), "system.gesture.switchSpaces") }
        if settings["TrackpadFourFingerVertSwipeGesture"] == 2 { add("mission4", swipes(4, [.up, .down]), "system.gesture.missionControl") }
        if settings["TrackpadThreeFingerTapGesture"] == 2 { add("lookup", [TrackpadGesture(kind: .tap, fingers: 3)], "system.gesture.lookUp") }
        if settings["TrackpadTwoFingerFromRightEdgeSwipeGesture"] == 3 { add("notifications", [], "system.gesture.notificationCenter") }
        if settings["TrackpadRightClick"] == 1 { add("secondary", [TrackpadGesture(kind: .tap, fingers: 2)], "system.gesture.secondaryClick") }
        return result
    }
}
