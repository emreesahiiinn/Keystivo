import AppKit
import CoreGraphics

/// What an event-tap handler decided to do with an event.
nonisolated public enum EventTapDisposition {
    case pass
    case consume
}

/// A participant in the shared event tap. Handlers are consulted in descending
/// priority; the first one that consumes an event stops propagation.
public protocol EventTapHandler: AnyObject {
    /// Higher runs first. Modal sessions (hints, switcher) use high priorities.
    var eventTapPriority: Int { get }
    /// Event types this handler currently wants. Return an empty set when idle so
    /// the tap can drop them from its mask entirely.
    var eventTapTypes: Set<CGEventType> { get }
    func handleTapEvent(_ event: CGEvent, type: CGEventType) -> EventTapDisposition
}

public extension CGEventType {
    /// NSEventTypeGesture — not exposed by the CGEventType enum.
    static let gesture = CGEventType(rawValue: 29)!
}

/// One shared `CGEventTap` for the whole app.
///
/// The tap's mask is recomputed from the handlers' current interests, so when no
/// feature needs keyboard events, no keyboard events are delivered at all (good
/// for privacy, CPU and battery).
public final class EventTapManager {
    public static let shared = EventTapManager()

    private final class WeakHandler {
        weak var value: (any EventTapHandler)?
        init(_ value: any EventTapHandler) { self.value = value }
    }

    private var handlers: [WeakHandler] = []
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var currentMask: CGEventMask = 0
    private let logger = Log.logger("EventTap")

    /// Marks events we synthesize so our own handlers ignore them.
    public static let syntheticEventMarker: Int64 = 0x4B53_5456

    public private(set) var isRunning = false
    private var isDispatching = false
    private var refreshPending = false
    private var reportedMissingPermission = false

    public init() {}

    public func add(_ handler: any EventTapHandler) {
        handlers.removeAll { $0.value == nil || $0.value === handler }
        handlers.append(WeakHandler(handler))
        handlers.sort { ($0.value?.eventTapPriority ?? 0) > ($1.value?.eventTapPriority ?? 0) }
        refresh()
    }

    public func remove(_ handler: any EventTapHandler) {
        handlers.removeAll { $0.value == nil || $0.value === handler }
        refresh()
    }

    /// Recomputes the event mask; call when a handler's interests change.
    public func refresh() {
        // A handler reacting to an event (e.g. the switcher closing) must not
        // tear down and rebuild the tap from inside the tap's own callback.
        if isDispatching {
            refreshPending = true
            return
        }
        handlers.removeAll { $0.value == nil }
        var mask: CGEventMask = 0
        for handler in handlers.compactMap(\.value) {
            for type in handler.eventTapTypes {
                mask |= CGEventMask(1) << CGEventMask(type.rawValue)
            }
        }
        guard mask != currentMask || (mask != 0 && tap == nil) else { return }
        stopTap()
        currentMask = mask
        if mask != 0 { startTap(mask: mask) }
    }

    private func startTap(mask: CGEventMask) {
        guard AXIsProcessTrusted() else {
            logger.notice("Event tap deferred: accessibility permission missing")
            if !reportedMissingPermission {
                reportedMissingPermission = true
                DiagnosticsCenter.shared.record(.warning, module: "EventTap", L("diagnostics.eventTap.deferred"))
            }
            return
        }
        reportedMissingPermission = false
        let callback: CGEventTapCallBack = { _, type, event, _ in
            nonisolated(unsafe) let event = event
            // The tap source is scheduled on the main run loop.
            let keep = MainActor.assumeIsolated {
                EventTapManager.shared.process(type: type, event: event)
            }
            return keep ? Unmanaged.passUnretained(event) : nil
        }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: nil
        ) else {
            DiagnosticsCenter.shared.record(.error, module: "EventTap", L("diagnostics.eventTap.failed"))
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        self.source = source
        isRunning = true
    }

    private func stopTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        isRunning = false
    }

    /// Returns false when the event should be swallowed.
    private func process(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            logger.notice("Event tap re-enabled after \(type.rawValue)")
            return true
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventMarker {
            return true
        }
        isDispatching = true
        defer {
            isDispatching = false
            if refreshPending {
                refreshPending = false
                DispatchQueue.main.async { MainActor.assumeIsolated { EventTapManager.shared.refresh() } }
            }
        }
        for handler in handlers.compactMap(\.value) where handler.eventTapTypes.contains(type) {
            if handler.handleTapEvent(event, type: type) == .consume {
                return false
            }
        }
        return true
    }
}

/// Helpers to synthesize input that our own tap will ignore.
public enum SyntheticInput {
    private static func source() -> CGEventSource? {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.userData = EventTapManager.syntheticEventMarker
        return source
    }

    public static func pressKey(_ keyCode: UInt16, modifiers: KeyModifiers = []) {
        let source = source()
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = modifiers.cgFlags
        up?.flags = modifiers.cgFlags
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }

    public static func pressKey(_ combo: KeyCombo) {
        pressKey(combo.keyCode, modifiers: combo.modifiers)
    }

    /// Simulates ⌘V in the frontmost application.
    public static func paste() {
        pressKey(KeyboardLayout.keyCode(for: "v") ?? 9 /* kVK_ANSI_V */, modifiers: .command)
    }

    public static func typeText(_ text: String) {
        let source = source()
        for chunk in text.utf16.chunked(into: 20) {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            var units = Array(chunk)
            event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            event?.post(tap: .cgSessionEventTap)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            up?.post(tap: .cgSessionEventTap)
        }
    }

    public enum MouseButton {
        case left, right, middle
        /// Extra buttons by CGEvent button number (3 = back, 4 = forward).
        case other(Int64)
    }

    public static func click(at point: CGPoint, button: MouseButton = .left, clickCount: Int = 1, modifiers: KeyModifiers = []) {
        let source = source()
        let (downType, upType, cgButton): (CGEventType, CGEventType, CGMouseButton) = switch button {
        case .left: (.leftMouseDown, .leftMouseUp, .left)
        case .right: (.rightMouseDown, .rightMouseUp, .right)
        case .middle: (.otherMouseDown, .otherMouseUp, .center)
        case .other(let number): (.otherMouseDown, .otherMouseUp, CGMouseButton(rawValue: UInt32(number)) ?? .center)
        }
        for index in 1...max(clickCount, 1) {
            let down = CGEvent(mouseEventSource: source, mouseType: downType, mouseCursorPosition: point, mouseButton: cgButton)
            let up = CGEvent(mouseEventSource: source, mouseType: upType, mouseCursorPosition: point, mouseButton: cgButton)
            if case .other(let number) = button {
                down?.setIntegerValueField(.mouseEventButtonNumber, value: number)
                up?.setIntegerValueField(.mouseEventButtonNumber, value: number)
            }
            down?.setIntegerValueField(.mouseEventClickState, value: Int64(index))
            up?.setIntegerValueField(.mouseEventClickState, value: Int64(index))
            down?.flags = modifiers.cgFlags
            up?.flags = modifiers.cgFlags
            down?.post(tap: .cgSessionEventTap)
            up?.post(tap: .cgSessionEventTap)
        }
    }

    public static func moveMouse(to point: CGPoint) {
        let event = CGEvent(mouseEventSource: source(), mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
        event?.post(tap: .cgSessionEventTap)
    }

    /// Posts a pixel-based scroll at `point` (positive `dy` scrolls content up).
    public static func scroll(dx: Int32 = 0, dy: Int32, at point: CGPoint? = nil) {
        guard let event = CGEvent(scrollWheelEvent2Source: source(), units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        if let point { event.location = point }
        event.post(tap: .cgSessionEventTap)
    }
}

extension Collection {
    func chunked(into size: Int) -> [SubSequence] {
        var result: [SubSequence] = []
        var start = startIndex
        while start != endIndex {
            let end = index(start, offsetBy: size, limitedBy: endIndex) ?? endIndex
            result.append(self[start..<end])
            start = end
        }
        return result
    }
}
