import AppKit
import Carbon.HIToolbox

/// Global shortcuts handled by the event tap instead of Carbon.
///
/// Carbon's `RegisterEventHotKey` cannot claim chords that the system consumes
/// first (⌘⇥, ⌘`) and fails for chords another app owns. Those bindings are
/// matched here, before the system sees them. Requires Accessibility.
public final class TapHotKeys: EventTapHandler {
    public static let shared = TapHotKeys()

    private struct Binding {
        let combo: KeyCombo
        let handler: @MainActor () -> Void
    }

    private var bindings: [UUID: Binding] = [:]
    public var isSuspended = false

    /// Chords macOS handles before regular hotkeys ever fire.
    public static let systemReservedCombos: Set<KeyCombo> = [
        KeyCombo(keyCode: UInt16(kVK_Tab), modifiers: .command),
        KeyCombo(keyCode: UInt16(kVK_Tab), modifiers: [.command, .shift]),
        KeyCombo(keyCode: UInt16(kVK_ANSI_Grave), modifiers: .command),
        KeyCombo(keyCode: UInt16(kVK_ANSI_Grave), modifiers: [.command, .shift]),
    ]

    public init() {
        EventTapManager.shared.add(self)
    }

    @discardableResult
    public func register(_ combo: KeyCombo, handler: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        bindings[id] = Binding(combo: combo, handler: handler)
        EventTapManager.shared.refresh()
        return id
    }

    public func unregister(_ id: UUID) {
        bindings[id] = nil
        EventTapManager.shared.refresh()
    }

    public func unregisterAll() {
        bindings.removeAll()
        EventTapManager.shared.refresh()
    }

    public var count: Int { bindings.count }

    /// Below modal sessions (switcher, hints) so they keep receiving keys while open.
    public var eventTapPriority: Int { 800 }

    public var eventTapTypes: Set<CGEventType> { bindings.isEmpty ? [] : [.keyDown] }

    public func handleTapEvent(_ event: CGEvent, type: CGEventType) -> EventTapDisposition {
        guard !isSuspended, !HotKeyCenter.shared.isSuspended else { return .pass }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = KeyModifiers(event.flags).subtracting(.function)
        guard let binding = bindings.values.first(where: { $0.combo.keyCode == keyCode && $0.combo.modifiers == modifiers }) else {
            return .pass
        }
        binding.handler()
        return .consume
    }
}

/// Captures the next key chord system-wide — including ⌘⇥, ⌘Space and other
/// chords macOS normally intercepts — for the shortcut recorder.
public final class KeyCaptureTap: EventTapHandler {
    public static let shared = KeyCaptureTap()

    private var handler: (@MainActor (KeyCombo) -> Void)?

    public init() {
        EventTapManager.shared.add(self)
    }

    /// True when capture can see system chords (the event tap is running).
    public var isAvailable: Bool { AXIsProcessTrusted() }

    public func begin(_ handler: @escaping @MainActor (KeyCombo) -> Void) {
        self.handler = handler
        EventTapManager.shared.refresh()
    }

    public func end() {
        handler = nil
        EventTapManager.shared.refresh()
    }

    public var eventTapPriority: Int { 5000 }

    public var eventTapTypes: Set<CGEventType> { handler == nil ? [] : [.keyDown] }

    public func handleTapEvent(_ event: CGEvent, type: CGEventType) -> EventTapDisposition {
        guard let handler else { return .pass }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard !KeyCodes.isModifierKey(keyCode) else { return .pass }
        handler(KeyCombo(keyCode: keyCode, modifiers: KeyModifiers(event.flags).subtracting(.function)))
        return .consume
    }
}
