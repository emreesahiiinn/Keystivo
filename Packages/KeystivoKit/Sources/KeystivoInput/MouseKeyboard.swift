import AppKit
import Carbon.HIToolbox
import KeystivoCore
import Observation

// MARK: - Scrolling

nonisolated public struct ScrollSettings: Codable, Hashable, Sendable {
    public var isEnabled = false
    /// Reverse wheel direction for mice only; trackpads keep the system setting.
    public var reverseMouseVertical = true
    public var reverseMouseHorizontal = false
    /// Multiplier applied to wheel ticks (1 = system speed).
    public var mouseSpeed = 1.0
    /// Turn discrete wheel ticks into smooth, animated pixel scrolling.
    public var smoothScrolling = true
    /// 0.05 (long glide) … 0.5 (snappy).
    public var smoothness = 0.2
    public var excludedApps: [String] = []
    public init() {}
}

/// Per-device scroll direction, speed and smooth scrolling (Mos / Scroll Reverser style).
@Observable
public final class ScrollEngine: EventTapHandler {
    public static let shared = ScrollEngine()

    public var settings = ScrollSettings() {
        didSet { EventTapManager.shared.refresh() }
    }

    @ObservationIgnored private var pending = CGVector.zero
    @ObservationIgnored private var location = CGPoint.zero
    @ObservationIgnored private var timer: Timer?

    public init() {}

    public var eventTapPriority: Int { 30 }
    public var eventTapTypes: Set<CGEventType> { settings.isEnabled ? [.scrollWheel] : [] }

    public func handleTapEvent(_ event: CGEvent, type: CGEventType) -> EventTapDisposition {
        // Trackpads and Magic Mouse send continuous (pixel) events; leave them alone.
        guard event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 else { return .pass }
        if let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, settings.excludedApps.contains(bundleID) {
            return .pass
        }
        let vertical: Double = settings.reverseMouseVertical ? -1 : 1
        let horizontal: Double = settings.reverseMouseHorizontal ? -1 : 1
        let speed = max(0.1, settings.mouseSpeed)

        if settings.smoothScrolling {
            let lines1 = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
            let lines2 = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
            // Point deltas already include system acceleration; fall back to lines.
            let points1 = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            let points2 = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
            let dy = (points1 != 0 ? points1 : lines1 * 10) * 4 * speed * vertical
            let dx = (points2 != 0 ? points2 : lines2 * 10) * 4 * speed * horizontal
            enqueue(dx: dx, dy: dy, at: event.location)
            return .consume
        }

        for (axis, fixed, point, sign) in [
            (CGEventField.scrollWheelEventDeltaAxis1, CGEventField.scrollWheelEventFixedPtDeltaAxis1, CGEventField.scrollWheelEventPointDeltaAxis1, vertical),
            (.scrollWheelEventDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventPointDeltaAxis2, horizontal),
        ] {
            let lines = event.getIntegerValueField(axis)
            event.setIntegerValueField(axis, value: Int64((Double(lines) * speed * sign).rounded()))
            event.setDoubleValueField(fixed, value: event.getDoubleValueField(fixed) * speed * sign)
            event.setDoubleValueField(point, value: event.getDoubleValueField(point) * speed * sign)
        }
        return .pass
    }

    // MARK: Smooth scrolling

    private func enqueue(dx: Double, dy: Double, at point: CGPoint) {
        // Reversing direction cancels any remaining glide immediately.
        if (dy > 0) != (pending.dy > 0), pending.dy != 0 { pending.dy = 0 }
        if (dx > 0) != (pending.dx > 0), pending.dx != 0 { pending.dx = 0 }
        pending.dx += dx
        pending.dy += dy
        location = point
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func step() {
        let factor = min(max(settings.smoothness, 0.05), 0.6)
        var dx = pending.dx * factor
        var dy = pending.dy * factor
        if abs(pending.dy) < 1 { dy = pending.dy }
        if abs(pending.dx) < 1 { dx = pending.dx }
        pending.dx -= dx
        pending.dy -= dy
        let x = Int32(clamping: dx.rounded().safeInt)
        let y = Int32(clamping: dy.rounded().safeInt)
        if x != 0 || y != 0 {
            let source = CGEventSource(stateID: .hidSystemState)
            source?.userData = EventTapManager.syntheticEventMarker
            if let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0) {
                event.location = location
                event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                event.post(tap: .cgSessionEventTap)
            }
        }
        if abs(pending.dx) < 0.5, abs(pending.dy) < 0.5 {
            pending = .zero
            timer?.invalidate()
            timer = nil
        }
    }
}

// MARK: - Mouse buttons

/// Extra mouse buttons mapped to actions (e.g. back/forward everywhere).
nonisolated public struct MouseButtonBinding: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var button: MouseGestureButton
    public var modifiers: KeyModifiers = []
    public var actions: [ActionInvocation]
    public var appBundleIDs: [String] = []
    public var isEnabled = true

    public init(button: MouseGestureButton, actions: [ActionInvocation]) {
        self.button = button
        self.actions = actions
    }
}

/// Runs actions for middle/side mouse buttons (SteerMouse / USB Overdrive style).
@Observable
public final class MouseButtonEngine: EventTapHandler {
    public static let shared = MouseButtonEngine()

    public var bindings: [MouseButtonBinding] = [] {
        didSet { EventTapManager.shared.refresh() }
    }
    /// Buttons reserved for mouse gestures are skipped.
    public var reservedButtons: Set<MouseGestureButton> = []
    @ObservationIgnored public var perform: (@MainActor ([ActionInvocation]) -> Void)?
    @ObservationIgnored private var swallowUp: Int64?

    public init() {}

    public var eventTapPriority: Int { 45 }
    public var eventTapTypes: Set<CGEventType> {
        bindings.contains(where: \.isEnabled) ? [.otherMouseDown, .otherMouseUp] : []
    }

    public func handleTapEvent(_ event: CGEvent, type: CGEventType) -> EventTapDisposition {
        let number = event.getIntegerValueField(.mouseEventButtonNumber)
        if type == .otherMouseUp {
            if swallowUp == number { swallowUp = nil; return .consume }
            return .pass
        }
        guard let button = MouseGestureButton.allCases.first(where: { $0.buttonNumber == number }),
              button != .right, !reservedButtons.contains(button) else { return .pass }
        let modifiers = KeyModifiers(event.flags).subtracting(.function)
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let candidates = bindings.filter { $0.isEnabled && $0.button == button && $0.modifiers == modifiers }
        let binding = candidates.first { binding in frontmost.map(binding.appBundleIDs.contains) == true }
            ?? candidates.first { $0.appBundleIDs.isEmpty }
        guard let binding else { return .pass }
        swallowUp = number
        let actions = binding.actions
        DispatchQueue.main.async { [weak self] in self?.perform?(actions) }
        return .consume
    }
}

// MARK: - Hyper key & key remapping

nonisolated public enum HyperKeyTrigger: String, Codable, Sendable, CaseIterable {
    case capsLock, rightCommand, rightOption, f19
    public var titleKey: String { "hyper.trigger.\(rawValue)" }

    /// HID usage (keyboard page) of the physical key.
    public var hidUsage: UInt64 {
        switch self {
        case .capsLock: 0x39
        case .rightCommand: 0xE7
        case .rightOption: 0xE6
        case .f19: 0x6E
        }
    }
}

nonisolated public struct HyperKeySettings: Codable, Hashable, Sendable {
    public var isEnabled = false
    public var trigger: HyperKeyTrigger = .capsLock
    /// ⌃⌥⇧⌘ (Hyper) or ⌃⌥⌘ ("Meh" without Shift).
    public var includesShift = true
    /// A quick tap alone sends Escape (great for Vim users).
    public var tapSendsEscape = true
    public init() {}
}

/// A single physical-key remap applied with `hidutil` (no driver, no root).
nonisolated public struct KeyRemap: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var from: UInt64
    public var to: UInt64
    /// Restrict to one device (vendor/product); nil = all keyboards.
    public var vendorID: Int?
    public var productID: Int?
    public var isEnabled = true

    public init(from: UInt64, to: UInt64, vendorID: Int? = nil, productID: Int? = nil) {
        self.from = from
        self.to = to
        self.vendorID = vendorID
        self.productID = productID
    }
}

/// Named HID keys offered in the remapping editor.
nonisolated public enum HIDKey: UInt64, CaseIterable, Sendable, Identifiable {
    case capsLock = 0x39, escape = 0x29, tab = 0x2B, grave = 0x35, isoSection = 0x64
    case leftControl = 0xE0, leftShift = 0xE1, leftOption = 0xE2, leftCommand = 0xE3
    case rightControl = 0xE4, rightShift = 0xE5, rightOption = 0xE6, rightCommand = 0xE7
    case f13 = 0x68, f14 = 0x69, f15 = 0x6A, f16 = 0x6B, f17 = 0x6C, f18 = 0x6D, f19 = 0x6E
    case deleteForward = 0x4C, home = 0x4A, end = 0x4D

    public var id: UInt64 { rawValue }
    public var titleKey: String { "hidkey.\(self)" }
}

/// Builds and applies `hidutil` key mappings. Pure JSON generation is testable;
/// applying only touches the current login session (reset on logout/restart).
public enum KeyRemapper {
    nonisolated public static let keyboardPage: UInt64 = 0x7_0000_0000

    /// Hyper key uses F18 as an intermediate key the event tap understands.
    nonisolated public static let hyperIntermediate = HIDKey.f18.rawValue

    nonisolated public static func mappingJSON(_ pairs: [(UInt64, UInt64)]) -> String {
        let entries = pairs.map { from, to in
            "{\"HIDKeyboardModifierMappingSrc\":\(keyboardPage | from),\"HIDKeyboardModifierMappingDst\":\(keyboardPage | to)}"
        }
        return "{\"UserKeyMapping\":[\(entries.joined(separator: ","))]}"
    }

    nonisolated public static func matchingJSON(vendorID: Int, productID: Int) -> String {
        "{\"VendorID\":\(vendorID),\"ProductID\":\(productID)}"
    }

    /// Devices that got their own mapping last time, so `reset` can clear them too.
    nonisolated(unsafe) private static var mappedDevices: Set<[Int]> = []

    /// Global mappings plus a device's own; the device's win for the same key.
    /// (A per-device mapping replaces the global one on that keyboard, so it must include it.)
    nonisolated public static func merged(global: [(UInt64, UInt64)], device: [(UInt64, UInt64)]) -> [(UInt64, UInt64)] {
        let overridden = Set(device.map(\.0))
        return global.filter { !overridden.contains($0.0) } + device
    }

    /// Applies global remaps (+ the hyper trigger) and per-device remaps.
    public static func apply(remaps: [KeyRemap], hyper: HyperKeySettings) async throws {
        var global: [(UInt64, UInt64)] = remaps.filter { $0.isEnabled && $0.vendorID == nil }.map { ($0.from, $0.to) }
        if hyper.isEnabled, !global.contains(where: { $0.0 == hyper.trigger.hidUsage }) {
            global.append((hyper.trigger.hidUsage, hyperIntermediate))
        }
        try await run(["property", "--set", mappingJSON(global)])
        let perDevice = Dictionary(grouping: remaps.filter { $0.isEnabled && $0.vendorID != nil && $0.productID != nil }) {
            [$0.vendorID!, $0.productID!]
        }
        // Devices whose own mapping was removed go back to the global one.
        for device in mappedDevices where perDevice[device] == nil {
            try? await run(["property", "--matching", matchingJSON(vendorID: device[0], productID: device[1]), "--set", mappingJSON(global)])
        }
        for (device, remaps) in perDevice {
            let pairs = merged(global: global, device: remaps.map { ($0.from, $0.to) })
            try await run(["property", "--matching", matchingJSON(vendorID: device[0], productID: device[1]), "--set", mappingJSON(pairs)])
        }
        mappedDevices = Set(perDevice.keys)
    }

    /// Removes every mapping Keystivo installed for this session.
    public static func reset() async {
        try? await run(["property", "--set", mappingJSON([])])
        for device in mappedDevices {
            try? await run(["property", "--matching", matchingJSON(vendorID: device[0], productID: device[1]), "--set", mappingJSON([])])
        }
        mappedDevices = []
    }

    /// For quitting: clears every mapping right away, blocking briefly. (An async
    /// reset can't run while the main thread waits for it.)
    nonisolated public static func resetNow() {
        runNow(["property", "--set", mappingJSON([])])
        for device in mappedDevices {
            runNow(["property", "--matching", matchingJSON(vendorID: device[0], productID: device[1]), "--set", mappingJSON([])])
        }
        mappedDevices = []
    }

    nonisolated private static func runNow(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
    }

    private static func run(_ arguments: [String]) async throws {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 { throw ActionError.failed("hidutil exited with \(process.terminationStatus)") }
        }.value
    }
}

/// Turns the intermediate F18 key into a Hyper modifier (⌃⌥⇧⌘) for any key
/// pressed while it's held; a lone tap can send Escape.
@Observable
public final class HyperKeyEngine: EventTapHandler {
    public static let shared = HyperKeyEngine()

    public var settings = HyperKeySettings() {
        didSet { EventTapManager.shared.refresh() }
    }

    @ObservationIgnored private var isHeld = false
    @ObservationIgnored private var usedAsModifier = false
    @ObservationIgnored private var pressedAt = Date.distantPast

    public init() {}

    // Runs before everything (including the shortcut recorder) so Hyper chords are seen everywhere.
    public var eventTapPriority: Int { 6000 }
    public var eventTapTypes: Set<CGEventType> { settings.isEnabled ? [.keyDown, .keyUp] : [] }

    private var hyperFlags: CGEventFlags {
        var flags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        if settings.includesShift { flags.insert(.maskShift) }
        return flags
    }

    public func handleTapEvent(_ event: CGEvent, type: CGEventType) -> EventTapDisposition {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if keyCode == kVK_F18 {
            if type == .keyDown {
                if !isHeld {
                    isHeld = true
                    usedAsModifier = false
                    pressedAt = .now
                }
            } else {
                isHeld = false
                if settings.tapSendsEscape, !usedAsModifier, Date.now.timeIntervalSince(pressedAt) < 0.3 {
                    SyntheticInput.pressKey(UInt16(kVK_Escape))
                }
            }
            return .consume
        }
        if isHeld {
            usedAsModifier = true
            event.flags = event.flags.union(hyperFlags)
        }
        return .pass
    }
}
