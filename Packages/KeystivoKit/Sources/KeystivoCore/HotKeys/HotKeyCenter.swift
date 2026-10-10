import AppKit
import Carbon.HIToolbox

nonisolated public struct HotKeyToken: Hashable, Sendable {
    fileprivate let id: UInt32
}

nonisolated public enum HotKeyError: LocalizedError, Equatable {
    case invalidShortcut
    case alreadyRegistered(String)
    case systemError(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidShortcut: L("hotkey.error.invalid")
        case .alreadyRegistered(let combo): L("hotkey.error.taken", combo)
        case .systemError(let code): L("hotkey.error.system", Int(code))
        }
    }
}

/// Global shortcuts backed by Carbon's `RegisterEventHotKey`.
///
/// This API needs no special permission and costs nothing while idle: the system
/// only wakes the app when a registered chord is pressed.
public final class HotKeyCenter {
    public static let shared = HotKeyCenter()

    private struct Registration {
        let ref: EventHotKeyRef
        let combo: KeyCombo
        let onPress: @MainActor () -> Void
        let onRelease: (@MainActor () -> Void)?
    }

    private var registrations: [UInt32: Registration] = [:]
    private var nextID: UInt32 = 1
    private var handlerRef: EventHandlerRef?
    private static let signature: OSType = 0x4B_53_54_56 // 'KSTV'

    /// While suspended (e.g. a shortcut recorder is focused) presses are ignored.
    public var isSuspended = false

    public init() {}

    public var registeredCombos: [KeyCombo] { registrations.values.map(\.combo) }

    @discardableResult
    public func register(
        _ combo: KeyCombo,
        onPress: @escaping @MainActor () -> Void,
        onRelease: (@MainActor () -> Void)? = nil
    ) throws(HotKeyError) -> HotKeyToken {
        guard combo.isValidGlobalShortcut else { throw .invalidShortcut }
        installHandlerIfNeeded()

        let id = nextID
        nextID &+= 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(
            UInt32(combo.keyCode), combo.modifiers.carbonFlags, hotKeyID,
            GetEventDispatcherTarget(), OptionBits(0), &ref
        )
        guard status == noErr, let ref else {
            if status == OSStatus(eventHotKeyExistsErr) { throw .alreadyRegistered(combo.displayString) }
            throw .systemError(status)
        }
        registrations[id] = Registration(ref: ref, combo: combo, onPress: onPress, onRelease: onRelease)
        return HotKeyToken(id: id)
    }

    public func unregister(_ token: HotKeyToken) {
        guard let registration = registrations.removeValue(forKey: token.id) else { return }
        UnregisterEventHotKey(registration.ref)
    }

    public func unregisterAll() {
        for registration in registrations.values { UnregisterEventHotKey(registration.ref) }
        registrations.removeAll()
    }

    /// Whether a combo can currently be registered (not taken by another app or by us).
    public func isAvailable(_ combo: KeyCombo) -> Bool {
        if registrations.values.contains(where: { $0.combo == combo }) { return false }
        guard let token = try? register(combo, onPress: {}) else { return false }
        unregister(token)
        return true
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr else { return status }
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            // Carbon dispatches hot keys on the main thread.
            MainActor.assumeIsolated {
                HotKeyCenter.shared.dispatch(id: hotKeyID.id, pressed: pressed)
            }
            return noErr
        }, types.count, &types, nil, &handlerRef)
    }

    private func dispatch(id: UInt32, pressed: Bool) {
        guard !isSuspended, let registration = registrations[id] else { return }
        if pressed {
            registration.onPress()
        } else {
            registration.onRelease?()
        }
    }
}
